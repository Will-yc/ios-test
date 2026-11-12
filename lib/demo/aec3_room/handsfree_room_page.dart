import 'dart:async';
import 'dart:io';
import 'dart:isolate';

import 'package:audio_session/audio_session.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:my_flutter_app/demo/aec3_room/audio_playback_manager.dart';
import 'package:my_flutter_app/demo/aec3_room/audio_processing_worker.dart';
import 'package:my_flutter_app/demo/aec3_room/room_socket.dart';
import 'package:my_flutter_app/demo/aec3_room/wav_export.dart';
import 'package:my_flutter_app/demo/util/my_dual_util.dart';
import 'package:native_aec/native_aec.dart';
import 'package:opus_ffi/opus_ffi.dart';
import 'package:path_provider/path_provider.dart';
import 'package:record/record.dart' hide IosAudioCategory;
import 'package:share_plus/share_plus.dart';

/// 实测页 —— Android ↔ iOS 无耳机对讲，一次进房从头录到尾，结束时导出 wav。
///
/// 与 `dual_room_page.dart`（调试页）的区别：这个页只有一个动线，
/// 不暴露 AEC 开关/回环/分段录音等实验开关，给真机实测用。
///
/// 通信复用 App 项目现成的音频房间服务端：
///   `wss://appapi.zhiyuexc.com/audiowss`（= HttpConfig_Socket.getSocketUrl）
/// 协议逐字段一致：连上先收 `ws_connection_success`，再发
///   {"type":"join","content":{"roomId","userId"}}   <- 两个字段都必须是**字符串**
/// 上行二进制 = 裸 opus 包；服务端混音后**扣掉发送者自己那一份**再下发，
/// 所以收到的永远是对方的声音 —— 这正好是 AEC 需要的干净参考信号。
///
/// 链路：mic(48k) → AEC3 → .pcm（成品）→ 结束时转 .wav → 系统分享导出
///                        └→ 48k→16k → opus → 上行
///
/// 编译期可预置（打 IPA 时写死，省得在真机上敲）：
///   --dart-define=ROOM_TEST=true
///   --dart-define=ROOM_URL=wss://appapi.zhiyuexc.com/audiowss
///   --dart-define=ROOM_ID=aec3test
const String kDefaultRoomUrl = String.fromEnvironment(
  'ROOM_URL',
  defaultValue: 'wss://appapi.zhiyuexc.com/audiowss',
);
const String kDefaultRoomId = String.fromEnvironment(
  'ROOM_ID',
  defaultValue: 'aec3test',
);

enum _Phase { idle, starting, live, stopping, done }

class HandsfreeRoomPage extends StatefulWidget {
  const HandsfreeRoomPage({super.key});

  @override
  State<HandsfreeRoomPage> createState() => _HandsfreeRoomPageState();
}

class _HandsfreeRoomPageState extends State<HandsfreeRoomPage>
    with WidgetsBindingObserver {
  // ---------- 通信 ----------
  final RoomSocketManager _socket = RoomSocketManager();
  StreamSubscription<RoomSocketStatus>? _statusSub;
  StreamSubscription<RoomMessage>? _textSub;
  StreamSubscription<Uint8List>? _binarySub;
  RoomSocketStatus _socketStatus = RoomSocketStatus.disconnected;
  int _clientsNum = 0;
  bool _peerJoined = false;

  // ---------- 采集 / 播放 ----------
  final AudioRecorder _recorder = AudioRecorder();
  AudioSession? _audioSession;
  OpusDecoder? _decoder;
  AudioPlaybackManager? _playbackManager;
  StreamSubscription<Uint8List>? _micSub;
  bool _gotMicData = false;

  // ---------- worker ----------
  Isolate? _audioIsolate;
  ReceivePort? _mainReceivePort;
  SendPort? _workerSendPort;
  Completer<void> _workerReady = Completer<void>();
  bool _isWorkerReady = false;
  bool _isWorkerClosed = false;
  Completer<void>? _fileClosed;

  // ---------- 录音成品 ----------
  String? _pcmPath;
  String _wavPath = '';
  int _pcmBytes = 0;
  Duration _elapsed = Duration.zero;
  DateTime? _recordStartAt;
  Timer? _uiTimer;

  // ---------- AEC 观测 ----------
  double _inDbfs = -90;
  double _outDbfs = -90;

  // ---------- 页面状态 ----------
  _Phase _phase = _Phase.idle;
  final List<String> _logs = [];

  /// 两台设备必须用不同身份（userId 不同），默认按平台分配。
  late String _identity = Platform.isIOS ? 'B' : 'A';
  late final TextEditingController _roomCtrl =
      TextEditingController(text: kDefaultRoomId);
  late final TextEditingController _urlCtrl =
      TextEditingController(text: kDefaultRoomUrl);

  String get _userId => 'hf_$_identity';
  bool get _busy => _phase == _Phase.starting || _phase == _Phase.stopping;
  bool get _canEditConfig => _phase == _Phase.idle || _phase == _Phase.done;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    _bindSocket();
    _uiTimer = Timer.periodic(const Duration(seconds: 1), (_) => _tick());
    _log('AEC3: ${aec3Available() ? '可用' : '不可用（将直通）'}');
    _log('服务端: $kDefaultRoomUrl');
    if (!aec3Available()) {
      _log('⚠️ 原生库没加载，录下来的成品里会有回声');
    }
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    _uiTimer?.cancel();
    _statusSub?.cancel();
    _textSub?.cancel();
    _binarySub?.cancel();
    _micSub?.cancel();
    _recorder.dispose();
    _playbackManager?.dispose();
    _socket.disconnect();
    // worker 还要 await flush 才关文件，别抢在前面 kill
    final isolate = _audioIsolate;
    _workerSendPort?.send({'type': 'dispose'});
    Future<void>.delayed(const Duration(milliseconds: 400), () {
      isolate?.kill(priority: Isolate.immediate);
    });
    _mainReceivePort?.close();
    super.dispose();
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    // iOS 切后台会立刻 suspend 进程，麦克风必然断流；这里只提示，不自动停，
    // 免得用户切出去看个通知就把整段录音掐了。
    if (state == AppLifecycleState.paused && _phase == _Phase.live) {
      _log('⚠️ App 进入后台，系统会掐断麦克风；请保持前台');
    }
  }

  // =====================================================================
  // 通信
  // =====================================================================

  void _bindSocket() {
    _statusSub = _socket.statusStream.listen((s) {
      if (!mounted) return;
      setState(() => _socketStatus = s);
      if (s == RoomSocketStatus.connected) {
        _sendJoin();
      } else if (s == RoomSocketStatus.error ||
          s == RoomSocketStatus.disconnected) {
        setState(() => _peerJoined = false);
      }
    });
    _textSub = _socket.textMessageStream.listen(_onText);
    _binarySub = _socket.binaryMessageStream.listen((pkt) {
      _playbackManager?.handleIncomingOpusPacket(pkt);
    });
  }

  void _sendJoin() {
    final room = _roomCtrl.text.trim();
    if (room.isEmpty) return;
    _socket.sendMessage(
      RoomMessage(
        type: WsType.join,
        content: {'roomId': room, 'userId': _userId},
      ),
    );
    _log('已进房 room=$room userId=$_userId');
  }

  void _onText(RoomMessage msg) {
    final data = msg.content;
    final map = data is Map ? data : const {};
    switch (msg.type) {
      case WsType.join:
        final uid = map['_userId']?.toString();
        if (uid != null && uid != _userId) {
          _log('👥 $uid 进房');
          setState(() => _peerJoined = true);
        }
        final n = (map['clientsNum'] as num?)?.toInt();
        if (n != null) setState(() => _clientsNum = n);
        break;
      case WsType.leave:
        final uid = map['_userId']?.toString();
        if (uid != null && uid != _userId) {
          _log('👋 $uid 离开');
          setState(() => _peerJoined = false);
        }
        break;
      case WsType.heartbeat:
        final n = (map['clientsNum'] as num?)?.toInt();
        if (n != null && n != _clientsNum) {
          setState(() {
            _clientsNum = n;
            _peerJoined = n >= 2;
          });
          _log('房间人数: $n');
        }
        break;
      default:
        break;
    }
  }

  // =====================================================================
  // worker
  // =====================================================================

  Future<void> _ensureWorker() async {
    if (!_isWorkerClosed && _isWorkerReady && _workerSendPort != null) return;

    _isWorkerReady = false;
    _isWorkerClosed = false;
    if (_workerReady.isCompleted) _workerReady = Completer<void>();
    _audioIsolate?.kill(priority: Isolate.immediate);
    _mainReceivePort?.close();
    _workerSendPort = null;

    _mainReceivePort = ReceivePort();
    _audioIsolate = await Isolate.spawn(
      audioProcessingWorker,
      _mainReceivePort!.sendPort,
      debugName: 'HandsfreeAudioWorker',
    );

    _mainReceivePort!.listen((message) {
      if (message is SendPort) {
        _workerSendPort = message;
        _isWorkerReady = true;
        if (!_workerReady.isCompleted) _workerReady.complete();
        return;
      }
      if (message is! Map) return;
      switch (message['type']) {
        case 'opus_packet':
          if (_socketStatus == RoomSocketStatus.connected) {
            _socket.sendBinaryMessage(message['data']);
          }
          break;
        case 'aec-unavailable':
          _log('⚠️ AEC3 句柄创建失败，本次直通');
          break;
        case 'aec_stats':
          if (!mounted) return;
          setState(() {
            _inDbfs = (message['inDbfs'] as num?)?.toDouble() ?? -90;
            _outDbfs = (message['outDbfs'] as num?)?.toDouble() ?? -90;
          });
          break;
        case 'file-closed':
          if (_fileClosed != null && !_fileClosed!.isCompleted) {
            _fileClosed!.complete();
          }
          break;
        case 'error':
          _log('❌ worker: ${message['data']}');
          break;
      }
    });

    await _workerReady.future.timeout(
      const Duration(seconds: 5),
      onTimeout: () => _log('❌ 音频线程启动超时'),
    );
  }

  void _forwardReference(Uint8List pcm) {
    final port = _workerSendPort;
    if (port == null || _isWorkerClosed || pcm.isEmpty) return;
    port.send({'type': 'ref_chunk', 'data': pcm});
  }

  // =====================================================================
  // 开始 / 结束
  // =====================================================================

  Future<void> _start() async {
    if (_busy || _phase == _Phase.live) return;
    setState(() {
      _phase = _Phase.starting;
      _wavPath = '';
      _pcmBytes = 0;
      _elapsed = Duration.zero;
      _gotMicData = false;
      _inDbfs = -90;
      _outDbfs = -90;
      _logs.clear();
    });
    _log('开始：room=${_roomCtrl.text.trim()} user=$_userId');

    try {
      if (!await _recorder.hasPermission()) {
        _log('❌ 没有麦克风权限');
        _toast('请先允许麦克风权限');
        setState(() => _phase = _Phase.idle);
        return;
      }

      await _ensureWorker();
      if (_workerSendPort == null) {
        _toast('音频线程未就绪');
        setState(() => _phase = _Phase.idle);
        return;
      }
      // 只建 AEC 句柄，文件在下面单独开
      _workerSendPort!.send({'type': 'init', 'aecEnabled': true});

      // 解码到 48k：参考信号必须与采集同采样率，opus 原生支持任意标准率
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
        onPlaybackReference: _forwardReference,
      );
      await _playbackManager!.init();
      await _activateAudioSession();

      // 采集前确保上一轮真的停了（否则 iOS 会拿到一条永不产出 buffer 的流）
      if (await _recorder.isRecording()) {
        await _recorder.stop();
        await Future<void>.delayed(const Duration(milliseconds: 150));
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
      _micSub = stream.listen(
        _onMicChunk,
        onError: (Object e) {
          _log('❌ 采集流错误: $e');
        },
      );

      // 进房（地址里带不带端口都行，RoomSocketManager 直接透传）
      final url = _urlCtrl.text.trim();
      _log('连接 $url …');
      final ok = await _socket.connect(url);
      if (!ok) _log('⚠️ 连接未成功，先本地录音，网络恢复后会自动重连');

      // 一次进房 = 一个成品文件：从这一刻开始写，直到点「结束」
      await _beginRecordFile();

      if (!mounted) return;
      setState(() => _phase = _Phase.live);
      _log('🎙️ 对讲中（AEC3 已开），可以开口说话了');
      Future<void>.delayed(const Duration(seconds: 5), () {
        if (!mounted || _phase != _Phase.live) return;
        if (!_gotMicData) _log('⚠️ 5 秒内没有麦克风数据，检查权限/设备占用');
      });
    } catch (e) {
      _log('❌ 启动失败: $e');
      _toast('启动失败: $e');
      if (mounted) setState(() => _phase = _Phase.idle);
    }
  }

  void _onMicChunk(Uint8List chunk) {
    if (chunk.isEmpty) return;
    if (!_gotMicData) setState(() => _gotMicData = true);
    final port = _workerSendPort;
    if (port == null || _isWorkerClosed) return;
    port.send({
      'type': 'pcm_chunk',
      'data': chunk,
      'isWriteRecordFile': true,
      'captureTime': DateTime.now().millisecondsSinceEpoch,
    });
  }

  Future<void> _beginRecordFile() async {
    final dir = await getApplicationDocumentsDirectory();
    final now = DateTime.now();
    final stamp = '${now.year}'
        '${now.month.toString().padLeft(2, '0')}'
        '${now.day.toString().padLeft(2, '0')}_'
        '${now.hour.toString().padLeft(2, '0')}'
        '${now.minute.toString().padLeft(2, '0')}'
        '${now.second.toString().padLeft(2, '0')}';
    final path = '${dir.path}/handsfree_${_identity}_$stamp.pcm';
    _fileClosed = Completer<void>();
    _workerSendPort?.send({
      'type': 'init',
      'filePath': path,
      'aecEnabled': true,
    });
    _workerSendPort?.send({
      'type': 'isWriteRecordFile',
      'isWriteRecordFile': true,
    });
    _recordStartAt = DateTime.now();
    setState(() {
      _pcmPath = path;
      _elapsed = Duration.zero;
    });
    _log('🔴 开始录制: $path');
  }

  Future<void> _stopAndExport() async {
    if (_phase != _Phase.live) return;
    setState(() => _phase = _Phase.stopping);
    _log('结束中…');

    // 1. 先断采集，再关文件：否则关文件之后还会有一两块写进来
    await _micSub?.cancel();
    _micSub = null;
    try {
      await _recorder.stop();
    } catch (e) {
      _log('停止采集异常: $e');
    }
    _workerSendPort?.send({
      'type': 'isWriteRecordFile',
      'isWriteRecordFile': false,
    });
    await _waitFileClosed();

    // 2. 收播放/worker/房间
    await _playbackManager?.dispose();
    _playbackManager = null;
    _decoder?.dispose();
    _decoder = null;
    final port = _workerSendPort;
    _workerSendPort = null;
    _isWorkerReady = false;
    _isWorkerClosed = true;
    port?.send({'type': 'dispose'});
    await _socket.disconnect();
    setState(() => _peerJoined = false);

    // 3. 转 wav
    final pcm = _pcmPath;
    if (pcm == null || !File(pcm).existsSync()) {
      _log('❌ 没有找到录音文件');
      setState(() => _phase = _Phase.done);
      return;
    }
    try {
      final len = await File(pcm).length();
      final wavPath = pcm.replaceAll(RegExp(r'\.pcm$'), '.wav');
      await pcmFileToWav(
        pcm,
        wavPath,
        sampleRate: kSampleRateRecorder,
        channels: kChannels,
      );
      final secs = len / 2 / kSampleRateRecorder;
      if (!mounted) return;
      setState(() {
        _wavPath = wavPath;
        _pcmBytes = len;
        _phase = _Phase.done;
      });
      _log('💾 导出完成 ${File(wavPath).uri.pathSegments.last}  '
          '${(len / 1024).toStringAsFixed(0)}KB  ${secs.toStringAsFixed(1)}s');
      await _share();
    } catch (e) {
      _log('❌ 转 wav 失败: $e');
      if (mounted) setState(() => _phase = _Phase.done);
    }
  }

  Future<void> _waitFileClosed() async {
    final c = _fileClosed;
    if (c == null || c.isCompleted) return;
    try {
      await c.future.timeout(const Duration(seconds: 3));
    } on TimeoutException {
      _log('⚠️ 等文件关闭超时，wav 可能缺尾巴');
    }
  }

  Future<void> _share() async {
    if (_wavPath.isEmpty || !File(_wavPath).existsSync()) {
      _toast('还没有可导出的文件');
      return;
    }
    final box = context.findRenderObject() as RenderBox?;
    try {
      await Share.shareXFiles(
        [XFile(_wavPath, mimeType: 'audio/wav')],
        subject: '无耳机对讲录音',
        sharePositionOrigin:
            box != null ? box.localToGlobal(Offset.zero) & box.size : null,
      );
    } catch (e) {
      _log('分享失败: $e');
    }
  }

  Future<void> _activateAudioSession() async {
    try {
      final session = _audioSession ?? await AudioSession.instance;
      _audioSession = session;
      await session.configure(
        AudioSessionConfiguration(
          avAudioSessionCategory: AVAudioSessionCategory.playAndRecord,
          // defaultToSpeaker：走扬声器而不是听筒，这是「不戴耳机」的前提
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
      await session.setActive(true);
    } catch (e) {
      _log('⚠️ 音频会话配置失败: $e');
    }
  }

  void _tick() {
    if (!mounted) return;
    if (_phase == _Phase.live && _workerSendPort != null) {
      _workerSendPort!.send({'type': 'aec_stats'});
    }
    setState(() {
      if (_recordStartAt != null && _phase == _Phase.live) {
        _elapsed = DateTime.now().difference(_recordStartAt!);
      }
    });
    // worker 每 12KB 才刷一次盘，这里直接看文件长度就够了（顺带能发现写盘卡住）
    final pcm = _pcmPath;
    if (_phase == _Phase.live && pcm != null) {
      File(pcm).length().then((n) {
        if (!mounted) return;
        if (n != _pcmBytes) setState(() => _pcmBytes = n);
      }).catchError((Object _) {});
    }
  }

  // =====================================================================
  // 小工具
  // =====================================================================

  void _log(String s) {
    final t = DateTime.now();
    final stamp = '${t.hour.toString().padLeft(2, '0')}:'
        '${t.minute.toString().padLeft(2, '0')}:'
        '${t.second.toString().padLeft(2, '0')}';
    _logs.add('$stamp  $s');
    if (_logs.length > 200) _logs.removeAt(0);
    if (mounted) setState(() {});
  }

  void _toast(String s) {
    if (!mounted) return;
    ScaffoldMessenger.of(context)
      ..clearSnackBars()
      ..showSnackBar(SnackBar(content: Text(s)));
  }

  void _copy(String s) {
    Clipboard.setData(ClipboardData(text: s));
    _toast('已复制');
  }

  Future<void> _confirmExit() async {
    if (_busy) {
      _toast('正在处理音频，稍等一下');
      return;
    }
    if (_phase != _Phase.live) {
      Navigator.of(context).pop();
      return;
    }
    final leave = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('正在对讲'),
        content: const Text('现在还录着音。离开会结束对讲并停止录音（已录部分不会自动导出）。'),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(ctx, false),
            child: const Text('继续对讲'),
          ),
          TextButton(
            onPressed: () => Navigator.pop(ctx, true),
            child: const Text('结束并离开'),
          ),
        ],
      ),
    );
    if (leave == true && mounted) {
      await _stopAndExport();
      if (mounted) Navigator.of(context).pop();
    }
  }

  // =====================================================================
  // UI
  // =====================================================================

  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    return PopScope(
      canPop: _phase != _Phase.live && !_busy,
      onPopInvokedWithResult: (didPop, _) {
        if (!didPop) _confirmExit();
      },
      child: Scaffold(
        appBar: AppBar(
          title: const Text('无耳机对讲实测'),
          actions: [
            IconButton(
              tooltip: '离开',
              onPressed: _busy ? null : _confirmExit,
              icon: const Icon(Icons.logout),
            ),
          ],
        ),
        body: ListView(
          padding: const EdgeInsets.fromLTRB(16, 12, 16, 32),
          children: [
            _tipCard(cs),
            const SizedBox(height: 12),
            _configCard(cs),
            const SizedBox(height: 12),
            _actionCard(cs),
            const SizedBox(height: 12),
            _statusCard(cs),
            if (_wavPath.isNotEmpty) ...[
              const SizedBox(height: 12),
              _resultCard(cs),
            ],
            const SizedBox(height: 12),
            _logCard(cs),
          ],
        ),
      ),
    );
  }

  Widget _tipCard(ColorScheme cs) => Container(
        padding: const EdgeInsets.all(12),
        decoration: BoxDecoration(
          color: cs.secondaryContainer,
          borderRadius: BorderRadius.circular(12),
        ),
        child: Text(
          '两台设备都别戴耳机、音量开到常用大小。一端选 A、一端选 B，'
          '房间号必须一样。开始后直接说话，成品里只会剩本端人声。\n'
          '前 1~2 秒是 AEC 收敛期，导出时保留原样。',
          style: TextStyle(color: cs.onSecondaryContainer, height: 1.45),
        ),
      );

  Widget _configCard(ColorScheme cs) => Card(
        child: Padding(
          padding: const EdgeInsets.all(14),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text('房间', style: Theme.of(context).textTheme.titleMedium),
              const SizedBox(height: 10),
              TextField(
                controller: _roomCtrl,
                enabled: _canEditConfig,
                decoration: const InputDecoration(
                  labelText: '房间号',
                  isDense: true,
                  border: OutlineInputBorder(),
                ),
              ),
              const SizedBox(height: 10),
              TextField(
                controller: _urlCtrl,
                enabled: _canEditConfig,
                style: const TextStyle(fontSize: 12),
                decoration: const InputDecoration(
                  labelText: '服务地址',
                  isDense: true,
                  border: OutlineInputBorder(),
                ),
              ),
              const SizedBox(height: 12),
              Row(
                children: [
                  const Text('本机身份'),
                  const SizedBox(width: 12),
                  SegmentedButton<String>(
                    segments: const [
                      ButtonSegment(value: 'A', label: Text('A 端')),
                      ButtonSegment(value: 'B', label: Text('B 端')),
                    ],
                    selected: {_identity},
                    onSelectionChanged: _canEditConfig
                        ? (s) => setState(() => _identity = s.first)
                        : null,
                  ),
                  const Spacer(),
                  Text(
                    _userId,
                    style: Theme.of(context).textTheme.bodySmall,
                  ),
                ],
              ),
            ],
          ),
        ),
      );

  Widget _actionCard(ColorScheme cs) {
    final bool live = _phase == _Phase.live;
    final String label;
    if (_phase == _Phase.starting) {
      label = '启动中…';
    } else if (_phase == _Phase.stopping) {
      label = '正在导出…';
    } else if (live) {
      label = '结束并导出 WAV';
    } else if (_phase == _Phase.done) {
      label = '再录一次';
    } else {
      label = '加入房间并开始';
    }
    return Column(
      children: [
        SizedBox(
          width: double.infinity,
          height: 56,
          child: FilledButton.icon(
            onPressed: _busy ? null : (live ? _stopAndExport : _start),
            style: FilledButton.styleFrom(
              backgroundColor: live ? cs.error : cs.primary,
            ),
            icon: Icon(live ? Icons.stop_circle_outlined : Icons.mic),
            label: Text(label, style: const TextStyle(fontSize: 17)),
          ),
        ),
        if (live) ...[
          const SizedBox(height: 8),
          Text(
            '正在录制 · ${_fmt(_elapsed)}',
            style: TextStyle(color: cs.error, fontWeight: FontWeight.w600),
          ),
        ],
      ],
    );
  }

  Widget _statusCard(ColorScheme cs) {
    final bool connected = _socketStatus == RoomSocketStatus.connected;
    return Card(
      child: Padding(
        padding: const EdgeInsets.all(14),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            _row(
              '连接',
              roomStatusText(_socketStatus),
              ok: connected,
            ),
            _row(
              '对端',
              _peerJoined ? '已进房' : (_phase == _Phase.live ? '等待中' : '—'),
              ok: _peerJoined,
            ),
            _row('房间人数', _clientsNum == 0 ? '—' : '$_clientsNum'),
            const Divider(height: 18),
            _row('采集电平', '${_inDbfs.toStringAsFixed(1)} dBFS'),
            _row('AEC 后', '${_outDbfs.toStringAsFixed(1)} dBFS'),
            _row(
              '回声抑制',
              (_inDbfs < -80 || _outDbfs < -80)
                  ? '—'
                  : '${(_inDbfs - _outDbfs).toStringAsFixed(1)} dB',
            ),
            const Divider(height: 18),
            _row('录制时长', _fmt(_elapsed)),
            _row('本段大小', _pcmBytes == 0 ? '—' : '${(_pcmBytes / 1024).round()} KB'),
            if (_pcmPath != null)
              Align(
                alignment: Alignment.centerRight,
                child: TextButton(
                  onPressed: () => _copy(_pcmPath!),
                  child: const Text('复制文件路径'),
                ),
              ),
          ],
        ),
      ),
    );
  }

  Widget _resultCard(ColorScheme cs) => Card(
        color: cs.tertiaryContainer,
        child: Padding(
          padding: const EdgeInsets.all(14),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Row(
                children: [
                  Icon(Icons.audio_file, color: cs.onTertiaryContainer),
                  const SizedBox(width: 8),
                  Text(
                    '成品已生成',
                    style: TextStyle(
                      color: cs.onTertiaryContainer,
                      fontWeight: FontWeight.w600,
                    ),
                  ),
                ],
              ),
              const SizedBox(height: 8),
              SelectableText(
                _wavPath,
                style: TextStyle(
                  fontSize: 12,
                  color: cs.onTertiaryContainer,
                ),
              ),
              const SizedBox(height: 10),
              Row(
                children: [
                  Expanded(
                    child: FilledButton.tonalIcon(
                      onPressed: _share,
                      icon: const Icon(Icons.ios_share),
                      label: const Text('导出 / 分享'),
                    ),
                  ),
                  const SizedBox(width: 10),
                  IconButton.filledTonal(
                    onPressed: () => _copy(_wavPath),
                    icon: const Icon(Icons.copy),
                  ),
                ],
              ),
            ],
          ),
        ),
      );

  Widget _logCard(ColorScheme cs) => Card(
        child: ExpansionTile(
          title: const Text('运行日志'),
          subtitle: Text('${_logs.length} 条'),
          childrenPadding: const EdgeInsets.fromLTRB(14, 0, 14, 14),
          initiallyExpanded: _phase == _Phase.live,
          children: [
            Container(
              width: double.infinity,
              padding: const EdgeInsets.all(10),
              decoration: BoxDecoration(
                color: cs.surfaceContainerHighest,
                borderRadius: BorderRadius.circular(8),
              ),
              child: SingleChildScrollView(
                scrollDirection: Axis.vertical,
                child: Text(
                  _logs.isEmpty ? '（暂无）' : _logs.join('\n'),
                  style: const TextStyle(fontSize: 11, height: 1.5),
                ),
              ),
            ),
          ],
        ),
      );

  Widget _row(String k, String v, {bool ok = false}) => Padding(
        padding: const EdgeInsets.symmetric(vertical: 3),
        child: Row(
          children: [
            SizedBox(
              width: 78,
              child: Text(k, style: const TextStyle(color: Colors.grey)),
            ),
            Expanded(child: Text(v)),
            if (ok) const Icon(Icons.check_circle, size: 15, color: Colors.green),
          ],
        ),
      );

  String _fmt(Duration d) {
    final m = d.inMinutes.toString().padLeft(2, '0');
    final s = (d.inSeconds % 60).toString().padLeft(2, '0');
    return '$m:$s';
  }
}
