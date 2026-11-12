import 'dart:math' as math;
import 'dart:typed_data';

/// 采集侧底噪门（Noise Gate）—— 砍掉「不说话时」的底噪与低频嗡鸣。
///
/// ## 为什么需要它
/// 真机成品的安静期里有三样东西在响，全都与语音无关：
///  1. **120~130Hz 的窄带嗡鸣**（现场空调/电源，实测占安静期总能量 ~36%，
///     A/B 两端都在同一频率，说明是环境而不是某一台手机）；
///  2. **12~18kHz 的嘶声**（8kHz 以上的采集噪底，高频旁路会让它原样进成品）；
///  3. 各平台不同的宽带底噪（iOS 实测 −57dBFS，比 Android 的 −65dBFS 更吵）。
///
/// AEC3 只负责消回声，**不会降低近端底噪**（NS 被有意关掉，怕改频响），
/// 所以静音期的底噪原样进了成品。
///
/// ## 做法
/// 谷值追踪估噪底（只快降、慢升），逐帧判「这一帧够不够响到像语音」：
///  - 帧电平 > 噪底 + [openDb] → 判语音，增益 1（**立刻开，绝不砍字头**）；
///  - 帧电平 < 噪底 + [closeDb] → 判静音，增益压到 [minGain]；
///  - 中间线性过渡，帧间一阶平滑，帧内按样本插值，避免台阶咔嗒。
///
/// 前面的二阶高通（[highPassHz]）顺手去掉次声与 60Hz 以下的缓慢漂移 ——
/// 注意 AEC3 侧的高通是**故意关掉**的（怕切浊音基频），这里 60Hz 比男声
/// 基频（~85Hz）低一档，不影响浊音。
class NoiseGate {
  NoiseGate({
    this.sampleRate = 48000,
    this.frameSamples = 480,
    this.highPassHz = 60.0,
    this.minGain = 0.11, // -19dB
    this.openDb = 9.0,
    this.closeDb = 4.0,
    this.attack = 0.55,
    this.release = 0.10,
  }) {
    _designHighPass();
  }

  final int sampleRate;
  final int frameSamples;
  final double highPassHz;

  /// 静音帧的最终增益（0.11 ≈ -19dB）。再狠会听到"抽吸"。
  final double minGain;

  /// 高于噪底这么多 → 立刻开门（保护字头）。
  final double openDb;

  /// 低于噪底这么多 → 判静音。
  final double closeDb;

  /// 增益平滑：attack 越大关得越快，release 越小放得越慢。
  final double attack;
  final double release;

  // ---- 高通（RBJ biquad）----
  double _b0 = 1, _b1 = 0, _b2 = 0, _a1 = 0, _a2 = 0;
  double _x1 = 0, _x2 = 0, _y1 = 0, _y2 = 0;

  // ---- 噪底 ----
  double _floorDb = -90;
  bool _floorInit = false;

  double _gain = 1.0;
  double _prevGain = 1.0;

  // ---- 对外读数 ----
  double get gain => _gain;
  double get floorDbfs => _floorDb;
  double _lastFrameDbfs = -90;
  double get lastFrameDbfs => _lastFrameDbfs;

  void _designHighPass() {
    final double f = highPassHz / sampleRate;
    final double w = 2 * math.pi * f;
    final double cosw = math.cos(w);
    final double sinw = math.sin(w);
    final double q = 0.7071067811865476;
    final double alpha = sinw / (2 * q);
    final double a0 = 1 + alpha;
    _b0 = (1 + cosw) / 2 / a0;
    _b1 = -(1 + cosw) / a0;
    _b2 = (1 + cosw) / 2 / a0;
    _a1 = -2 * cosw / a0;
    _a2 = (1 - alpha) / a0;
  }

  /// 返回**新的** int16-LE 缓冲（不改动入参）。调用方常常需要「同一帧同时
  /// 走上行与落盘两条链路」，原地改会把另一条链路的数据一起改掉。
  Uint8List process(Uint8List pcm) {
    if (pcm.length < 4) return pcm;
    final int n = pcm.length ~/ 2;
    final ByteData bd = ByteData.view(pcm.buffer, pcm.offsetInBytes, n * 2);

    // 1) 高通（float 中间）
    final Float64List x = Float64List(n);
    double sumSq = 0;
    for (int i = 0; i < n; i++) {
      final double v = bd.getInt16(i * 2, Endian.little).toDouble();
      final double y = _b0 * v + _b1 * _x1 + _b2 * _x2 - _a1 * _y1 - _a2 * _y2;
      _x2 = _x1;
      _x1 = v;
      _y2 = _y1;
      _y1 = y;
      x[i] = y;
      sumSq += y * y;
    }

    // 2) 帧电平与噪底
    final double rms = math.sqrt(sumSq / n);
    final double frameDb = 20 * _log10(rms / 32768.0 + 1e-12);
    _lastFrameDbfs = frameDb;
    if (!_floorInit) {
      _floorDb = frameDb;
      _floorInit = true;
    } else if (frameDb < _floorDb) {
      // 快降：安静段 100ms 内贴住真实底噪
      _floorDb += (frameDb - _floorDb) * 0.35;
    } else {
      // 慢升：语音不会把噪底抬上去（每帧 +0.15dB 上限，语音段毫秒级，攒不动）
      _floorDb += math.min(frameDb - _floorDb, 0.15) * 0.5;
    }
    if (_floorDb < -95) _floorDb = -95;
    if (_floorDb > -30) _floorDb = -30;

    // 3) 目标增益
    double target;
    final double margin = frameDb - _floorDb;
    if (margin >= openDb) {
      target = 1.0; // 语音：立刻全开，不砍字头
    } else if (margin <= closeDb) {
      target = minGain;
    } else {
      final double t = (margin - closeDb) / (openDb - closeDb);
      target = minGain + (1.0 - minGain) * t;
    }

    // 4) 平滑（开快关慢，避免抽吸感；关过快会听到"呼吸"）
    _gain = target > _gain
        ? _gain + (target - _gain) * attack
        : _gain + (target - _gain) * release;

    // 5) 按样本线性插值增益：从上一帧的收尾值走到本帧目标值，
    //    这样即使 gain 变化大也不会在帧边界留台阶（台阶 = 100Hz 调制咔嗒）。
    final double g0 = _prevGain;
    final double g1 = _gain;
    final double step = (g1 - g0) / n;
    final ByteData out = ByteData(n * 2);
    for (int i = 0; i < n; i++) {
      final double g = g0 + step * i;
      out.setInt16(
        i * 2,
        (x[i] * g).round().clamp(-32768, 32767),
        Endian.little,
      );
    }
    _prevGain = g1;
    return out.buffer.asUint8List();
  }

  void reset() {
    _x1 = 0;
    _x2 = 0;
    _y1 = 0;
    _y2 = 0;
    _floorDb = -90;
    _floorInit = false;
    _gain = 1.0;
    _prevGain = 1.0;
    _lastFrameDbfs = -90;
  }

  static double _log10(double v) => math.log(v) / 2.302585092994046;
}
