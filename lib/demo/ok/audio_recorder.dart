import 'dart:async';
import 'dart:typed_data';

import 'package:audio_session/audio_session.dart';
import 'package:flutter/foundation.dart';
import 'package:my_flutter_app/demo/util/my_dual_util.dart';
import 'package:record/record.dart';

/// PCM 录音数据回调
typedef OnPcmData = void Function(Uint8List samples);

class PcmRecorder {
  final int sampleRate;
  final int channelCount;
  AudioSession? _audioSession;

  final AudioRecorder _recorder = AudioRecorder();
  StreamSubscription<Uint8List>? _subscription;

  bool _isRecording = false;
  bool get isRecording => _isRecording;

  /// 录音数据回调（Int16 样本）
  OnPcmData? onData;

  /// 错误回调
  ValueChanged<String>? onError;

  /// 状态变化回调
  VoidCallback? onStateChanged;

  PcmRecorder({this.sampleRate = 48000, this.channelCount = 1});

  /// 请求权限
  Future<bool> hasPermission() async {
    return await _recorder.hasPermission();
  }

  /// 开始录音
  Future<void> start() async {
    if (_isRecording) return;

    _audioSession = await AudioSession.instance;

    try {
      if (!await hasPermission()) {
        onError?.call('未获得录音权限');
        return;
      }

      debugPrint('[PcmRecorder] 开始录音...');
      InputDevice? builtInMic = await DualUtil.findBuiltInMicNew(
        recorder: _recorder,
        audioSession: _audioSession,
      );

      final stream = await _recorder.startStream(
        RecordConfig(
          encoder: AudioEncoder.pcm16bits,
          sampleRate: sampleRate,
          numChannels: channelCount,
          device: builtInMic,
        ),
      );

      _isRecording = true;
      onStateChanged?.call();

      _subscription = stream.listen(
        (Uint8List chunk) {
          if (chunk.isEmpty) return;
          onData?.call(chunk);
        },
        onError: (error) {
          debugPrint('[PcmRecorder] 录音流错误: $error');
          onError?.call('录音流错误: $error');
          stop();
        },
        onDone: () {
          debugPrint('[PcmRecorder] 录音流结束');
          stop();
        },
        cancelOnError: true,
      );

      debugPrint('[PcmRecorder] 录音已开始');
    } catch (e) {
      debugPrint('[PcmRecorder] 开始录音失败: $e');
      onError?.call('开始录音失败: $e');
      stop();
    }
  }

  /// 停止录音
  void stop() {
    _subscription?.cancel();
    _subscription = null;

    try {
      _recorder.stop();
    } catch (e) {
      debugPrint('[PcmRecorder] 停止录音异常: $e');
    }

    final wasRecording = _isRecording;
    _isRecording = false;

    if (wasRecording) {
      onStateChanged?.call();
      debugPrint('[PcmRecorder] 录音已停止');
    }
  }

  /// 释放资源
  void dispose() {
    stop();
    _recorder.dispose();
  }
}
