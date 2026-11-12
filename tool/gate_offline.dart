// 相关门（ResidualGate）离线仿真：用真机录音直接回放门的判决路径。
//
// 用法（桌面 Linux，无需 native 库）：
//   dart run tool/gate_offline.dart <capture.pcm> <farend.wav> [echo_lag_ms] [ref_lead_ms]
//
// 数据来源（2026-11-12 真机复测）：
//   capture  = Android 侧 AEC 前原始采集 `_raw.pcm`（48k/16bit/mono）
//   farend   = 对端（iOS）成品 wav —— 它就是 Android 下行播放的内容代理
//   echo_lag = 对端语音出现在 capture 里的文件时间轴延迟（离线互相关实测 3027ms）
//   ref_lead = 参考流比回声早到多少毫秒 = echo_lag - 真实播放缓冲(取 150ms)
//
// 期望：门自搜出 lag≈150ms；「纯回声段」压制 ≥20dB；「纯本端段」≈0dB（直通）。
import 'dart:io';
import 'dart:math' as math;
import 'dart:typed_data';

import 'package:my_flutter_app/demo/aec3_room/residual_gate.dart';

void main(List<String> args) {
  if (args.length < 2) {
    stderr.writeln('用法: dart run tool/gate_offline.dart <capture.pcm> '
        '<farend.wav> [echo_lag_ms=3027] [ref_lead_ms=2877]');
    exit(2);
  }
  final int refLeadMs = args.length > 3 ? int.parse(args[3]) : 2877;

  final Uint8List cap = File(args[0]).readAsBytesSync();
  final Uint8List refAll = File(args[1]).readAsBytesSync();
  final Uint8List ref = Uint8List.sublistView(refAll, 44); // 跳过 wav 头

  const int frameBytes = 960; // 10ms @48k int16
  const int secBytes = frameBytes * 100;
  final gate = ResidualGate();

  int refFedBytes = 0;
  final int nSec = cap.length ~/ secBytes + 1;
  final List<double> inSq = List.filled(nSec, 0);
  final List<double> outSq = List.filled(nSec, 0);
  final List<int> inN = List.filled(nSec, 0);
  final List<int> lagSec = List.filled(nSec, -1);
  final ByteData capBd = ByteData.sublistView(cap);

  for (int t = 0; t + frameBytes <= cap.length; t += frameBytes) {
    // 参考泵：capture 时间轴 t 时刻，参考已喂到 (t - refLead)。1ms = 96 字节。
    final int refTarget =
        math.max(0, (t - refLeadMs * 96) ~/ frameBytes) * frameBytes;
    while (refFedBytes < refTarget && refFedBytes + frameBytes <= ref.length) {
      gate.pushReference(
        Uint8List.sublistView(ref, refFedBytes, refFedBytes + frameBytes),
      );
      refFedBytes += frameBytes;
    }
    final frame = Uint8List.sublistView(cap, t, t + frameBytes);
    final out = gate.process(frame);
    final ByteData outBd = ByteData.sublistView(out);

    final int s = t ~/ secBytes;
    double si = 0, so = 0;
    for (int i = 0; i < frameBytes ~/ 2; i++) {
      final double a = capBd.getInt16(t + i * 2, Endian.little).toDouble();
      final double b = outBd.getInt16(i * 2, Endian.little).toDouble();
      si += a * a;
      so += b * b;
    }
    inSq[s] += si;
    outSq[s] += so;
    inN[s] += frameBytes ~/ 2;
    lagSec[s] = gate.currentLagMs;
  }

  double db(double sq, int n) => n == 0
      ? -240.0
      : 20 * math.log(math.sqrt(sq / n) / 32768 + 1e-12) / math.ln10;

  stdout.writeln('lag 轨迹(每秒): ${lagSec.take(20).toList()} ...');
  void win(String label, int a, int b) {
    double si = 0, so = 0;
    int n = 0;
    for (int s = a; s < b && s < nSec; s++) {
      si += inSq[s];
      so += outSq[s];
      n += inN[s];
    }
    if (n == 0) return;
    final din = db(si, n), dout = db(so, n);
    stdout.writeln('$label $a~${b}s: in=${din.toStringAsFixed(1)}dB '
        'out=${dout.toStringAsFixed(1)}dB 压制=${(din - dout).toStringAsFixed(1)}dB');
  }

  win('纯回声段', 43, 46);
  win('纯回声段2', 52, 57);
  win('纯本端段', 27, 31);
  win('混合段', 3, 10);
  stdout.writeln('最终 lag=${gate.currentLagMs}ms '
      'rho=${gate.lastRho.toStringAsFixed(3)}');
}
