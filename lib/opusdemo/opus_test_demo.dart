// import 'package:audioplayers/audioplayers.dart';
// import 'package:flutter/material.dart';
// import 'package:flutter/services.dart';
// import 'package:opus_ffi/opus_ffi.dart';
// import 'package:path_provider/path_provider.dart';
// import 'pcm_data_saver.dart';

// void main() {
//   runApp(const MyApp());
// }

// class MyApp extends StatelessWidget {
//   const MyApp({super.key});

//   @override
//   Widget build(BuildContext context) {
//     return MaterialApp(
//       title: 'Opus 解码示例',
//       theme: ThemeData(
//         colorScheme: ColorScheme.fromSeed(seedColor: Colors.deepPurple),
//         useMaterial3: true,
//       ),
//       home: const OpusDecoderPage(),
//     );
//   }
// }

// class OpusDecoderPage extends StatefulWidget {
//   const OpusDecoderPage({super.key});

//   @override
//   State<OpusDecoderPage> createState() => _OpusDecoderPageState();
// }

// class _OpusDecoderPageState extends State<OpusDecoderPage> {
//   bool _isDecoding = false;
//   bool _isDecoded = false;
//   String? _wavFilePath;
//   String? _errorMessage;
//   final AudioPlayer _audioPlayer = AudioPlayer();
//   bool _isPlaying = false;

//   @override
//   void dispose() {
//     _audioPlayer.dispose();
//     super.dispose();
//   }

//   Future<void> _decodeOpusFile() async {
//     setState(() {
//       _isDecoding = true;
//       _isDecoded = false;
//       _errorMessage = null;
//       _wavFilePath = null;
//     });

//     try {
//       // 加载 opus 文件
//       final ByteData opusData = await rootBundle.load(
//         'assets/R20251013-120111.opus',
//       );
//       final Uint8List opusBytes = opusData.buffer.asUint8List();

//       // 创建解码器（假设是单声道，16kHz 采样率，可以根据实际情况调整）
//       final decoder = OpusDecoder(channels: Channels.mono, sampleRate: 16000);

//       try {
//         // 获取临时目录
//         final directory = await getTemporaryDirectory();
//         final wavPath = '${directory.path}/decoded_audio.wav';

//         // 创建 PCM 数据保存器
//         final pcmSaver = PcmDataSaver(
//           wavPath,
//           sampleRate: 16000,
//           sampleBits: 16,
//           channels: 1,
//         );

//         await pcmSaver.open();

//         // 按块解码 opus 数据（每个块 80 字节，与测试代码保持一致）
//         const int chunkSize = 80;
//         int offset = 0;

//         while (offset < opusBytes.length) {
//           final remaining = opusBytes.length - offset;
//           final currentChunkSize = remaining < chunkSize
//               ? remaining
//               : chunkSize;

//           final chunk = opusBytes.sublist(offset, offset + currentChunkSize);

//           try {
//             final pcmData = decoder.decode(chunk);

//             // 将 Int16List 转换为字节列表以便写入
//             // Int16List 每个元素是 2 字节，所以需要转换为字节数组
//             final pcmBytes = Uint8List.view(pcmData.buffer);
//             await pcmSaver.write(pcmBytes.toList());

//             offset += currentChunkSize;
//           } catch (e) {
//             // 如果单个块解码失败，尝试解码剩余的所有数据
//             if (offset == 0) {
//               // 如果第一个块就失败，尝试解码整个文件
//               final pcmData = decoder.decode(opusBytes);
//               final pcmBytes = Uint8List.view(pcmData.buffer);
//               await pcmSaver.write(pcmBytes.toList());
//             }
//             break;
//           }
//         }

//         await pcmSaver.close();

//         setState(() {
//           _wavFilePath = wavPath;
//           _isDecoded = true;
//           _isDecoding = false;
//         });
//       } finally {
//         decoder.dispose();
//       }
//     } catch (e) {
//       setState(() {
//         _errorMessage = '解码失败: $e';
//         _isDecoding = false;
//       });
//     }
//   }

//   Future<void> _playAudio() async {
//     if (_wavFilePath == null) return;

//     try {
//       if (_isPlaying) {
//         await _audioPlayer.stop();
//         setState(() {
//           _isPlaying = false;
//         });
//       } else {
//         await _audioPlayer.play(DeviceFileSource(_wavFilePath!));
//         setState(() {
//           _isPlaying = true;
//         });

//         // 监听播放完成
//         _audioPlayer.onPlayerComplete.listen((_) {
//           setState(() {
//             _isPlaying = false;
//           });
//         });
//       }
//     } catch (e) {
//       setState(() {
//         _errorMessage = '播放失败: $e';
//         _isPlaying = false;
//       });
//     }
//   }

//   @override
//   Widget build(BuildContext context) {
//     return Scaffold(
//       appBar: AppBar(
//         backgroundColor: Theme.of(context).colorScheme.inversePrimary,
//         title: const Text('Opus 解码示例'),
//       ),
//       body: Center(
//         child: Padding(
//           padding: const EdgeInsets.all(24.0),
//           child: Column(
//             mainAxisAlignment: MainAxisAlignment.center,
//             children: <Widget>[
//               const Text(
//                 'Opus 音频解码测试',
//                 style: TextStyle(fontSize: 24, fontWeight: FontWeight.bold),
//               ),
//               const SizedBox(height: 32),
//               ElevatedButton.icon(
//                 onPressed: _isDecoding ? null : _decodeOpusFile,
//                 icon: _isDecoding
//                     ? const SizedBox(
//                         width: 20,
//                         height: 20,
//                         child: CircularProgressIndicator(strokeWidth: 2),
//                       )
//                     : const Icon(Icons.code),
//                 label: Text(_isDecoding ? '解码中...' : '解码'),
//                 style: ElevatedButton.styleFrom(
//                   padding: const EdgeInsets.symmetric(
//                     horizontal: 32,
//                     vertical: 16,
//                   ),
//                 ),
//               ),
//               const SizedBox(height: 24),
//               if (_isDecoded && _wavFilePath != null) ...[
//                 ElevatedButton.icon(
//                   onPressed: _playAudio,
//                   icon: Icon(_isPlaying ? Icons.stop : Icons.play_arrow),
//                   label: Text(_isPlaying ? '停止播放' : '播放'),
//                   style: ElevatedButton.styleFrom(
//                     padding: const EdgeInsets.symmetric(
//                       horizontal: 32,
//                       vertical: 16,
//                     ),
//                     backgroundColor: Colors.green,
//                     foregroundColor: Colors.white,
//                   ),
//                 ),
//                 const SizedBox(height: 16),
//                 Text(
//                   'WAV 文件已保存: ${_wavFilePath!.split('/').last}',
//                   style: const TextStyle(fontSize: 12, color: Colors.grey),
//                 ),
//               ],
//               if (_errorMessage != null) ...[
//                 const SizedBox(height: 24),
//                 Container(
//                   padding: const EdgeInsets.all(16),
//                   decoration: BoxDecoration(
//                     color: Colors.red.shade50,
//                     borderRadius: BorderRadius.circular(8),
//                     border: Border.all(color: Colors.red.shade200),
//                   ),
//                   child: Row(
//                     children: [
//                       Icon(Icons.error_outline, color: Colors.red.shade700),
//                       const SizedBox(width: 12),
//                       Expanded(
//                         child: Text(
//                           _errorMessage!,
//                           style: TextStyle(color: Colors.red.shade700),
//                         ),
//                       ),
//                     ],
//                   ),
//                 ),
//               ],
//             ],
//           ),
//         ),
//       ),
//     );
//   }
// }
