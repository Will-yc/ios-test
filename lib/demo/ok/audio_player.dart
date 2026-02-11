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

  // 添加一个标志来跟踪是否在喂数据过程中
  bool _isFeeding = false;

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
      // 设置更小的阈值以确保及时喂数据
      await FlutterPcmSound.setFeedThreshold(320); // 20ms @ 16kHz
      FlutterPcmSound.setFeedCallback(_onFeed);

      _initialized = true;
      debugPrint('[PcmPlayer] 初始化成功');
    } catch (e) {
      debugPrint('[PcmPlayer] 初始化失败: $e');
      onError?.call('初始化播放引擎失败: $e');
    }
  }

  /// 向缓冲区写入样本数据
  void write8Samples(Uint8List chunk) {
    _buffer.addAll(DualUtil.bytesToInt16Samples(chunk));
    // 限制缓冲区大小，丢弃最旧的数据
    while (_buffer.length > maxBufferSamples) {
      _buffer.removeFirst();
    }

    // 如果有数据且播放器正在运行，尝试立即喂数据
    if (_isPlaying && _buffer.length >= 320 && !_isFeeding) {
      _tryFeedImmediately();
    }
  }

  void write16Samples(List<int> chunk) {
    _buffer.addAll(chunk);
    // 限制缓冲区大小，丢弃最旧的数据
    while (_buffer.length > maxBufferSamples) {
      _buffer.removeFirst();
    }

    // 如果有数据且播放器正在运行，尝试立即喂数据
    if (_isPlaying && _buffer.length >= 320 && !_isFeeding) {
      _tryFeedImmediately();
    }
  }

  /// 尝试立即喂数据
  Future<void> _tryFeedImmediately() async {
    if (!_isPlaying || _isFeeding) return;

    try {
      _isFeeding = true;
      // 喂一帧数据（320个样本）
      final frameSize = 320;
      if (_buffer.length >= frameSize) {
        final List<int> samplesToFeed = [];
        for (int i = 0; i < frameSize; i++) {
          samplesToFeed.add(_buffer.removeFirst());
        }
        debugPrint('[PcmPlayer] 立即喂 $frameSize 样本, 缓冲区剩余: ${_buffer.length}');
        await FlutterPcmSound.feed(PcmArrayInt16.fromList(samplesToFeed));
      }
    } catch (e) {
      debugPrint('[PcmPlayer] 立即喂数据失败: $e');
    } finally {
      _isFeeding = false;
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

      // 先喂一些静音，防止启动时缓冲区为空
      final silenceFrameSize = 320; // 20ms
      final silence = List<int>.filled(silenceFrameSize, 0);

      // 喂3帧静音以确保播放器启动
      for (int i = 0; i < 3; i++) {
        await FlutterPcmSound.feed(PcmArrayInt16.fromList(silence));
        await Future.delayed(Duration(milliseconds: 10));
      }

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
      try {
        onStateChanged?.call();
        // FlutterPcmSound.stop();
      } catch (e) {
        debugPrint('[PcmPlayer] 停止播放失败: $e');
      }
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

    if (!_isPlaying || _isFeeding) return;

    try {
      _isFeeding = true;

      // 计算需要的样本数
      final int samplesNeeded;

      if (remainingFrames <= 0) {
        // 如果remainingFrames为0或负数，使用默认帧大小
        samplesNeeded = 320; // 20ms @ 16kHz
        debugPrint(
          '[PcmPlayer] remainingFrames为$remainingFrames，使用默认帧大小: $samplesNeeded',
        );
      } else {
        samplesNeeded = remainingFrames;
      }

      final List<int> samplesToFeed;

      if (_buffer.length >= samplesNeeded) {
        // 有足够数据
        samplesToFeed = List<int>.generate(
          samplesNeeded,
          (_) => _buffer.removeFirst(),
        );
        debugPrint('[PcmPlayer] 喂 $samplesNeeded 样本, 缓冲区剩余: ${_buffer.length}');
      } else if (_buffer.isNotEmpty) {
        // 部分数据 + 静音填充
        final available = _buffer.length;
        final data = List<int>.generate(
          available,
          (_) => _buffer.removeFirst(),
        );
        final silence = List<int>.filled(samplesNeeded - available, 0);
        samplesToFeed = [...data, ...silence];
        debugPrint(
          '[PcmPlayer] 部分喂 $available 样本 + ${samplesNeeded - available} 静音, 缓冲区剩余: ${_buffer.length}',
        );
      } else {
        // 无数据，喂静音
        samplesToFeed = List<int>.filled(samplesNeeded, 0);
        debugPrint('[PcmPlayer] 无数据，喂 $samplesNeeded 静音样本');
      }

      await FlutterPcmSound.feed(PcmArrayInt16.fromList(samplesToFeed));
    } catch (e) {
      debugPrint('[PcmPlayer] 喂数据失败: $e');
    } finally {
      _isFeeding = false;
    }
  }
}
