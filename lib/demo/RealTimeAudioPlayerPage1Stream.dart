import 'dart:async';
import 'dart:typed_data';
import 'package:flutter/material.dart';
import 'package:just_audio/just_audio.dart';
import 'package:record/record.dart';

/// Helper function to convert an integer to a Uint8List,
/// correctly handling byte counts and little-endian format for WAV headers.
Uint8List _intToBytes(int value, int byteCount) {
  final buffer = Uint8List(byteCount).buffer;
  final byteData = ByteData.view(buffer);
  if (byteCount == 2) {
    byteData.setUint16(0, value, Endian.little);
  } else if (byteCount == 4) {
    byteData.setUint32(0, value, Endian.little);
  } else {
    throw Exception('Unsupported byteCount for _intToBytes: $byteCount');
  }
  return buffer.asUint8List();
}

/// Generates a WAV header for streaming PCM audio.
/// It uses 0x7FFFFFFF as a placeholder for chunk sizes, indicating unknown length,
/// which is suitable for real-time streaming.
Uint8List _createWavHeader(int sampleRate, int numChannels, int bitsPerSample) {
  final byteRate = (sampleRate * numChannels * bitsPerSample) ~/ 8;
  final blockAlign = (numChannels * bitsPerSample) ~/ 8;

  final header = BytesBuilder();
  // RIFF chunk
  header.add(Uint8List.fromList('RIFF'.codeUnits));
  header.add(
    _intToBytes(0x7FFFFFFF, 4),
  ); // ChunkSize (placeholder for unknown size)
  header.add(Uint8List.fromList('WAVE'.codeUnits));

  // fmt sub-chunk
  header.add(Uint8List.fromList('fmt '.codeUnits));
  header.add(_intToBytes(16, 4)); // Subchunk1Size (16 for PCM)
  header.add(_intToBytes(1, 2)); // AudioFormat (1 for PCM)
  header.add(_intToBytes(numChannels, 2)); // NumChannels
  header.add(_intToBytes(sampleRate, 4)); // SampleRate
  header.add(_intToBytes(byteRate, 4)); // ByteRate
  header.add(_intToBytes(blockAlign, 2)); // BlockAlign
  header.add(_intToBytes(bitsPerSample, 2)); // BitsPerSample

  // data sub-chunk
  header.add(Uint8List.fromList('data'.codeUnits));
  header.add(
    _intToBytes(0x7FFFFFFF, 4),
  ); // Subchunk2Size (data size, placeholder for unknown size)

  return header.toBytes();
}

class RealTimeAudioPlayerStreamPage extends StatefulWidget {
  @override
  _RealTimeAudioPlayerPageState createState() =>
      _RealTimeAudioPlayerPageState();
}

class _RealTimeAudioPlayerPageState
    extends State<RealTimeAudioPlayerStreamPage> {
  final _audioRecorder = AudioRecorder();
  final AudioPlayer _audioPlayer = AudioPlayer();
  StreamSubscription<Uint8List>? _audioStreamSubscription;
  bool _isRecording = false;
  bool _isPlaying = false;

  // Define audio parameters for WAV header, matching RecordConfig
  static const int _sampleRate = 16000;
  static const int _numChannels = 1;
  static const int _bitsPerSample = 16; // 16 bits for pcm16bits

  @override
  void initState() {
    super.initState();
    // Initialize the audio player, though `setAudioSource` will be called on demand.
  }

  Future<void> _startRecordingAndPlaying() async {
    if (!await _audioRecorder.hasPermission()) {
      print('未获得录音权限');
      return;
    }
    if (_isRecording) return; // Prevent starting if already recording

    try {
      // Start recording stream with specified configuration
      final recordingStream = await _audioRecorder.startStream(
        RecordConfig(
          encoder: AudioEncoder.pcm16bits,
          sampleRate: _sampleRate,
          numChannels: _numChannels,
        ),
      );

      setState(() {
        _isRecording = true;
      });

      // Create a new StreamAudioSources instance with the live recording stream
      // and the WAV parameters. This ensures a fresh stream for each playback session.
      final audioSource = StreamAudioSources(
        recordingStream,
        _sampleRate,
        _numChannels,
        _bitsPerSample,
      );

      // Set the audio source to the player
      await _audioPlayer.setAudioSource(audioSource);

      // Start playing the audio
      await _audioPlayer.play();

      setState(() {
        _isPlaying = true;
      });

      // Listen to the recording stream to manage UI state if recording stops externally
      _audioStreamSubscription = recordingStream.listen(
        (chunk) {
          debugPrint("PCM 数据流入中: ${chunk.length} bytes");
          // You can add debugging here if needed, e.g., print('Received PCM chunk size: ${chunk.length}');
        },
        onError: (error) {
          print('Recording stream error: $error');
          _stopRecordingAndPlaying(); // Stop everything on recording error
        },
        onDone: () {
          print('Recording stream finished externally');
          _stopRecordingAndPlaying(); // Stop everything on recording stream end
        },
      );
    } catch (e) {
      print('Failed to start recording and playing: $e');
      _stopRecordingAndPlaying(); // Ensure state is reset if an error occurs
    }
  }

  Future<void> _stopRecordingAndPlaying() async {
    // Only proceed if currently recording or playing to avoid unnecessary operations
    if (!_isRecording && !_isPlaying) return;

    setState(() {
      _isRecording = false;
      _isPlaying = false;
    });

    // Cancel the subscription to the recording stream
    await _audioStreamSubscription?.cancel();
    _audioStreamSubscription = null; // Clear the subscription

    // Stop the audio recorder
    await _audioRecorder.stop();

    // Stop the audio player
    await _audioPlayer.stop();
  }

  @override
  void dispose() {
    _audioStreamSubscription?.cancel(); // Cancel any active subscription
    _audioRecorder.dispose(); // Dispose the recorder
    _audioPlayer.dispose(); // Dispose the player
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: const Text('实时音频播放')),
      body: Center(
        child: Column(
          mainAxisAlignment: MainAxisAlignment.center,
          children: <Widget>[
            ElevatedButton(
              onPressed: _isRecording ? null : _startRecordingAndPlaying,
              child: const Text('开始录音并播放'),
            ),
            const SizedBox(height: 20),
            ElevatedButton(
              onPressed: _isRecording ? _stopRecordingAndPlaying : null,
              child: const Text('停止'),
            ),
          ],
        ),
      ),
    );
  }
}

class StreamAudioSources extends StreamAudioSource {
  final Stream<Uint8List> _pcmStream;
  final int sampleRate;
  final int numChannels;
  final int bitsPerSample;

  StreamAudioSources(
    this._pcmStream,
    this.sampleRate,
    this.numChannels,
    this.bitsPerSample,
  );

  @override
  Future<StreamAudioResponse> request([int? start, int? end]) async {
    // 强制从头开始，对于实时流，忽略 just_audio 的 range 请求
    final streamController = StreamController<Uint8List>();

    // 添加 WAV 头
    final header = _createWavHeader(sampleRate, numChannels, bitsPerSample);
    streamController.add(header);

    // 订阅广播流并转发
    final subscription = _pcmStream.listen(
      (data) {
        if (!streamController.isClosed) {
          streamController.add(data);
        }
      },
      onDone: () => streamController.close(),
      onError: (e) => streamController.addError(e),
      cancelOnError: false,
    );

    return StreamAudioResponse(
      sourceLength: null,
      contentLength: null,
      offset: 0,
      stream: streamController.stream,
      contentType: 'audio/wav',
    );
  }
}
