// import 'dart:typed_data';

// import 'package:flutter/material.dart';
// import 'package:my_flutter_app/demo/ok/audio_player.dart';
// import 'package:my_flutter_app/demo/ok/audio_recorder.dart';
// import 'package:my_flutter_app/demo/util/my_dual_resampler_rate.dart';
// import 'package:my_flutter_app/demo/util/my_dual_util.dart';
// import 'package:opus_ffi/opus_ffi.dart';

// class PcmSoundAppOpus extends StatefulWidget {
//   @override
//   _PcmSoundAppOpusState createState() => _PcmSoundAppOpusState();
// }

// class _PcmSoundAppOpusState extends State<PcmSoundAppOpus>
//     with WidgetsBindingObserver {
//   // 录音器使用 48kHz（硬件录音）
//   static const int _recordSampleRate = 48000;
//   // Opus和播放器使用 16kHz（网络传输优化）
//   static const int _opusSampleRate = 16000;
//   static const int _channelCount = 1;
//   static const int frameSize = 320; // 20ms @ 16kHz

//   // Opus 编解码器（16kHz）
//   final encoder = OpusDecoder(
//     channels: Channels.mono,
//     sampleRate: _opusSampleRate,
//   );
//   // OpusEncoder.create(
//   //   sampleRate: _opusSampleRate,
//   //   channels: _channelCount,
//   // );
//   final decoder = OpusEncoder(
//     channels: Channels.mono,
//     sampleRate: _opusSampleRate,
//   );
//   // OpusDecoder.create(
//   //   sampleRate: _opusSampleRate,
//   //   channels: _channelCount,
//   // );

//   bool _isActive = true;

//   late final PcmRecorder _recorder;
//   late final PcmPlayer _player;

//   final GlobalKey<ScaffoldMessengerState> _scaffoldKey =
//       GlobalKey<ScaffoldMessengerState>();

//   @override
//   void initState() {
//     super.initState();
//     WidgetsBinding.instance.addObserver(this);

//     // 创建录音器（48kHz）
//     _recorder = PcmRecorder(
//       sampleRate: _recordSampleRate,
//       channelCount: _channelCount,
//     );
//     _recorder.onData = _onRecordData;
//     _recorder.onError = _showError;
//     _recorder.onStateChanged = _refresh;

//     // 创建播放器（16kHz，匹配Opus输出）
//     _player = PcmPlayer(
//       sampleRate: _opusSampleRate,
//       channelCount: _channelCount,
//       maxBufferSeconds: 1,
//     );
//     _player.onError = _showError;
//     _player.onStateChanged = _refresh;

//     // 初始化播放引擎
//     _player.init();

//     // 设
//   }

//   @override
//   void dispose() {
//     WidgetsBinding.instance.removeObserver(this);
//     _recorder.dispose();
//     _player.dispose();

//     // 释放 Opus 资源
//     encoder.dispose();
//     decoder.dispose();

//     super.dispose();
//   }

//   @override
//   void didChangeAppLifecycleState(AppLifecycleState state) {
//     _isActive = state == AppLifecycleState.resumed;

//     if (_isActive && _player.isPlaying && !_recorder.isRecording) {
//       _recorder.start();
//     } else if (!_isActive && _recorder.isRecording) {
//       _recorder.stop();
//     }

//     _refresh();
//   }

//   /// 录音数据到达 → Opus 编解码 → 写入播放器
//   void _onRecordData(Uint8List chunk) {

//     try {
//       // 1. 将录音数据从 48kHz 重采样到 16kHz
//       final Uint8List resampled48kTo16k = MyResamplerRate.resample48kTo16k(
//         chunk,
//       );

//       // 2. 将 Uint8List 转换为 Int16List（用于 Opus 编码）
//       final List<int> int16Samples = DualUtil.bytesToInt16Samples(
//         resampled48kTo16k,
//       );

//       // 3. 确保数据长度是 frameSize 的整数倍
//       final int numFrames = int16Samples.length ~/ frameSize;
//       if (numFrames == 0) {
//         debugPrint('数据不足一个帧，跳过');
//         return;
//       }

//       for (int i = 0; i < numFrames; i++) {
//         final start = i * frameSize;
//         final end = start + frameSize;
//         if (end > int16Samples.length) break;

//         final frameSamples = int16Samples.sublist(start, end);
//         final Int16List pcmDataForEncode = Int16List.fromList(frameSamples);

//         // 4. Opus 编码
//         final Uint8List? encodedData = encoder.encode(
//           pcmDataForEncode,
//           frameSize,
//         );
//         if (encodedData == null) {
//           debugPrint('Opus 编码失败');
//           continue;
//         }

//         // 5. Opus 解码
//         final Uint8List? decodedPcm = decoder!.decode(encodedData, frameSize);
//         if (decodedPcm == null) {
//           debugPrint('Opus 解码失败');
//           continue;
//         }

//         // 6. 直接写入播放器缓冲区（已经是 16kHz）
//         // 播放器使用 write8Samples，它内部会转换为 Int16
//         _player.write8Samples(decodedPcm);
//       }
//     } catch (e) {
//       debugPrint('编解码处理错误: $e');
//     }
//   }

//   /// 开始边录边播
//   Future<void> _startAll() async {
//     await _player.start();

//     if (_isActive) {
//       await _recorder.start();
//     }
//   }

//   /// 停止全部
//   void _stopAll() {
//     _recorder.stop();
//     _player.stop();
//     _refresh();
//   }

//   void _refresh() {
//     if (mounted) setState(() {});
//   }

//   void _showError(String message) {
//     debugPrint('Error: $message');
//     WidgetsBinding.instance.addPostFrameCallback((_) {
//       _scaffoldKey.currentState?.showSnackBar(SnackBar(content: Text(message)));
//     });
//   }

//   @override
//   Widget build(BuildContext context) {
//     final isRunning = _player.isPlaying;

//     return MaterialApp(
//       scaffoldMessengerKey: _scaffoldKey,
//       theme: ThemeData(primarySwatch: Colors.blue),
//       home: Scaffold(
//         appBar: AppBar(centerTitle: true, title: const Text('边录边播')),
//         body: Center(
//           child: Padding(
//             padding: const EdgeInsets.symmetric(horizontal: 32),
//             child: Column(
//               mainAxisAlignment: MainAxisAlignment.center,
//               children: [
//                 // 控制按钮
//                 Row(
//                   mainAxisAlignment: MainAxisAlignment.spaceEvenly,
//                   children: [
//                     ElevatedButton.icon(
//                       onPressed: isRunning ? null : _startAll,
//                       icon: const Icon(Icons.play_arrow),
//                       label: const Text('开始'),
//                       style: ElevatedButton.styleFrom(
//                         padding: const EdgeInsets.symmetric(
//                           horizontal: 24,
//                           vertical: 12,
//                         ),
//                       ),
//                     ),
//                     ElevatedButton.icon(
//                       onPressed: isRunning ? _stopAll : null,
//                       icon: const Icon(Icons.stop),
//                       label: const Text('停止'),
//                       style: ElevatedButton.styleFrom(
//                         backgroundColor: Colors.red,
//                         padding: const EdgeInsets.symmetric(
//                           horizontal: 24,
//                           vertical: 12,
//                         ),
//                       ),
//                     ),
//                   ],
//                 ),

//                 const SizedBox(height: 48),

//                 // 状态信息
//                 _StatusCard(
//                   children: [
//                     _StatusRow(
//                       label: '录音',
//                       value: _recorder.isRecording ? '🔴 录音中' : '⬛ 停止',
//                       value2: '${_recordSampleRate ~/ 1000}kHz',
//                     ),
//                     _StatusRow(
//                       label: '播放',
//                       value: _player.isPlaying ? '🔊 播放中' : '🔇 停止',
//                       value2: '${_opusSampleRate ~/ 1000}kHz',
//                     ),
//                     _StatusRow(label: '应用', value: _isActive ? '✅ 前台' : '⏸ 后台'),
//                     const Divider(),
//                     _StatusRow(
//                       label: '播放器剩余帧',
//                       value: '${_player.remainingFrames}',
//                     ),
//                     _StatusRow(
//                       label: '缓冲区样本数',
//                       value: '${_player.bufferLength}',
//                     ),
//                     _StatusRow(
//                       label: '缓冲时长',
//                       value:
//                           '${(_player.bufferLength / _opusSampleRate * 1000).toStringAsFixed(0)} ms',
//                     ),
//                   ],
//                 ),
//               ],
//             ),
//           ),
//         ),
//       ),
//     );
//   }
// }

// /// 状态卡片
// class _StatusCard extends StatelessWidget {
//   final List<Widget> children;

//   const _StatusCard({required this.children});

//   @override
//   Widget build(BuildContext context) {
//     return Card(
//       elevation: 2,
//       child: Padding(
//         padding: const EdgeInsets.all(16),
//         child: Column(children: children),
//       ),
//     );
//   }
// }

// /// 状态行
// class _StatusRow extends StatelessWidget {
//   final String label;
//   final String value;
//   final String? value2;

//   const _StatusRow({required this.label, required this.value, this.value2});

//   @override
//   Widget build(BuildContext context) {
//     return Padding(
//       padding: const EdgeInsets.symmetric(vertical: 4),
//       child: Row(
//         mainAxisAlignment: MainAxisAlignment.spaceBetween,
//         children: [
//           Text(label, style: const TextStyle(fontWeight: FontWeight.w500)),
//           if (value2 != null)
//             Row(
//               children: [
//                 Text(value),
//                 const SizedBox(width: 8),
//                 Text(
//                   value2!,
//                   style: TextStyle(color: Colors.blue, fontSize: 12),
//                 ),
//               ],
//             )
//           else
//             Text(value),
//         ],
//       ),
//     );
//   }
// }
