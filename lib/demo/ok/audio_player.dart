import 'dart:collection';

import 'package:flutter/foundation.dart';
import 'package:flutter_pcm_sound/flutter_pcm_sound.dart';
import 'package:my_flutter_app/demo/util/my_dual_util.dart';

class PcmPlayer {
  final int sampleRate;
  final int channelCount;
  final int maxBufferSamples;

  /// 样本缓冲区
  final Queue<int> _buffer = Queue<int>();
  int get bufferLength => _buffer.length;

  bool _isPlaying = false;
  bool get isPlaying => _isPlaying;

  bool _initialized = false;

  int _remainingFrames = 0;
  int get remainingFrames => _remainingFrames;

  /// 状态变化回调
  VoidCallback? onStateChanged;

  /// 错误回调
  ValueChanged<String>? onError;

  PcmPlayer({
    this.sampleRate = 48000,
    this.channelCount = 1,
    int maxBufferSeconds = 1,
  }) : maxBufferSamples = sampleRate * channelCount * maxBufferSeconds;

  /// 初始化播放引擎
  Future<void> init() async {
    if (_initialized) return;

    try {
      await FlutterPcmSound.setLogLevel(LogLevel.verbose);
      await FlutterPcmSound.setup(
        sampleRate: sampleRate,
        channelCount: channelCount,
      );
      await FlutterPcmSound.setFeedThreshold(sampleRate ~/ 20); // 50ms
      FlutterPcmSound.setFeedCallback(_onFeed);

      _initialized = true;
      debugPrint('[PcmPlayer] 初始化成功');
    } catch (e) {
      debugPrint('[PcmPlayer] 初始化失败: $e');
      onError?.call('初始化播放引擎失败: $e');
    }
  }

  /// 向缓冲区写入样本数据
  void writeSamples(Uint8List chunk) {
    _buffer.addAll(DualUtil.bytesToInt16Samples(chunk));
    // 限制缓冲区大小，丢弃最旧的数据
    while (_buffer.length > maxBufferSamples) {
      _buffer.removeFirst();
    }
  }

  /// 开始播放
  Future<void> start() async {
    if (_isPlaying) return;

    if (!_initialized) {
      await init();
    }

    try {
      _isPlaying = true;

      // 先喂一小段静音，防止启动时缓冲区为空
      final silence = List<int>.filled(sampleRate ~/ 10, 0);
      await FlutterPcmSound.feed(PcmArrayInt16.fromList(silence));

      FlutterPcmSound.start();

      onStateChanged?.call();
      debugPrint('[PcmPlayer] 播放已开始');
    } catch (e) {
      _isPlaying = false;
      debugPrint('[PcmPlayer] 开始播放失败: $e');
      onError?.call('开始播放失败: $e');
    }
  }

  /// 停止播放
  void stop() {
    final wasPlaying = _isPlaying;
    _isPlaying = false;
    _buffer.clear();

    if (wasPlaying) {
      onStateChanged?.call();
      debugPrint('[PcmPlayer] 播放已停止');
    }
  }

  /// 释放资源
  Future<void> dispose() async {
    stop();
    try {
      await FlutterPcmSound.release();
    } catch (e) {
      debugPrint('[PcmPlayer] 释放失败: $e');
    }
    _initialized = false;
  }

  /// FlutterPcmSound 请求数据的回调
  void _onFeed(int remainingFrames) async {
    _remainingFrames = remainingFrames;
    onStateChanged?.call();

    if (!_isPlaying) return;

    try {
      final samplesNeeded = remainingFrames;
      final List<int> samplesToFeed;

      if (_buffer.length >= samplesNeeded) {
        // 有足够数据
        samplesToFeed = List<int>.generate(
          samplesNeeded,
          (_) => _buffer.removeFirst(),
        );
      } else if (_buffer.isNotEmpty) {
        // 部分数据 + 静音填充
        final available = _buffer.length;
        final data = List<int>.generate(
          available,
          (_) => _buffer.removeFirst(),
        );
        final silence = List<int>.filled(samplesNeeded - available, 0);
        samplesToFeed = [...data, ...silence];
      } else {
        // 无数据，喂静音
        samplesToFeed = List<int>.filled(samplesNeeded, 0);
      }

      debugPrint('[PcmPlayer] 喂 $samplesNeeded 样本, 缓冲区剩余: ${_buffer.length}');

      await FlutterPcmSound.feed(PcmArrayInt16.fromList(samplesToFeed));
    } catch (e) {
      debugPrint('[PcmPlayer] 喂数据失败: $e');
    }
  }
}
