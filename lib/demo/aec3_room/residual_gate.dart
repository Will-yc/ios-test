import 'dart:math' as math;
import 'dart:typed_data';

/// 下行相关门（Residual Gate）—— AEC 之后的回声清尾层。
///
/// 目的：AEC3 是**按比例**消回声，单层线性滤波在外放场景只能给 20~25dB，
/// 成品里仍能听到「对方的声音」。这一层把判决做狠：凡「能用下行参考解释
/// 掉大部分能量」的帧，整帧压到接近静音。
///
/// ## 上一版为什么一次都没生效（已修，别再改回去）
/// 上一版用「当帧参考」与「当帧采集」做零延迟相关，注释写「参考已由页面侧
/// REF_DELAY 队列对齐」。这是误判：页面把参考延迟 [assumedDelayMs] 只是
/// 为了让 **AEC3 看到较小的延迟**，而采集里此刻的回声对应的是「播放缓冲 +
/// 声学路径 + 页面延迟」之前送出的那批字节 —— 实测 321~352ms。两者错开
/// 300ms 以上，归一化相关恒等于 0，`rho` 永远落在 `rhoNone` 以下，门形同虚设。
///
/// 现在的做法：**门自己搜延迟**。每 [searchIntervalFrames] 帧，在
/// `[minDelayMs, maxDelayMs]` 内用降采样波形做一次粗搜，再在粗解附近全率精化，
/// 结果缓存；逐帧判决用缓存值。这样 REF_DELAY 猜错多少都不影响门。
///
/// ## 判据（每个 10ms 帧，48kHz = 480 样本）
/// 1. `rho` = 采集帧与「回退 [currentLagMs] 处的参考」的归一化互相关（取绝对值）。
/// 2. `rho >= rhoFull` → 本帧几乎全是回声 → 增益压到 [gFloor]。
/// 3. `rho <= rhoNone` → 纯本端 → 增益 1。
/// 4. 之间线性过渡（双讲时部分被压，用户已明确接受「成品优先」）。
/// 5. **能量兜底**：下行在响、而本帧电平比参考低 [energyDropDb] 以上 ——
///    本端根本没人说话，剩下的只能是残余 → 直接压到 [gFloor]。
/// 6. **下行静默直通**：参考电平低于 [silentRefDbfs] 时无回声可消 → 增益 1，
///    绝不误压本端说话（这条是硬保护）。
class ResidualGate {
  ResidualGate({
    this.sampleRate = 48000,
    this.frameSamples = 480, // 48kHz 下 10ms
    this.assumedDelayMs = 300,
    this.minDelayMs = 40,
    this.maxDelayMs = 620,
    this.rhoFull = 0.40,
    this.rhoNone = 0.10,
    this.gFloor = 0.02, // -34dB
    this.smooth = 0.6,
    this.energyDropDb = 14.0,
    this.silentRefDbfs = -55.0,
    this.debug = false,
  });

  final int sampleRate;
  final int frameSamples;

  /// 搜索起点（不是结论）。仅用于「还没搜到 lag」的前几百毫秒。
  final int assumedDelayMs;
  final int minDelayMs;
  final int maxDelayMs;

  final double rhoFull;
  final double rhoNone;
  final double gFloor;
  final double smooth;

  /// 本帧电平比参考低这么多 → 判「本端无人说话，全是残余」。
  final double energyDropDb;

  /// 参考电平低于此值 → 下行静默，无回声可消，强制直通。
  final double silentRefDbfs;

  /// 打印延迟搜索过程（只在离线验证时打开）。
  final bool debug;

  /// 延迟搜索间隔（帧）。100ms 一次足够：播放缓冲的变化是秒级。
  static const int searchIntervalFrames = 10;

  /// 粗搜包络的块长（48k 采样下 192 = 4ms）。
  static const int envBlockSamples = 192;

  /// 粗搜探针块数（50 × 4ms = 200ms）。太短会被音节起伏带偏，太长跟不上延迟漂移。
  static const int envProbeBlocks = 50;

  /// **冷启动**用的探针块数（150 × 4ms = 600ms）。
  ///
  /// 冷启动没有「上一帧 lag」可做先验，而任何起伏性信号（语音的音节、调幅）
  /// 都会在等价延迟处给出同样高的包络相关 —— 实测 500ms 会被 166ms 抢走，
  /// 两者刚好差一个 322ms 的起伏周期。探针必须长过起伏周期才能唯一确定。
  /// 一旦锁定，后续用 200ms 短探针快速跟随漂移即可。
  static const int envColdProbeBlocks = 150;

  /// 「留在原位」先验的惩罚系数（每偏离 1 秒扣多少相关分）。
  /// 0.15 意味着：等价峰要高出 0.15 才值得移动 1 秒；实测的假峰间隔是
  /// 100~300ms 量级，扣分只有 0.015~0.045，刚好压住假峰又不妨碍真实漂移。
  static const double lagPriorPenalty = 0.15;

  /// 包络粗筛后保留几个候选交给波形复筛。
  /// 3 个足够：真峰 + 最多两个"差整数个音节周期"的等价峰。
  static const int candTopK = 3;

  int get _minLag => minDelayMs * sampleRate ~/ 1000;
  int get _maxLag => maxDelayMs * sampleRate ~/ 1000;

  final _Ring _cap = _Ring(48000); // 采集留 1s（冷启动探针 600ms 够用）

  /// 参考留 2s：冷启动要用 600ms 探针，加上最长 620ms 的延迟，合计 1220ms，
  /// 1s 的环不够（会一直返回 false，门永远等不到第一个 lag）。
  final _Ring _refKeep = _Ring(96000);

  int _lag = -1;
  int _sinceSearch = 0;
  double _prevGain = 1.0;

  double _lastRho = 0;
  double _lastCapDbfs = -90;
  double _lastRefDbfs = -90;

  // ---- 对外读数（页面/日志用）----
  double get lastRho => _lastRho;
  double get currentGain => _prevGain;
  int get currentLagMs => _lag < 0 ? -1 : (_lag * 1000 ~/ sampleRate);
  double get lastCapDbfs => _lastCapDbfs;
  double get lastRefDbfs => _lastRefDbfs;

  /// 构造完先给一个可用 lag，免得开头几百毫秒完全不管。
  int get _initialLag => assumedDelayMs * sampleRate ~/ 1000;

  /// 判决实际用的延迟：搜到了就用真值，没搜到先用假设值顶着。
  int get _effectiveLag => _lag >= 0 ? _lag : _initialLag;

  /// 下行参考喂入（int16-LE 单声道，任意块长）。
  void pushReference(Uint8List pcm) {
    if (pcm.length < 2) return;
    final int n = pcm.length ~/ 2;
    final ByteData bd = ByteData.view(pcm.buffer, pcm.offsetInBytes, n * 2);
    final Int16List s = Int16List(n);
    for (int i = 0; i < n; i++) {
      s[i] = bd.getInt16(i * 2, Endian.little);
    }
    _refKeep.addInt16(s);
  }

  /// 对 AEC 输出的一帧做门控，返回同长度字节（int16-LE）。
  Uint8List process(Uint8List frame) {
    if (frame.length < 2) return frame;
    final int n = frame.length ~/ 2;
    final ByteData inBd =
        ByteData.view(frame.buffer, frame.offsetInBytes, n * 2);
    final Int16List pcm = Int16List(n);
    double sumSq = 0;
    for (int i = 0; i < n; i++) {
      final int v = inBd.getInt16(i * 2, Endian.little);
      pcm[i] = v;
      sumSq += v * v;
    }
    _cap.addInt16(pcm);

    final double capRms = math.sqrt(sumSq / n);
    _lastCapDbfs = 20 * _log10(capRms / 32768.0 + 1e-12);

    // 帧近乎静音：什么都不用做（也算"直通"，别把增益平滑状态搅乱）
    if (capRms < 2.0) {
      _lastRho = 0;
      if (_lag < 0) _lag = _initialLag;
      _prevGain += (1.0 - _prevGain) * (smooth * 0.5);
      return frame;
    }

    // 延迟搜索（周期性）。注意：搜不到时**不要把 _lag 提前赋成假设值** ——
    // 一旦赋值，`_lag >= 0` 就会让冷启动逻辑（长探针 + 无先验）永久失效，
    // 之后一直用短探针在错误先验附近打转，永远跳不出来。判决另走 _effectiveLag。
    if (++_sinceSearch >= searchIntervalFrames || _lag < 0) {
      _sinceSearch = 0;
      _searchLag(n);
    }

    double g = 1.0;
    final Float64List refWin = Float64List(n);
    if (_windowBeforeEnd(_refKeep, _effectiveLag, n, refWin)) {
      double eRef = 0;
      double cross = 0;
      for (int i = 0; i < n; i++) {
        final double r = refWin[i];
        eRef += r * r;
        cross += pcm[i] * r;
      }
      final double refRms = math.sqrt(eRef / n);
      _lastRefDbfs = 20 * _log10(refRms / 32768.0 + 1e-12);

      if (refRms < 1.0) {
        // 下行静默：无回声可消，强制直通（硬保护，别误压本端）
        g = 1.0;
        _lastRho = 0;
      } else {
        final double rho =
            (cross / (math.sqrt(eRef) * math.sqrt(sumSq) + 1e-9)).abs();
        _lastRho = rho.clamp(0.0, 1.0);

        if (rho >= rhoFull) {
          g = gFloor;
        } else if (rho <= rhoNone) {
          g = 1.0;
        } else {
          final double t = (rho - rhoNone) / (rhoFull - rhoNone);
          // 过渡区最多压到 -12dB（双讲时保护本端，仍能削掉一部分对方声音）
          const double midFloor = 0.25;
          g = midFloor + (1.0 - midFloor) * (1.0 - t);
        }

        // 能量兜底：本端明显没人说话，剩下的只能是残余
        if (_lastRefDbfs > silentRefDbfs &&
            _lastCapDbfs < _lastRefDbfs - energyDropDb) {
          g = math.min(g, gFloor);
        }
      }
    }

    // 帧间平滑：向下压快、向上放慢，避免砍本端字头
    _prevGain = g < _prevGain
        ? _prevGain + (g - _prevGain) * smooth
        : _prevGain + (g - _prevGain) * (smooth * 0.5);
    final double apply = _prevGain;
    if (apply >= 0.999) return frame;

    final ByteData out = ByteData(n * 2);
    for (int i = 0; i < n; i++) {
      out.setInt16(
        i * 2,
        (pcm[i] * apply).round().clamp(-32768, 32767),
        Endian.little,
      );
    }
    return out.buffer.asUint8List();
  }

  /// 在 `[minDelayMs, maxDelayMs]` 内搜「让采集与参考最相关」的回退量。
  ///
  /// ## 为什么粗搜必须用包络，不能直接相关波形
  /// 语音（以及任何有基音周期的信号）的波形自相关在「相隔整数个基音周期」处
  /// 有等价峰。实测用谐波信号做 8 级降采样波形搜，500ms 会被搜成 166ms
  /// （差 60 个基音周期）；真机语音基音 80~300Hz，间隔 3~12ms，620ms 的搜索
  /// 范围里有几十个等价峰，波形粗搜必然会跳到错的周期上。
  ///
  /// 包络（每 [envBlockSamples] 的 RMS）把基音周期彻底抹平，只留音节起伏，
  /// 因此粗搜不会跳峰；再用窄范围波形精化拿到样本级精度。
  void _searchLag(int frameLen) {
    const int block = envBlockSamples; // 4ms
    final int probeBlocks =
        _lag < 0 ? envColdProbeBlocks : envProbeBlocks; // 冷启动用长探针
    final int probeSamples = block * probeBlocks;

    if (_cap.length < probeSamples) return;
    if (_refKeep.length < _maxLag + probeSamples) return;

    final int refSamples = _maxLag + probeSamples;
    final int refBlocks = refSamples ~/ block;
    final Float64List capEnv = Float64List(probeBlocks);
    final Float64List refEnv = Float64List(refBlocks);
    if (!_envelope(_cap, probeBlocks, block, capEnv)) return;
    if (!_envelope(_refKeep, refBlocks, block, refEnv)) return;

    // 粗搜（块精度 4ms）
    //
    // 加「留在原位」的先验：任何周期性信号都会让相关在等价延迟处出现几乎
    // 同样高的峰（实测谐波+调幅信号上 450ms 会被 128ms 抢走，两者相差整数个
    // 调幅周期）。真实播放延迟是**缓变**的（远小于 10ms/s），所以对偏离当前
    // 估计的候选按距离扣分，等价峰就会被留在原位；只有确实更优的峰才切过去。
    final int minLagBlocks = _minLag ~/ block;
    final int maxLagBlocks = _maxLag ~/ block;
    final int prevLag = _lag;
    final List<int> cands = <int>[];
    final List<double> candScores = <double>[];
    for (int lb = minLagBlocks; lb <= maxLagBlocks; lb++) {
      final int start = refBlocks - lb - probeBlocks;
      if (start < 0) continue;
      double eR = 0;
      double eC = 0;
      double cross = 0;
      for (int i = 0; i < probeBlocks; i++) {
        final double r = refEnv[start + i];
        final double c = capEnv[i];
        eR += r * r;
        eC += c * c;
        cross += c * r;
      }
      if (eR < 1e-12 || eC < 1e-12) continue;
      final double r = cross / (math.sqrt(eR * eC) + 1e-15);
      double score = r;
      if (prevLag >= 0) {
        final double devSec = ((lb * block) - prevLag).abs() / sampleRate;
        score -= lagPriorPenalty * devSec;
      }
      cands.add(lb);
      candScores.add(score);
    }
    if (cands.isEmpty) return;

    // 取包络得分最高的 [candTopK] 个候选：包络只能说明"起伏对上了"，
    // 起伏相近的假峰（差整数个音节周期）必须靠波形再筛一遍。
    final List<int> order = List<int>.generate(cands.length, (i) => i)
      ..sort((a, b) => candScores[b].compareTo(candScores[a]));

    final int fineProbe = math.min(1920, frameLen * 4);
    final Float64List capP = Float64List(fineProbe);
    if (!_windowBeforeEnd(_cap, 0, fineProbe, capP)) return;
    double capSq = 0;
    for (int i = 0; i < fineProbe; i++) {
      capSq += capP[i] * capP[i];
    }
    if (capSq < 1.0) return;

    int lagBest = -1;
    double bestFine = 0;
    final Float64List refWin = Float64List(fineProbe);
    final int topK = math.min(candTopK, order.length);
    final List<String> dbg = <String>[];
    for (int t = 0; t < topK; t++) {
      final int base = cands[order[t]] * block;
      final int lo = math.max(0, base - 2 * block);
      final int hi = base + 2 * block;
      double localBest = 0;
      for (int cand = lo; cand <= hi; cand += 4) {
        if (!_windowBeforeEnd(_refKeep, cand, fineProbe, refWin)) continue;
        double eRef = 0;
        double cross = 0;
        for (int i = 0; i < fineProbe; i++) {
          final double r = refWin[i];
          eRef += r * r;
          cross += capP[i] * r;
        }
        if (eRef < 1.0) continue;
        final double r = (cross / (math.sqrt(eRef * capSq) + 1e-9)).abs();
        if (r > localBest) localBest = r;
        if (r > bestFine) {
          bestFine = r;
          lagBest = cand;
        }
      }
      dbg.add('${base * 1000 ~/ sampleRate}ms(env=${candScores[order[t]].toStringAsFixed(3)},'
          'wave=${localBest.toStringAsFixed(3)})');
    }
    if (debug) {
      // 离线验证专用（worker 里 debug 恒为 false，不会打印）
      // ignore: avoid_print
      print('[gate] 冷启动=${_lag < 0} topK=${dbg.join(" ")} → '
          'pick=${lagBest < 0 ? -1 : lagBest * 1000 ~/ sampleRate}ms '
          'wave=${bestFine.toStringAsFixed(3)}');
    }
    if (lagBest >= 0 && bestFine >= 0.05) _lag = lagBest;
  }

  /// 从 [ring] 末尾往前取 [blocks] 块、每块 [block] 样本的 RMS 包络。
  static bool _envelope(
    _Ring ring,
    int blocks,
    int block,
    Float64List out,
  ) {
    final int need = blocks * block;
    if (need > ring.length) return false;
    final int cap = ring.capacity;
    int p = (ring.writePos - need) % cap;
    if (p < 0) p += cap;
    for (int b = 0; b < blocks; b++) {
      double s = 0;
      for (int i = 0; i < block; i++) {
        final double v = ring.buf[p];
        s += v * v;
        if (++p == cap) p = 0;
      }
      out[b] = math.sqrt(s / block);
    }
    return true;
  }

  static double _log10(double x) => math.log(x) / 2.302585092994046;

  /// 取 [ring] 里「距末尾回退 back 样本起、共 len 样本」写到 [out]。
  static bool _windowBeforeEnd(_Ring ring, int back, int len, Float64List out) {
    if (back + len > ring.length) return false;
    final int cap = ring.capacity;
    int start = (ring.writePos - back - len) % cap;
    if (start < 0) start += cap;
    for (int i = 0; i < len; i++) {
      out[i] = ring.buf[start];
      if (++start == cap) start = 0;
    }
    return true;
  }

  void reset() {
    _cap.clear();
    _refKeep.clear();
    _lag = -1;
    _sinceSearch = 0;
    _prevGain = 1.0;
    _lastRho = 0;
    _lastCapDbfs = -90;
    _lastRefDbfs = -90;
  }
}

/// 定长环形缓冲（Float64）。上一版用 `List<int>` 逐样本 add + removeRange，
/// 每秒 4.8 万次插入加搬移，在 isolate 里是纯浪费。
class _Ring {
  _Ring(this.capacity) : buf = Float64List(capacity);

  final int capacity;
  final Float64List buf;
  int writePos = 0;
  int length = 0;

  void addInt16(Int16List s) {
    for (int i = 0; i < s.length; i++) {
      buf[writePos] = s[i].toDouble();
      if (++writePos == capacity) writePos = 0;
      if (length < capacity) length++;
    }
  }

  void clear() {
    writePos = 0;
    length = 0;
  }
}
