import 'dart:math' as math;
import 'dart:typed_data';

/// 下行相关门（Residual Gate）—— AEC 之后的「宁可错杀」回声清尾层。
///
/// 目的：AEC3 是**按比例**消回声，双讲时为了保本端会漏掉一部分远端残余，
/// 加上厂商音效的非线性，成品里仍能听到「对方的声音」。这一层把判决做极端：
/// **只要这帧里能跟下行参考对上的能量占比够高，就整帧压低到接近静音**，
/// 换「成品彻底无回声」。代价是双讲（双方同时说话）时本端也会被压低 ——
/// 这是用户明确接受的产品取舍（成品优先）。
///
/// ## 为什么放 AEC 之后、写盘之前
/// 写进 .pcm 的字节就是最终成品，后处理修不回来。这一层只作用于**落盘链路**，
/// 不碰上行 opus 编码，所以实时对讲的音量/质量不受影响。
///
/// ## 判据（每个 10ms 帧，48kHz = 480 样本）
/// 1. 帧能量 `E_out` 与帧内下行参考 `ref` 的**归一化互相关峰值** `ρ`。
/// 2. `ρ >= rhoFull` → 判定「本帧几乎全是回声」→ 增益压到 `gFloor`（≈全压掉）。
/// 3. `ρ <= rhoNone` → 纯本端 → 增益 1。
/// 4. 之间线性过渡。增益帧间一阶平滑，避免咔嗒。
///
/// ## 参考对齐
/// 下行参考是「正在送扬声器」的字节，要经过 [refDelaySamples] 才出现在采集里。
/// 这里维护一份参考环形缓冲，取「delay 前的样本」与当前帧做相关 —— 与 AEC 的
/// REF_DELAY_MS 是同一件事，但独立实现，便于离线验证和单独调。
class ResidualGate {
  ResidualGate({
    this.sampleRate = 48000,
    this.frameSamples = 480, // 48kHz 下 10ms
    this.refDelayMs = 0, // 0 = 假设参考已由上游对齐；否则自己补偿
    this.rhoFull = 0.55,
    this.rhoNone = 0.20,
    this.gFloor = 0.02, // -34dB，接近静音但留一点点过渡
    this.smooth = 0.6, // 帧间增益平滑系数（越大越平滑）
  });

  final int sampleRate;
  final int frameSamples;
  final int refDelayMs;
  final double rhoFull;
  final double rhoNone;
  final double gFloor;
  final double smooth;

  int get refDelaySamples => refDelayMs * sampleRate ~/ 1000;

  /// 参考环形缓冲：存最近 [refDelaySamples + frameSamples + 余量] 样本。
  final _RefBuf _ref = _RefBuf();

  double _prevGain = 1.0;

  /// 下行参考喂入（int16-LE 单声道，任意块长）。
  void pushReference(Uint8List pcm) {
    _ref.add(pcm);
  }

  /// 对 AEC 输出的一帧做门控，返回同长度字节（int16-LE）。
  /// [refAligned] 为 true 时，表示调用方已经保证 reference 与 capture 时间对齐
  /// （例如上游用 REF_DELAY_MS 队列对齐过），此时不再额外平移。
  Uint8List process(Uint8List frame, {bool refAligned = false}) {
    if (frame.length < 2) return frame;
    final int n = frame.length ~/ 2;
    final Int16List inPcm =
        frame.buffer.asInt16List(frame.offsetInBytes, n);

    final double rho = _correlate(inPcm, refAligned);

    // 归一化相关 → 目标增益
    double g;
    if (rho >= rhoFull) {
      g = gFloor;
    } else if (rho <= rhoNone) {
      g = 1.0;
    } else {
      final double t = (rho - rhoNone) / (rhoFull - rhoNone);
      g = gFloor + (1.0 - gFloor) * (1.0 - t);
    }

    // 帧间一阶平滑（只向下压快、向上收慢，避免砍自己人声的起始）
    if (g < _prevGain) {
      _prevGain = _prevGain + (g - _prevGain) * smooth;
    } else {
      _prevGain = _prevGain + (g - _prevGain) * (smooth * 0.5);
    }
    final double apply = _prevGain;

    if (apply >= 0.999) return frame; // 无需处理，原样返回省一次拷贝

    final ByteData out = ByteData(frame.length);
    for (int i = 0; i < n; i++) {
      final int v = (inPcm[i] * apply).round();
      out.setInt16(i * 2, v.clamp(-32768, 32767), Endian.little);
    }
    return out.buffer.asUint8List(out.offsetInBytes, out.lengthInBytes);
  }

  /// 最近一帧的归一化互相关峰值（诊断用）。
  double get lastRho => _lastRho;
  double _lastRho = 0;

  /// 当前生效增益（诊断用）。
  double get currentGain => _prevGain;

  double _correlate(Int16List frame, bool refAligned) {
    final int n = frame.length;
    final int shift = refAligned ? 0 : refDelaySamples;

    // 帧能量
    double eOut = 0;
    for (int i = 0; i < n; i++) {
      eOut += frame[i] * frame[i];
    }
    if (eOut < 1.0) {
      _lastRho = 0;
      return 0; // 帧近乎静音：无需处理，rho=0（判定为纯本端/静音）
    }

    // 取参考窗口（与帧等长，起点回退 shift 样本）
    final Int16List? r = _ref.window(n + shift, n);
    if (r == null) {
      _lastRho = 0;
      return 0; // 参考还没攒够
    }

    // 参考窗口能量
    double eRef = 0;
    for (int i = 0; i < n; i++) {
      eRef += r[i] * r[i];
    }
    if (eRef < 1.0) {
      _lastRho = 0;
      return 0; // 下行静音，无回声可消
    }

    // 归一化互相关（零延迟处，因为 shift 已经在取窗时补偿）
    double cross = 0;
    for (int i = 0; i < n; i++) {
      cross += frame[i] * r[i];
    }
    final double rho = cross / math.sqrt(eOut * eRef);
    _lastRho = rho.clamp(-1.0, 1.0);
    return _lastRho;
  }

  void reset() {
    _ref.clear();
    _prevGain = 1.0;
    _lastRho = 0;
  }
}

/// int16-LE 环形缓冲，按样本存 int，支持「取最近 window 个样本」。
class _RefBuf {
  final List<int> _buf = [];
  static const int _cap = 48000 * 4; // 4 秒上限，防内存失控

  void add(Uint8List pcm) {
    final Int16List s = pcm.buffer.asInt16List(pcm.offsetInBytes, pcm.length ~/ 2);
    for (int i = 0; i < s.length; i++) {
      _buf.add(s[i]);
    }
    if (_buf.length > _cap) {
      _buf.removeRange(0, _buf.length - _cap);
    }
  }

  /// 取「距当前末尾回退 [back] 样本起、共 [len] 样本」的窗口。
  Int16List? window(int back, int len) {
    if (_buf.length < back + len) return null;
    final int start = _buf.length - back - len;
    final Int16List out = Int16List(len);
    for (int i = 0; i < len; i++) {
      out[i] = _buf[start + i];
    }
    return out;
  }

  void clear() => _buf.clear();
}
