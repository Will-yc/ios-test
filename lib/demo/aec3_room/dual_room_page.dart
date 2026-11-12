import 'dart:async';
import 'dart:io';
import 'dart:isolate';

import 'package:audio_session/audio_session.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:my_flutter_app/demo/aec3_room/audio_processing_worker.dart';
import 'package:my_flutter_app/demo/aec3_room/audio_playback_manager.dart';
import 'package:my_flutter_app/demo/aec3_room/room_socket.dart';
import 'package:my_flutter_app/demo/aec3_room/wav_export.dart';
import 'package:my_flutter_app/demo/util/my_dual_util.dart';
import 'package:native_aec/native_aec.dart';
import 'package:opus_ffi/opus_ffi.dart';
import 'package:path_provider/path_provider.dart';
import 'package:record/record.dart' hide IosAudioCategory;
import 'package:share_plus/share_plus.dart';

/// 外放免提对讲验证页 —— 移植自
/// `zyxc-record-app/lib/module/chat/audio/my_dual_recorder_main_page.dart`。
///
/// 保留的能力（结构与原工程一致，方便日后整体迁移）：
///   · 房间通信：join / leave / heartbeat / 二进制裸 opus 透传 / start_record / stop_record
///   · 采集 48k pcm16 → **AEC3** → 落盘 .pcm（成品）＋ 48k→16k → opus → WS
///   · 下行 opus → 48k 解码 → 播放，并把「正在播的字节」回喂 AEC 作参考信号
///   · 停止后把 .pcm 导出成 .wav（可分享）
///
/// 刻意去掉的：转码上传、元数据/台词 JSON、成员名册、主题同步、耳机检测
/// （本页的验证前提就是**不戴耳机**）。
class Aec3RoomPage extends StatefulWidget {
  const Aec3RoomPage({super.key});

  @override
  State<Aec3RoomPage> createState() => _Aec3RoomPageState();
}

class _Aec3RoomPageState extends State<Aec3RoomPage> {
  // ---------- 通信 ----------
  final RoomSocketManager _socket = RoomSocketManager();
  StreamSubscription? _statusSub;
  StreamSubscription? _textSub;
  StreamSubscription? _binarySub;

  RoomSocketStatus _socketStatus = RoomSocketStatus.disconnected;
  int _roomClients = 0;

  final TextEditingController _urlCtrl =
      TextEditingController(text: 'ws://192.168.3.6:8089');
  final TextEditingController _roomCtrl = TextEditingController(text: '1234');

  /// 两台设备必须选不同的身份（A / B），它就是 join 消息里的 userId。
  String _identity = 'A';
  String get _userId => 'test_$_identity';

  // ---------- 采集 / 播放 ----------
  final AudioRecorder _recorder = AudioRecorder();
  AudioSession? _audioSession;
  OpusDecoder? _decoder;
  AudioPlaybackManager? _playbackManager;
  StreamSubscription? _micSub;

  bool _isTalking = false;
  bool _hasListenVoice = false;
  bool _enableAec = true;

  /// 回环自测：上行的 opus 直接喂给本机播放器（不走 WS）。
  /// 单机就能验证「采集 → AEC → opus → 解码 → 播放」整条链路是否通。
  /// 注意：此时参考信号就是自己的声音，AEC 会把它当回声消掉 ——
  /// 所以回环下「声音变小」是**正确**表现，说明 AEC 在工作。
  bool _loopback = false;

  // ---------- worker isolate ----------
  Isolate? _audioIsolate;
  ReceivePort? _mainReceivePort;
  SendPort? _workerSendPort;
  Completer<void> _workerReadyCompleter = Completer<void>();
  bool _isWorkerReady = false;
  bool _isWorkerClosed = false;
  int? _currentActualStartTime;

  // ---------- 录音 ----------
  bool _isWriteRecordFile = false;
  String? _pcmPath;
  String _lastWavPath = '';
  final List<String> _segments = [];
  int _segSeq = 1;
  Completer<void>? _fileClosed;
  DateTime? _recordStartAt;
  int _recordSeconds = 0;
  Timer? _uiTimer;

  // ---------- AEC 观测 ----------
  double _inDbfs = -90;
  double _outDbfs = -90;
  int _aecFrames = 0;
  int _starved = 0;
  int _bytesIn = 0;
  int _bytesOut = 0;
  double _playDelayMs = 0;

  final List<String> _logs = [];

  @override
  void initState() {
    super.initState();
    _bindSocket();
    _uiTimer = Timer.periodic(const Duration(seconds: 1), (_) => _tickUi());
    _log('AEC3 可用: ${aec3Available() ? '是' : '否（将直通，不消回声）'}');
    _log('构建信息: ${aec3BuildInfo() ?? '-'}');
  }

  @override
  void dispose() {
    _uiTimer?.cancel();
    _statusSub?.cancel();
    _textSub?.cancel();
    _binarySub?.cancel();
    _micSub?.cancel();
    _recorder.dispose();
    _playbackManager?.dispose();
    // 不能"发完 dispose 立刻 kill"：worker 还要 await fileSink.flush()，
    // 抢在前面 kill 会把最后一段尾部字节丢掉（wav 时长比实际短一截）。
    // 给它 400ms 自己处理完并关端口，再兜底 kill。
    final isolate = _audioIsolate;
    _workerSendPort?.send({'type': 'dispose'});
    Future.delayed(const Duration(milliseconds: 400), () {
      isolate?.kill(priority: Isolate.immediate);
    });
    _mainReceivePort?.close();
    super.dispose();
  }

  // =====================================================================
  // 通信
  // =====================================================================

  void _bindSocket() {
    _statusSub = _socket.statusStream.listen((s) {
      if (!mounted) return;
      setState(() => _socketStatus = s);
      if (s == RoomSocketStatus.connected) _join();
    });
    _textSub = _socket.textMessageStream.listen(_onTextMessage);
    _binarySub = _socket.binaryMessageStream.listen((pkt) {
      // 下行：裸 opus → 48k 解码 → 播放（播放侧会顺手回喂 AEC 参考信号）
      _playbackManager?.handleIncomingOpusPacket(pkt);
    });
  }

  void _join() {
    _socket.sendMessage(
      RoomMessage(
        type: WsType.join,
        content: {'roomId': _roomCtrl.text.trim(), 'userId': _userId},
      ),
    );
    _log('已进房 room=${_roomCtrl.text.trim()} userId=$_userId');
  }

  void _onTextMessage(RoomMessage msg) {
    final data = msg.content;
    switch (msg.type) {
      case WsType.join:
        final uid = data is Map ? data['_userId']?.toString() : null;
        _log('👥 $uid 进房');
        break;
      case WsType.leave:
        final uid = data is Map ? data['_userId']?.toString() : null;
        _log('👋 $uid 离开');
        break;
      case WsType.heartbeat:
        if (data is Map) {
          setState(() {
            _roomClients = (data['clientsNum'] as num?)?.toInt() ?? _roomClients;
          });
        }
        break;
      case WsType.startRecord:
        // 对端（房主）发起录音：按 delayedTimestamp 对齐后再开始写盘
        final ts = int.tryParse('${data is Map ? data['delayedTimestamp'] : ''}');
        final delayMs = ts == null
            ? 0
            : (ts - DateTime.now().millisecondsSinceEpoch).clamp(0, 5000);
        _log('📥 收到 start_record，${delayMs}ms 后开始写盘');
        _beginWriteAfter(delayMs);
        break;
      case WsType.stopRecord:
        _log('📥 收到 stop_record');
        _stopRecording(broadcast: false);
        break;
      default:
        _log('未知消息: ${msg.type} $data');
    }
  }

  // =====================================================================
  // worker isolate（AEC 在这里跑，不占 UI 线程）
  // =====================================================================

  Future<void> _ensureWorker() async {
    if (!_isWorkerClosed && _isWorkerReady && _workerSendPort != null) return;

    _isWorkerReady = false;
    _isWorkerClosed = false;
    if (_workerReadyCompleter.isCompleted) {
      _workerReadyCompleter = Completer<void>();
    }
    _audioIsolate?.kill(priority: Isolate.immediate);
    _mainReceivePort?.close();
    _workerSendPort = null;

    _mainReceivePort = ReceivePort();
    _audioIsolate = await Isolate.spawn(
      audioProcessingWorker,
      _mainReceivePort!.sendPort,
      debugName: 'Aec3AudioWorker',
    );

    _mainReceivePort!.listen((message) {
      if (message is SendPort) {
        _workerSendPort = message;
        _isWorkerReady = true;
        if (!_workerReadyCompleter.isCompleted) {
          _workerReadyCompleter.complete();
        }
        return;
      }
      if (message is! Map) return;
      switch (message['type']) {
        case 'opus_packet':
          if (_loopback) {
            _playbackManager?.handleIncomingOpusPacket(message['data']);
          } else if (_socketStatus == RoomSocketStatus.connected) {
            _socket.sendBinaryMessage(message['data']);
          }
          break;
        case 'aec-unavailable':
          _log('⚠️ AEC3 不可用（原生库未加载），本次为直通');
          break;
        case 'aec_stats':
          setState(() {
            _inDbfs = (message['inDbfs'] as num?)?.toDouble() ?? -90;
            _outDbfs = (message['outDbfs'] as num?)?.toDouble() ?? -90;
            _aecFrames = (message['frames'] as num?)?.toInt() ?? 0;
            _starved = (message['starved'] as num?)?.toInt() ?? 0;
            _bytesIn = (message['bytesIn'] as num?)?.toInt() ?? 0;
            _bytesOut = (message['bytesOut'] as num?)?.toInt() ?? 0;
          });
          break;
        case 'first_chunk_time':
          _currentActualStartTime = message['time'];
          _log('▶️ 首块落盘 @ $_currentActualStartTime');
          break;
        case 'file-closed':
          if (_fileClosed != null && !_fileClosed!.isCompleted) {
            _fileClosed!.complete();
          }
          _log('📁 worker 已关闭本段文件（字节全部落盘）');
          break;
        case 'error':
          _log('❌ worker: ${message['data']}');
          break;
      }
    });

    await _workerReadyCompleter.future.timeout(
      const Duration(seconds: 5),
      onTimeout: () => _log('❌ worker 启动超时'),
    );
  }

  /// 播放侧把「正在送给扬声器」的字节交过来 → 转发给 worker 当参考信号。
  void _forwardPlaybackReference(Uint8List pcm) {
    final port = _workerSendPort;
    if (port == null || _isWorkerClosed || pcm.isEmpty) return;
    port.send({'type': 'ref_chunk', 'data': pcm});
  }

  // =====================================================================
  // 开始 / 结束对话
  // =====================================================================

  Future<void> _startTalking() async {
    if (_isTalking) return;
    if (!await _recorder.hasPermission()) {
      _toast('没有麦克风权限');
      return;
    }

    try {
      _pcmPath = null;
      _lastWavPath = '';
      _recordSeconds = 0;
      // 不清 _segments：多轮对话录的段都留着，导出时一次全导

      await _ensureWorker();
      if (_workerSendPort == null) {
        _toast('音频线程未就绪');
        return;
      }
      // 只建 AEC 句柄，不开文件：文件在「开始录音」那一刻才分配（一段一文件）
      _workerSendPort!.send({'type': 'init', 'aecEnabled': _enableAec});

      // 解码器按 48k 输出：AEC 的参考信号必须与采集同采样率（48k）。
      // 对端上行是 16k 编码的 opus，解码到 48k 是 opus 原生能力，不是上采样。
      _decoder?.dispose();
      _decoder = OpusDecoder(
        sampleRate: kSampleRateRecorder,
        channels: Channels.mono,
      );
      await _playbackManager?.dispose();
      _playbackManager = AudioPlaybackManager(
        sampleRate: kSampleRateRecorder,
        channelCount: kChannels,
        decoder: _decoder,
        onPlaybackReference: _enableAec ? _forwardPlaybackReference : null,
      );
      await _playbackManager!.init();
      await _activateAudioSession();

      // 采集前先确保上一轮真的停了（否则 iOS 会拿到一条"永不产出 buffer"的流）
      if (await _recorder.isRecording()) {
        await _recorder.stop();
        await Future.delayed(const Duration(milliseconds: 100));
      }

      final mic = await DualUtil.findBuiltInMicNew(
        recorder: _recorder,
        audioSession: _audioSession,
      );

      final stream = await _recorder.startStream(
        RecordConfig(
          encoder: AudioEncoder.pcm16bits,
          sampleRate: kSampleRateRecorder,
          numChannels: kChannels,
          device: mic,
        ),
      );

      _hasListenVoice = false;
      _micSub = stream.listen(
        (chunk) {
          if (chunk.isEmpty) return;
          _hasListenVoice = true;
          final port = _workerSendPort;
          if (port == null || _isWorkerClosed) return;
          port.send({
            'type': 'pcm_chunk',
            'data': chunk,
            'isWriteRecordFile': _isWriteRecordFile,
            'captureTime': DateTime.now().millisecondsSinceEpoch,
          });
        },
        onError: (Object e) {
          _log('❌ 采集流错误: $e');
          _stopTalking();
        },
        onDone: () => _log('采集流 onDone'),
      );

      setState(() => _isTalking = true);
      _log('🎙️ 开始对话（AEC ${_enableAec ? '开' : '关'}，48k 采集/48k 播放，无变速）');

      Future.delayed(const Duration(seconds: 5), () {
        if (!mounted || !_isTalking) return;
        if (!_hasListenVoice) _log('⚠️ 5 秒内没收到麦克风数据，检查权限/设备');
      });
    } catch (e) {
      _log('❌ 启动失败: $e');
      _toast('启动失败: $e');
    }
  }

  Future<void> _stopTalking() async {
    if (!_isTalking) return;
    if (_isWriteRecordFile) {
      _stopRecording(broadcast: true);
      await Future.delayed(const Duration(milliseconds: 300));
    }
    try {
      await _micSub?.cancel();
      _micSub = null;
      await _recorder.stop();
      // worker 里 AEC 句柄与文件句柄一起收
      if (_workerSendPort != null) {
        _isWorkerClosed = true;
        _isWorkerReady = false;
        _workerSendPort!.send({'type': 'dispose'});
        _workerSendPort = null;
      }
      await _playbackManager?.dispose();
      _playbackManager = null;
      _decoder?.dispose();
      _decoder = null;
    } catch (e) {
      _log('停止异常: $e');
    }
    if (mounted) setState(() => _isTalking = false);
    _log('⏹️ 已结束对话');
  }

  Future<void> _activateAudioSession() async {
    try {
      final session = _audioSession ?? await AudioSession.instance;
      _audioSession = session;
      await session.configure(
        AudioSessionConfiguration(
          avAudioSessionCategory: AVAudioSessionCategory.playAndRecord,
          // 🔴 外放验证的关键：defaultToSpeaker 让声音走扬声器（不是听筒）
          avAudioSessionCategoryOptions:
              AVAudioSessionCategoryOptions.allowBluetooth |
              AVAudioSessionCategoryOptions.defaultToSpeaker,
          avAudioSessionMode: AVAudioSessionMode.defaultMode,
          avAudioSessionRouteSharingPolicy:
              AVAudioSessionRouteSharingPolicy.defaultPolicy,
          avAudioSessionSetActiveOptions: AVAudioSessionSetActiveOptions.none,
          androidAudioAttributes: const AndroidAudioAttributes(
            contentType: AndroidAudioContentType.speech,
            flags: AndroidAudioFlags.none,
            usage: AndroidAudioUsage.media,
          ),
          androidAudioFocusGainType: AndroidAudioFocusGainType.gain,
          androidWillPauseWhenDucked: true,
        ),
      );
      final ok = await session.setActive(true);
      _log('音频会话已配置并激活: $ok');
    } catch (e) {
      _log('⚠️ 音频会话配置失败: $e');
    }
  }

  // =====================================================================
  // 录音（写 .pcm）：房主广播 start_record，双端对齐后同时开始写
  // =====================================================================

  void _startRecording() {
    if (!_isTalking) {
      _toast('请先开始对话');
      return;
    }
    if (_isWriteRecordFile) return;
    // 与后端一致：给对端一个 2 秒的准备时间
    final delayed = DateTime.now().millisecondsSinceEpoch + 2000;
    _socket.sendMessage(
      RoomMessage(
        type: WsType.startRecord,
        content: {'delayedTimestamp': delayed.toString()},
      ),
    );
    _log('📤 广播 start_record（2s 后开始写盘）');
    _beginWriteAfter(2000);
  }

  void _beginWriteAfter(int delayMs) {
    Future.delayed(Duration(milliseconds: delayMs), () async {
      if (!mounted || !_isTalking) {
        _log('⚠️ 到点但未在对话中，跳过开始写盘');
        return;
      }
      // 防重入：两端同时广播/连点两下都会走到这里，重复 init 会把上一段
      // 还没 push 进 _segments 的文件直接关掉（那段就丢了）
      if (_isWriteRecordFile) return;
      // 🔴 每一段都是**独立文件**：worker 在「停止写盘」时会把 sink 关掉，
      //    不重新 init 就再也不会写任何字节（表现为"第二次录音是 0 字节"）。
      //    init 里的 aec?.reset() 只清帧缓存/统计，自适应滤波器保留，
      //    所以重新 init 不会让 AEC 重新收敛一秒。
      final dir = await getApplicationDocumentsDirectory();
      final ts = DateTime.now().millisecondsSinceEpoch;
      final segPath = '${dir.path}/aec3_${_identity}_${ts}_seg${_segSeq++}.pcm';
      _fileClosed = Completer<void>();
      _workerSendPort?.send({
        'type': 'init',
        'filePath': segPath,
        'aecEnabled': _enableAec,
      });
      _workerSendPort?.send({
        'type': 'isWriteRecordFile',
        'isWriteRecordFile': true,
      });
      setState(() {
        _pcmPath = segPath;
        _isWriteRecordFile = true;
        _recordStartAt = DateTime.now();
        _recordSeconds = 0;
      });
      _log('🔴 开始写入 $_pcmPath（AEC 后的字节）');
    });
  }

  void _stopRecording({bool broadcast = true}) {
    if (!_isWriteRecordFile) return;
    if (broadcast) {
      _socket.sendMessage(
        RoomMessage(type: WsType.stopRecord, content: {'reason': '手动停止'}),
      );
      _log('📤 广播 stop_record');
    }
    _workerSendPort?.send({
      'type': 'isWriteRecordFile',
      'isWriteRecordFile': false,
    });
    final finished = _pcmPath;
    setState(() {
      _isWriteRecordFile = false;
      _recordStartAt = null;
      if (finished != null) _segments.add(finished);
      _pcmPath = null;
    });
    _log('⏸️ 停止写入（第 ${_segments.length} 段），可导出 WAV');
    _toast('已停止录音，点「导出 WAV」');
  }

  /// 等 worker 确认「这段文件的字节已全部落盘」。
  Future<void> _waitFileClosed() async {
    final c = _fileClosed;
    if (c == null || c.isCompleted) return;
    try {
      await c.future.timeout(const Duration(seconds: 3));
    } on TimeoutException {
      _log('⚠️ 等 worker 关闭文件超时，导出的 wav 可能缺尾巴');
    }
  }

  Future<void> _exportWav() async {
    if (_isWriteRecordFile) {
      _toast('请先停止录音');
      return;
    }
    final targets = <String>[..._segments];
    if (targets.isEmpty) {
      final p = _pcmPath;
      if (p != null && File(p).existsSync()) {
        targets.add(p);
      } else {
        _toast('还没有录音文件');
        return;
      }
    }

    await _waitFileClosed();

    var okCount = 0;
    for (final pcm in targets) {
      if (!File(pcm).existsSync()) continue;
      final wavPath = pcm.replaceAll(RegExp(r'\.pcm$'), '.wav');
      try {
        await pcmFileToWav(
          pcm,
          wavPath,
          sampleRate: kSampleRateRecorder,
          channels: kChannels,
        );
        final pcmLen = await File(pcm).length();
        _log('💾 ${File(pcm).uri.pathSegments.last} → ${File(wavPath).uri.pathSegments.last}  '
            'pcm=${(pcmLen / 1024).toStringAsFixed(1)}KB '
            '时长≈${(pcmLen / 2 / kSampleRateRecorder).toStringAsFixed(1)}s');
        okCount++;
        _lastWavPath = wavPath;
      } catch (e) {
        _log('❌ 导出失败 $pcm: $e');
      }
    }
    if (okCount > 0) {
      setState(() {});
      _toast('已导出 $okCount 个 WAV');
    }
  }

  Future<void> _shareWav() async {
    if (_lastWavPath.isEmpty || !File(_lastWavPath).existsSync()) {
      _toast('请先导出 WAV');
      return;
    }
    await Share.shareXFiles([XFile(_lastWavPath)], subject: 'AEC3 录音');
  }

  void _copyPath(String p) {
    Clipboard.setData(ClipboardData(text: p));
    _toast('路径已复制');
  }

  // =====================================================================
  // UI
  // =====================================================================

  void _tickUi() {
    if (!mounted) return;
    if (_isTalking && _workerSendPort != null) {
      _workerSendPort!.send({'type': 'aec_stats'});
    }
    setState(() {
      _playDelayMs = _playbackManager?.getCurrentDelay() ?? 0;
      if (_recordStartAt != null) {
        _recordSeconds =
            DateTime.now().difference(_recordStartAt!).inSeconds;
      }
    });
  }

  void _log(String msg) {
    final t = DateTime.now().toIso8601String().substring(11, 19);
    debugPrint('[$t] $msg');
    if (!mounted) return;
    setState(() {
      _logs.add('$t  $msg');
      if (_logs.length > 200) _logs.removeAt(0);
    });
  }

  void _toast(String msg) {
    if (!mounted) return;
    ScaffoldMessenger.of(context)
      ..hideCurrentSnackBar()
      ..showSnackBar(SnackBar(content: Text(msg), duration: const Duration(seconds: 2)));
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final cs = theme.colorScheme;
    return Scaffold(
      appBar: AppBar(
        title: const Text('AEC3 外放免提对讲（验证）'),
        backgroundColor: cs.primaryContainer,
      ),
      body: ListView(
        padding: const EdgeInsets.all(12),
        children: [
          _warnCard(cs),
          _connectCard(cs),
          _talkCard(cs),
          _recordCard(cs),
          _logCard(cs),
        ],
      ),
    );
  }

  Widget _warnCard(ColorScheme cs) => Card(
        color: cs.tertiaryContainer,
        child: Padding(
          padding: const EdgeInsets.all(12),
          child: Text(
            '验证前提：两台设备都不要戴耳机，扬声器音量开到常用大小。\n'
            'A 端外放的声音会漏进 A 的麦克风 → 由 A 的 AEC3 消掉（参考信号 = A 正在播的字节）。\n'
            '成品 .pcm / .wav 里应该听不到对方的声音（只有本端说话）。',
            style: TextStyle(color: cs.onTertiaryContainer, height: 1.5),
          ),
        ),
      );

  Widget _connectCard(ColorScheme cs) => Card(
        child: Padding(
          padding: const EdgeInsets.all(12),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              _sectionTitle('1. 房间通信', cs),
              const SizedBox(height: 8),
              TextField(
                controller: _urlCtrl,
                decoration: const InputDecoration(
                  labelText: '中继地址（ws://）',
                  isDense: true,
                  border: OutlineInputBorder(),
                ),
              ),
              const SizedBox(height: 8),
              Row(
                children: [
                  Expanded(
                    child: TextField(
                      controller: _roomCtrl,
                      decoration: const InputDecoration(
                        labelText: '房间号',
                        isDense: true,
                        border: OutlineInputBorder(),
                      ),
                    ),
                  ),
                  const SizedBox(width: 8),
                  SegmentedButton<String>(
                    segments: const [
                      ButtonSegment(value: 'A', label: Text('A 端')),
                      ButtonSegment(value: 'B', label: Text('B 端')),
                    ],
                    selected: {_identity},
                    onSelectionChanged: _isTalking
                        ? null
                        : (v) => setState(() => _identity = v.first),
                  ),
                ],
              ),
              const SizedBox(height: 10),
              Row(
                children: [
                  Expanded(
                    child: FilledButton.icon(
                      onPressed: _socketStatus == RoomSocketStatus.connected
                          ? null
                          : () async {
                              final ok =
                                  await _socket.connect(_urlCtrl.text.trim());
                              _log(ok ? '✅ 已连接中继' : '❌ 连接失败');
                            },
                      icon: const Icon(Icons.wifi),
                      label: Text('连接（${roomStatusText(_socketStatus)}）'),
                    ),
                  ),
                  const SizedBox(width: 8),
                  OutlinedButton(
                    onPressed: () async {
                      await _socket.disconnect();
                      _log('已断开');
                    },
                    child: const Text('断开'),
                  ),
                ],
              ),
              const SizedBox(height: 6),
              Text(
                '房间人数：$_roomClients   本地身份：$_userId',
                style: Theme.of(context).textTheme.bodySmall,
              ),
            ],
          ),
        ),
      );

  Widget _talkCard(ColorScheme cs) => Card(
        child: Padding(
          padding: const EdgeInsets.all(12),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              _sectionTitle('2. 对话（48k 采集 / 48k 播放 / 无变速）', cs),
              const SizedBox(height: 8),
              Row(
                children: [
                  Expanded(
                    child: FilledButton.icon(
                      onPressed: _isTalking ? _stopTalking : _startTalking,
                      style: FilledButton.styleFrom(
                        backgroundColor: _isTalking ? cs.error : cs.primary,
                      ),
                      icon: Icon(_isTalking ? Icons.stop : Icons.mic),
                      label: Text(_isTalking ? '结束对话' : '开始对话'),
                    ),
                  ),
                  const SizedBox(width: 8),
                  FilterChip(
                    label: const Text('AEC3'),
                    selected: _enableAec,
                    onSelected: _isTalking
                        ? null
                        : (v) => setState(() => _enableAec = v),
                  ),
                  const SizedBox(width: 6),
                  FilterChip(
                    label: const Text('回环'),
                    selected: _loopback,
                    onSelected: _isTalking
                        ? null
                        : (v) => setState(() => _loopback = v),
                  ),
                ],
              ),
              const SizedBox(height: 8),
              if (!_isTalking)
                Text(
                  '回环自测：上行 opus 直接喂本机播放（不走网络）。单机即可验证全链路；'
                  '此时参考信号就是自己的声音，AEC 会把它当回声消掉，所以「回环下声音变小」= AEC 在工作。',
                  style: TextStyle(fontSize: 11.5, color: cs.onSurfaceVariant),
                ),
              const SizedBox(height: 10),
              _kv('AEC 抑制量',
                  '${(_inDbfs - _outDbfs).toStringAsFixed(1)} dB   (in ${_inDbfs.toStringAsFixed(1)} / out ${_outDbfs.toStringAsFixed(1)} dBFS)'),
              _kv('AEC 帧 / 缺参考', '$_aecFrames / $_starved'),
              _kv('样本守恒（AEC 前后字节）', '$_bytesIn → $_bytesOut'),
              _kv('播放延迟', '${_playDelayMs.toStringAsFixed(0)} ms'),
              if (_bytesIn > 0 && _bytesOut > 0 && _bytesIn != _bytesOut)
                Padding(
                  padding: const EdgeInsets.only(top: 4),
                  child: Text(
                    '⚠️ 前后字节不相等，只允许差 < 960B（一个 10ms 帧）；持续不等说明吃样本，时间轴会漂',
                    style: TextStyle(color: cs.error, fontSize: 12),
                  ),
                ),
            ],
          ),
        ),
      );

  Widget _recordCard(ColorScheme cs) => Card(
        child: Padding(
          padding: const EdgeInsets.all(12),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              _sectionTitle('3. 录音 / 导出', cs),
              const SizedBox(height: 8),
              Row(
                children: [
                  Expanded(
                    child: FilledButton.icon(
                      onPressed: _isWriteRecordFile ? null : _startRecording,
                      icon: const Icon(Icons.fiber_manual_record),
                      label: const Text('开始录音（广播）'),
                    ),
                  ),
                  const SizedBox(width: 8),
                  Expanded(
                    child: OutlinedButton.icon(
                      onPressed: _isWriteRecordFile
                          ? () => _stopRecording(broadcast: true)
                          : null,
                      icon: const Icon(Icons.stop_circle_outlined),
                      label: const Text('停止录音'),
                    ),
                  ),
                ],
              ),
              const SizedBox(height: 8),
              _kv('录音状态',
                  _isWriteRecordFile ? '🔴 录制中 ${_recordSeconds}s' : '未录制'),
              _kv('已完成段数', '${_segments.length} 段'),
              _kv('当前段文件',
                  _pcmPath == null ? '（点开始录音后分配）' : _pcmPath!),
              if (_pcmPath != null)
                Align(
                  alignment: Alignment.centerRight,
                  child: TextButton(
                    onPressed: () => _copyPath(_pcmPath!),
                    child: const Text('复制 PCM 路径'),
                  ),
                ),
              const SizedBox(height: 6),
              Row(
                children: [
                  Expanded(
                    child: FilledButton.tonalIcon(
                      onPressed: _exportWav,
                      icon: const Icon(Icons.music_note),
                      label: const Text('导出 WAV'),
                    ),
                  ),
                  const SizedBox(width: 8),
                  Expanded(
                    child: OutlinedButton.icon(
                      onPressed: _shareWav,
                      icon: const Icon(Icons.share),
                      label: const Text('分享 WAV'),
                    ),
                  ),
                ],
              ),
              if (_lastWavPath.isNotEmpty)
                Padding(
                  padding: const EdgeInsets.only(top: 6),
                  child: InkWell(
                    onTap: () => _copyPath(_lastWavPath),
                    child: Text(
                      'WAV: $_lastWavPath',
                      style: const TextStyle(fontSize: 12),
                    ),
                  ),
                ),
            ],
          ),
        ),
      );

  Widget _logCard(ColorScheme cs) => Card(
        child: Padding(
          padding: const EdgeInsets.all(12),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Row(
                children: [
                  Expanded(child: _sectionTitle('运行日志', cs)),
                  TextButton(
                    onPressed: () => setState(_logs.clear),
                    child: const Text('清空'),
                  ),
                ],
              ),
              SizedBox(
                height: 220,
                child: ListView.builder(
                  reverse: true,
                  itemCount: _logs.length,
                  itemBuilder: (_, i) {
                    final line = _logs[_logs.length - 1 - i];
                    return Padding(
                      padding: const EdgeInsets.symmetric(vertical: 1),
                      child: Text(
                        line,
                        style: const TextStyle(
                          fontFamily: 'monospace',
                          fontSize: 11,
                          height: 1.35,
                        ),
                      ),
                    );
                  },
                ),
              ),
            ],
          ),
        ),
      );

  Widget _sectionTitle(String s, ColorScheme cs) => Text(
        s,
        style: TextStyle(fontWeight: FontWeight.bold, color: cs.primary),
      );

  Widget _kv(String k, String v) => Padding(
        padding: const EdgeInsets.symmetric(vertical: 2),
        child: Row(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            SizedBox(
              width: 132,
              child: Text(k, style: const TextStyle(fontSize: 12.5)),
            ),
            Expanded(
              child: Text(
                v,
                style: const TextStyle(fontSize: 12.5, fontFamily: 'monospace'),
              ),
            ),
          ],
        ),
      );
}
