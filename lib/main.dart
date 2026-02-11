import 'package:flutter/material.dart';
import 'package:my_flutter_app/demo/RealTimeAudioPlayerPage1Htpp.dart';
import 'package:my_flutter_app/demo/RealTimeAudioPlayerPage1Stream.dart';
import 'package:my_flutter_app/demo/flutterpcm.dart';
import 'package:my_flutter_app/demo/ok/pcm_sound_app_opus.dart';
import 'package:my_flutter_app/demo/opus_test_demo.dart';

void main() {
  runApp(const MyApp());
}

class MyApp extends StatelessWidget {
  const MyApp({super.key});

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      title: '音频演示应用',
      theme: ThemeData(
        colorScheme: ColorScheme.fromSeed(seedColor: Colors.deepPurple),
        useMaterial3: true,
      ),
      home: const NavigationPage(), // 修改为导航页面
    );
  }
}

class NavigationPage extends StatelessWidget {
  const NavigationPage({super.key});

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: const Text('音频演示首页'),
        backgroundColor: Theme.of(context).colorScheme.primaryContainer,
      ),
      body: Center(
        child: Column(
          mainAxisAlignment: MainAxisAlignment.center,
          children: [
            const SizedBox(height: 20),
            const Icon(Icons.audiotrack, size: 80, color: Colors.deepPurple),
            const SizedBox(height: 20),
            const Text(
              '音频演示应用',
              style: TextStyle(
                fontSize: 28,
                fontWeight: FontWeight.bold,
                color: Colors.deepPurple,
              ),
            ),
            const SizedBox(height: 10),
            const Text(
              '请选择要进入的功能页面',
              style: TextStyle(fontSize: 16, color: Colors.grey),
            ),
            const SizedBox(height: 40),

            // 第一个页面按钮
            Padding(
              padding: const EdgeInsets.symmetric(horizontal: 40, vertical: 10),
              child: ElevatedButton(
                onPressed: () {
                  Navigator.push(
                    context,
                    MaterialPageRoute(
                      builder: (context) => const OpusDemoPage(),
                    ),
                  );
                },
                style: ElevatedButton.styleFrom(
                  minimumSize: const Size(double.infinity, 60),
                  backgroundColor: Colors.blueAccent,
                  shape: RoundedRectangleBorder(
                    borderRadius: BorderRadius.circular(12),
                  ),
                ),
                child: const Row(
                  mainAxisAlignment: MainAxisAlignment.center,
                  children: [
                    Icon(Icons.code, color: Colors.white),
                    SizedBox(width: 10),
                    Text(
                      'Opus 编解码演示',
                      style: TextStyle(fontSize: 18, color: Colors.white),
                    ),
                  ],
                ),
              ),
            ),

            // 第二个页面按钮
            Padding(
              padding: const EdgeInsets.symmetric(horizontal: 40, vertical: 10),
              child: ElevatedButton(
                onPressed: () {
                  Navigator.push(
                    context,
                    MaterialPageRoute(builder: (context) => PcmSoundApp()),
                  );
                },
                style: ElevatedButton.styleFrom(
                  minimumSize: const Size(double.infinity, 60),
                  backgroundColor: Colors.greenAccent,
                  shape: RoundedRectangleBorder(
                    borderRadius: BorderRadius.circular(12),
                  ),
                ),
                child: const Row(
                  mainAxisAlignment: MainAxisAlignment.center,
                  children: [
                    Icon(Icons.stream, color: Colors.white),
                    SizedBox(width: 10),
                    Text(
                      '实时音频播放 (pcm重采样)',
                      style: TextStyle(fontSize: 18, color: Colors.white),
                    ),
                  ],
                ),
              ),
            ),

            // 第三个页面按钮
            Padding(
              padding: const EdgeInsets.symmetric(horizontal: 40, vertical: 10),
              child: ElevatedButton(
                onPressed: () {
                  Navigator.push(
                    context,
                    MaterialPageRoute(builder: (context) => PcmSoundAppOpus()),
                  );
                },
                style: ElevatedButton.styleFrom(
                  minimumSize: const Size(double.infinity, 60),
                  backgroundColor: Colors.orangeAccent,
                  shape: RoundedRectangleBorder(
                    borderRadius: BorderRadius.circular(12),
                  ),
                ),
                child: const Row(
                  mainAxisAlignment: MainAxisAlignment.center,
                  children: [
                    Icon(Icons.http, color: Colors.white),
                    SizedBox(width: 10),
                    Text(
                      '实时音频播放 (opus)',
                      style: TextStyle(fontSize: 18, color: Colors.white),
                    ),
                  ],
                ),
              ),
            ),

            const SizedBox(height: 30),
            const Divider(height: 20, thickness: 1),
            const Padding(
              padding: EdgeInsets.all(16.0),
              child: Text(
                '这是一个音频功能演示应用，包含三种不同的音频处理功能。',
                textAlign: TextAlign.center,
                style: TextStyle(color: Colors.grey),
              ),
            ),
          ],
        ),
      ),
    );
  }
}

// 如果你的其他页面还没有创建，这里提供了一个简单的模板
// 实际使用时，你需要创建对应的页面文件

// class OpusDemoPage extends StatefulWidget {
//   const OpusDemoPage({super.key});
// 
//   @override
//   State<OpusDemoPage> createState() => _OpusDemoPageState();
// }
// 
// class _OpusDemoPageState extends State<OpusDemoPage> {
//   @override
//   Widget build(BuildContext context) {
//     return Scaffold(
//       appBar: AppBar(title: const Text('Opus 编解码演示')),
//       body: const Center(child: Text('Opus 编解码演示页面')),
//     );
//   }
// }
// 
// class RealTimeAudioPlayerStreamPage extends StatefulWidget {
//   const RealTimeAudioPlayerStreamPage({super.key});
// 
//   @override
//   State<RealTimeAudioPlayerStreamPage> createState() => _RealTimeAudioPlayerStreamPageState();
// }
// 
// class _RealTimeAudioPlayerStreamPageState extends State<RealTimeAudioPlayerStreamPage> {
//   @override
//   Widget build(BuildContext context) {
//     return Scaffold(
//       appBar: AppBar(title: const Text('实时音频播放 (流式)')),
//       body: const Center(child: Text('实时音频播放 (流式) 页面')),
//     );
//   }
// }
// 
// class RealTimeAudioPlayerHttpPage extends StatefulWidget {
//   const RealTimeAudioPlayerHttpPage({super.key});
// 
//   @override
//   State<RealTimeAudioPlayerHttpPage> createState() => _RealTimeAudioPlayerHttpPageState();
// }
// 
// class _RealTimeAudioPlayerHttpPageState extends State<RealTimeAudioPlayerHttpPage> {
//   @override
//   Widget build(BuildContext context) {
//     return Scaffold(
//       appBar: AppBar(title: const Text('实时音频播放 (HTTP)')),
//       body: const Center(child: Text('实时音频播放 (HTTP) 页面')),
//     );
//   }
// }