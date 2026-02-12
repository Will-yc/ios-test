import 'dart:async';
import 'dart:typed_data';
import 'package:flutter/material.dart';
import 'package:flutter_pcm_sound/flutter_pcm_sound.dart';
import 'package:my_flutter_app/demo/util/my_dual_resampler_rate.dart';
import 'package:record/record.dart' hide IosAudioCategory;
import 'package:opus_ffi/opus_ffi.dart';

// 假设 FlutterPcmSound 和 PcmArrayInt16 类就在当前文件或已导入

class OpusLiveStreamPage extends StatefulWidget {
  const OpusLiveStreamPage({super.key});

  @override
  State<OpusLiveStreamPage> createState() => _OpusLiveStreamPageState();
}

class _OpusLiveStreamPageState extends State<OpusLiveStreamPage> {
  final AudioRecorder _recorder = AudioRecorder();
  StreamSubscription? _subscription;

  // Opus 参数
  late OpusEncoder _encoder;
  late OpusDecoder _decoder;
  static const int _recordSampleRate = 48000;
  static const int _channelCount = 1;
  static const int _opusSampleRate = 16000;
  final int _frameSize = 320; // 20ms @ 48kHz

  // 字节缓冲区：用于暂存从 recorder 出来的原始 Uint8List
  final List<int> _accumulationBuffer = [];
  bool _isRunning = false;

  @override
  void initState() {
    super.initState();
    // 1. 初始化编解码器
    _encoder = OpusEncoder(
      sampleRate: _opusSampleRate,
      channels: Channels.mono,
      application: Application.voip,
    );
    _decoder = OpusDecoder(
      sampleRate: _opusSampleRate,
      channels: Channels.mono,
    );
  }

  Future<void> _toggleStream() async {
    if (_isRunning) {
      await _stop();
    } else {
      await _start();
    }
  }

  Future<void> _start() async {
    if (!await _recorder.hasPermission()) return;

    // 2. 初始化播放器设置 (根据你提供的源码)
    FlutterPcmSound.setLogLevel(LogLevel.none);
    await FlutterPcmSound.setup(
      sampleRate: _opusSampleRate,
      channelCount: _channelCount,
      iosAudioCategory: IosAudioCategory.playAndRecord, // 录播模式
    );

    // 3. 启动录音流
    final stream = await _recorder.startStream(
      const RecordConfig(
        encoder: AudioEncoder.pcm16bits,
        sampleRate: _recordSampleRate,
        numChannels: _channelCount,
      ),
    );

    setState(() => _isRunning = true);

    _subscription = stream.listen((Uint8List chunk) {
      final Uint8List resampled48kTo16k = MyResamplerRate.resample48kTo16k(
        chunk,
      );

      _accumulationBuffer.addAll(resampled48kTo16k);

      // 4. 帧对齐逻辑：Opus 每一帧必须是固定长度
      // 16bit = 2字节。所以 960 采样 = 1920 字节
      while (_accumulationBuffer.length >= _frameSize * 2) {
        final frameBytes = Uint8List.fromList(
          _accumulationBuffer.sublist(0, _frameSize * 2),
        );
        _accumulationBuffer.removeRange(0, _frameSize * 2);

        // --- 编码 (PCM -> Opus) ---
        // 使用 view 避免内存拷贝
        final pcmInput = Int16List.view(frameBytes.buffer);
        final opusPacket = _encoder.encode(pcmInput, inputSize: _frameSize);

        // --- 模拟传输 / 解码 (Opus -> PCM) ---
        final decodedPcm = _decoder.decode(opusPacket);

        // 5. 播放 (对接你提供的 PcmArrayInt16 结构)
        // 效率最高的方法：直接通过 buffer 构造 ByteData
        final pcmArray = PcmArrayInt16(bytes: decodedPcm.buffer.asByteData());

        FlutterPcmSound.feed(pcmArray);
      }
    });
  }

  Future<void> _stop() async {
    await _subscription?.cancel();
    await _recorder.stop();
    await FlutterPcmSound.release(); // 释放资源
    _accumulationBuffer.clear();
    setState(() => _isRunning = false);
  }

  @override
  void dispose() {
    _encoder.dispose();
    _decoder.dispose();
    _recorder.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: const Text("Opus + PcmSound Demo")),
      body: Center(
        child: Column(
          mainAxisAlignment: MainAxisAlignment.center,
          children: [
            const Icon(Icons.mic, size: 64, color: Colors.blue),
            const SizedBox(height: 20),
            ElevatedButton(
              onPressed: _toggleStream,
              style: ElevatedButton.styleFrom(
                backgroundColor: _isRunning ? Colors.red : Colors.green,
                fixedSize: const Size(200, 60),
              ),
              child: Text(_isRunning ? "停止" : "开始 (请佩戴耳机)"),
            ),
          ],
        ),
      ),
    );
  }
}
