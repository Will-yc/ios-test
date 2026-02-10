import 'package:flutter/material.dart';
import 'package:my_flutter_app/demo/ok/audio_player.dart';
import 'package:my_flutter_app/demo/ok/audio_recorder.dart';

class PcmSoundApp extends StatefulWidget {
  @override
  _PcmSoundAppState createState() => _PcmSoundAppState();
}

class _PcmSoundAppState extends State<PcmSoundApp> with WidgetsBindingObserver {
  static const int _sampleRate = 44100;
  static const int _channelCount = 1;

  bool _isActive = true;

  late final PcmRecorder _recorder;
  late final PcmPlayer _player;

  final GlobalKey<ScaffoldMessengerState> _scaffoldKey =
      GlobalKey<ScaffoldMessengerState>();

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);

    // 创建录音器
    _recorder = PcmRecorder(
      sampleRate: _sampleRate,
      channelCount: _channelCount,
    );
    _recorder.onData = _onRecordData;
    _recorder.onError = _showError;
    _recorder.onStateChanged = _refresh;

    // 创建播放器
    _player = PcmPlayer(sampleRate: _sampleRate, channelCount: _channelCount);
    _player.onError = _showError;
    _player.onStateChanged = _refresh;

    // 初始化播放引擎
    _player.init();
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    _recorder.dispose();
    _player.dispose();
    super.dispose();
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    _isActive = state == AppLifecycleState.resumed;

    if (_isActive && _player.isPlaying && !_recorder.isRecording) {
      _recorder.start();
    } else if (!_isActive && _recorder.isRecording) {
      _recorder.stop();
    }

    _refresh();
  }

  /// 录音数据到达 → 写入播放器缓冲区
  void _onRecordData(List<int> samples) {
    _player.writeSamples(samples);
  }

  /// 开始边录边播
  Future<void> _startAll() async {
    await _player.start();

    if (_isActive) {
      await _recorder.start();
    }
  }

  /// 停止全部
  void _stopAll() {
    _recorder.stop();
    _player.stop();
    _refresh();
  }

  void _refresh() {
    if (mounted) setState(() {});
  }

  void _showError(String message) {
    debugPrint('Error: $message');
    WidgetsBinding.instance.addPostFrameCallback((_) {
      _scaffoldKey.currentState?.showSnackBar(SnackBar(content: Text(message)));
    });
  }

  @override
  Widget build(BuildContext context) {
    final isRunning = _player.isPlaying;

    return MaterialApp(
      scaffoldMessengerKey: _scaffoldKey,
      theme: ThemeData(primarySwatch: Colors.blue),
      home: Scaffold(
        appBar: AppBar(centerTitle: true, title: const Text('边录边播')),
        body: Center(
          child: Padding(
            padding: const EdgeInsets.symmetric(horizontal: 32),
            child: Column(
              mainAxisAlignment: MainAxisAlignment.center,
              children: [
                // 控制按钮
                Row(
                  mainAxisAlignment: MainAxisAlignment.spaceEvenly,
                  children: [
                    ElevatedButton.icon(
                      onPressed: isRunning ? null : _startAll,
                      icon: const Icon(Icons.play_arrow),
                      label: const Text('开始'),
                      style: ElevatedButton.styleFrom(
                        padding: const EdgeInsets.symmetric(
                          horizontal: 24,
                          vertical: 12,
                        ),
                      ),
                    ),
                    ElevatedButton.icon(
                      onPressed: isRunning ? _stopAll : null,
                      icon: const Icon(Icons.stop),
                      label: const Text('停止'),
                      style: ElevatedButton.styleFrom(
                        backgroundColor: Colors.red,
                        padding: const EdgeInsets.symmetric(
                          horizontal: 24,
                          vertical: 12,
                        ),
                      ),
                    ),
                  ],
                ),

                const SizedBox(height: 48),

                // 状态信息
                _StatusCard(
                  children: [
                    _StatusRow(
                      label: '录音',
                      value: _recorder.isRecording ? '🔴 录音中' : '⬛ 停止',
                    ),
                    _StatusRow(
                      label: '播放',
                      value: _player.isPlaying ? '🔊 播放中' : '🔇 停止',
                    ),
                    _StatusRow(label: '应用', value: _isActive ? '✅ 前台' : '⏸ 后台'),
                    const Divider(),
                    _StatusRow(
                      label: '播放器剩余帧',
                      value: '${_player.remainingFrames}',
                    ),
                    _StatusRow(
                      label: '缓冲区样本数',
                      value: '${_player.bufferLength}',
                    ),
                    _StatusRow(
                      label: '缓冲时长',
                      value:
                          '${(_player.bufferLength / _sampleRate * 1000).toStringAsFixed(0)} ms',
                    ),
                  ],
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}

/// 状态卡片
class _StatusCard extends StatelessWidget {
  final List<Widget> children;

  const _StatusCard({required this.children});

  @override
  Widget build(BuildContext context) {
    return Card(
      elevation: 2,
      child: Padding(
        padding: const EdgeInsets.all(16),
        child: Column(children: children),
      ),
    );
  }
}

/// 状态行
class _StatusRow extends StatelessWidget {
  final String label;
  final String value;

  const _StatusRow({required this.label, required this.value});

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 4),
      child: Row(
        mainAxisAlignment: MainAxisAlignment.spaceBetween,
        children: [
          Text(label, style: const TextStyle(fontWeight: FontWeight.w500)),
          Text(value),
        ],
      ),
    );
  }
}
