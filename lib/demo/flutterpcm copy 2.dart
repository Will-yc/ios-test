import 'dart:async';
import 'dart:typed_data';

import 'package:flutter/material.dart';
import 'package:flutter_pcm_sound/flutter_pcm_sound.dart';
import 'package:record/record.dart';

class PcmSoundApp extends StatefulWidget {
  @override
  _PcmSoundAppState createState() => _PcmSoundAppState();
}

class _PcmSoundAppState extends State<PcmSoundApp> with WidgetsBindingObserver {
  static const int sampleRate = 44100; // 44100 兼容性更好
  static const int channelCount = 1;

  bool _isPlaying = false;
  bool _isActive = true;
  bool _isRecording = false;
  int _remainingFrames = 0;

  // ✅ 使用 Int16 样本缓冲区，而不是字节缓冲区
  List<int> _sampleBuffer = [];
  final int _maxSamples = sampleRate * 2; // 最多缓存2秒的样本

  final AudioRecorder _audioRecorder = AudioRecorder();
  StreamSubscription<Uint8List>? _audioStreamSubscription;

  final GlobalKey<ScaffoldMessengerState> _scaffoldMessengerKey =
      GlobalKey<ScaffoldMessengerState>();

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    _initAudioEngine();
  }

  Future<void> _initAudioEngine() async {
    try {
      await FlutterPcmSound.setLogLevel(LogLevel.verbose);
      await FlutterPcmSound.setup(
        sampleRate: sampleRate,
        channelCount: channelCount,
      );
      LogLevel level = LogLevel.none;
      FlutterPcmSound.setLogLevel(level);
      // ✅ 设置合理的阈值
      await FlutterPcmSound.setFeedThreshold(sampleRate ~/ 20); // 50ms
      FlutterPcmSound.setFeedCallback(_onFeed);
      debugPrint('音频引擎初始化成功');
    } catch (e) {
      debugPrint('初始化音频引擎失败: $e');
      _showError('初始化音频引擎失败: $e');
    }
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    _stopRecording();
    FlutterPcmSound.release().catchError((e) {
      debugPrint('释放音频引擎失败: $e');
    });
    super.dispose();
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    setState(() {
      _isActive = state == AppLifecycleState.resumed;
    });

    if (_isActive && _isPlaying && !_isRecording) {
      _startRecording();
    } else if (!_isActive && _isRecording) {
      _stopRecording();
    }
  }

  void _showError(String message) {
    debugPrint('Error: $message');
    WidgetsBinding.instance.addPostFrameCallback((_) {
      _scaffoldMessengerKey.currentState?.showSnackBar(
        SnackBar(content: Text("Error: $message")),
      );
    });
  }

  /// ✅ 关键：将 PCM16 字节数据转换为 Int16 样本列表
  List<int> _bytesToInt16Samples(Uint8List bytes) {
    // PCM 16-bit little-endian: 每2个字节组成一个样本
    // 确保字节数是偶数
    int sampleCount = bytes.length ~/ 2;
    List<int> samples = List<int>.filled(sampleCount, 0);

    for (int i = 0; i < sampleCount; i++) {
      int low = bytes[i * 2];
      int high = bytes[i * 2 + 1];
      int sample = (high << 8) | low; // little-endian

      // 转换为有符号 16 位整数
      if (sample >= 32768) {
        sample -= 65536;
      }
      samples[i] = sample;
    }

    return samples;
  }

  void _onFeed(int remainingFrames) async {
    setState(() {
      _remainingFrames = remainingFrames;
    });

    if (!_isPlaying || !_isActive) return;

    try {
      // ✅ remainingFrames 就是需要的样本数（单声道下 frame = sample）
      int samplesNeeded = remainingFrames;

      List<int> samplesToFeed;

      if (_sampleBuffer.length >= samplesNeeded) {
        // 有足够的数据
        samplesToFeed = _sampleBuffer.sublist(0, samplesNeeded);
        _sampleBuffer = _sampleBuffer.sublist(samplesNeeded);
      } else if (_sampleBuffer.isNotEmpty) {
        // 有部分数据，剩余用静音填充
        samplesToFeed = List<int>.from(_sampleBuffer);
        int silence = samplesNeeded - samplesToFeed.length;
        samplesToFeed.addAll(List<int>.filled(silence, 0));
        _sampleBuffer.clear();
      } else {
        // 完全没有数据，喂静音
        samplesToFeed = List<int>.filled(samplesNeeded, 0);
      }

      // debugPrint('喂数据: $samplesNeeded 样本, 缓冲区剩余: ${_sampleBuffer.length} 样本');

      // ✅ PcmArrayInt16.fromList 期望的是 Int16 样本值 (-32768 ~ 32767)
      await FlutterPcmSound.feed(PcmArrayInt16.fromList(samplesToFeed));
    } catch (e) {
      debugPrint('喂数据失败: $e');
    }
  }

  Future<void> _startRecording() async {
    if (_isRecording) return;

    try {
      if (!await _audioRecorder.hasPermission()) {
        _showError('未获得录音权限');
        return;
      }

      _sampleBuffer.clear();

      debugPrint('开始录音...');

      final recordingStream = await _audioRecorder.startStream(
        RecordConfig(
          encoder: AudioEncoder.pcm16bits,
          sampleRate: sampleRate,
          numChannels: channelCount,
        ),
      );

      setState(() {
        _isRecording = true;
      });

      _audioStreamSubscription = recordingStream.listen(
        (Uint8List chunk) {
          if (chunk.isEmpty) return;

          // ✅ 关键修复：将字节转换为 Int16 样本
          List<int> samples = _bytesToInt16Samples(chunk);

          // debugPrint(
          //   '录音数据: ${chunk.length} 字节 = ${samples.length} 样本, '
          //   '缓冲区: ${_sampleBuffer.length} 样本',
          // );

          _sampleBuffer.addAll(samples);

          // 限制缓冲区大小
          if (_sampleBuffer.length > _maxSamples) {
            _sampleBuffer.removeRange(0, _sampleBuffer.length - _maxSamples);
          }
        },
        onError: (error) {
          debugPrint('录音流错误: $error');
          _stopRecording();
        },
        onDone: () {
          debugPrint('录音流结束');
          _stopRecording();
        },
        cancelOnError: true,
      );

      debugPrint('录音已开始');
    } catch (e) {
      debugPrint('开始录音失败: $e');
      _showError('开始录音失败: $e');
      _stopRecording();
    }
  }

  void _stopRecording() {
    _audioStreamSubscription?.cancel();
    _audioStreamSubscription = null;

    try {
      _audioRecorder.stop();
    } catch (e) {
      debugPrint('停止录音失败: $e');
    }

    if (mounted) {
      setState(() {
        _isRecording = false;
      });
    }
    debugPrint('录音已停止');
  }

  Future<void> _startPlaying() async {
    try {
      setState(() {
        _isPlaying = true;
      });

      // ✅ 先喂一些静音数据，避免一开始就触发 feed callback 时缓冲区为空
      await FlutterPcmSound.feed(
        PcmArrayInt16.fromList(List<int>.filled(sampleRate ~/ 10, 0)),
      );

      FlutterPcmSound.start();

      if (_isActive) {
        await _startRecording();
      }

      debugPrint('播放已开始');
    } catch (e) {
      debugPrint('开始播放失败: $e');
      _showError('开始播放失败: $e');
      setState(() {
        _isPlaying = false;
      });
    }
  }

  void _stopPlaying() {
    _isPlaying = false;
    _stopRecording();

    // ✅ 清空缓冲区
    _sampleBuffer.clear();

    setState(() {});
    debugPrint('播放已停止');
  }

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      scaffoldMessengerKey: _scaffoldMessengerKey,
      theme: ThemeData(primarySwatch: Colors.blue),
      home: Scaffold(
        appBar: AppBar(
          centerTitle: true,
          title: Text('Audio Recorder PCM Sound'),
        ),
        body: Center(
          child: Column(
            mainAxisAlignment: MainAxisAlignment.spaceEvenly,
            children: [
              ElevatedButton(
                onPressed: _isPlaying ? null : _startPlaying,
                child: Text('开始录音并播放'),
              ),
              ElevatedButton(
                onPressed: _isPlaying ? _stopPlaying : null,
                child: Text('停止'),
              ),
              Text('$_remainingFrames 剩余帧数'),
              Text('缓冲区: ${_sampleBuffer.length} 样本'),
              Text('录音状态: ${_isRecording ? "🔴 正在录音" : "⬛ 停止"}'),
              Text('播放状态: ${_isPlaying ? "🔊 正在播放" : "🔇 停止"}'),
              Text('应用状态: ${_isActive ? "✅ 活跃" : "⏸ 非活跃"}'),
            ],
          ),
        ),
      ),
    );
  }
}
