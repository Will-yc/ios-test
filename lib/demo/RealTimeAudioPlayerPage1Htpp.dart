import 'dart:async';
import 'dart:io';
import 'dart:typed_data';
import 'package:flutter/material.dart';
import 'package:just_audio/just_audio.dart';
import 'package:record/record.dart';
import 'package:shelf/shelf.dart';
import 'package:shelf/shelf_io.dart' as shelf_io;

class RealTimeAudioPlayerHttpPage extends StatefulWidget {
  @override
  _RealTimeAudioPlayerHttpPageState createState() =>
      _RealTimeAudioPlayerHttpPageState();
}

class _RealTimeAudioPlayerHttpPageState
    extends State<RealTimeAudioPlayerHttpPage> {
  final _audioRecorder = AudioRecorder();
  final AudioPlayer _audioPlayer = AudioPlayer();

  HttpServer? _httpServer;
  StreamSubscription<Uint8List>? _audioStreamSubscription;
  final StreamController<Uint8List> _audioStreamController =
      StreamController<Uint8List>();
  bool _isRecording = false;
  bool _isPlaying = false;
  int _port = 8080;

  @override
  void initState() {
    super.initState();
    _startHttpServer();
  }

  Future<void> _startHttpServer() async {
    final handler = _createHttpHandler();

    try {
      _httpServer = await shelf_io.serve(
        handler,
        InternetAddress.anyIPv4,
        _port,
      );
      print('HTTP服务器启动在端口 ${_httpServer!.port}');
    } catch (e) {
      print('启动HTTP服务器失败: $e');
    }
  }

  Handler _createHttpHandler() {
    return (Request request) async {
      if (request.url.path == '/audio') {
        // 返回音频流
        final stream = _audioStreamController.stream;

        return Response.ok(
          stream,
          headers: {
            'Content-Type': 'audio/wav',
            'Transfer-Encoding': 'chunked',
            'Connection': 'keep-alive',
          },
        );
      }

      return Response.notFound('Not Found');
    };
  }

  Future<void> _startRecording() async {
    if (_isRecording) return;

    try {
      // 开始录音流
      final stream = await _audioRecorder.startStream(
        RecordConfig(
          encoder: AudioEncoder.pcm16bits,
          sampleRate: 16000,
          numChannels: 1,
        ),
      );

      setState(() {
        _isRecording = true;
      });

      // 监听录音流并发送到HTTP流
      _audioStreamSubscription = stream.listen(
        (chunk) {
          final wavChunk = _createWavChunk(chunk);
          _audioStreamController.add(wavChunk);
        },
        onError: (error) {
          print('录音流错误: $error');
          _stopRecording();
        },
        onDone: () {
          print('录音流结束');
          _stopRecording();
        },
      );

      // 开始播放
      await _startPlaying();
    } catch (e) {
      print('开始录音失败: $e');
    }
  }

  Future<void> _startPlaying() async {
    if (_isPlaying) return;

    try {
      // 使用HTTP URL作为音频源
      final audioSource = AudioSource.uri(
        Uri.parse('http://localhost:${_httpServer?.port ?? _port}/audio'),
      );

      await _audioPlayer.setAudioSource(audioSource);
      await _audioPlayer.play();

      setState(() {
        _isPlaying = true;
      });
    } catch (e) {
      print('开始播放失败: $e');
    }
  }

  Uint8List _createWavChunk(Uint8List pcmData) {
    // 对于流式WAV，我们只需要发送一次头，然后发送数据
    // 这里简化处理，实际需要更复杂的逻辑
    return pcmData;
  }

  Future<void> _stopRecording() async {
    setState(() {
      _isRecording = false;
    });

    await _audioStreamSubscription?.cancel();
    await _audioRecorder.stop();
    await _stopPlaying();
  }

  Future<void> _stopPlaying() async {
    setState(() {
      _isPlaying = false;
    });

    await _audioPlayer.stop();
    _audioStreamController.close();
  }

  @override
  void dispose() {
    _audioStreamSubscription?.cancel();
    _audioRecorder.dispose();
    _audioPlayer.dispose();
    _audioStreamController.close();
    _httpServer?.close();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: Text('实时音频播放')),
      body: Center(
        child: Column(
          mainAxisAlignment: MainAxisAlignment.center,
          children: [
            Text('HTTP服务器端口: ${_httpServer?.port ?? _port}'),
            SizedBox(height: 20),
            ElevatedButton(
              onPressed: _isRecording ? null : _startRecording,
              child: Text('开始录音并播放'),
            ),
            SizedBox(height: 20),
            ElevatedButton(
              onPressed: _isRecording ? _stopRecording : null,
              child: Text('停止'),
            ),
          ],
        ),
      ),
    );
  }
}
