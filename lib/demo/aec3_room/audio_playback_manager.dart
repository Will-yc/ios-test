import 'dart:async';
import 'dart:typed_data';

import 'package:flutter/foundation.dart';
import 'package:flutter_pcm_sound/flutter_pcm_sound.dart';

import 'loop_gain_guard.dart';
import 'howl_notch.dart';

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

  /// 底层维持的"安全垫"水位。native 缓冲在 50~100ms 间 oscillate（feed 阈值 50ms）。
  static const int targetNativeMs = 100;

  /// 总延迟（native 余量 + Dart 缓冲）超过这个值就硬追平（清空 Dart 缓冲）。
  ///
  /// **这就是播放侧延迟的硬上限**：Dart 缓冲最多攒到 ~500ms 即被清掉，native
  /// 那 ~100ms 无法清（插件无 flush API），所以播放侧总延迟恒 ≤ ~600ms，
  /// **不会无界积压、不会播放很久之前的音频块**。服务端 2~3.6s 单向延迟是另一
  /// 回事（音频到达时就已经那么旧），播放侧只能保证不再额外叠加超过 ~600ms。
  /// 调小→更贴近 live 但丢弃更频繁；调大→更平滑但延迟更高。500ms 是折中。
  static const int hardSyncThresholdMs = 500;

  bool _isRunning = false;
  bool _isInitialized = false;

  /// 采集侧闭环增益守卫（由页面持有，喂的是 **AEC 前的原始采集**）。
  /// 啸叫是声学闭环在麦克风侧产生的，上一版把检测器挂在下行解码字节上，
  /// 看错了信号 —— 真机日志里一次都没触发过。
  final LoopGainGuard? guard;

  /// 播放侧啸叫陷波（与采集侧同频点，页面检测器统一下发）。
  /// 在参考信号取出**之前**作用，保证 AEC 参考与扬声器字节一致。
  final HowlNotch? notch;

  final BytesBuilder _playbackBuffer = BytesBuilder();

  int _fadeInSamplesRemaining = 0;
  int _nativeRemainingFrames = 0;
  DateTime? _lastPacketTime;

  AudioPlaybackManager({
    this.sampleRate = 48000,
    this.channelCount = 1,
    required dynamic decoder,
    this.onPlaybackReference,
    this.guard,
    this.notch,
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

    // 积压超阈值 → 清掉陈旧的 Dart 缓冲，保住「只播最新、不播很久之前的块」。
    // **但不丢当前包**：当前包是最新到的音频，清完缓冲正好用它重建，否则白白
    // 损失一帧（20ms）最 live 的声音（旧行为 hardSync 后直接 return 把当前包也丢了）。
    // native 已喂的那 ~100ms 无法清（插件无 flush API），是延迟的不可压缩下限。
    if (totalBacklogFrames > _msToFrames(hardSyncThresholdMs)) {
      hardSync();
    }

    try {
      final Int16List decodedPcm = _decoder.decode(opusPacket);
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
    // 同 handleIncomingOpusPacket：积压超阈值清陈旧缓冲，但保留当前（最新）数据。
    if (totalBacklogFrames > _msToFrames(hardSyncThresholdMs)) {
      hardSync();
    }
    _playbackBuffer.add(pcm);
    _tryFillNativeAnchor();
  }

  void hardSync() {
    // 诊断：记录这次丢掉了多少陈旧缓冲（真机上据此判断丢弃是否过频）。
    final double droppedMs =
        (_playbackBuffer.length ~/ (2 * channelCount)) / sampleRate * 1000;
    _playbackBuffer.clear();
    _fadeInSamplesRemaining = _msToFrames(fadeInDurationMs);
    debugPrint('🔥 强制追平：丢弃陈旧缓冲 ${droppedMs.toStringAsFixed(0)}ms，'
        'native 余 ${currentDelayMs.toStringAsFixed(0)}ms（不可清）');
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
    // 播放侧陷波先于 duck 与参考取出：扬声器里就没有啸叫频点，
    // 环路在这一端被挖掉 22dB，且 AEC 参考与扬声器字节仍一致。
    if (notch != null) chunk = notch!.process(chunk);
    final Int16List pcm = chunk.buffer.asInt16List(
      chunk.offsetInBytes,
      chunk.length ~/ 2,
    );
    // 下行能量喂给采集侧守卫，用于「环路增益 = 采集/下行」判据。
    // 必须在乘 duck **之前**取，否则 duck 自己会把这个比值反向放大。
    guard?.feedRender(pcm);
    final ByteData out = ByteData(chunk.length);
    // duck = 采集侧守卫判到起振时的临时压低系数（正常恒为 1.0）
    final double duck = guard?.duckFactor ?? 1.0;

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

// 采集侧守卫（LoopGainGuard）已迁到 loop_gain_guard.dart：
// 旧版把啸叫检测挂在下行解码字节上、判据是「800ms 等幅单频」，
// 真机实测的跳频间歇自激一次都命中不了。这里只保留 duck 读数的注入点。
