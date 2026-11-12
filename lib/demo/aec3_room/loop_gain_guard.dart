import 'dart:math' as math;
import 'dart:typed_data';

/// 基 2 复数 FFT（原地，迭代）。整个工程只此一份实现：
/// 采集侧守卫用它算窄带 Q，延迟标定用它做互相关。
class Fft {
  Fft._();

  /// [re] / [im] 长度必须是 2 的幂。
  static void transform(Float64List re, Float64List im, {bool inverse = false}) {
    final int n = re.length;
    if (inverse) {
      for (int i = 0; i < n; i++) {
        im[i] = -im[i];
      }
    }

    // 位反转置换
    int j = 0;
    for (int i = 1; i < n; i++) {
      int bit = n >> 1;
      while ((j & bit) != 0) {
        j ^= bit;
        bit >>= 1;
      }
      j ^= bit;
      if (i < j) {
        final double tr = re[i];
        re[i] = re[j];
        re[j] = tr;
        final double ti = im[i];
        im[i] = im[j];
        im[j] = ti;
      }
    }

    for (int len = 2; len <= n; len <<= 1) {
      final double ang = (inverse ? 1 : -1) * 2.0 * math.pi / len;
      final double wr = math.cos(ang);
      final double wi = math.sin(ang);
      final int half = len >> 1;
      for (int start = 0; start < n; start += len) {
        double cr = 1.0;
        double ci = 0.0;
        for (int k = 0; k < half; k++) {
          final int a = start + k;
          final int b = a + half;
          final double vr = re[b] * cr - im[b] * ci;
          final double vi = re[b] * ci + im[b] * cr;
          re[b] = re[a] - vr;
          im[b] = im[a] - vi;
          re[a] += vr;
          im[a] += vi;
          final double ncr = cr * wr - ci * wi;
          ci = cr * wi + ci * wr;
          cr = ncr;
        }
      }
    }

    if (inverse) {
      for (int i = 0; i < n; i++) {
        re[i] /= n;
        im[i] = -im[i] / n;
      }
    }
  }

  static int nextPow2(int n) {
    int p = 1;
    while (p < n) {
      p <<= 1;
    }
    return p;
  }
}

/// 采集侧「闭环增益守卫」—— 无耳机外放对讲的啸叫兜底。
///
/// ## 为什么挂在采集侧
/// 啸叫是 A 麦 → 上行 → B 扬声器 → B 麦 → … 的**声学闭环**在某一端起振，
/// 它只存在于「麦克风听到的」信号里；下行解码字节是干净的对方人声，
/// 在里面永远找不到自激。上一版把检测器挂在播放侧（`_howling.feed(decodedPcm)`）
/// 是看错了信号，真机日志里「检测到啸叫」一次都没出现过。
///
/// ## 为什么判据不是「等幅单频 800ms」
/// 真机 14:09 段的字节证据：60 个 100ms 窗的峰频 std=632Hz（823↔2074Hz 跳变），
/// 包络 CV=1.26，是**跳频、间歇、幅度起伏**的自激，不是稳态正弦。
/// 「过零率变异系数 < 2% 连续 800ms」这类判据在物理上不可能命中。
/// 真实特征只有两条：**极窄的谱峰（Q 高）** + **该峰能量持续递增（起振）**。
///
/// ## 真正可分的特征：窄带能量占比（tonality）
/// 用真机字节量化过（`14:09` 啸叫窗 vs `14:10` 无啸叫长段）：
///
/// | 片段 | Q 中位 | Q90 | **窄带能量占比中位** |
/// |---|---|---|---|
/// | 啸叫窗 9.4–11.6s | 21.2 | 29.6 | **0.806** |
/// | 正常语音 0–8s | 9.7 | 14.0 | 0.340 |
/// | 无啸叫 0–20s | 10.2 | 15.1 | 0.422 |
///
/// 联合门限 `Q>=18 && tonality>=0.5 && 峰电平>=-50dBFS` 的帧命中率：
/// 啸叫窗 **61.2%**，正常语音最高 **2.3%** —— 差 26 倍，可以直接当判据。
/// 单看 Q 或单看「能量持续上升」都会误伤（语音谐波 / 音节起伏），
/// 只有「绝大部分能量压在一个极窄频点」是啸叫独有的。
///
/// ## 触发规则
/// 最近 ~200ms 内窄带主导帧占比 >= 40% 即 duck；若同时检测到环路增益
/// （采集/下行能量比）持续上升，门槛放宽到 25% 以便更早打断闭环。
/// 稳态啸叫也抓得到，不再要求「起振上升」——真机啸叫有 1~2s 平台期。
///
/// ## duck 的作用
/// 把播放增益临时压到 [duckLevel] 打断闭环，再线性恢复。参考信号取自
/// 「已经乘过 duck 的同一份字节」，所以 AEC 不需要重新对齐，只是跟着慢变增益收敛。
class LoopGainGuard {
  LoopGainGuard({this.sampleRate = 48000});

  final int sampleRate;

  // ---------- 参数（全常量，便于纯 Dart 单测按同一套数值复刻）----------
  static const int fftSize = 1024; // 21.3ms @48k
  static const int hopSize = 512; // 10.7ms 一帧，50% 重叠
  static const int lowBin = 4; // ~187Hz
  static const int highBin = 86; // ~4.0kHz（啸叫实测 823Hz / 2.1kHz）
  static const double peakQDb = 18.0; // 窄带峰相对邻带的能量比
  static const double minTonality = 0.5; // 窄带能量 / 全帧能量
  static const double minPeakDbfs = -50.0; // 排除本底噪声
  static const int riseFrames = 19; // 19 × 10.7ms ≈ 203ms
  static const double narrowRatio = 0.40; // 窗口内「窄带主导」帧占比门限
  static const double narrowRatioFast = 0.25; // 环路增益同时上升时放宽
  static const double loopRiseDb = 5.0;
  static const double minRenderRms = 0.0015; // 下行确实在响才用增益判据
  static const double duckLevel = 0.25;
  static const int holdFrames = 281; // ~3s 恢复
  static const int cooldownFrames = 94; // 恢复后再冷却 ~1s

  // ---------- 输入缓冲 ----------
  final Float64List _acc = Float64List(fftSize);
  int _accFill = 0;
  final Float64List _re = Float64List(fftSize);
  final Float64List _im = Float64List(fftSize);
  final Float64List _power = Float64List(fftSize >> 1);

  static final Float64List _hann = Float64List.fromList(
    List<double>.generate(
      fftSize,
      (i) => 0.5 - 0.5 * math.cos(2.0 * math.pi * i / fftSize),
    ),
  );

  // ---------- 历史 / 状态 ----------
  final List<double> _qHist = <double>[];
  final List<double> _peakDbHist = <double>[];
  final List<bool> _narrowHist = <bool>[];
  final List<double> _loopHist = <double>[];
  final List<bool> _loopValid = <bool>[];

  double _renderRms = 0;
  double _duck = 1.0;
  int _duckLeft = 0;
  int _cooldown = 0;
  int _triggerCount = 0;
  String _lastReason = '';
  int _frames = 0;

  // ---------- 对外读数 ----------
  double get duckFactor => _duck;
  bool get isDucking => _duckLeft > 0;
  int get triggerCount => _triggerCount;
  String get lastReason => _lastReason;
  double get lastPeakHz => _peakHz;
  double get lastPeakQDb => _peakQDb;
  double get lastTonality => _tonality;
  double get captureDbfs => _capDbfs;
  double get renderDbfs => 20 * _log10(_renderRms + 1e-20);
  double get loopGainDb => _loopGainDb;
  int get analyzedFrames => _frames;

  double _peakHz = 0;
  double _peakQDb = -90;
  double _tonality = 0;
  double _capDbfs = -90;
  double _loopGainDb = -90;

  static double _log10(double x) => math.log(x) / 2.302585092994046;

  void reset() {
    _accFill = 0;
    _acc.fillRange(0, fftSize, 0);
    _qHist.clear();
    _peakDbHist.clear();
    _narrowHist.clear();
    _loopHist.clear();
    _loopValid.clear();
    _renderRms = 0;
    _duck = 1.0;
    _duckLeft = 0;
    _cooldown = 0;
    _triggerCount = 0;
    _lastReason = '';
    _frames = 0;
    _peakHz = 0;
    _peakQDb = -90;
    _tonality = 0;
    _capDbfs = -90;
    _loopGainDb = -90;
  }

  /// 下行能量。喂的是**解码后、乘 duck 之前**的字节，
  /// 这样环路增益估计不会被自己的 duck 动作反向放大（自反馈）。
  void feedRender(Int16List frame) {
    if (frame.isEmpty) return;
    double sum = 0;
    for (int i = 0; i < frame.length; i++) {
      final double v = frame[i] / 32768.0;
      sum += v * v;
    }
    final double rms = math.sqrt(sum / frame.length);
    _renderRms = math.max(rms, _renderRms * 0.995);
  }

  /// 便捷入口：直接吃采集流的 Uint8List，不要求 buffer 偶对齐。
  void feedCaptureBytes(Uint8List bytes) {
    final int n = bytes.length ~/ 2;
    if (n == 0) return;
    if (bytes.offsetInBytes.isEven) {
      feedCapture(bytes.buffer.asInt16List(bytes.offsetInBytes, n));
      return;
    }
    final ByteData bd = ByteData.view(bytes.buffer, bytes.offsetInBytes);
    final Int16List tmp = Int16List(n);
    for (int i = 0; i < n; i++) {
      tmp[i] = bd.getInt16(i * 2, Endian.little);
    }
    feedCapture(tmp);
  }

  /// AEC **之前**的原始采集。任意块长都行，内部按 10.7ms hop 切帧。
  void feedCapture(Int16List frame) {
    int i = 0;
    while (i < frame.length) {
      final int take = math.min(fftSize - _accFill, frame.length - i);
      for (int k = 0; k < take; k++) {
        _acc[_accFill + k] = frame[i + k] / 32768.0;
      }
      _accFill += take;
      i += take;
      if (_accFill == fftSize) {
        _analyze();
        // 滑动窗口：保留后 (fftSize - hopSize) 个样本
        final int keep = fftSize - hopSize;
        for (int k = 0; k < keep; k++) {
          _acc[k] = _acc[k + hopSize];
        }
        _accFill = keep;
      }
    }
  }

  void _analyze() {
    _frames++;
    // 1) Hann + 实部装填
    for (int k = 0; k < fftSize; k++) {
      _re[k] = _acc[k] * _hann[k];
      _im[k] = 0;
    }
    // 2) 宽带 RMS / 窄带功率谱
    double sumSq = 0;
    for (int k = 0; k < fftSize; k++) {
      sumSq += _acc[k] * _acc[k];
    }
    final double capRms = math.sqrt(sumSq / fftSize);
    _capDbfs = 20 * _log10(capRms + 1e-20);

    Fft.transform(_re, _im);
    for (int k = 0; k < (fftSize >> 1); k++) {
      _power[k] = _re[k] * _re[k] + _im[k] * _im[k];
    }

    int peakBin = lowBin;
    double peak = 0;
    for (int k = lowBin; k <= highBin; k++) {
      if (_power[k] > peak) {
        peak = _power[k];
        peakBin = k;
      }
    }
    // Hann 窗下单频幅度 A ≈ 4·sqrt(P)/N
    final double peakDbfs =
        20 * _log10(4.0 * math.sqrt(peak) / fftSize + 1e-20);

    // 邻带（跳过峰附近 ±2 bin），只统计 187Hz~4kHz
    double nbSum = 0;
    int nbCount = 0;
    for (int k = lowBin; k <= highBin; k++) {
      if ((k - peakBin).abs() <= 2) continue;
      nbSum += _power[k];
      nbCount++;
    }
    final double qDb =
        10 * _log10((peak + 1e-20) / (nbSum / math.max(nbCount, 1) + 1e-20));
    _peakHz = peakBin * sampleRate / fftSize;
    _peakQDb = qDb;

    // 窄带能量 / 全帧能量：区分「单频自激」与「语音谐波」的决定性特征。
    double total = 0;
    for (int k = 1; k < (fftSize >> 1); k++) {
      total += _power[k];
    }
    double band = 0;
    final int bandLo = math.max(1, peakBin - 2);
    final int bandHi = math.min((fftSize >> 1) - 1, peakBin + 2);
    for (int k = bandLo; k <= bandHi; k++) {
      band += _power[k];
    }
    _tonality = band / (total + 1e-20);

    // 3) 环路增益 = 采集电平 − 下行电平（只有下行在响才算有效）
    final bool renderActive = _renderRms > minRenderRms;
    final double lg = renderActive
        ? 20 * _log10((capRms + 1e-9) / (_renderRms + 1e-9))
        : -90;
    _loopGainDb = renderActive ? lg : -90;
    _renderRms *= 0.98; // 每 hop 衰减（约 500ms 时间常数）

    final bool narrowNow = qDb >= peakQDb &&
        _tonality >= minTonality &&
        peakDbfs >= minPeakDbfs;
    _pushHistory(qDb, peakDbfs, lg, renderActive, narrowNow);

    // 4) duck 状态机
    if (_duckLeft > 0) {
      _duckLeft--;
      final double t = 1.0 - _duckLeft / holdFrames;
      _duck = duckLevel + (1.0 - duckLevel) * t;
    } else {
      _duck = 1.0;
    }
    if (_cooldown > 0) _cooldown--;

    if (_duckLeft > 0 || _cooldown > 0 || _qHist.length < riseFrames) return;

    // 5) 主判据：最近 200ms 内「窄带主导」帧占比
    int narrow = 0;
    for (final bool v in _narrowHist) {
      if (v) narrow++;
    }
    final double ratio = narrow / _narrowHist.length;
    // 6) 加速项：环路增益（采集/下行）持续上升时放宽门槛，更早打断闭环。
    //    它**不独立触发** —— 双讲时采集电平波动很大，单独用会误伤。
    final bool gainRising = _isRising(
      _loopHist,
      _loopValid,
      loopRiseDb,
      (double v) => v > -60,
    );
    final double need = gainRising ? narrowRatioFast : narrowRatio;

    if (ratio >= need) {
      _duckLeft = holdFrames;
      _cooldown = holdFrames + cooldownFrames;
      _duck = duckLevel;
      _triggerCount++;
      _lastReason = gainRising
          ? '窄带主导 ${(ratio * 100).round()}% + 环路增益上升'
          : '窄带主导 ${(ratio * 100).round()}% @ '
              '${_peakHz.toStringAsFixed(0)}Hz Q=${qDb.toStringAsFixed(1)}dB';
    }
  }

  void _pushHistory(
    double qDb,
    double peakDbfs,
    double lg,
    bool renderActive,
    bool narrow,
  ) {
    _qHist.add(qDb);
    _peakDbHist.add(peakDbfs);
    _narrowHist.add(narrow);
    _loopHist.add(lg);
    _loopValid.add(renderActive);
    if (_qHist.length > riseFrames) {
      _qHist.removeAt(0);
      _peakDbHist.removeAt(0);
      _narrowHist.removeAt(0);
      _loopHist.removeAt(0);
      _loopValid.removeAt(0);
    }
  }

  /// 窗口内「有效帧占比 >= narrowRatio」且「后 1/3 均值 − 前 1/3 均值 >= minRise」。
  /// 允许跳频/间歇：只看窄带能量序列本身，不要求峰频恒定、也不要求过零率恒定。
  bool _isRising(
    List<double> values,
    List<bool> valid,
    double minRise,
    bool Function(double) levelOk,
  ) {
    final int n = values.length;
    if (n < riseFrames) return false;
    int good = 0;
    for (int i = 0; i < n; i++) {
      if (valid[i] && levelOk(values[i])) good++;
    }
    if (good / n < narrowRatio) return false;

    final int third = n ~/ 3;
    double head = 0;
    double tail = 0;
    int hn = 0;
    int tn = 0;
    for (int i = 0; i < third; i++) {
      if (valid[i] && levelOk(values[i])) {
        head += values[i];
        hn++;
      }
    }
    for (int i = n - third; i < n; i++) {
      if (valid[i] && levelOk(values[i])) {
        tail += values[i];
        tn++;
      }
    }
    if (hn == 0 || tn == 0) return false;
    return (tail / tn - head / hn) >= minRise;
  }
}
