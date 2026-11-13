// 参考断流守卫（playout lack）离线验证：直接驱动 ResidualGate，不依赖真机录音。
//
// 场景：播放停顿（网络断层）→ 参考环冻结在陈旧远端字节上 → 本端在停顿期说话。
//   - 无守卫：能量兜底拿陈旧参考判决，本端电平低于陈旧远端 14dB → 误判「残余」压死。
//   - 有守卫：距上次 pushReference 超过 refLackFrames → 停用能量兜底 → rho 路径
//     判本端与陈旧远端不相关 → 直通。
//
// 用法：dart run tool/gate_reflack_test.dart
import 'dart:io';
import 'dart:math' as math;
import 'dart:typed_data';

import 'package:my_flutter_app/demo/aec3_room/residual_gate.dart';

const int sr = 48000;
const int frame = 480; // 10ms 样本数
const int frameBytes = frame * 2; // 10ms int16-LE 字节数 = 960

/// n 个样本、freq/amp/phase 的 int16-LE 单声道正弦，返回 n*2 字节。
Uint8List tone(double freq, double amp, int n, double phase) {
  final out = ByteData(n * 2);
  for (int i = 0; i < n; i++) {
    final double v = amp * math.sin(2 * math.pi * freq * i / sr + phase);
    out.setInt16(i * 2, v.round().clamp(-32768, 32767), Endian.little);
  }
  return out.buffer.asUint8List();
}

double rmsDb(Uint8List b) {
  final bd = ByteData.sublistView(b);
  double s = 0;
  final n = b.length ~/ 2;
  for (int i = 0; i < n; i++) {
    final double v = bd.getInt16(i * 2, Endian.little).toDouble();
    s += v * v;
  }
  return 20 * math.log(math.sqrt(s / n) / 32768 + 1e-12) / math.ln10;
}

/// 衰减一份 int16-LE 字节。
Uint8List atten(Uint8List src, double k) {
  final e = ByteData.sublistView(src);
  final c = ByteData(src.length);
  for (int i = 0; i < src.length ~/ 2; i++) {
    c.setInt16(i * 2,
        (e.getInt16(i * 2, Endian.little) * k).round().clamp(-32768, 32767),
        Endian.little);
  }
  return c.buffer.asUint8List();
}

/// 跑一遍：refLackFrames 大 = 守卫关；= 40 = 守卫开。返回停顿期本端段被压制的 dB。
double run({required int refLackFrames, required bool verbose}) {
  final gate = ResidualGate(
    sampleRate: sr,
    frameSamples: frame,
    assumedDelayMs: 150,
    refLackFrames: refLackFrames,
  );

  const int lagSamples = 150 * sr ~/ 1000; // 7200，回声延迟
  const int lagBytes = lagSamples * 2;
  const int phase1Frames = 250; // 2.5s：锁定 + 收敛
  const int stallFrames = 120; // 1.2s 播放停顿

  // 远端参考：300Hz 响音（amp 11000 ≈ -9.5dBFS），长度覆盖 phase1 + 余量
  final int totalSamples = lagSamples + frame * (phase1Frames + 60);
  final refSig = tone(300, 11000, totalSamples, 0);

  int refFed = 0; // 已喂参考的字节数
  double stallOutSq = 0;
  int stallOutN = 0;
  double stallInDb = 0;

  for (int f = 0; f < phase1Frames + stallFrames; f++) {
    final bool stalling = f >= phase1Frames;

    // 参考泵：phase1 每帧喂 10ms；停顿期不喂（模拟播放停）
    if (!stalling && refFed + frameBytes <= refSig.length) {
      gate.pushReference(Uint8List.sublistView(refSig, refFed, refFed + frameBytes));
      refFed += frameBytes;
    }

    Uint8List cap;
    if (!stalling) {
      // 回声 = 参考延迟 lagBytes 的同频信号，衰减 0.28（≈ -11dB，rho 高）
      final int src = refFed - lagBytes;
      if (src >= 0 && src + frameBytes <= refSig.length) {
        cap = atten(Uint8List.sublistView(refSig, src, src + frameBytes), 0.28);
      } else {
        cap = tone(300, 3000, frame, 0);
      }
    } else {
      // 停顿期本端语音：1100Hz amp 1000（≈ -30dBFS，比陈旧远端 -9.5dBFS 低 >14dB）
      cap = tone(1100, 1000, frame, f * 0.7);
      if (f == phase1Frames) stallInDb = rmsDb(cap);
    }

    final out = gate.process(cap);

    // 量停顿期稳态（跳过守卫触发头 45 帧 = refLackFrames 40 + 平滑）
    if (stalling && f > phase1Frames + 45) {
      final obd = ByteData.sublistView(out);
      for (int i = 0; i < frame; i++) {
        final double v = obd.getInt16(i * 2, Endian.little).toDouble();
        stallOutSq += v * v;
        stallOutN++;
      }
    }
  }

  final outDb = stallOutN == 0
      ? -240.0
      : 20 * math.log(math.sqrt(stallOutSq / stallOutN) / 32768 + 1e-12) / math.ln10;
  if (verbose) {
    stdout.writeln('  refLackFrames=$refLackFrames  本端输入=${stallInDb.toStringAsFixed(1)}dB  '
        '停顿期输出=${outDb.toStringAsFixed(1)}dB  '
        '压制=${(stallInDb - outDb).toStringAsFixed(1)}dB  '
        'converged=${gate.converged} refLacking=${gate.refLacking}');
  }
  return stallInDb - outDb;
}

void main() {
  stdout.writeln('== 参考断流守卫验证：播放停顿期本端语音是否被误压 ==');
  stdout.writeln('[守卫关] refLackFrames=100000（永不触发）:');
  final off = run(refLackFrames: 100000, verbose: true);
  stdout.writeln('[守卫开] refLackFrames=40（400ms 断流即停用能量兜底）:');
  final on = run(refLackFrames: 40, verbose: true);
  stdout.writeln('');
  stdout.writeln('结论：守卫关时停顿期本端被压 ${off.toStringAsFixed(1)}dB（误杀）；'
      '守卫开时压 ${on.toStringAsFixed(1)}dB。');
  if (off - on > 6.0) {
    stdout.writeln('✅ 守卫生效：停顿期本端语音多保留 ${(off - on).toStringAsFixed(1)}dB。');
  } else {
    stdout.writeln('⚠️ 守卫效果不明显（差 ${(off - on).toStringAsFixed(1)}dB），需复核。');
  }
}
