import 'package:flutter/material.dart';
import 'package:native_aec/native_aec.dart';

import 'aec3_selftest.dart';

/// AEC3 离线自测页：不需要麦克风、不需要两台手机。
///
/// 验证三件事：库有没有加载、FFI 通路对不对、算法输出是否与桌面基线一致。
/// 具体信号与统计在 aec3_selftest.dart 里，命令行也能跑同一份代码。
class Aec3TestPage extends StatefulWidget {
  const Aec3TestPage({super.key});

  @override
  State<Aec3TestPage> createState() => _Aec3TestPageState();
}

class _Aec3TestPageState extends State<Aec3TestPage> {
  String _report = '点上面的按钮开始。';
  bool _running = false;
  bool? _available;
  Aec3SelfTestResult? _last;

  @override
  void initState() {
    super.initState();
    _available = aec3Available();
  }

  Future<void> runTest() async {
    setState(() {
      _running = true;
      _report = '计算中…';
    });
    // 让 UI 先把「计算中」刷出来
    await Future<void>.delayed(const Duration(milliseconds: 30));

    Aec3SelfTestResult result;
    try {
      result = runAec3SelfTest();
    } catch (e, st) {
      result = Aec3SelfTestResult(
        report: '❌ 异常: $e\n${st.toString().split('\n').take(4).join('\n')}',
        ok: false,
        version: null,
        erle: 0,
        nearKeep: 0,
        doubleTalk: 0,
        sampleBalanced: false,
        elapsedMs: 0,
      );
    }

    setState(() {
      _report = result.report;
      _last = result;
      _running = false;
      _available = aec3Available();
    });
  }

  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    final last = _last;

    return Scaffold(
      appBar: AppBar(title: const Text('AEC3 回声消除自测')),
      body: ListView(
        padding: const EdgeInsets.all(16),
        children: [
          Card(
            color: _available == true
                ? Colors.green.withValues(alpha: 0.12)
                : Colors.red.withValues(alpha: 0.12),
            child: Padding(
              padding: const EdgeInsets.all(12),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    _available == null
                        ? '检测中…'
                        : (_available!
                              ? '✅ AEC3 可用'
                              : '❌ AEC3 不可用（库未加载或符号缺失）'),
                    style: const TextStyle(
                      fontSize: 16,
                      fontWeight: FontWeight.bold,
                    ),
                  ),
                  const SizedBox(height: 4),
                  Text(
                    aec3BuildInfo() ?? '(no build info)',
                    style: const TextStyle(fontSize: 12, color: Colors.grey),
                  ),
                ],
              ),
            ),
          ),
          const SizedBox(height: 12),
          FilledButton.icon(
            onPressed: _running ? null : runTest,
            icon: const Icon(Icons.play_arrow),
            label: Text(_running ? '计算中…' : '开始自测（6 秒合成信号）'),
          ),
          if (last != null) ...[
            const SizedBox(height: 12),
            Row(
              children: [
                _pill(cs, '结果', last.ok ? 'PASS' : 'FAIL', last.ok),
                const SizedBox(width: 8),
                _pill(cs, 'ERLE', '${last.erle.toStringAsFixed(1)}dB',
                    last.erle >= 25),
                const SizedBox(width: 8),
                _pill(cs, '守恒', last.sampleBalanced ? 'OK' : 'BAD',
                    last.sampleBalanced),
              ],
            ),
          ],
          const SizedBox(height: 16),
          Container(
            width: double.infinity,
            padding: const EdgeInsets.all(12),
            decoration: BoxDecoration(
              color: cs.surfaceContainerHighest,
              borderRadius: BorderRadius.circular(8),
            ),
            child: SelectableText(
              _report,
              style: const TextStyle(
                fontFamily: 'monospace',
                fontSize: 13,
                height: 1.5,
              ),
            ),
          ),
        ],
      ),
    );
  }

  Widget _pill(ColorScheme cs, String label, String value, bool good) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 6),
      decoration: BoxDecoration(
        color: (good ? Colors.green : Colors.red).withValues(alpha: 0.15),
        borderRadius: BorderRadius.circular(20),
      ),
      child: Text(
        '$label $value',
        style: TextStyle(
          fontSize: 12,
          fontWeight: FontWeight.w600,
          color: good ? Colors.green.shade800 : Colors.red.shade800,
        ),
      ),
    );
  }
}
