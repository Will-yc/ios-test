import 'dart:isolate';
import 'dart:math' as math;
import 'dart:typed_data';

import 'loop_gain_guard.dart' show Fft;

/// 延迟标定：播放一段已知的 PN 序列，采集 **AEC 前**的原始字节，
/// 用 FFT 互相关直接算出「送进播放器 → 扬声器 → 空气 → 麦克风」的真实延迟。
///
/// 这替代了之前靠 `REF_DELAY_MS` 编译期常量猜 iOS 延迟的做法。
/// 判据与 TRTC 的「时间戳粗对齐 + 谱指纹精对齐」同源：用一个自相关极尖的
/// 宽带序列，峰位置就是环路延迟，处理增益 10log10(N) ≈ 50dB，
/// 即使回声被 AEC/空气衰减几十 dB 也能稳定检出。
class DelayEstimate {
  const DelayEstimate({
    required this.lagMs,
    required this.correlation,
    required this.peakToSide,
    required this.sampleRate,
  });

  /// 端到端延迟（ms）：从「参考样本进入播放缓冲」到「被麦克风采到」
  final double lagMs;
  final double correlation;
  final double peakToSide;
  final int sampleRate;

  /// 参考补偿建议：留 100ms 正延迟给 AEC3 自己的延迟估计器（宁可欠补）。
  int get suggestedRefDelayMs =>
      math.max(0, (lagMs - 100).round() ~/ 10 * 10);

  bool get reliable => correlation > 0.02 && peakToSide > 1.8;

  @override
  String toString() =>
      'lag=${lagMs.toStringAsFixed(1)}ms corr=${correlation.toStringAsFixed(3)} '
      'p2s=${peakToSide.toStringAsFixed(2)} → 建议补偿 ${suggestedRefDelayMs}ms';
}

/// 生成 48k/mono/int16 LE 的 PN 标定信号。
///
/// 幅度默认 0.15（约 -16dBFS）：上班时间不吵，同时 2s 序列的处理增益
/// 足够把回声从本底里拉出来。序列做了 3 点平滑，避免纯白噪过于刺耳。
Uint8List buildCalibSignal({
  int sampleRate = 48000,
  int seconds = 2,
  double amplitude = 0.15,
}) {
  final int n = sampleRate * seconds;
  final out = Uint8List(n * 2);
  final bd = ByteData.view(out.buffer);
  // PN 源必须用**长周期**随机：之前用 15 级 LFSR（周期仅 32767 样本 =
  // 682.6ms），互相关在 corr[682.6ms − 真lag] 出现比真峰还强的周期镜像，
  // 实测把 350ms 测成 332.6ms、130ms 测成 552.6ms。改用 LCG 的高位
  // （最低位周期只有 2，会退化成方波），周期 2^31 远超搜索窗。
  int seed = 0x1A2B3C4D;
  double s0 = 0;
  double s1 = 0;
  for (int i = 0; i < n; i++) {
    seed = (seed * 1103515245 + 12345) & 0x7FFFFFFF;
    final double pn = ((seed >> 16) & 1) == 1 ? 1.0 : -1.0;
    // 3 点滑动平均（低通，削掉最刺耳的高频，不影响自相关峰）
    final double v = (pn + s0 + s1) / 3.0;
    s1 = s0;
    s0 = pn;
    final int sample = (v * amplitude * 32767).round().clamp(-32768, 32767);
    bd.setInt16(i * 2, sample, Endian.little);
  }
  return out;
}

/// 在独立 isolate 里跑互相关（131072 点 FFT，主 isolate 会卡 UI）。
Future<DelayEstimate?> estimateDelay(
  Uint8List ref,
  Uint8List cap, {
  int sampleRate = 48000,
  int maxLagMs = 600,
}) {
  if (ref.length < 1024 || cap.length < 1024) {
    return Future<DelayEstimate?>.value(null);
  }
  return Isolate.run(() => estimateDelaySync(
        ref,
        cap,
        sampleRate: sampleRate,
        maxLagMs: maxLagMs,
      ));
}

/// 同步版本（纯 Dart 单测直接调，不依赖 Flutter / isolate）。
DelayEstimate? estimateDelaySync(
  Uint8List ref,
  Uint8List cap, {
  int sampleRate = 48000,
  int maxLagMs = 600,
}) {
  final int refLen = ref.length ~/ 2;
  final int capLen = cap.length ~/ 2;
  if (refLen < 128 || capLen < 128) return null;

  final int maxLag = sampleRate * maxLagMs ~/ 1000;
  final int l = Fft.nextPow2(refLen + maxLag + 1);
  if (l > (1 << 20)) return null; // 别把内存吃爆

  Float64List toDouble(Uint8List bytes, int len, double mean) {
    final bd = ByteData.view(bytes.buffer, bytes.offsetInBytes);
    final out = Float64List(l);
    final int n = math.min(len, l);
    for (int i = 0; i < n; i++) {
      out[i] = bd.getInt16(i * 2, Endian.little) / 32768.0 - mean;
    }
    return out;
  }

  double meanOf(Uint8List bytes, int len) {
    final bd = ByteData.view(bytes.buffer, bytes.offsetInBytes);
    double s = 0;
    for (int i = 0; i < len; i++) {
      s += bd.getInt16(i * 2, Endian.little);
    }
    return s / len / 32768.0;
  }

  final double refMean = meanOf(ref, refLen);
  final double capMean = meanOf(cap, capLen);
  final Float64List aRe = toDouble(ref, refLen, refMean);
  final Float64List bRe = toDouble(cap, capLen, capMean);
  final Float64List aIm = Float64List(l);
  final Float64List bIm = Float64List(l);

  Fft.transform(aRe, aIm);
  Fft.transform(bRe, bIm);

  // conj(A) * B
  for (int k = 0; k < l; k++) {
    final double ar = aRe[k];
    final double ai = aIm[k];
    final double br = bRe[k];
    final double bi = bIm[k];
    aRe[k] = ar * br + ai * bi;
    aIm[k] = ar * bi - ai * br;
  }
  Fft.transform(aRe, aIm, inverse: true); // aRe[lag] = Σ ref[n]·cap[n+lag]

  int bestLag = 0;
  double best = 0;
  for (int lag = 0; lag <= maxLag && lag < l; lag++) {
    final double v = aRe[lag].abs();
    if (v > best) {
      best = v;
      bestLag = lag;
    }
  }

  // 归一化相关系数 + 次峰比（排除主峰 ±5ms 之外的最大旁瓣）
  final bdRef = ByteData.view(ref.buffer, ref.offsetInBytes);
  double refEnergy = 0;
  for (int i = 0; i < refLen; i++) {
    final double v = bdRef.getInt16(i * 2, Endian.little) / 32768.0 - refMean;
    refEnergy += v * v;
  }
  final bdCap = ByteData.view(cap.buffer, cap.offsetInBytes);
  double capEnergy = 0;
  final int winEnd = math.min(capLen, bestLag + refLen);
  for (int i = bestLag; i < winEnd; i++) {
    final double v = bdCap.getInt16(i * 2, Endian.little) / 32768.0 - capMean;
    capEnergy += v * v;
  }
  final double denom = math.sqrt(refEnergy * capEnergy) + 1e-20;
  final double corr = best / denom;

  final int guard = (sampleRate * 0.005).round();
  double side = 0;
  for (int lag = 0; lag <= maxLag && lag < l; lag++) {
    if ((lag - bestLag).abs() < guard) continue;
    final double v = aRe[lag].abs();
    if (v > side) side = v;
  }
  final double peakToSide = best / (side + 1e-20);

  return DelayEstimate(
    lagMs: bestLag * 1000.0 / sampleRate,
    correlation: corr,
    peakToSide: peakToSide,
    sampleRate: sampleRate,
  );
}
