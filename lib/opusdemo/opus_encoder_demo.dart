// round_trip_page.dart
import 'dart:io';
import 'dart:typed_data';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:my_flutter_app/opusdemo/pcm_data_saver.dart';
import 'package:opus_ffi/opus_ffi.dart';
import 'package:path_provider/path_provider.dart';
import 'package:audioplayers/audioplayers.dart';

// 假设您的 opus.dart 已导出修复后的 OpusDecoder/OpusEncoder 和 PcmDataSaver

class OpusRoundTripPage extends StatefulWidget {
  const OpusRoundTripPage({super.key});

  @override
  State<OpusRoundTripPage> createState() => _OpusRoundTripPageState();
}

class _OpusRoundTripPageState extends State<OpusRoundTripPage> {
  bool _isProcessing = false;
  String? _errorMessage;

  // 原始解码结果
  String? _originalPcmPath;
  Duration? _decodeDuration;

  // 编码结果
  String? _newOpusPath;
  Duration? _encodeDuration;

  // 二次解码结果
  String? _newWavPath;
  Duration? _redecodeDuration;

  // 播放器
  final AudioPlayer _player = AudioPlayer();
  bool _isPlayingOriginal = false;
  bool _isPlayingNew = false;

  // 缓存第一次解码的 PCM（用于重编码）
  Int16List? _cachedPcm;

  @override
  void dispose() {
    _player.dispose();
    super.dispose();
  }

  Future<void> _runRoundTrip() async {
    setState(() {
      _isProcessing = true;
      _errorMessage = null;
      _originalPcmPath = null;
      _newOpusPath = null;
      _newWavPath = null;
      _cachedPcm = null;
    });

    try {
      // -------------------- 1. 加载原始 Opus 文件 --------------------
      final ByteData opusData = await rootBundle.load(
        'assets/R20251013-120111.opus',
      );
      final Uint8List opusBytes = opusData.buffer.asUint8List();

      // -------------------- 2. 解码为 WAV（完全参考您的代码）----------------
      final decoder = OpusDecoder(channels: Channels.mono, sampleRate: 16000);
      final decodeSw = Stopwatch()..start();

      try {
        final dir = await getTemporaryDirectory();
        final pcmPath = '${dir.path}/decoded_audio.pcm';
        final saver = PcmDataSaver(
          pcmPath,
          sampleRate: 16000,
          sampleBits: 16,
          channels: 1,
        );
        await saver.openExt();

        // 按 80 字节块解码
        const int chunkSize = 80;
        int offset = 0;
        final List<Int16List> pcmChunks = [];
        int totalSamples = 0;

        while (offset < opusBytes.length) {
          final remaining = opusBytes.length - offset;
          final currentChunkSize = remaining < chunkSize
              ? remaining
              : chunkSize;
          final chunk = opusBytes.sublist(offset, offset + currentChunkSize);

          final pcmData = decoder.decode(chunk);
          pcmChunks.add(pcmData);
          totalSamples += pcmData.length;

          final pcmBytes = Uint8List.view(pcmData.buffer);
          await saver.write(pcmBytes.toList());

          offset += currentChunkSize;
        }

        // 合并 PCM 以便后续编码
        final mergedPcm = Int16List(totalSamples);
        int pos = 0;
        for (final chunk in pcmChunks) {
          mergedPcm.setAll(pos, chunk);
          pos += chunk.length;
        }
        _cachedPcm = mergedPcm;

        await saver.close();
        decodeSw.stop();

        setState(() {
          _originalPcmPath = pcmPath;
          _decodeDuration = decodeSw.elapsed;
        });
      } finally {
        decoder.dispose();
      }

      // -------------------- 3. 将 PCM 编码为新的 Opus --------------------
      final encoder = OpusEncoder(
        channels: Channels.mono,
        sampleRate: 16000,
        application: Application.voip,
      );
      final encodeSw = Stopwatch()..start();

      try {
        final dir = await getTemporaryDirectory();
        final opusPath = '${dir.path}/reencoded.opus';
        final file = File(opusPath);
        final sink = file.openWrite();

        const int frameSize = 320; // 20ms @16kHz
        final pcm = _cachedPcm!;

        for (int i = 0; i < pcm.length; i += frameSize) {
          final end = (i + frameSize) < pcm.length ? i + frameSize : pcm.length;
          final frame = pcm.sublist(i, end);

          if (frame.length < frameSize) {
            final padded = Int16List(frameSize);
            padded.setAll(0, frame);
            sink.add(encoder.encode(padded, inputSize: frameSize));
          } else {
            sink.add(encoder.encode(frame, inputSize: frameSize));
          }
        }

        await sink.flush();
        await sink.close();
        encodeSw.stop();

        setState(() {
          _newOpusPath = opusPath;
          _encodeDuration = encodeSw.elapsed;
        });
      } finally {
        encoder.dispose();
      }

      // -------------------- 4. 将新 Opus 再次解码为 WAV --------------------
      final reDecoder = OpusDecoder(channels: Channels.mono, sampleRate: 16000);
      final reDecodeSw = Stopwatch()..start();

      try {
        final newOpusBytes = await File(_newOpusPath!).readAsBytes();
        final dir = await getTemporaryDirectory();
        final newWavPath = '${dir.path}/redecoded.wav';
        final saver = PcmDataSaver(
          newWavPath,
          sampleRate: 16000,
          sampleBits: 16,
          channels: 1,
        );
        await saver.open();

        // 一次性解码整个文件（也可按块，但简单起见）
        final pcm = reDecoder.decode(newOpusBytes);
        final pcmBytes = Uint8List.view(pcm.buffer);
        await saver.write(pcmBytes.toList());
        await saver.close();

        reDecodeSw.stop();
        setState(() {
          _newWavPath = newWavPath;
          _redecodeDuration = reDecodeSw.elapsed;
        });
      } finally {
        reDecoder.dispose();
      }

      setState(() => _isProcessing = false);
    } catch (e) {
      setState(() {
        _errorMessage = '往返过程失败: $e';
        _isProcessing = false;
      });
    }
  }

  // ---------- 播放 WAV ----------
  Future<void> _playWav(
    String path,
    bool Function() isPlaying,
    void Function(bool) setIsPlaying,
  ) async {
    try {
      if (isPlaying()) {
        await _player.stop();
        setIsPlaying(false);
      } else {
        await _player.play(DeviceFileSource(path));
        setIsPlaying(true);
        _player.onPlayerComplete.listen((_) {
          if (mounted) setIsPlaying(false);
        });
      }
    } catch (e) {
      setState(() => _errorMessage = '播放失败: $e');
    }
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: const Text('Opus 往返验证 (WAV 版本)')),
      body: SingleChildScrollView(
        padding: const EdgeInsets.all(24),
        child: Column(
          children: [
            ElevatedButton.icon(
              onPressed: _isProcessing ? null : _runRoundTrip,
              icon: _isProcessing
                  ? const SizedBox(
                      width: 20,
                      height: 20,
                      child: CircularProgressIndicator(strokeWidth: 2),
                    )
                  : const Icon(Icons.cyclone),
              label: Text(_isProcessing ? '处理中...' : '开始往返验证'),
              style: ElevatedButton.styleFrom(
                minimumSize: const Size(double.infinity, 48),
              ),
            ),
            const SizedBox(height: 20),

            if (_errorMessage != null)
              Container(
                padding: const EdgeInsets.all(12),
                color: Colors.red.shade50,
                child: Text(
                  _errorMessage!,
                  style: const TextStyle(color: Colors.red),
                ),
              ),

            // 原始 WAV 信息
            if (_originalPcmPath != null) ...[
              const SizedBox(height: 24),
              _buildInfoTile(
                '原始解码 WAV',
                _originalPcmPath!.split('/').last,
                _decodeDuration,
              ),
              ElevatedButton.icon(
                onPressed: () => _playWav(
                  _originalPcmPath!,
                  () => _isPlayingOriginal,
                  (v) => setState(() => _isPlayingOriginal = v),
                ),
                icon: Icon(_isPlayingOriginal ? Icons.stop : Icons.play_arrow),
                label: Text(_isPlayingOriginal ? '停止播放' : '播放原始 WAV'),
                style: ElevatedButton.styleFrom(
                  backgroundColor: Colors.blue,
                  foregroundColor: Colors.white,
                ),
              ),
            ],

            // 新 Opus 文件信息
            if (_newOpusPath != null) ...[
              const SizedBox(height: 24),
              _buildInfoTile(
                '新编码 Opus',
                _newOpusPath!.split('/').last,
                _encodeDuration,
              ),
            ],

            // 新 WAV 信息
            if (_newWavPath != null) ...[
              const SizedBox(height: 24),
              _buildInfoTile(
                '二次解码 WAV',
                _newWavPath!.split('/').last,
                _redecodeDuration,
              ),
              ElevatedButton.icon(
                onPressed: () => _playWav(
                  _newWavPath!,
                  () => _isPlayingNew,
                  (v) => setState(() => _isPlayingNew = v),
                ),
                icon: Icon(_isPlayingNew ? Icons.stop : Icons.play_arrow),
                label: Text(_isPlayingNew ? '停止播放' : '播放新 WAV'),
                style: ElevatedButton.styleFrom(
                  backgroundColor: Colors.green,
                  foregroundColor: Colors.white,
                ),
              ),
            ],
          ],
        ),
      ),
    );
  }

  Widget _buildInfoTile(String title, String subtitle, Duration? duration) {
    return Container(
      width: double.infinity,
      padding: const EdgeInsets.all(16),
      margin: const EdgeInsets.only(bottom: 12),
      decoration: BoxDecoration(
        color: Colors.grey.shade100,
        borderRadius: BorderRadius.circular(8),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(title, style: const TextStyle(fontWeight: FontWeight.bold)),
          const SizedBox(height: 4),
          Text(subtitle, style: const TextStyle(fontSize: 12)),
          if (duration != null)
            Text(
              '耗时: ${duration.inMilliseconds} ms',
              style: const TextStyle(fontSize: 12),
            ),
        ],
      ),
    );
  }
}
