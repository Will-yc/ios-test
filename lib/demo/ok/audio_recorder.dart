import 'dart:async';
import 'dart:typed_data';

import 'package:flutter/foundation.dart';
import 'package:record/record.dart';

/// PCM 录音数据回调
typedef OnPcmData = void Function(List<int> samples);

class PcmRecorder {
  final int sampleRate;
  final int channelCount;

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

  PcmRecorder({this.sampleRate = 44100, this.channelCount = 1});

  /// 请求权限
  Future<bool> hasPermission() async {
    return await _recorder.hasPermission();
  }

  /// 开始录音
  Future<void> start() async {
    if (_isRecording) return;

    try {
      if (!await hasPermission()) {
        onError?.call('未获得录音权限');
        return;
      }

      debugPrint('[PcmRecorder] 开始录音...');

      final stream = await _recorder.startStream(
        RecordConfig(
          encoder: AudioEncoder.pcm16bits,
          sampleRate: sampleRate,
          numChannels: channelCount,
        ),
      );

      _isRecording = true;
      onStateChanged?.call();

      _subscription = stream.listen(
        (Uint8List chunk) {
          if (chunk.isEmpty) return;

          // 字节转 Int16 样本
          final samples = _bytesToInt16Samples(chunk);
          debugPrint(
            '[PcmRecorder] 收到 ${chunk.length} 字节 = ${samples.length} 样本',
          );

          onData?.call(samples);
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

  /// 将 PCM16 little-endian 字节转换为 Int16 样本
  List<int> _bytesToInt16Samples(Uint8List bytes) {
    final sampleCount = bytes.length ~/ 2;
    final samples = List<int>.filled(sampleCount, 0);

    for (int i = 0; i < sampleCount; i++) {
      final low = bytes[i * 2];
      final high = bytes[i * 2 + 1];
      int sample = (high << 8) | low;

      // 有符号转换
      if (sample >= 32768) {
        sample -= 65536;
      }
      samples[i] = sample;
    }

    return samples;
  }
}
