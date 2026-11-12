import 'dart:math';
import 'dart:typed_data';

import 'package:native_aec/native_aec.dart';

/// AEC3 离线自测（纯 Dart，不依赖 Flutter，可在命令行直接跑）。
///
/// 为什么要有这个：
///   · 不需要麦克风、不需要两台手机，就能验证「库加载 / FFI 通路 / 算法输出」
///   · Android、iOS、桌面跑的是**同一份代码**，结果可直接对比
///   · 桌面跑出的数字与 C++ 直调 API 的基线（ERLE 30.6dB）对齐，
///     说明 Dart 侧的分帧、样本守恒、统计口径都是对的
class Aec3SelfTestResult {
  const Aec3SelfTestResult({
    required this.report,
    required this.ok,
    required this.version,
    required this.erle,
    required this.nearKeep,
    required this.doubleTalk,
    required this.sampleBalanced,
    required this.elapsedMs,
  });

  final String report;
  final bool ok;
  final String? version;

  /// 回声抑制量（正数 = 压了多少 dB）
  final double erle;
  final double nearKeep;
  final double doubleTalk;
  final bool sampleBalanced;
  final int elapsedMs;

  /// 桌面 x86_64 + C++ 直调的基线
  static const double baselineErle = 30.6;
  static const double baselineNear = 0.0;
  static const double baselineDoubleTalk = -4.6;
}

const int _sr = 48000;
const int _chunk = 960; // 20ms
const int _seconds = 6;
const double _echoDelayMs = 80;
const double _echoGain = 0.35;
const double _echoNonlinear = 0.03;

Aec3SelfTestResult runAec3SelfTest() {
  final sw = Stopwatch()..start();
  final sb = StringBuffer();
  final version = aec3BuildInfo();

  sb.writeln('库版本: ${version ?? "❌ 未加载（符号缺失）"}');

  final aec = Aec3Processor.tryCreate(sampleRate: _sr);
  if (aec == null) {
    sb.writeln('❌ Aec3Processor 创建失败，无法继续。');
    sw.stop();
    return Aec3SelfTestResult(
      report: sb.toString(),
      ok: false,
      version: version,
      erle: 0,
      nearKeep: 0,
      doubleTalk: 0,
      sampleBalanced: false,
      elapsedMs: sw.elapsedMilliseconds,
    );
  }

  // ── 1. 造信号 ───────────────────────────────────────────────
  // far ：扬声器要放的「对方声音」，也是 AEC 的参考信号来源
  // near：本端人声
  // mic ：麦克风实际收到 = far 的延迟回声 + near
  final int total = _seconds * _sr;
  final far = Float64List(total);
  final near = Float64List(total);

  _fillVoice(far, 0, 2 * _sr, 110); // 0~2s 对方说
  _fillVoice(far, 4 * _sr, 6 * _sr, 110); // 4~6s 对方又说（双讲）
  _fillVoice(near, 2 * _sr, 6 * _sr, 165); // 2~6s 我一直在说

  final int delay = (_echoDelayMs / 1000 * _sr).round();
  final mic = Float64List(total);
  for (int i = 0; i < total; i++) {
    double echo = 0;
    if (i >= delay) {
      final double x = far[i - delay];
      // 扬声器大音量下的非线性失真，真实设备上一定存在
      echo = _echoGain * (x + _echoNonlinear * x * x * x);
    }
    mic[i] = (echo + near[i]).clamp(-1.0, 1.0);
  }

  // ── 2. 逐块喂给 AEC3 ────────────────────────────────────────
  final outBuf = Float64List(total + _chunk);
  int outLen = 0;
  int totalIn = 0;

  for (int off = 0; off + _chunk <= total; off += _chunk) {
    aec.pushReference(_toPcm16(far, off, _chunk));
    totalIn += _chunk;
    final res = aec.processCapture(_toPcm16(mic, off, _chunk));
    final n = res.length ~/ 2;
    if (n > 0) {
      final view = Int16List.view(res.buffer, res.offsetInBytes, n);
      for (int i = 0; i < n && outLen + i < outBuf.length; i++) {
        outBuf[outLen + i] = view[i] / 32768.0;
      }
      outLen += n;
    }
  }

  final stats = aec.stats();
  final int starved = stats?.refStarvedFrames ?? 0;
  final int frames = stats?.processedFrames ?? 0;
  aec.dispose();
  sw.stop();

  // ── 3. 分段统计（都是 out 相对 in 的增益，负值=被压低）─────
  final double erleGain = _ratio(outBuf, mic, 0, 2 * _sr);
  final double nearKeep = _ratio(outBuf, mic, 2 * _sr, 4 * _sr);
  final double doubleTalk = _ratio(outBuf, mic, 4 * _sr, 6 * _sr);
  final double erle = -erleGain;
  final bool balanced = totalIn == outLen;
  final bool ok = balanced && erle >= 25 && frames > 0;

  sb.writeln('样本守恒: in=$totalIn out=$outLen '
      '(${balanced ? "✅ 严格相等" : "❌ 差 ${outLen - totalIn}"})');
  sb.writeln('处理帧数: $frames (缺参考 $starved 帧)');
  sb.writeln('耗时: ${sw.elapsedMilliseconds} ms '
      '($_seconds s 音频)');
  sb.writeln('');
  sb.writeln('【纯回声段 0~2s】对方说、我沉默');
  sb.writeln('  mic ${_db(mic, 0, 2 * _sr).toStringAsFixed(1)} dBFS → '
      'out ${_db(outBuf, 0, 2 * _sr).toStringAsFixed(1)} dBFS');
  sb.writeln('  ERLE = ${erle.toStringAsFixed(1)} dB '
      '${erle >= 25 ? "✅ 回声已消除" : "❌ 抑制不足"}');
  sb.writeln('');
  sb.writeln('【本端独说 2~4s】对方静音');
  sb.writeln('  相对变化 ${nearKeep.toStringAsFixed(1)} dB '
      '${nearKeep.abs() < 1.5 ? "✅ 人声无损" : "⚠️ 人声被改"}');
  sb.writeln('');
  sb.writeln('【双讲 4~6s】两人同时说');
  sb.writeln('  相对变化 ${doubleTalk.toStringAsFixed(1)} dB '
      '（-3~-6dB 属正常，是 AEC 的 NLP）');
  sb.writeln('');
  sb.writeln('合格线：ERLE ≥ 25dB、样本严格守恒。');
  sb.writeln('桌面实测 30~36dB（合成信号不同批次会有差异），'
      '双端低于 20dB 才需要排查。');

  return Aec3SelfTestResult(
    report: sb.toString(),
    ok: ok,
    version: version,
    erle: erle,
    nearKeep: nearKeep,
    doubleTalk: doubleTalk,
    sampleBalanced: balanced,
    elapsedMs: sw.elapsedMilliseconds,
  );
}

/// 合成类语音：基频 + 谐波 + 音节包络 + 少量噪声
void _fillVoice(Float64List dst, int start, int end, double f0) {
  final int n = end - start;
  final rnd = Random(start);
  const harmonics = <double>[1, 0.62, 0.4, 0.26, 0.17, 0.11, 0.07, 0.05];
  for (int i = 0; i < n; i++) {
    final double t = i / _sr;
    // 每 0.25s 一个音节，带 15% 上升 / 30% 下降
    final double pos = (t * 4) % 1.0;
    final double env = pos < 0.15
        ? pos / 0.15
        : (pos > 0.7 ? (1 - pos) / 0.3 : 1.0);
    double v = 0;
    for (int h = 0; h < harmonics.length; h++) {
      v += harmonics[h] * sin(2 * pi * f0 * (h + 1) * t);
    }
    // 轻微噪声，避免纯周期信号过于理想
    v += 0.02 * (rnd.nextDouble() * 2 - 1);
    dst[start + i] = (v * 0.18 * env.clamp(0.0, 1.0)).clamp(-1.0, 1.0);
  }
}

Uint8List _toPcm16(Float64List src, int start, int count) {
  final out = Uint8List(count * 2);
  final view = Int16List.view(out.buffer);
  for (int i = 0; i < count; i++) {
    view[i] = (src[start + i] * 32767).round().clamp(-32768, 32767);
  }
  return out;
}

double _db(Float64List x, int a, int b) {
  double sum = 0;
  for (int i = a; i < b && i < x.length; i++) {
    sum += x[i] * x[i];
  }
  final double rms = sqrt(sum / max(1, b - a));
  return 20 * log(max(rms, 1e-9)) / ln10;
}

double _ratio(Float64List out, Float64List inp, int a, int b) =>
    _db(out, a, b) - _db(inp, a, b);
