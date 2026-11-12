import 'dart:math' as math;
import 'dart:typed_data';

/// 自适应啸叫陷波（采集侧）。
///
/// 为什么需要它：外放对讲一旦「AEC 没把自回声消干净」，即使两台设备**不在同一个
/// 房间**，回路依然是闭合的 ——
///   A 麦 → 上行 → B 外放 → B 麦 → 上行 → A 外放 → A 麦
/// 声耦合只发生在各自设备「自己的扬声器→自己的麦克风」这一段，房间不共享也切不断
/// 这条回路。回路增益一旦 >1，就会在增益峰值频率上自激；而且这个频率会随 AEC 残余、
/// 播放缓冲漂移到处跳，听感就是「一片吼叫/杂音」而不是单音哨。
///
/// AEC3 只做线性自适应，压不掉这种已经建立起来的自激（它的参考信号与真实回声
/// 一旦错开几十毫秒就废）。所以在采集侧补一层窄带陷波：把「已确认是啸叫的那个
/// 窄峰」直接挖掉，等价于把该频点的回路增益压到 1 以下，振荡立刻掉下来。
///
/// 作用点：AEC 之后、编码/落盘之前 —— 上行与成品同时受益（只挖窄带，不动语音）。
class HowlNotch {
  HowlNotch({
    this.sampleRate = 48000,
    this.maxNotches = 3,
    this.bandwidthHz = 160.0,
    this.depthDb = 22.0,
  });

  final int sampleRate;

  /// 同时最多挖几个坑（啸叫频率会跳，留 3 个够覆盖一轮跳频）。
  final int maxNotches;

  /// 陷波 -3dB 带宽（Hz）。太宽会削语音，太窄追不上漂移。
  final double bandwidthHz;

  /// 中心频点的抑制深度（dB）。
  final double depthDb;

  final List<_BiquadNotch> _filters = <_BiquadNotch>[];

  /// 实际生效的频点（平滑后的），对外只读，便于状态卡展示/断言。
  List<double> get activeHz => _filters
      .where((f) => f.currentHz > 0 && f.gain > 0.01)
      .map((f) => f.currentHz)
      .toList();

  bool get isActive => _filters.any((f) => f.currentHz > 0);

  void reset() => _filters.clear();

  /// 下发一组「当前确认是啸叫」的频点。
  ///
  /// 重复调用是常态（检测器每 250ms 报一次），已存在的频点只会刷新目标值，
  /// 不会重复建滤波器；被淘汰的频点会**平滑淡出**（目标幅度归零）后移除。
  void setTargets(List<double> hz) {
    final cleaned = <double>[];
    for (final f in hz) {
      if (f < 150 || f > sampleRate / 2 - 200) continue;
      // 太近的合成一个（相距 < 0.6 个带宽就不必重复挖）
      if (cleaned.any((c) => (c - f).abs() < bandwidthHz * 0.6)) continue;
      cleaned.add(f);
    }
    final want = cleaned.take(maxNotches).toList();

    // 1) 已存在的：刷新目标；不在 want 里的：目标归零（淡出）
    for (final f in _filters) {
      final hit = want.where((w) => (w - f.targetHz).abs() <= bandwidthHz).toList();
      if (hit.isNotEmpty) {
        f.targetHz = hit.first;
      } else {
        f.targetHz = 0; // 0 = 淡出后移除
      }
    }

    // 2) 新增的：建滤波器（从幅度 0 淡入，避免咔嗒）
    for (final w in want) {
      final exists = _filters.any((f) => (f.targetHz - w).abs() <= bandwidthHz);
      if (exists) continue;
      if (_filters.length >= maxNotches) continue;
      final f = _BiquadNotch(sampleRate: sampleRate, hz: w, q: _qFor(w));
      f.gain = 0;
      _filters.add(f);
    }
    _prune();
  }

  double _qFor(double hz) => math.max(4.0, hz / bandwidthHz);

  void _prune() {
    _filters.removeWhere((f) => f.targetHz <= 0 && f.gain <= 0.001);
  }

  /// 处理一块 48k/16bit/mono PCM（小端字节）。返回长度不变的新字节。
  Uint8List process(Uint8List pcm) {
    if (pcm.isEmpty || _filters.isEmpty) return pcm;
    final int n = pcm.lengthInBytes ~/ 2;
    final Int16List src = pcm.buffer.asInt16List(pcm.offsetInBytes, n);
    final ByteData out = ByteData(pcm.lengthInBytes);
    final double k = 1.0 - math.pow(10.0, -depthDb / 20.0).toDouble();

    // 每块重新算一次系数（频点/幅度平滑），块内不变 → 不会 zipper 噪声
    for (final f in _filters) {
      f.step();
    }

    for (int i = 0; i < n; i++) {
      double v = src[i].toDouble();
      for (final f in _filters) {
        if (f.gain <= 0.001) continue;
        final double y = f.run(v);
        v = v - k * f.gain * (v - y);
      }
      out.setInt16(i * 2, v.round().clamp(-32768, 32767), Endian.little);
    }
    _prune();
    return out.buffer.asUint8List();
  }
}

/// RBJ 二阶陷波（direct form II transposed），频点与幅度都可平滑过渡。
class _BiquadNotch {
  _BiquadNotch({
    required this.sampleRate,
    required double hz,
    required this.q,
  })  : targetHz = hz,
        currentHz = hz;

  final int sampleRate;
  final double q;

  /// 目标频点；0 表示「淡出后删除」。
  double targetHz;

  /// 平滑后的当前频点。
  double currentHz;

  /// 幅度 0~1（0 = 不作用）。淡入淡出都走这一条。
  double gain = 1.0;

  double _b0 = 1, _b1 = 0, _b2 = 0, _a1 = 0, _a2 = 0;
  double _z1 = 0, _z2 = 0;
  bool _coeffValid = false;

  static const double _hzLerp = 0.25;
  static const double _gainLerp = 0.25;

  void step() {
    if (targetHz <= 0) {
      gain += (0 - gain) * _gainLerp;
      if (gain < 0.01) gain = 0;
    } else {
      currentHz += (targetHz - currentHz) * _hzLerp;
      gain += (1.0 - gain) * _gainLerp;
    }
    _computeCoeffs();
  }

  void _computeCoeffs() {
    final double f = currentHz.clamp(20.0, sampleRate * 0.45);
    final double w0 = 2 * math.pi * f / sampleRate;
    final double cosw = math.cos(w0);
    // 陷波 -3dB 带宽 = bandwidthHz → Q = f / BW（Q 由外部按带宽换算好）
    final double alpha = math.sin(w0) / (2 * q);
    final double a0 = 1 + alpha;
    _b0 = 1 / a0;
    _b1 = -2 * cosw / a0;
    _b2 = 1 / a0;
    _a1 = -2 * cosw / a0;
    _a2 = (1 - alpha) / a0;
    _coeffValid = true;
  }

  double run(double x) {
    if (!_coeffValid) _computeCoeffs();
    final double y = _b0 * x + _z1;
    _z1 = _b1 * x - _a1 * y + _z2;
    _z2 = _b2 * x - _a2 * y;
    return y;
  }
}
