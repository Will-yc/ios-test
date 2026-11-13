// 能量主导判据（2026-11-13 回归修复）离线回归验证。
//
// 不依赖真机录音：用确定性合成信号复现「lag 搜不准 → 纯回声 rho 偏低」的回归，
// 驱动修复后的 ResidualGate，断言成品 bar：回声硬压、本端/双讲保留。
//
// 回归机理（修复前两条漏声路径，离线对照已实测）：
//   1. rho<=rhoNone 无条件 g=1.0：lag 不准时纯回声 rho≈0，响回声原样漏出(压 0.4dB)。
//   2. 近端 VAD 只看 rho<0.15+电平：misaligned 回声 rho 偏低被误判双讲 → 软底放行。
//   且 rho 略高于 rhoNone 落在过渡区时线性增益≈1，同样漏（旧修复只补 rho<=rhoNone
//   分支，实测错位回声 rho≈0.07 只压 5.8dB）。
// 修复（能量主导，不依赖 lag 精度，成品优先）：下行在响 + 参考新鲜 + 采集≤参考
//   → 回声主导 → 提到所有 rho 分支之前直接 gFloor；VAD 追加非回声主导(采集>参考)。
//
// 合成信号说明：参考 R 与回声源 R2 用不同噪声种子但**同一音节包络、同一电平**。
// 这模拟「门搜到的 lag 处参考窗与真实回声错位」——波形互相关 rho≈0，而采集电平
// 仍≤参考（回声是衰减副本）。包络相同保证粗搜仍指向原 lag、波形复筛拒绝搬家，
// lag 稳定、rho 持续偏低，正是回归现场。本端 L 用第三种子。
//
// 用法：dart run tool/gate_energy_test.dart
import 'dart:io';
import 'dart:math' as math;
import 'dart:typed_data';

import 'package:my_flutter_app/demo/aec3_room/residual_gate.dart';

const int sr = 48000;
const int frame = 480; // 10ms
const int frameBytes = frame * 2;
const int lagFrames = 15; // 150ms 回声延迟
const int lagSamples = lagFrames * frame; // 7200

// 确定性 LCG 噪声（[-1,1)），种子独立。
class Noise {
  Noise(int seed) : _s = seed & 0x7fffffff;
  int _s;
  double next() {
    _s = (_s * 1103515245 + 12345) & 0x7fffffff;
    return (_s / 0x7fffffff) * 2.0 - 1.0;
  }
}

// 3Hz 音节包络（0.35~1.0），让包络粗搜能唯一锁定 lag。
double env(int sampleIdx) {
  final double t = sampleIdx / sr;
  return 0.35 + 0.65 * (0.5 + 0.5 * math.sin(2 * math.pi * 3.0 * t));
}

// 生成 totalSamples 个样本的带包络噪声，amp 为峰值系数。
Float64List sig(int seed, int totalSamples, double amp) {
  final n = Noise(seed);
  final out = Float64List(totalSamples);
  for (int i = 0; i < totalSamples; i++) {
    out[i] = n.next() * env(i) * amp;
  }
  return out;
}

Uint8List toFrame(Float64List src, int startSample, double gain) {
  final out = ByteData(frameBytes);
  for (int i = 0; i < frame; i++) {
    final int j = startSample + i;
    final double v = (j >= 0 && j < src.length) ? src[j] * gain : 0.0;
    out.setInt16(i * 2, v.round().clamp(-32768, 32767), Endian.little);
  }
  return out.buffer.asUint8List();
}

Uint8List mix(Uint8List a, Uint8List b) {
  final ab = ByteData.sublistView(a);
  final bb = ByteData.sublistView(b);
  final out = ByteData(frameBytes);
  for (int i = 0; i < frame; i++) {
    final int v =
        ab.getInt16(i * 2, Endian.little) + bb.getInt16(i * 2, Endian.little);
    out.setInt16(i * 2, v.clamp(-32768, 32767), Endian.little);
  }
  return out.buffer.asUint8List();
}

// 每段 300 帧(3s)。稳态取后 200 帧(跳过前 1s 平滑/瞬态)。
const int phaseFrames = 300;
const int steadySkip = 100;

class PhaseResult {
  PhaseResult(this.label);
  final String label;
  double inSq = 0, outSq = 0;
  int n = 0;
  int nearEndHits = 0, frames = 0;
  double rhoSum = 0;
  void add(Uint8List inF, Uint8List outF, bool nearEnd, double rho) {
    final ib = ByteData.sublistView(inF);
    final ob = ByteData.sublistView(outF);
    for (int i = 0; i < frame; i++) {
      final double a = ib.getInt16(i * 2, Endian.little).toDouble();
      final double b = ob.getInt16(i * 2, Endian.little).toDouble();
      inSq += a * a;
      outSq += b * b;
      n++;
    }
    if (nearEnd) nearEndHits++;
    frames++;
    rhoSum += rho;
  }

  double get inDb => n == 0
      ? -240
      : 20 * math.log(math.sqrt(inSq / n) / 32768 + 1e-12) / math.ln10;
  double get outDb => n == 0
      ? -240
      : 20 * math.log(math.sqrt(outSq / n) / 32768 + 1e-12) / math.ln10;
  double get supp => inDb - outDb;
  double get rhoAvg => frames == 0 ? 0 : rhoSum / frames;
  double get nePct => frames == 0 ? 0 : 100.0 * nearEndHits / frames;
}

const List<String> _labels = [
  'P0 收敛(干净回声)',
  'P1 纯回声·低rho',
  'P2 纯本端',
  'P3 双讲(采集>参考)',
  'P4 响回声·采集≈参考',
];

List<PhaseResult> run() {
  final gate = ResidualGate(
      sampleRate: sr, frameSamples: frame, assumedDelayMs: 150);
  const int totalFrames = phaseFrames * 5;
  const int totalSamples = totalFrames * frame + lagSamples + frame;
  // R: 参考/回声源(种子1)；R2: 错位回声源(种子2，同包络同电平)；L: 本端(种子3)
  final r = sig(1, totalSamples, 18000);
  final r2 = sig(2, totalSamples, 18000);
  final l = sig(3, totalSamples, 18000);

  final results = List.generate(5, (i) => PhaseResult(_labels[i]));
  int refFedSamples = 0;
  bool convergedAtEnd = false;
  int lagAtEnd = -1;

  for (int f = 0; f < totalFrames; f++) {
    final int phase = f ~/ phaseFrames;
    final int capStart = f * frame;

    // 参考泵：P2(本端)喂静音，其余喂 R（每帧 10ms，与采集同步推进）。
    final Uint8List refFrame =
        phase == 2 ? Uint8List(frameBytes) : toFrame(r, refFedSamples, 1.0);
    gate.pushReference(refFrame);
    refFedSamples += frame;

    Uint8List cap;
    switch (phase) {
      case 0: // 收敛：干净回声 R 延迟 150ms，衰减 0.3 → rho 高，锁定 lag
        cap = toFrame(r, capStart - lagSamples, 0.30);
        break;
      case 1: // 纯回声·低 rho：错位回声源 R2，衰减 0.3（采集≤参考）
        cap = toFrame(r2, capStart - lagSamples, 0.30);
        break;
      case 2: // 纯本端：参考静音，本端 L 衰减 0.5（≈ -16dBFS）
        cap = toFrame(l, capStart, 0.50);
        break;
      case 3: // 双讲：本端 L 明显响(3.0，采集>参考) + 弱回声 R(0.05) → rho 低
        cap = mix(toFrame(l, capStart, 3.0),
            toFrame(r, capStart - lagSamples, 0.05));
        break;
      default: // 响回声·采集≈参考：错位 R2 衰减 0.28（≈ 参考电平，rho 低）
        cap = toFrame(r2, capStart - lagSamples, 0.28);
        break;
    }

    final out = gate.process(cap);
    final int pf = f % phaseFrames;
    if (pf >= steadySkip) {
      results[phase].add(cap, out, gate.lastNearEnd, gate.lastRho);
    }
    if (f == phaseFrames - 1) {
      convergedAtEnd = gate.converged;
      lagAtEnd = gate.currentLagMs;
      stdout.writeln('  [收敛段末] lag=${lagAtEnd}ms converged=$convergedAtEnd '
          'rho=${gate.lastRho.toStringAsFixed(3)}');
    }
  }
  if (!convergedAtEnd || (lagAtEnd - 150).abs() > 20) {
    stderr.writeln('⚠️ 收敛异常：lag=$lagAtEnd converged=$convergedAtEnd');
  }
  return results;
}

void main() {
  stdout.writeln('== 能量主导判据回归验证：回声硬压、本端/双讲保留 ==');
  final rs = run();
  for (final r in rs) {
    stdout.writeln('  ${r.label}: in=${r.inDb.toStringAsFixed(1)}dB '
        'out=${r.outDb.toStringAsFixed(1)}dB 压制=${r.supp.toStringAsFixed(1)}dB '
        'rho均值=${r.rhoAvg.toStringAsFixed(3)} 近端VAD=${r.nePct.toStringAsFixed(0)}%');
  }

  stdout.writeln('');
  stdout.writeln('== 判定 ==');
  bool ok = true;
  void check(String name, bool cond, String detail) {
    stdout.writeln('${cond ? "✅" : "❌"} $name  $detail');
    if (!cond) ok = false;
  }

  check('P0 干净回声硬压≥20dB', rs[0].supp >= 20.0,
      '压制=${rs[0].supp.toStringAsFixed(1)}dB');
  // 回归核心：lag 不准、rho 偏低（含过渡区）的纯回声也必须硬压。
  check('P1 纯回声低rho 硬压≥20dB', rs[1].supp >= 20.0,
      '压制=${rs[1].supp.toStringAsFixed(1)}dB rho=${rs[1].rhoAvg.toStringAsFixed(3)}');
  check('P4 响回声采集≈参考 硬压≥20dB', rs[4].supp >= 20.0,
      '压制=${rs[4].supp.toStringAsFixed(1)}dB');
  // 本端/双讲不得误压（成品只本端、自然底噪）。
  check('P2 纯本端直通(压制<3dB)', rs[2].supp < 3.0,
      '压制=${rs[2].supp.toStringAsFixed(1)}dB');
  check('P3 双讲保留本端(压制<12dB)', rs[3].supp < 12.0,
      '压制=${rs[3].supp.toStringAsFixed(1)}dB');
  check('P3 双讲判近端(VAD>50%)', rs[3].nePct > 50.0,
      'VAD命中=${rs[3].nePct.toStringAsFixed(0)}%');

  stdout.writeln('');
  stdout.writeln(ok ? '✅ 全部通过：回声硬压、本端/双讲保留。' : '❌ 有判定未通过，需复核。');
  exit(ok ? 0 : 1);
}