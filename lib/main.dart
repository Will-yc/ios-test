import 'dart:ffi';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:my_flutter_app/demo/aec3_room/dual_room_page.dart';
import 'package:my_flutter_app/demo/aec3_room/e2e_selftest_page.dart';
import 'package:my_flutter_app/demo/aec3_room/handsfree_room_page.dart';
import 'package:my_flutter_app/demo/aec3_test_page.dart';
import 'package:my_flutter_app/demo/test_opus.dart';

import 'package:ffi/ffi.dart';

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
      //  flutter run --dart-define=AEC3_E2E=true  直接进真机端到端自测
      //  注意用 String.fromEnvironment 判断：bool.fromEnvironment 只认
      //  字面量 true/false，"1" 会被当成 false。
      // 打 IPA / 装真机时用 --dart-define=ROOM_TEST=true 直接进实测页
      home: const String.fromEnvironment('ROOM_TEST') == 'true'
          ? const HandsfreeRoomPage()
          : const String.fromEnvironment('AEC3_E2E') == 'true'
              ? const Aec3E2ePage()
              : NavigationPage(),
    );
  }
}

class NavigationPage extends StatelessWidget {
  NavigationPage({super.key});

  // 加载动态库
  final dylib = Platform.isAndroid
      ? DynamicLibrary.open('libnative_add.so')
      : DynamicLibrary.process(); // 仅演示，iOS 需单独处理

  // 查找函数并转换为 Dart 函数类型
  int Function(int, int) get addFunc => dylib
      .lookup<NativeFunction<Int32 Function(Int32, Int32)>>('add')
      .asFunction<int Function(int, int)>();

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
            Padding(
              padding: const EdgeInsets.symmetric(horizontal: 40, vertical: 10),
              child: ElevatedButton(
                onPressed: () {
                  Navigator.push(
                    context,
                    MaterialPageRoute(
                      builder: (context) => const HandsfreeRoomPage(),
                    ),
                  );
                },
                style: ElevatedButton.styleFrom(
                  backgroundColor: Colors.deepPurple,
                  shape: RoundedRectangleBorder(
                    borderRadius: BorderRadius.circular(12),
                  ),
                ),
                child: const Row(
                  mainAxisAlignment: MainAxisAlignment.center,
                  children: [
                    Icon(Icons.mic, color: Colors.white),
                    SizedBox(width: 10),
                    Text(
                      '无耳机对讲实测（Android ↔ iOS）',
                      style: TextStyle(fontSize: 17, color: Colors.white),
                    ),
                  ],
                ),
              ),
            ),

            Padding(
              padding: const EdgeInsets.symmetric(horizontal: 40, vertical: 10),
              child: ElevatedButton(
                onPressed: () {
                  Navigator.push(
                    context,
                    MaterialPageRoute(
                      builder: (context) => OpusLiveStreamPage(),
                    ),
                  );
                },
                style: ElevatedButton.styleFrom(
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
                      '实时音频播放opus',
                      style: TextStyle(fontSize: 18, color: Colors.white),
                    ),
                  ],
                ),
              ),
            ),

            Padding(
              padding: const EdgeInsets.symmetric(horizontal: 40, vertical: 10),
              child: ElevatedButton(
                onPressed: () {
                  final result = addFunc(42, 8);
                  print('42 + 8 = $result');
                },
                style: ElevatedButton.styleFrom(
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
                      '测试ffi',
                      style: TextStyle(fontSize: 18, color: Colors.white),
                    ),
                  ],
                ),
              ),
            ),

            Padding(
              padding: const EdgeInsets.symmetric(horizontal: 40, vertical: 10),
              child: ElevatedButton(
                onPressed: () {
                  Navigator.push(
                    context,
                    MaterialPageRoute(
                      builder: (context) => const Aec3RoomPage(),
                    ),
                  );
                },
                style: ElevatedButton.styleFrom(
                  backgroundColor: Colors.indigoAccent,
                  shape: RoundedRectangleBorder(
                    borderRadius: BorderRadius.circular(12),
                  ),
                ),
                child: const Row(
                  mainAxisAlignment: MainAxisAlignment.center,
                  children: [
                    Icon(Icons.headset_off, color: Colors.white),
                    SizedBox(width: 10),
                    Text(
                      'AEC3 外放免提对讲（双人）',
                      style: TextStyle(fontSize: 18, color: Colors.white),
                    ),
                  ],
                ),
              ),
            ),

            Padding(
              padding: const EdgeInsets.symmetric(horizontal: 40, vertical: 10),
              child: ElevatedButton(
                onPressed: () {
                  Navigator.push(
                    context,
                    MaterialPageRoute(
                      builder: (context) => const Aec3TestPage(),
                    ),
                  );
                },
                style: ElevatedButton.styleFrom(
                  backgroundColor: Colors.deepOrangeAccent,
                  shape: RoundedRectangleBorder(
                    borderRadius: BorderRadius.circular(12),
                  ),
                ),
                child: const Row(
                  mainAxisAlignment: MainAxisAlignment.center,
                  children: [
                    Icon(Icons.graphic_eq, color: Colors.white),
                    SizedBox(width: 10),
                    Text(
                      'AEC3 回声消除自测',
                      style: TextStyle(fontSize: 18, color: Colors.white),
                    ),
                  ],
                ),
              ),
            ),

            Padding(
              padding: const EdgeInsets.symmetric(horizontal: 40, vertical: 10),
              child: ElevatedButton(
                onPressed: () {
                  Navigator.push(
                    context,
                    MaterialPageRoute(
                      builder: (context) => const Aec3E2ePage(),
                    ),
                  );
                },
                style: ElevatedButton.styleFrom(
                  backgroundColor: Colors.teal,
                  shape: RoundedRectangleBorder(
                    borderRadius: BorderRadius.circular(12),
                  ),
                ),
                child: const Row(
                  mainAxisAlignment: MainAxisAlignment.center,
                  children: [
                    Icon(Icons.science, color: Colors.white),
                    SizedBox(width: 10),
                    Text(
                      'AEC3 真机端到端自测',
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
                '这是一个音频功能演示应用',
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
