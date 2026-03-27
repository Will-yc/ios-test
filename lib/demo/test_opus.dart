import 'dart:async';
import 'dart:typed_data';
import 'package:flutter/material.dart';
import 'package:flutter_pcm_sound/flutter_pcm_sound.dart';
import 'package:my_flutter_app/demo/util/my_dual_resampler_rate.dart';
import 'package:record/record.dart' hide IosAudioCategory;
import 'package:opus_ffi/opus_ffi.dart';

class OpusLiveStreamPage extends StatefulWidget {
  const OpusLiveStreamPage({super.key});

  @override
  State<OpusLiveStreamPage> createState() => _OpusLiveStreamPageState();
}

class _OpusLiveStreamPageState extends State<OpusLiveStreamPage> {
  final AudioRecorder _recorder = AudioRecorder();
  StreamSubscription? _subscription;

  final StreamController<Uint8List> _opusController =
      StreamController<Uint8List>.broadcast();
  Stream<Uint8List> get opusStream => _opusController.stream;

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
    init();
  }

  void init() async {
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
    // FlutterPcmSound.setLogLevel(LogLevel.none);
    await FlutterPcmSound.setup(
      sampleRate: _opusSampleRate,
      channelCount: _channelCount,
      iosAudioCategory: IosAudioCategory.playAndRecord, // 录播模式
    );
    opusStream.listen((opusPacket) {
      final decodedPcm = _decoder.decode(opusPacket);
      final pcmArray = PcmArrayInt16(bytes: decodedPcm.buffer.asByteData());
      FlutterPcmSound.feed(pcmArray);
    });
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

      while (_accumulationBuffer.length >= _frameSize * 2) {
        final frameBytes = Uint8List.fromList(
          _accumulationBuffer.sublist(0, _frameSize * 2),
        );
        _accumulationBuffer.removeRange(0, _frameSize * 2);
        final pcmInput = Int16List.view(frameBytes.buffer);
        final opusPacket = _encoder.encode(pcmInput, inputSize: _frameSize);
        _opusController.add(opusPacket);
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
