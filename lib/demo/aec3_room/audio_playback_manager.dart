import 'dart:async';
import 'dart:math' as math;
import 'dart:typed_data';

import 'package:flutter/foundation.dart';
import 'package:flutter_pcm_sound/flutter_pcm_sound.dart';

/// 下行播放器（严格对齐原工程 `my_dual_audio_playback_manager.dart` 的结构，
/// 只做了一个改动：**1.25x 变速被彻底删掉**）。
///
/// 为什么必须删：
///   AEC 要求「参考信号 ↔ 采集信号」的延迟稳定。1.25x 变速会让两边延迟持续
///   漂移，自适应滤波器永远在重新收敛 —— 外放回声根本消不干净。
///   原工程是用 `fixedPlaybackRate: kEnableAec` 把这条路关掉的，这里直接不实现。
///
/// hardSync 保留：它丢弃的是**尚未喂给底层**的数据，不改变已经在播的那 100ms
/// 节奏，所以对 AEC 无影响；网络断层时靠它把延迟拉回来。
class AudioPlaybackManager {
  final int sampleRate;
  final int channelCount;
  final dynamic _decoder;

  /// 播放增益。**别再往上调**：外放对讲时这份字节同时是 AEC 的参考信号，
  /// 乘 1.6 后凡峰值超过 20479 的样本都会被 clamp 硬削波，削波是不可逆的
  /// 非线性 —— AEC 的线性自适应滤波器只匹配得上基波，削出来的谐波会当成
  /// 近端人声留在成品里，听感就是"文件里还有对方的声音"。
  /// 要更响请调系统媒体音量，而不是在这里放大。
  final double baseVolume;
  static const double defaultBaseVolume = 1.0;
  static const int fadeInDurationMs = 10;

  /// 底层维持的"安全垫"水位
  static const int targetNativeMs = 100;

  /// 总延迟超过这个值就硬追平
  static const int hardSyncThresholdMs = 500;

  bool _isRunning = false;
  bool _isInitialized = false;

  /// 啸叫兜底：闭环自激一旦起振，靠人去关音量已经来不及。
  final _HowlingGuard _howling = _HowlingGuard();

  final BytesBuilder _playbackBuffer = BytesBuilder();

  int _fadeInSamplesRemaining = 0;
  int _nativeRemainingFrames = 0;
  DateTime? _lastPacketTime;

  AudioPlaybackManager({
    this.sampleRate = 48000,
    this.channelCount = 1,
    required dynamic decoder,
    this.onPlaybackReference,
    double baseVolume = defaultBaseVolume,
  })  : _decoder = decoder,
        baseVolume = baseVolume <= 0 ? defaultBaseVolume : baseVolume;

  /// 参考信号回调：把「正在送给扬声器」的那份 PCM 原样交出去（WebRTC AEC3 用）。
  /// 必须与喂给底层的**同一份**数据（已过 baseVolume + 渐入）。
  final void Function(Uint8List pcm)? onPlaybackReference;

  int _msToFrames(int ms) => (sampleRate * (ms / 1000.0)).toInt();

  int get totalBacklogFrames {
    final int dartFrames = _playbackBuffer.length ~/ (2 * channelCount);
    return _nativeRemainingFrames + dartFrames;
  }

  double get currentDelayMs => (totalBacklogFrames / sampleRate) * 1000;

  Future<void> init() async {
    if (_isInitialized) await dispose();
    await Future.delayed(const Duration(milliseconds: 100));

    FlutterPcmSound.setLogLevel(LogLevel.error);
    // 🔴 必须 playAndRecord：插件默认 playback，会把 record 随后设的
    //    playAndRecord category 切换成"打断正在跑的 AudioUnit"，
    //    结果就是"开始录音后听不到对方"。
    await _enqueueAudioOp(
      () => FlutterPcmSound.setup(
        sampleRate: sampleRate,
        channelCount: channelCount,
        iosAudioCategory: IosAudioCategory.playAndRecord,
      ),
      propagateError: true,
    );

    await FlutterPcmSound.setFeedThreshold(_msToFrames(50));
    FlutterPcmSound.setFeedCallback((remainingFrames) {
      _nativeRemainingFrames = remainingFrames;
      _tryFillNativeAnchor();
    });

    _isInitialized = true;
    _isRunning = true;
    debugPrint('✅ 播放器初始化完成 (target=${targetNativeMs}ms)');
  }

  /// 收到一个 opus 包（对端上行是 16k 编码，这里按 48k 解码 —— opus 支持
  /// 解码到任意标准采样率，且内部本来就在 48k 域工作，零额外损失）。
  void handleIncomingOpusPacket(Uint8List opusPacket) {
    if (!_isRunning || !_isInitialized) return;

    final now = DateTime.now();
    if (_lastPacketTime != null &&
        now.difference(_lastPacketTime!).inMilliseconds > 800) {
      debugPrint('📡 网络断层重启（渐入 10ms）');
      _fadeInSamplesRemaining = _msToFrames(fadeInDurationMs);
    }
    _lastPacketTime = now;

    if (totalBacklogFrames > _msToFrames(hardSyncThresholdMs)) {
      hardSync();
      return;
    }

    try {
      final Int16List decodedPcm = _decoder.decode(opusPacket);
      _howling.feed(decodedPcm);
      _playbackBuffer.add(Uint8List.view(
        decodedPcm.buffer,
        decodedPcm.offsetInBytes,
        decodedPcm.lengthInBytes,
      ));
      _tryFillNativeAnchor();
    } catch (e) {
      debugPrint('解码异常: $e');
    }
  }

  /// E2E 自测用：直接把 48k/16bit/mono PCM 塞进播放链路（跳过 opus 解码）。
  /// 与 [handleIncomingOpusPacket] 走同一条 feed 路径，所以参考信号依旧是
  /// 「正在送给扬声器的同一份字节」—— AEC 对比实验的前提。
  void handleRawPcm(Uint8List pcm) {
    if (!_isRunning || !_isInitialized || pcm.isEmpty) return;
    if (totalBacklogFrames > _msToFrames(hardSyncThresholdMs)) {
      hardSync();
      return;
    }
    _playbackBuffer.add(pcm);
    _tryFillNativeAnchor();
  }

  void hardSync() {
    _playbackBuffer.clear();
    _fadeInSamplesRemaining = _msToFrames(fadeInDurationMs);
    debugPrint('🔥 强制追平，当前总延迟 ${currentDelayMs.toStringAsFixed(1)}ms');
  }

  void _tryFillNativeAnchor() {
    if (!_isRunning || _playbackBuffer.isEmpty) return;

    final int targetFrames = _msToFrames(targetNativeMs);
    if (_nativeRemainingFrames < targetFrames) {
      final int framesNeeded = targetFrames - _nativeRemainingFrames;
      final int bytesNeeded = framesNeeded * 2 * channelCount;

      final Uint8List allData = _playbackBuffer.takeBytes();
      final int toWrite = bytesNeeded.clamp(0, allData.length);

      _doFeed(allData.sublist(0, toWrite));

      if (toWrite < allData.length) {
        _playbackBuffer.add(allData.sublist(toWrite));
      }
    }
  }

  void _doFeed(Uint8List chunk) {
    final Int16List pcm = chunk.buffer.asInt16List(
      chunk.offsetInBytes,
      chunk.length ~/ 2,
    );
    final ByteData out = ByteData(chunk.length);
    // duck = 啸叫兜底的临时压低系数（检测不到啸叫时恒为 1.0）
    final double duck = _howling.duckFactor;

    for (int i = 0; i < pcm.length; i++) {
      double vol = baseVolume * duck;
      if (_fadeInSamplesRemaining > 0) {
        final double factor =
            1.0 - (_fadeInSamplesRemaining / _msToFrames(fadeInDurationMs));
        vol *= factor;
        _fadeInSamplesRemaining--;
      }
      final int processed = (pcm[i] * vol).round().clamp(-32768, 32767);
      out.setInt16(i * 2, processed, Endian.little);
    }

    // 🔴 先把参考信号交出去，再喂扬声器：AEC 需要参考「早于」对应采集帧到达。
    onPlaybackReference?.call(out.buffer.asUint8List(0, chunk.length));

    FlutterPcmSound.feed(PcmArrayInt16(bytes: out));
    _nativeRemainingFrames += chunk.length ~/ (2 * channelCount);
  }

  double getCurrentDelay() {
    if (!_isInitialized || !_isRunning) return 0;
    final double delay = currentDelayMs;
    return delay > 100 ? delay : 0;
  }

  Future<void> dispose() async {
    _isRunning = false;
    _isInitialized = false;
    _playbackBuffer.clear();
    _lastPacketTime = null;
    FlutterPcmSound.setFeedCallback(null);
    await _enqueueAudioOp(() => FlutterPcmSound.release());
    debugPrint('🧹 播放器资源已释放');
  }

  // --- 进程级音频引擎操作的串行队列 ---
  // setup()/release() 动的是同一份进程级 AVAudioSession + AudioUnit，
  // 两个都是不等待的平台通道调用：上一个页面的 release 晚到会把新页面的
  // AudioUnit 一起拆掉（表现为"既听不到也录不到"）。用一条 Future 链严格排序。
  static Future<void> _audioOpChain = Future<void>.value();

  static Future<void> _enqueueAudioOp(
    Future<void> Function() op, {
    bool propagateError = false,
  }) {
    final run = _audioOpChain.then((_) => op());
    _audioOpChain = run.catchError((Object e) {
      debugPrint('音频引擎操作失败: $e');
    });
    return propagateError ? run : _audioOpChain;
  }
}

/// 啸叫（闭环自激）兜底。
///
/// 无耳机双端外放时，A 麦 → 上行 → B 扬声器 → B 麦 → 上行 → A 扬声器
/// 是一个闭环；只要有一端 AEC 没对齐（残余回声没消掉），环路增益就可能过 1，
/// 在某个频点起振——表现为双方都不说话时突然尖啸，靠人去关音量根本来不及。
///
/// 检测特征（纯时域，零依赖）：啸叫是**等幅单频正弦**，
/// 它的「每帧过零率」几乎恒定；语音的过零率帧间波动很大。
/// 连续 800ms 过零率变异系数 < 2% 且每帧都够响 → 判定啸叫，
/// 立即把播放增益压到 0.3（打断环路），3 秒内线性恢复。
///
/// 误伤分析：正常语音不可能 800ms 过零率恒定；稳态窄带噪声（风扇）能量
/// 远低于 -40dBFS 门限。duck 期间参考信号同步缩小（取自同一份 out 字节），
/// AEC 只需跟着慢变增益收敛，不会错位。
class _HowlingGuard {
  static const int windowFrames = 40; // 40 × 20ms = 800ms
  static const double minRms = 0.01; // -40dBFS，排除本底噪声
  static const double zcrCvLimit = 0.02; // 过零率变异系数门限
  static const double minZcr = 0.005; // 过零率太低（近直流/极低频）不判
  static const double duckLevel = 0.3;
  static const int holdFrames = 150; // 压低保持 3s 后线性恢复

  final List<double> _zcrs = <double>[];
  final List<double> _rmss = <double>[];
  int _duckFramesLeft = 0;
  bool _logged = false;

  double _duck = 1.0;
  double get duckFactor => _duck;

  void feed(Int16List frame) {
    final int n = frame.length;
    if (n < 64) return;

    int crossings = 0;
    double sumSq = 0.0;
    for (int i = 1; i < n; i++) {
      final int a = frame[i - 1];
      final int b = frame[i];
      if ((a >= 0) != (b >= 0)) crossings++;
      final double v = b / 32768.0;
      sumSq += v * v;
    }
    _zcrs.add(crossings / n);
    _rmss.add(math.sqrt(sumSq / n));
    if (_zcrs.length > windowFrames) {
      _zcrs.removeAt(0);
      _rmss.removeAt(0);
    }

    // duck 状态推进（线性恢复，让 AEC 能跟着收敛）
    if (_duckFramesLeft > 0) {
      _duckFramesLeft--;
      final double t = 1.0 - _duckFramesLeft / holdFrames;
      _duck = duckLevel + (1.0 - duckLevel) * t;
      if (_duckFramesLeft == 0) _logged = false;
    } else {
      _duck = 1.0;
    }

    // 检测（只在未 duck 时判，避免恢复期反复触发）
    if (_duckFramesLeft > 0 || _zcrs.length < windowFrames) return;
    for (final r in _rmss) {
      if (r < minRms) return;
    }
    final double mean = _zcrs.reduce((a, b) => a + b) / windowFrames;
    if (mean < minZcr) return;
    double varSum = 0.0;
    for (final z in _zcrs) {
      final double d = z - mean;
      varSum += d * d;
    }
    final double cv = math.sqrt(varSum / windowFrames) / mean;
    if (cv < zcrCvLimit) {
      _duckFramesLeft = holdFrames;
      _duck = duckLevel;
      if (!_logged) {
        _logged = true;
        debugPrint('🔥 检测到啸叫（过零率恒定 ${mean.toStringAsFixed(3)}，'
            'CV=${cv.toStringAsFixed(4)}），压低播放增益 3 秒');
      }
    }
  }
}
