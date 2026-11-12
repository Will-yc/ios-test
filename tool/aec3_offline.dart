// 命令行跑 AEC3 自测，与 App 内「AEC3 回声消除自测」用的是同一份逻辑。
//
// 用法（桌面 Linux，需要先把 libnative_aec.so 编出来）：
//   LD_LIBRARY_PATH=<so 所在目录> dart run tool/aec3_offline.dart
//
// 桌面结果应与 C++ 直调 API 的基线一致（ERLE 30.6dB / 本端 0.0 / 双讲 -4.6）。
import 'dart:io';

import 'package:my_flutter_app/demo/aec3_selftest.dart';

void main() {
  final r = runAec3SelfTest();
  stdout.writeln(r.report);
  stdout.writeln('');
  stdout.writeln('─' * 50);
  stdout.writeln('PASS=${r.ok}  ERLE=${r.erle.toStringAsFixed(1)}dB  '
      '本端=${r.nearKeep.toStringAsFixed(1)}dB  '
      '双讲=${r.doubleTalk.toStringAsFixed(1)}dB  '
      '守恒=${r.sampleBalanced}  耗时=${r.elapsedMs}ms');
  exit(r.ok ? 0 : 1);
}
