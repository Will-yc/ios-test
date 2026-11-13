import 'dart:async';
import 'dart:io';
import 'dart:isolate';
import 'dart:math' as math;
import 'dart:typed_data';

import 'package:audio_session/audio_session.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:my_flutter_app/demo/aec3_room/audio_playback_manager.dart';
import 'package:my_flutter_app/demo/aec3_room/audio_processing_worker.dart';
import 'package:my_flutter_app/demo/aec3_room/delay_calibrator.dart';
import 'package:my_flutter_app/demo/aec3_room/howl_notch.dart';
import 'package:my_flutter_app/demo/aec3_room/loop_gain_guard.dart';
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

/// 参考信号延迟补偿（ms）——**这是外放回声能不能消掉的关键，不是调参**。
///
/// AEC 只能消「参考帧 ↔ 采集帧按时间对齐」的那部分回声。播放侧的字节是先
/// 交给播放引擎，再经过 native 缓冲（targetNativeMs=100）、输出缓冲、扬声器、
/// 空气、麦克风，之后才会出现在采集流里。**这段延迟两端不一样**：
///   - Android（PMA120 实测）：AudioTrack 缓冲大，321~352ms → 补 250
///   - iOS：AudioUnit 输出缓冲小得多，估 130~160ms → 补 100（**未实测**）
///
/// 推得过满会变成**负延迟**（参考比回声晚到），AEC 无法处理、效果直接归零
/// —— 两端闭环里只要有一端归零，回声残余 ~0dB，环路增益就会过 1，表现为
/// 双方一停顿就啸叫。所以宁可欠补（留正延迟给 AEC 自己的延迟估计器）。
///
/// 这里的值只是**编译期默认初值**：页面上的「参考补偿」下拉可在运行时改
/// （100/150/200/250/300），「标定延迟」按钮会播 PN 序列自动测出真机延迟，
/// 不再靠猜。扫描时两端各跑一次标定即可。
final int kRefDelayMs = int.fromEnvironment(
  'REF_DELAY_MS',
  defaultValue: Platform.isAndroid ? 250 : 100,
);

/// 播放增益默认 **70%**（参考 TRTC：通话档播放音量默认 50，从不拉满）。
///
/// 送进扬声器的字节同时就是 AEC 的参考信号。原来固定乘 1.6，峰值一过
/// 20479 就被 clamp 硬削波；削波是不可逆非线性，AEC 的线性滤波器只对得上
/// 基波，谐波会原样留在成品里。更关键的是：客户端放大直接抬高声学闭环增益，
/// 真机时间线已证实「音量推到 4 档 → 3 秒后啸叫起振」。
/// 环路增益与播放音量成正比：100%→70% 直接给环路 −3dB 余量。
/// 因此即便 dart-define 传 PLAY_GAIN_PCT=200，这里也钳到 100；
/// 想更响请调系统媒体音量（那部分由采集侧守卫动态 duck 兜底）。
const int kMaxPlayGainPct = 100;
final int kPlayGainPct = math.min(
  int.fromEnvironment('PLAY_GAIN_PCT', defaultValue: 70),
  kMaxPlayGainPct,
);

/// 系统 3A 开关（VPIO / VOICE_COMMUNICATION 通话档）。**默认关**。
///
/// 曾参考 TRTC「通话一律走系统 3A」把 iOS 切成 voiceChat+VPIO（bd2c408），
/// 2026-11-12 真机成品实测证明这条路对本项目是双输：
///   1. **音质被毁**：VPIO 把采集限到语音带宽（成品频谱 <16kHz，应 20kHz），
///      NS 把静音段压成纯数字零（成品大段 -240dBFS，底噪"太干净"不自然），
///      而本项目成品是方言语料，要的就是全频带 + 真实噪底。
///   2. **回声照旧**：播放走 FlutterPcmSound 自己的 AudioUnit，VPIO 的 AEC
///      参考不到这条渲染流，实测 iOS 成品里对方声音照样在；且真机网络
///      单向延迟 2~3s，任何按「小延迟」设计的系统 AEC 都追不上。
/// 现在两端统一：裸麦 48k → worker AEC3 + 相关门（门用本地播放参考自搜
/// 延迟，天然不受网络延迟影响），上行与成品共用门的判决。
/// 仅做 A/B 对照时用 --dart-define=SYS_3A=true 打开。
const bool kSys3A =
    String.fromEnvironment('SYS_3A', defaultValue: 'false') == 'true';

/// Android「双流」开关，**默认关**。2026-11-12 真机回归实测（PMA120）：
/// 第二条 VOICE_COMMUNICATION 采集流一启动就把第一条裸麦成品流抢占停摆
/// （成品.pcm 与 _raw.pcm 都只剩 80ms）→ Android 成品全空；且 modeNormal
/// 下 AcousticEchoCanceler 不生效（它要 MODE_IN_COMMUNICATION），这条上行
/// 反而把对端声音原样送回 → iOS 一直听到自己的回声。故默认回到单流。
/// 仅在确认能并发采集的机型上才用 --dart-define=SYS_3A_DUAL=true 打开做 A/B。
const bool kAndroidDualStream =
    String.fromEnvironment('SYS_3A_DUAL', defaultValue: 'false') == 'true';

/// 诊断开关：把 AEC **之前**的原始采集也落一份 `_raw.pcm`，
/// 重测后可以拿两份文件直接算出真实 ERLE，不用再靠听感判断。
/// （统一用 String 比较：这个工程里 bool.fromEnvironment 读 dart-define 曾静默失效）
const bool kKeepRaw = String.fromEnvironment('KEEP_RAW') == 'true';

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

  // ---------- 系统 3A 上行流（仅 Android 且 SYS_3A_DUAL=true，默认不用）----------
  // 第二条采集流：16k VOICE_COMMUNICATION + 系统 AEC/NS/AGC，直接编码上行。
  // 注意：record 插件虽按实例隔离，但系统层并发采集会抢占 —— PMA120 实测
  // 第二条流会把第一条裸麦成品流停摆，故默认关闭，见 kAndroidDualStream。
  final AudioRecorder _uplinkRecorder = AudioRecorder();
  StreamSubscription<Uint8List>? _uplinkSub;
  OpusEncoder? _uplinkEncoder;
  final BytesBuilder _uplinkBuf = BytesBuilder();
  bool _sysUplinkActive = false;
  DateTime? _uplinkLastDataAt;
  // 连续「全数字零」的起点：真麦即使被 NS 压过也不会连续 3s 输出纯零，
  // 只有采集通路被系统抢占/静音时才会 —— 用它触发回退，而不是误判安静。
  DateTime? _uplinkZeroSince;

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
  int _aecFrames = 0;
  int _aecStarved = 0;
  int _aecBytesIn = 0;
  int _aecBytesOut = 0;
  // 高频旁路是否真的生效（由 worker 的 init-over 回报，旧 native 库会为 false）
  bool _highBandBypass = false;
  // 下行相关门（成品彻底无回声）是否开启
  bool _residualGate = false;
  // 采集侧啸叫陷波是否在岗（worker 回报）
  bool _howlNotch = false;
  // 采集侧底噪门是否在岗
  bool _noiseGate = false;
  // 上行 AGC 是否在岗（默认关：它会把啸叫托在稳态）
  bool _upstreamAgc = false;
  // worker 是否已完成初始化（未初始化时下面几行显示的是初始值，
  // 直接写「关」会让人误以为被编译期关掉了 —— 真机问过一次）
  bool _audioInited = false;
  // 相关门自搜出来的回声延迟与当帧读数（诊断：lag 不合理就说明这层没工作）
  int _gateLagMs = -1;
  double _gateRho = 0;
  double _noiseFloorDb = -90;
  // 当前真正在挖的陷波频点
  List<double> _notchHz = const <double>[];
  // 检测器下发给 worker 的频点集合（去重、带淘汰）
  final List<double> _notchTargets = <double>[];
  Timer? _notchTimer;

  // ---------- 采集侧闭环增益守卫 ----------
  // 喂的是 AEC **之前**的原始采集；duck 系数由播放器在 _doFeed 里读取。
  final LoopGainGuard _guard = LoopGainGuard();
  int _lastTriggerCount = 0;

  // 播放侧陷波：与采集侧陷波同频点。环路「本端麦→上行→对方外放→对方麦」
  // 每一端各挖一次，一圈 44dB，比单端挖更快熄振。
  final HowlNotch _playNotch = HowlNotch();

  // ---------- 参考延迟：运行时可调 + 一键标定 ----------
  int _refDelayMs = kRefDelayMs;
  static const List<int> kRefDelayOptions = [0, 100, 150, 200, 250, 300];
  bool _calibActive = false;
  bool _calibBusy = false;
  final BytesBuilder _calibCap = BytesBuilder();
  DateTime? _calibStartAt;
  DelayEstimate? _calibResult;

  // ---------- 参考信号延迟队列 ----------
  // 播放侧交来的字节先压 _refDelayMs 再喂 AEC（详见 kRefDelayMs 注释）。
  // 按 10ms 小块排队，让到达时刻精确到 AEC 自己的帧长，避免整块 100ms
  // 一起到期导致块内对齐误差最大 100ms。
  final List<MapEntry<int, Uint8List>> _refQ = <MapEntry<int, Uint8List>>[];
  final Stopwatch _refClock = Stopwatch();
  Timer? _refTimer;

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
    _calibActive = false;
    _stopRefPump();
    _stopNotchDetector();
    _statusSub?.cancel();
    _textSub?.cancel();
    _binarySub?.cancel();
    _micSub?.cancel();
    _uplinkSub?.cancel();
    _uplinkBuf.clear();
    _uplinkEncoder?.dispose();
    _recorder.dispose();
    _uplinkRecorder.dispose();
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
          // 系统 3A 上行流在岗时，上行由那条流直接编码（见 _onUplinkChunk），
          // worker 这份丢弃；回退后自动恢复转发。
          if (_sysUplinkActive) break;
          // 标定期间本端在放 PN 序列，别把它发给对端（对方会听到一段噪声）
          if (_socketStatus == RoomSocketStatus.connected && !_calibActive) {
            _socket.sendBinaryMessage(message['data']);
          }
          break;
        case 'aec-unavailable':
          _log('⚠️ AEC3 句柄创建失败，本次直通');
          break;
        case 'init-over':
          if (!mounted) return;
          setState(() {
            _highBandBypass = message['highBandBypass'] == true;
            _residualGate = message['residualGate'] == true;
            _howlNotch = message['howlNotch'] == true;
            _noiseGate = message['noiseGate'] == true;
            _upstreamAgc = message['upstreamAgc'] == true;
            _audioInited = true;
          });
          break;
        case 'howl_notch_ack':
          if (!mounted) return;
          final List<dynamic> act = (message['active'] as List<dynamic>?) ?? const [];
          setState(() {
            _notchHz = act.map((e) => (e as num).toDouble()).toList();
          });
          break;
        case 'aec_stats':
          if (!mounted) return;
          setState(() {
            _inDbfs = (message['inDbfs'] as num?)?.toDouble() ?? -90;
            _outDbfs = (message['outDbfs'] as num?)?.toDouble() ?? -90;
            _aecFrames = (message['frames'] as num?)?.toInt() ?? 0;
            _aecStarved = (message['starved'] as num?)?.toInt() ?? 0;
            _aecBytesIn = (message['bytesIn'] as num?)?.toInt() ?? 0;
            _aecBytesOut = (message['bytesOut'] as num?)?.toInt() ?? 0;
            _gateLagMs = (message['gateLagMs'] as num?)?.toInt() ?? -1;
            _gateRho = (message['gateRho'] as num?)?.toDouble() ?? 0;
            _noiseFloorDb = (message['noiseFloor'] as num?)?.toDouble() ?? -90;
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

  /// 播放侧回调：把「即将送给扬声器的同一份字节」压 kRefDelayMs 后再交给 AEC。
  ///
  /// 直接转发（delay=0）会让参考比回声早 350ms，AEC 完全失效 —— 这是实测里
  /// 「成品还带着对方声音」的唯一原因。
  void _forwardReference(Uint8List pcm) {
    final port = _workerSendPort;
    if (port == null || _isWorkerClosed || pcm.isEmpty) return;
    // 标定信号不喂 AEC：它的目的是让回声**原样**留在采集里做互相关，
    // 一旦被 AEC 消掉，延迟峰就测不出来了。
    if (_calibActive) return;

    if (_refDelayMs <= 0) {
      port.send({'type': 'ref_chunk', 'data': pcm});
      return;
    }
    // 泵已停（结束导出 / 还没开始）：不再排队，否则队列只增不发白占内存
    if (!_refClock.isRunning) return;

    const int frameBytes = kSampleRateRecorder ~/ 100 * 2; // 10ms 一块
    final int base = _refClock.elapsedMilliseconds + _refDelayMs;
    int lastDue = _refQ.isEmpty ? 0 : _refQ.last.key;
    for (int off = 0; off < pcm.length; off += frameBytes) {
      final int end = math.min(off + frameBytes, pcm.length);
      // 块内偏移也要算进到期时刻，否则整块 100ms 同时到期
      final int offMs = (off ~/ 2) * 1000 ~/ kSampleRateRecorder;
      int due = base + offMs;
      // 严格保序：SendPort 是 FIFO，AEC 侧也是按帧顺序取用，
      // 一旦乱序就会永久错位（AEC 不会自己纠正队列顺序）。
      if (due <= lastDue) due = lastDue + 1;
      lastDue = due;
      _refQ.add(MapEntry(due, Uint8List.sublistView(pcm, off, end)));
    }
  }

  /// 启动参考信号泵。必须在播放器建好**之前**调用 ——
  /// `_forwardReference` 用 `_refClock` 打时间戳，时钟要先跑起来。
  void _startRefPump() {
    _stopRefPump();
    _refClock
      ..reset()
      ..start();
    if (_refDelayMs <= 0) return;
    _refTimer = Timer.periodic(const Duration(milliseconds: 5), (_) {
      final port = _workerSendPort;
      if (port == null) return;
      final int now = _refClock.elapsedMilliseconds;
      while (_refQ.isNotEmpty && now >= _refQ.first.key) {
        port.send({'type': 'ref_chunk', 'data': _refQ.removeAt(0).value});
      }
    });
  }

  void _stopRefPump() {
    _refTimer?.cancel();
    _refTimer = null;
    _refClock.stop();
    _refQ.clear();
  }

  // =====================================================================
  // 采集侧啸叫陷波：检测器 → worker
  // =====================================================================

  /// 检测器只做一件事：把守卫的「啸叫投票」结果收集成一组陷波目标。
  ///
  /// 判据（全部来自 [LoopGainGuard] 已有的读数，不新增 FFT）：
  /// - 最近 500ms 啸叫投票占比 >= [voteGate]（投票容忍间歇 bursts 与跳频，
  ///   真机第四版录音里啸叫被对话调制成间歇窄带，旧的「单频点连续 750ms」
  ///   判据在 1.9↔2.2kHz 跳频下永远攒不够计数，25s 才锁上一次）；
  /// - 峰频落在 [notchMinHz] ~ [notchMaxHz]（**下限 1200Hz 是硬约束**：
  ///   人声基频 80~400Hz、低次谐波 400~1200Hz 全在下面，挖了就是把人说话
  ///   挖空；实测啸叫在 1.5~3.8kHz）；
  /// - 采集电平 > -35dBFS：静音期的残余回声（-44dBFS）不配锁频，
  ///   旧版曾在安静段把 1406Hz 残响锁成啸叫；
  /// - 同一频点 ±[mergeHz] 内不重复挖，最多同时挖 3 个；
  /// - 6 秒没再被确认的频点自动淘汰（worker 侧会平滑淡出，不会咔嗒）。
  /// 锁定的频点同时下发给**采集侧与播放侧**两个陷波器：环路是
  /// 「A 麦→上行→B 外放→B 麦」，两端各挖 22dB，一圈 44dB，振荡必熄。
  static const double voteGate = 0.25;
  static const double mergeHz = 120.0;
  static const int maxTargets = 3;
  static const int staleMs = 6000;
  static const double notchMinHz = 1200.0;
  static const double notchMaxHz = 6000.0;

  void _startNotchDetector() {
    _stopNotchDetector();
    if (!_howlNotch) return; // worker 没开这一层就没必要发
    _notchTimer = Timer.periodic(const Duration(milliseconds: 250), (_) {
      if (!mounted || _phase != _Phase.live) return;
      final double hz = _guard.lastPeakHz;
      final bool inBand = hz >= notchMinHz && hz <= notchMaxHz;
      final bool howly =
          _guard.howlVoteRatio >= voteGate && _guard.captureDbfs > -35;
      if (inBand && howly) _rememberNotch(hz);
      _expireNotch();
      _playNotch.setTargets(List<double>.from(_notchTargets));
      _workerSendPort?.send({
        'type': 'howl_notch',
        'hz': List<double>.from(_notchTargets),
      });
    });
  }

  final Map<double, int> _notchSeen = <double, int>{};

  void _rememberNotch(double hz) {
    final int now = DateTime.now().millisecondsSinceEpoch;
    for (final double k in _notchSeen.keys.toList()) {
      if ((k - hz).abs() <= mergeHz) {
        // 同一频点小幅漂移：跟到新值，陷波器内部会平滑过渡
        _notchSeen.remove(k);
        _notchSeen[hz] = now;
        return;
      }
    }
    _notchSeen[hz] = now;
    if (_notchSeen.length > maxTargets) {
      // 淘汰最久没被确认的那个（啸叫频率会跳，只留最近出现的）
      final keys = _notchSeen.keys.toList()
        ..sort((a, b) => _notchSeen[a]!.compareTo(_notchSeen[b]!));
      _notchSeen.remove(keys.first);
    }
    _log('🔪 陷波锁定 ${hz.toStringAsFixed(0)}Hz（可选 '
        '${_notchSeen.keys.map((e) => e.toStringAsFixed(0)).join("/")}）');
  }

  void _expireNotch() {
    final int now = DateTime.now().millisecondsSinceEpoch;
    _notchSeen.removeWhere((_, t) => now - t > staleMs);
    final List<double> next = _notchSeen.keys.toList()..sort();
    if (next.length != _notchTargets.length ||
        !Iterable<int>.generate(next.length)
            .every((i) => (next[i] - _notchTargets[i]).abs() < 1)) {
      _notchTargets
        ..clear()
        ..addAll(next);
    }
  }

  void _stopNotchDetector() {
    _notchTimer?.cancel();
    _notchTimer = null;
    _notchSeen.clear();
    _notchTargets.clear();
    _playNotch.reset();
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
      _aecFrames = 0;
      _audioInited = false;
      _aecStarved = 0;
      _aecBytesIn = 0;
      _aecBytesOut = 0;
      _lastTriggerCount = 0;
      _logs.clear();
    });
    _guard.reset();
    _log('开始：room=${_roomCtrl.text.trim()} user=$_userId');
    _log('参考补偿 $_refDelayMs ms（默认 $kRefDelayMs；页面上可实时改，或点「标定延迟」实测）');

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
      // 参考信号泵一定要在建播放器之前起：播放第一块就会回调 _forwardReference，
      // 那时 _refClock 必须已经在走，否则整条时间轴从负数起步。
      _startRefPump();
      _playbackManager = AudioPlaybackManager(
        sampleRate: kSampleRateRecorder,
        channelCount: kChannels,
        decoder: _decoder,
        baseVolume: kPlayGainPct / 100.0,
        guard: _guard,
        notch: _playNotch,
        onPlaybackReference: _forwardReference,
      );
      await _playbackManager!.init();
      await _activateAudioSession();

      // 采集前确保上一轮真的停了（否则 iOS 会拿到一条永不产出 buffer 的流）
      if (await _recorder.isRecording()) {
        await _recorder.stop();
        await Future<void>.delayed(const Duration(milliseconds: 150));
      }
      // 采集设备：默认 **不指定**，让 record 走 Android 的 DEFAULT 通路。
      //
      // 实测（PMA120）指定内置麦（内部会 setPreferredDevice）之后，playAndRecord
      // 下的这条输入通路被系统按「通话」处理：带宽硬截到 16k（16k 以上恒为
      // 数字零），并且 2k 以上的语音被压掉 30~40dB，成品听感发闷、缺齿音。
      // 对照实验：e2e 自测页不指定 device，同一台机器能录到 22k 的完整带宽。
      // 需要复核这个结论时加 --dart-define=PIN_MIC=true 恢复旧行为。
      // 注意必须用 String.fromEnvironment：bool.fromEnvironment 只认字面量
      // true/false，读不到 --dart-define 传进来的字符串，开关会静默失效。
      const bool pinMic = String.fromEnvironment('PIN_MIC') == 'true';
      final mic = pinMic
          ? await DualUtil.findBuiltInMicNew(
              recorder: _recorder,
              audioSession: _audioSession,
            )
          : null;
      // iOS 只允许一条采集流：默认裸麦（成品要 20kHz 带宽 + 自然噪底）。
      // 仅显式 SYS_3A=true 时才在这条流上启用 VPIO 做 A/B 对照 ——
      // record 插件把 echoCancel=true 映射成 inputNode.setVoiceProcessingEnabled。
      // 真机实测 VPIO 双输：成品带宽被限到 <16kHz、静音段压成数字零，
      // 且它的 AEC 参考不到 FlutterPcmSound 的渲染流，回声照样漏进成品。
      final bool ios3A = kSys3A && Platform.isIOS;
      final stream = await _recorder.startStream(
        RecordConfig(
          encoder: AudioEncoder.pcm16bits,
          sampleRate: kSampleRateRecorder,
          numChannels: kChannels,
          device: mic,
          // TRTC 式全频带：明确走物理麦克风 + MODE_NORMAL，且关闭系统 3A。
          // 一旦让系统按「通话/语音识别」通路处理输入，Android 会把带宽
          // 限到 16kHz 并叠加系统 AEC/AGC —— 那正是我们要用 AEC3 自己做的事。
          androidConfig: const AndroidRecordConfig(
            audioSource: AndroidAudioSource.mic,
            audioManagerMode: AudioManagerMode.modeNormal,
          ),
          autoGain: ios3A,
          echoCancel: ios3A,
          noiseSuppress: ios3A,
        ),
      );
      _micSub = stream.listen(
        _onMicChunk,
        onError: (Object e) {
          _log('❌ 采集流错误: $e');
        },
      );
      if (ios3A) {
        _log('🛡️ iOS 系统 3A（VPIO）已开：采集先经系统 AEC/NS/AGC');
      }

      // Android：默认单流（成品+上行共用裸麦 48k）。双流仅在显式打开
      // SYS_3A_DUAL 时启用 —— PMA120 上并发采集会把成品流抢占停摆，见 kAndroidDualStream。
      if (kSys3A && Platform.isAndroid && kAndroidDualStream) {
        await _startSysUplink();
      }

      // 进房（地址里带不带端口都行，RoomSocketManager 直接透传）
      final url = _urlCtrl.text.trim();
      _log('连接 $url …');
      final ok = await _socket.connect(url);
      if (!ok) _log('⚠️ 连接未成功，先本地录音，网络恢复后会自动重连');

      // 一次进房 = 一个成品文件：从这一刻开始写，直到点「结束」
      await _beginRecordFile();

      if (!mounted) return;
      setState(() => _phase = _Phase.live);
      _startNotchDetector();
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

    // 采集侧闭环守卫：必须吃 **AEC 之前**的原始字节。啸叫是声学闭环在
    // 麦克风侧产生的，AEC 之后已被滤波器污染；上一版挂在下行侧更是看错了信号。
    _guard.feedCaptureBytes(chunk);

    // 延迟标定：只收开头 3.1s 的原始采集（回声要保留，不能取 AEC 后的成品）
    if (_calibActive) {
      final int ms = DateTime.now().difference(_calibStartAt!).inMilliseconds;
      if (ms <= 3100) _calibCap.add(chunk);
    }

    final port = _workerSendPort;
    if (port == null || _isWorkerClosed) return;
    port.send({
      'type': 'pcm_chunk',
      'data': chunk,
      'isWriteRecordFile': true,
      'captureTime': DateTime.now().millisecondsSinceEpoch,
    });
  }

  // =====================================================================
  // 系统 3A 上行流（Android 双流方案，参考 TRTC 通话档）
  // =====================================================================

  /// 开第二条采集流：16k + VOICE_COMMUNICATION + 系统 AEC/NS/AGC。
  ///
  /// 为什么不动 AudioManager 全局模式（保持 modeNormal）：
  /// MODE_IN_COMMUNICATION 会改整机路由/音量策略，可能把第一条裸麦流和
  /// flutter_pcm_sound 的播放一起带偏（听筒路由/音量骤降）。TRTC 敢设是因为
  /// 它独占整条音频管线；我们是混合管线，只用「采集源 + 效果器」这一层，
  /// AcousticEchoCanceler 挂在采集会话上即可生效，不依赖全局模式。
  Future<void> _startSysUplink() async {
    try {
      final stream = await _uplinkRecorder.startStream(
        RecordConfig(
          encoder: AudioEncoder.pcm16bits,
          sampleRate: kSampleRateUplink,
          numChannels: 1,
          androidConfig: const AndroidRecordConfig(
            audioSource: AndroidAudioSource.voiceCommunication,
            audioManagerMode: AudioManagerMode.modeNormal,
          ),
          echoCancel: true,
          noiseSuppress: true,
          autoGain: true,
        ),
      );
      _uplinkEncoder?.dispose();
      _uplinkEncoder = OpusEncoder(
        sampleRate: kSampleRateUplink,
        channels: Channels.mono,
        application: Application.voip,
      );
      _uplinkBuf.clear();
      _uplinkZeroSince = null;
      _uplinkLastDataAt = DateTime.now();
      _sysUplinkActive = true;
      _uplinkSub = stream.listen(
        _onUplinkChunk,
        onError: (Object e) {
          _log('❌ 系统3A上行流错误: $e');
          _fallbackSysUplink('流错误');
        },
      );
      _log('🛡️ 系统3A上行已开（VOICE_COMMUNICATION + AEC/NS/AGC，16k）');
    } catch (e) {
      _log('⚠️ 系统3A上行流启动失败，回退 worker 上行: $e');
      _sysUplinkActive = false;
    }
  }

  /// 上行流数据：攒满 20ms（16k×320 样本）就编码发包。
  /// 同时做「通路死亡」检测：连续 3s 纯数字零 → 回退。
  void _onUplinkChunk(Uint8List chunk) {
    if (!_sysUplinkActive || chunk.isEmpty) return;
    final now = DateTime.now();
    _uplinkLastDataAt = now;

    // 全零检测：真麦有环境底噪，NS 之后也不会是纯零；纯零 = 通路被抢占
    bool allZero = true;
    for (int i = 0; i < chunk.length; i++) {
      if (chunk[i] != 0) {
        allZero = false;
        break;
      }
    }
    if (allZero) {
      _uplinkZeroSince ??= now;
      if (now.difference(_uplinkZeroSince!).inMilliseconds >= 3000) {
        _fallbackSysUplink('连续 3s 全零（采集通路疑似被系统抢占）');
        return;
      }
    } else {
      _uplinkZeroSince = null;
    }

    // 标定期间不上行（与 worker 上行同规则）
    if (_calibActive) return;
    if (_socketStatus != RoomSocketStatus.connected) return;

    _uplinkBuf.add(chunk);
    const int frameBytes = 320 * 2; // 16k 下 20ms
    while (_uplinkBuf.length >= frameBytes) {
      final all = _uplinkBuf.takeBytes();
      final frame = Uint8List.sublistView(all, 0, frameBytes);
      if (all.length > frameBytes) {
        _uplinkBuf.add(Uint8List.sublistView(all, frameBytes));
      }
      final enc = _uplinkEncoder;
      if (enc == null) return;
      try {
        final pcm = Int16List.view(frame.buffer, frame.offsetInBytes, 320);
        final pkt = enc.encode(pcm, inputSize: 320);
        _socket.sendBinaryMessage(pkt);
      } catch (e) {
        _log('❌ 系统3A上行编码失败: $e');
        _fallbackSysUplink('编码失败');
        return;
      }
    }
  }

  /// 回退：关掉第二条流，恢复转发 worker 的 opus 包（worker 一直在编码，
  /// 只是被 _sysUplinkActive 挡着没发，回退即刻生效，无断档）。
  void _fallbackSysUplink(String reason) {
    if (!_sysUplinkActive) return;
    _sysUplinkActive = false;
    _log('⚠️ 系统3A上行回退（$reason），改用 AEC3+底噪门上行');
    _stopSysUplink();
  }

  Future<void> _stopSysUplink() async {
    _sysUplinkActive = false;
    await _uplinkSub?.cancel();
    _uplinkSub = null;
    _uplinkBuf.clear();
    _uplinkEncoder?.dispose();
    _uplinkEncoder = null;
    try {
      if (await _uplinkRecorder.isRecording()) {
        await _uplinkRecorder.stop();
      }
    } catch (_) {}
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
      // 诊断轨道：AEC 之前的原始采集（KEEP_RAW=true 才有）
      'rawFilePath':
          kKeepRaw ? path.replaceAll(RegExp(r'\.pcm$'), '_raw.pcm') : null,
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
    if (_calibBusy) {
      _toast('标定进行中，请等 3 秒完成再结束');
      return;
    }
    setState(() => _phase = _Phase.stopping);
    _log('结束中…');

    // 1. 先断采集，再关文件：否则关文件之后还会有一两块写进来
    _calibActive = false;
    await _micSub?.cancel();
    _micSub = null;
    await _stopSysUplink();
    _stopRefPump();
    _stopNotchDetector();
    _log('AEC 汇总: 帧=$_aecFrames 缺参考=$_aecStarved '
        '样本 ${_aecBytesIn ~/ 2}→${_aecBytesOut ~/ 2}（差 '
        '${(_aecBytesIn - _aecBytesOut) ~/ 2} 样本，应 < 480）');
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

  /// 清空本 App 自己的录音目录里所有 `handsfree_*` 成品（pcm / wav / _raw.pcm）。
  ///
  /// 只扫应用文档目录的第一层，只删本页产出的命名前缀，不碰别的东西；
  /// 删除不可恢复，所以先列数量+体积让用户确认。
  Future<void> _deleteAllFiles() async {
    if (_phase == _Phase.live || _busy) {
      _toast('正在对讲，先结束再删除');
      return;
    }

    final List<File> files;
    try {
      final dir = await getApplicationDocumentsDirectory();
      if (!dir.existsSync()) {
        _toast('没有可删除的文件');
        return;
      }
      files = dir
          .listSync(followLinks: false)
          .whereType<File>()
          .where((f) {
            final name = f.uri.pathSegments.last;
            return (name.startsWith('handsfree_') ||
                    name.startsWith('calib_')) &&
                (name.endsWith('.pcm') || name.endsWith('.wav'));
          })
          .toList()
        ..sort((a, b) => a.path.compareTo(b.path));
    } catch (e) {
      _log('❌ 扫描文件失败: $e');
      _toast('扫描文件失败');
      return;
    }

    if (files.isEmpty) {
      _toast('没有可删除的文件');
      return;
    }

    int totalBytes = 0;
    for (final f in files) {
      try {
        totalBytes += f.lengthSync();
      } catch (_) {}
    }
    final sizeMb = totalBytes / 1024 / 1024;

    if (!mounted) return;
    final bool? ok = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('删除所有录音文件？'),
        content: Text(
          '将要删除 ${files.length} 个文件，共 ${sizeMb.toStringAsFixed(1)} MB，'
          '包含已导出的 wav。此操作不可恢复。',
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(ctx, false),
            child: const Text('取消'),
          ),
          TextButton(
            style: TextButton.styleFrom(
              foregroundColor: Theme.of(ctx).colorScheme.error,
            ),
            onPressed: () => Navigator.pop(ctx, true),
            child: const Text('全部删除'),
          ),
        ],
      ),
    );
    if (ok != true) return;

    int deleted = 0;
    final List<String> failed = [];
    for (final f in files) {
      try {
        await f.delete();
        deleted++;
      } catch (_) {
        failed.add(f.uri.pathSegments.last);
      }
    }

    if (!mounted) return;
    setState(() {
      _wavPath = '';
      _pcmPath = null;
      _pcmBytes = 0;
    });
    _log('🧹 已删除 $deleted 个文件（${sizeMb.toStringAsFixed(1)} MB）'
        '${failed.isEmpty ? '' : '，失败 ${failed.length} 个'}');
    _toast(failed.isEmpty ? '已删除 $deleted 个文件' : '删除 $deleted 个，${failed.length} 个失败');
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
          // SYS_3A：iOS 走 voiceChat（= TRTC 通话档，系统 VPIO 做 AEC/NS/AGC）。
          // defaultMode 是裸麦，回声/啸叫全靠自己那套 AEC3，实测压不住网络环路。
          avAudioSessionMode: (kSys3A && Platform.isIOS)
              ? AVAudioSessionMode.voiceChat
              : AVAudioSessionMode.defaultMode,
          avAudioSessionRouteSharingPolicy:
              AVAudioSessionRouteSharingPolicy.defaultPolicy,
          avAudioSessionSetActiveOptions: AVAudioSessionSetActiveOptions.none,
          androidAudioAttributes: const AndroidAudioAttributes(
            // music 而不是 speech：speech 会让部分 ROM 把整条输入通路切到
            // 「通话」档（16kHz 带宽 + 系统 3A），把 20kHz 的齿音/空气感砍掉。
            contentType: AndroidAudioContentType.music,
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

  /// 一键测真机回声延迟（替代靠编译期常量猜 iOS 的 100ms）。
  ///
  /// 播放 2s 已知 PN 序列，同时收 3.1s **AEC 前**的原始采集，用 FFT 互相关
  /// 找峰 —— 峰位置就是「送进播放器 → 扬声器 → 空气 → 麦克风」的端到端延迟。
  /// 标定期间：不喂 AEC 参考（否则回声被消掉，测不到峰）、不上行（对端不吵）。
  Future<void> _runCalibration() async {
    if (_calibBusy) {
      _toast('标定进行中');
      return;
    }
    if (_phase != _Phase.live) {
      _toast('先加入房间再标定');
      return;
    }
    setState(() => _calibBusy = true);
    _log('🔬 标定开始：播放 2s PN 序列，请保持安静、暂时别说话');
    try {
      final dir = await getApplicationDocumentsDirectory();
      final Uint8List ref = buildCalibSignal();
      _calibCap.clear();
      _calibStartAt = DateTime.now();
      _calibActive = true;
      await File('${dir.path}/calib_ref.pcm').writeAsBytes(ref);

      // 一次性塞进播放缓冲：_tryFillNativeAnchor 按 100ms 水位逐步喂出，
      // 参考与采集两条时间轴速率都是 48k，互相关峰不会被展宽。
      _playbackManager?.handleRawPcm(ref);

      await Future<void>.delayed(const Duration(milliseconds: 3300));
      _calibActive = false;
      final Uint8List cap = _calibCap.takeBytes();
      await File('${dir.path}/calib_cap.pcm').writeAsBytes(cap);
      _log('🔬 采集 ${(cap.length / 1024).toStringAsFixed(0)}KB，计算互相关…');
      // 标定这 3 秒 AEC 一直缺参考，重置一下让它重新收敛，别污染后续成品
      _workerSendPort?.send({'type': 'aec_reset'});
      final DelayEstimate? est = await estimateDelay(ref, cap);
      if (!mounted) return;
      setState(() {
        _calibResult = est;
        _calibBusy = false;
      });
      if (est == null) {
        _log('🔬 ❌ 标定失败：采集数据太短');
      } else if (!est.reliable) {
        _log('🔬 ⚠️ 置信度低 $est（峰不够尖；环境太吵或系统音量太小）');
      } else {
        _log('🔬 ✅ 实测端到端 ${est.lagMs.toStringAsFixed(1)}ms，'
            '相关 ${est.correlation.toStringAsFixed(3)}，'
            '建议参考补偿 ${est.suggestedRefDelayMs}ms');
        _log('   把「参考补偿」调到 ${est.suggestedRefDelayMs}ms 后重录一段验证');
      }
    } catch (e) {
      _calibActive = false;
      if (mounted) setState(() => _calibBusy = false);
      _log('🔬 ❌ 标定异常: $e');
    }
  }

  void _tick() {
    if (!mounted) return;
    // 守卫触发只在日志里报一次（duck 有 3s + 1s 冷却，一秒轮询足够捕获）
    if (_guard.triggerCount != _lastTriggerCount) {
      _lastTriggerCount = _guard.triggerCount;
      _log('🔥 采集侧守卫触发（${_guard.lastReason}），'
          '播放增益压到 ${(LoopGainGuard.duckLevel * 100).round()}% 后 3s 恢复');
    }
    if (_phase == _Phase.live && _workerSendPort != null) {
      _workerSendPort!.send({'type': 'aec_stats'});
    }
    // 系统3A上行流断供检测：3s 没有任何数据 → 回退（与全零检测互补）
    if (_sysUplinkActive && _uplinkLastDataAt != null) {
      if (DateTime.now().difference(_uplinkLastDataAt!).inMilliseconds >= 3000) {
        _fallbackSysUplink('3s 无数据');
      }
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
              tooltip: '删除所有录音文件',
              onPressed: _busy ? null : _deleteAllFiles,
              icon: const Icon(Icons.delete_sweep_outlined),
            ),
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
          '前 1~2 秒是 AEC 收敛期，导出时保留原样。\n'
          '成品是 48kHz 全频带（高频旁路已开，可到 20kHz）；对讲上行仍按房间协议'
          '走 16k opus，所以「对方听到的」只有 8kHz 带宽，这是协议限制，不是录音问题。\n'
          '外放音量越大，麦克风拾到的回声越强，AEC 能压掉的比例是固定的 —— '
          '想听感更干净就把系统音量调小一档。\n'
          '采集侧守卫已开：检测到窄带起振或环路增益持续上升，会自动把播放增益'
          '临时压到 25% 打断啸叫，3 秒后恢复。\n'
          '首次在某一端跑前，先点「标定延迟」实测这台机器的回声延迟，'
          '再把「参考补偿」调到建议值；两端各自标定一次。',
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
              const SizedBox(height: 6),
              Row(
                children: [
                  const Text('参考补偿'),
                  const SizedBox(width: 12),
                  DropdownButton<int>(
                    value: _refDelayMs,
                    isDense: true,
                    items: [
                      for (final v
                          in ({...kRefDelayOptions, _refDelayMs}.toList()..sort()))
                        DropdownMenuItem<int>(
                          value: v,
                          child: Text(v == 0 ? '0（关）' : '${v}ms'),
                        ),
                    ],
                    onChanged: (int? v) {
                      if (v == null || v == _refDelayMs) return;
                      final int old = _refDelayMs;
                      setState(() => _refDelayMs = v);
                      _log('⚙️ 参考补偿 $old → ${v}ms'
                          '${_phase == _Phase.live ? '（对讲中平滑过渡：新值只作用于新入队的块）' : ''}');
                    },
                  ),
                  const Spacer(),
                  if (_calibResult != null)
                    Text(
                      '建议 ${_calibResult!.suggestedRefDelayMs}ms',
                      style: TextStyle(fontSize: 12, color: cs.primary),
                    ),
                ],
              ),
              if (_calibResult != null)
                Padding(
                  padding: const EdgeInsets.only(top: 2),
                  child: Text(
                    '实测端到端 ${_calibResult!.lagMs.toStringAsFixed(1)}ms · '
                    '相关 ${_calibResult!.correlation.toStringAsFixed(3)} · '
                    '${_calibResult!.reliable ? '结果可用' : '置信度低，仅供试扫'}',
                    style: const TextStyle(fontSize: 11, color: Colors.grey),
                  ),
                ),
              const SizedBox(height: 8),
              SizedBox(
                width: double.infinity,
                child: OutlinedButton.icon(
                  onPressed:
                      (_phase == _Phase.live && !_calibBusy) ? _runCalibration : null,
                  icon: _calibBusy
                      ? const SizedBox(
                          width: 15,
                          height: 15,
                          child: CircularProgressIndicator(strokeWidth: 2),
                        )
                      : const Icon(Icons.graphic_eq, size: 18),
                  label: Text(
                    _calibBusy ? '标定中…（3 秒，请保持安静）' : '标定延迟（实测真机回声延迟）',
                    style: const TextStyle(fontSize: 13),
                  ),
                ),
              ),
              const Padding(
                padding: EdgeInsets.only(top: 4),
                child: Text(
                  '进房后可点：播放 2 秒轻微噪声，这 3 秒不发给对方、不喂 AEC，'
                  '用互相关算出真实延迟并给出建议补偿值。',
                  style: TextStyle(fontSize: 11, color: Colors.grey),
                ),
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
            _row('AEC 帧', _aecFrames == 0 ? '—' : '$_aecFrames（缺参考 $_aecStarved）'),
            _row(
              '参考补偿',
              '$_refDelayMs ms',
              ok: _refDelayMs > 0,
            ),
            _row(
              '高频旁路',
              !_audioInited
                  ? '— 待开录'
                  : (_highBandBypass ? '开 · 成品可达 20kHz' : '关 · 旧行为'),
              ok: _audioInited && _highBandBypass,
            ),
            _row(
              '残留门',
              !_audioInited
                  ? '— 待开录'
                  : !_residualGate
                  ? '关 · 仅 AEC3'
                  : (_gateLagMs < 0
                      ? '开 · 正在搜回声延迟'
                      : '开 · 对齐 $_gateLagMs ms（ρ=${_gateRho.toStringAsFixed(2)}）'),
              ok: _audioInited && _residualGate && _gateLagMs >= 0,
            ),
            _row(
              '啸叫陷波',
              !_audioInited
                  ? '— 待开录'
                  : !_howlNotch
                  ? '关'
                  : (_notchHz.isEmpty
                      ? '待命 · 未检出'
                      : '挖 ${_notchHz.map((e) => e.toStringAsFixed(0)).join('/')}Hz'),
              ok: _audioInited && _howlNotch,
            ),
            _row(
              '底噪门',
              !_audioInited
                  ? '— 待开录'
                  : (_noiseGate
                      ? '开 · 噪底 ${_noiseFloorDb.toStringAsFixed(0)}dBFS'
                      : '关'),
              ok: _audioInited && _noiseGate,
            ),
            _row(
              '系统3A上行',
              !kSys3A
                  ? '关 · 裸麦48k→AEC3+相关门 上行'
                  : Platform.isIOS
                      ? '开 · iOS VPIO 单流（成品会被限带宽）'
                      : (kAndroidDualStream
                          ? (_sysUplinkActive
                              ? '开 · VOICE_COMM 双流'
                              : '回退 · worker 上行')
                          : '单流 · 裸麦48k→AEC3 上行'),
              // 默认（SYS_3A=false）裸麦链路就是正确状态 → ok
              ok: !kSys3A ||
                  Platform.isIOS ||
                  !kAndroidDualStream ||
                  _sysUplinkActive,
            ),
            _row(
              '上行 AGC',
              _upstreamAgc ? '开 · 会把啸叫托在稳态' : '关 · 环路里不补增益',
              ok: !_upstreamAgc,
            ),
            const Divider(height: 18),
            _row(
              '啸叫守卫',
              _guard.isDucking
                  ? '压低中 · 已触发 $_lastTriggerCount 次'
                  : '运行中 · 已触发 $_lastTriggerCount 次',
              ok: !_guard.isDucking,
            ),
            _row(
              '播放增益',
              '${(kPlayGainPct * _guard.duckFactor).round()}%'
                  '${_guard.isDucking ? '（duck）' : ''}',
            ),
            _row(
              '环路增益',
              _guard.loopGainDb < -60
                  ? '—'
                  : '${_guard.loopGainDb.toStringAsFixed(1)} dB',
            ),
            _row(
              '窄带峰',
              _guard.lastPeakQDb < 0
                  ? '—'
                  : '${_guard.lastPeakHz.toStringAsFixed(0)}Hz '
                      'Q=${_guard.lastPeakQDb.toStringAsFixed(0)}dB',
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
                    tooltip: '复制路径',
                    onPressed: () => _copy(_wavPath),
                    icon: const Icon(Icons.copy),
                  ),
                  const SizedBox(width: 6),
                  IconButton.filledTonal(
                    tooltip: '删除所有录音文件',
                    onPressed: _busy ? null : _deleteAllFiles,
                    icon: const Icon(Icons.delete_sweep_outlined),
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
