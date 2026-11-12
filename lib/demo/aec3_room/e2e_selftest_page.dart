import 'dart:async';
import 'dart:io';
import 'dart:isolate';
import 'dart:math' as math;
import 'dart:typed_data';

import 'package:flutter/material.dart';
import 'package:opus_ffi/opus_ffi.dart';
import 'package:path_provider/path_provider.dart';
import 'package:record/record.dart';

import '../util/my_dual_resampler_rate.dart';
import 'audio_playback_manager.dart';
import 'audio_processing_worker.dart';

/// 真机端到端自测（**不需要人操作**，进页面自动跑）。
///
/// 它验证的是「无耳机外放」这条链路里唯一没法在桌面上验的部分：
/// 扬声器真正发出的声音 → 空气 → 麦克风 → AEC3 → .pcm 落盘。
///
/// 做法是同一份测试信号跑两遍：
///   ① AEC 开：信号既喂给扬声器、也作为参考信号喂给 AEC3
///   ② AEC 关：同样的信号、同样的音量，AEC3 直通
/// 两段 .pcm 在同一区间的 RMS 差就是**真实 ERLE**（不是合成信号的理论值）。
///
/// 每一次的时序都与对讲页严格一致：参考信号按 20ms 一批、贴着真实时钟推给
/// worker（和 opus 包到达节奏相同），采集流实时进 worker，AEC 之后才落盘。
/// 参考信号延迟补偿（ms）。编译期可调：
///   flutter run --dart-define=AEC3_E2E=true --dart-define=REF_DELAY_MS=250
///
/// 为什么要它：真机实测「送进播放器 → 扬声器出声 → 麦克风采到」的延迟是
/// **352ms**（互相关测的，抖动 <1ms）。AEC3 内部的 render buffer 只能覆盖
/// 约 200ms，超出之后延迟估计落到错误的峰，自适应滤波器永远对不齐 ——
/// 表现就是 ERLE 只有 8dB 左右、但残余明显不是噪声。
/// 把参考整体推迟 kRefDelayMs 再喂，表观延迟就变成 352-kRefDelayMs。
const int kRefDelayMs =
    int.fromEnvironment('REF_DELAY_MS', defaultValue: 250);

class Aec3E2ePage extends StatefulWidget {
  const Aec3E2ePage({super.key});

  @override
  State<Aec3E2ePage> createState() => _Aec3E2ePageState();
}

class _Aec3E2ePageState extends State<Aec3E2ePage> {
  final List<String> _lines = [];
  bool _running = false;
  bool _done = false;
  String? _dirPath;
  String _verdict = '';

  final ScrollController _scroll = ScrollController();

  @override
  void initState() {
    super.initState();
    // 首帧之后再跑，保证 UI 已经能把进度画出来
    WidgetsBinding.instance.addPostFrameCallback((_) {
      Future<void>.delayed(
        const Duration(milliseconds: 400),
        () => _runAll(),
      );
    });
  }

  @override
  void dispose() {
    _scroll.dispose();
    super.dispose();
  }

  void _log(String s) {
    // ignore: avoid_print
    print('[AEC3-E2E] $s');
    if (!mounted) return;
    setState(() => _lines.add(s));
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (_scroll.hasClients) {
        _scroll.jumpTo(_scroll.position.maxScrollExtent);
      }
    });
  }

  // ===================================================================
  // 主流程
  // ===================================================================

  Future<void> _runAll() async {
    if (_running) return;
    setState(() {
      _running = true;
      _lines.clear();
      _done = false;
      _verdict = '';
    });

    final Stopwatch all = Stopwatch()..start();
    final StringBuffer report = StringBuffer();
    void both(String s) {
      _log(s);
      report.writeln(s);
    }

    try {
      final dir = await getApplicationDocumentsDirectory();
      final base = Directory('${dir.path}/aec3_e2e');
      if (!base.existsSync()) base.createSync(recursive: true);
      _dirPath = base.path;
      both('设备: ${Platform.operatingSystem} ${Platform.version}');
      both('输出目录: ${base.path}');

      final signal = _buildTestSignal();
      both('参考延迟补偿: $kRefDelayMs ms（真机端到端延迟实测 352ms）');
      both('测试信号: ${(signal.length ~/ 2 / kSampleRateRecorder)}s '
          '对数扫频 200→3600Hz + 4Hz 音节包络, 48k/16bit/mono');

      // 扬声器音量必须够大，否则麦克风拾到的回声太弱，测不出 ERLE
      await _hintVolume();

      final runOn = await _runOnce(
        aecOn: true,
        signal: signal,
        pcmPath: '${base.path}/aec_on.pcm',
        onLine: both,
      );
      both('');
      final runOff = await _runOnce(
        aecOn: false,
        signal: signal,
        pcmPath: '${base.path}/aec_off.pcm',
        onLine: both,
      );
      both('');

      // ---------------- 统计 ----------------
      both('──────── 结果 ────────');
      final double echoOverFloor = runOff.dbFs - runOff.floorDb;
      final bool valid = echoOverFloor >= 8.0;
      final double erle = runOff.dbFs - runOn.dbFs;
      both('静音段 RMS（本底噪声，只采集不播放）');
      both('  AEC 关: ${runOff.floorDb.toStringAsFixed(1)} dBFS');
      both('  AEC 开: ${runOn.floorDb.toStringAsFixed(1)} dBFS');
      both('  回声比本底高 ${echoOverFloor.toStringAsFixed(1)} dB'
          '（≥8dB 才算测得准）');
      both('回声段 RMS（信号 1.0s 起，统计 7.0~10.9s，已跳过收敛期）');
      both('  AEC 关: ${runOff.dbFs.toStringAsFixed(1)} dBFS   '
          '（麦克风原始拾音）');
      both('  AEC 开: ${runOn.dbFs.toStringAsFixed(1)} dBFS   '
          '（AEC3 之后才落盘）');
      both('  ➜ 实测 ERLE = ${erle.toStringAsFixed(1)} dB');
      // 残余已经压到本底噪声时，实测 ERLE 是「测量的下限」，不是算法上限
      final bool bottomedOut = runOn.dbFs <= runOn.floorDb + 3.0;
      if (bottomedOut) {
        both('  ✅ 残余已落在本底噪声上（比本底高 '
            '${(runOn.dbFs - runOn.floorDb).toStringAsFixed(1)} dB）'
            '→ 真实抑制量 ≥ ${erle.toStringAsFixed(1)} dB，实测值只是下限');
      } else {
        both('  ⚠️ 残余比本底高 '
            '${(runOn.dbFs - runOn.floorDb).toStringAsFixed(1)} dB'
            '→ 还能再压，下面的 ERLE 就是真实值');
      }
      both('');
      both('AEC 内部统计: 处理 ${runOn.frames} 帧, '
          '缺参考 ${runOn.starved} 帧, '
          '样本 in/out = ${runOn.bytesIn}/${runOn.bytesOut}');
      both('  样本守恒: '
          '${runOn.bytesIn == runOn.bytesOut ? "✅ 严格相等" : "❌ 不等"}');

      // ---------------- opus 上行链路（桌面验不了，只有真机能验）----------
      both('');
      both('──────── 上行 opus（48k→16k→opus→decode, 16k）────────');
      final opusInfo = await _checkOpus(signal);
      both(opusInfo);

      // ---------------- 判定 ----------------
      both('');
      String verdict;
      if (!valid) {
        verdict = '⚠️ 无效：回声只比本底高 ${echoOverFloor.toStringAsFixed(1)} dB'
            '（${runOff.dbFs.toStringAsFixed(1)} vs '
            '${runOff.floorDb.toStringAsFixed(1)} dBFS），信噪比不够。'
            '把媒体音量调大一档再跑。';
      } else if (bottomedOut) {
        verdict = '✅ 通过：残余回声已压到本底噪声（${runOn.dbFs.toStringAsFixed(1)} '
            'dBFS vs 本底 ${runOn.floorDb.toStringAsFixed(1)} dBFS），'
            '实测 ERLE ${erle.toStringAsFixed(1)} dB 是下限；'
            '成品里听不到对方的声音';
      } else if (erle >= 20) {
        verdict = '✅ 通过：外放回声被压低 ${erle.toStringAsFixed(1)} dB'
            '（目标 ≥20dB）';
      } else if (erle >= 12) {
        verdict = '⚠️ 偏弱：只压低 ${erle.toStringAsFixed(1)} dB。'
            '检查是否开了系统「通话音效」/音量偏小，或手机壳挡住扬声器。';
      } else {
        verdict = '❌ 失败：只压低 ${erle.toStringAsFixed(1)} dB，AEC3 没起作用。';
      }
      both(verdict);
      both('说明: 静音段补零计 starved 属正常（那 1s 扬声器本来就没响）; '
          'AEC 收敛约需 0.5~1.5s，统计窗口已跳过。');
      both('总耗时: ${all.elapsed.inSeconds}s');
      _verdict = verdict;

      final rf = File('${base.path}/report.txt');
      await rf.writeAsString(report.toString());
      _log('📄 报告已写入 ${rf.path}');
      report.writeln('报告路径: ${rf.path}');
    } catch (e, st) {
      both('❌ 异常: $e');
      both(st.toString().split('\n').take(6).join('\n'));
      _verdict = '❌ 异常中断';
      if (_dirPath != null) {
        try {
          await File('$_dirPath/report.txt').writeAsString(report.toString());
        } catch (_) {}
      }
    } finally {
      if (mounted) {
        setState(() {
          _running = false;
          _done = true;
        });
      }
    }
  }

  // ===================================================================
  // 单次：采集 + 播放 + AEC + 落盘
  // ===================================================================

  Future<_RunStat> _runOnce({
    required bool aecOn,
    required Uint8List signal,
    required String pcmPath,
    required void Function(String) onLine,
  }) async {
    onLine('════ AEC ${aecOn ? "开" : "关"} ════');
    final File f = File(pcmPath);
    if (f.existsSync()) f.deleteSync();

    // ---- 1. worker ----
    final ReceivePort rp = ReceivePort();
    final Completer<void> ready = Completer<void>();
    final Completer<void> fileClosed = Completer<void>();
    final Completer<void> initOver = Completer<void>();
    SendPort? port;
    String? unavailable;
    int frames = 0;
    int starved = 0;
    int bytesIn = 0;
    int bytesOut = 0;

    final Isolate iso = await Isolate.spawn(
      audioProcessingWorker,
      rp.sendPort,
      debugName: 'aec3-e2e-worker',
    );
    rp.listen((Object? m) {
      if (m is SendPort) {
        port = m;
        if (!ready.isCompleted) ready.complete();
        return;
      }
      if (m is! Map) return;
      switch (m['type']) {
        case 'init-over':
          if (!initOver.isCompleted) initOver.complete();
          break;
        case 'aec-unavailable':
          unavailable = 'AEC3 原生库不可用';
          break;
        case 'file-closed':
          if (!fileClosed.isCompleted) fileClosed.complete();
          break;
        case 'aec_stats':
          frames = (m['frames'] as num?)?.toInt() ?? 0;
          starved = (m['starved'] as num?)?.toInt() ?? 0;
          bytesIn = (m['bytesIn'] as num?)?.toInt() ?? 0;
          bytesOut = (m['bytesOut'] as num?)?.toInt() ?? 0;
          break;
        case 'error':
          onLine('  worker: ${m['data']}');
          break;
      }
    });
    await ready.future.timeout(const Duration(seconds: 5));
    final SendPort w = port!;
    w.send({
      'type': 'init',
      'aecEnabled': aecOn,
      'filePath': pcmPath,
    });
    await initOver.future.timeout(const Duration(seconds: 5));
    if (unavailable != null) onLine('  ⚠️ $unavailable（本次为直通）');

    // ---- 2. 播放器（参考信号走 onPlaybackReference，与真实链路同一份字节）----
    // 参考延迟队列：播放侧交来的字节先压 kRefDelayMs 再喂 AEC，
    // 把「送进播放器 → 真的从扬声器出来」这段硬件延迟从表观延迟里扣掉。
    final List<MapEntry<int, Uint8List>> refQ = <MapEntry<int, Uint8List>>[];
    final Stopwatch refClock = Stopwatch()..start();
    Timer? refTimer;
    void pushRef(Uint8List pcm) {
      if (kRefDelayMs <= 0) {
        w.send({'type': 'ref_chunk', 'data': pcm});
        return;
      }
      refQ.add(MapEntry(refClock.elapsedMilliseconds + kRefDelayMs, pcm));
    }

    final AudioPlaybackManager player = AudioPlaybackManager(
      sampleRate: kSampleRateRecorder,
      channelCount: kChannels,
      decoder: null,
      onPlaybackReference: aecOn ? pushRef : null,
    );
    if (aecOn && kRefDelayMs > 0) {
      refTimer = Timer.periodic(const Duration(milliseconds: 5), (_) {
        while (refQ.isNotEmpty &&
            refClock.elapsedMilliseconds >= refQ.first.key) {
          w.send({'type': 'ref_chunk', 'data': refQ.removeAt(0).value});
        }
      });
    }
    await player.init();

    // ---- 3. 采集 ----
    final AudioRecorder rec = AudioRecorder();
    if (!await rec.hasPermission()) {
      throw StateError('没有麦克风权限');
    }
    bool writeFlag = false;
    int micBytes = 0;
    final Stream<Uint8List> stream = await rec.startStream(
      RecordConfig(
        encoder: AudioEncoder.pcm16bits,
        sampleRate: kSampleRateRecorder,
        numChannels: kChannels,
      ),
    );
    final StreamSubscription<Uint8List> sub = stream.listen(
      (Uint8List chunk) {
        if (chunk.isEmpty) return;
        micBytes += chunk.length;
        w.send({
          'type': 'pcm_chunk',
          'data': chunk,
          'isWriteRecordFile': writeFlag,
          'captureTime': DateTime.now().millisecondsSinceEpoch,
        });
      },
      onError: (Object e) => onLine('  采集错误: $e'),
    );

    // 采集引擎起流后要 ~300ms 才开始稳定出块
    await Future<void>.delayed(const Duration(milliseconds: 500));
    if (micBytes == 0) onLine('  ⚠️ 500ms 内没有麦克风数据');
    writeFlag = true;
    w.send({'type': 'isWriteRecordFile', 'isWriteRecordFile': true});
    // 先录 1s「只有本底噪声、扬声器不响」的段：没这个基准就分不清
    // 「AEC 没起作用」和「已经压到房间本底了」——真机上这两者数字一样。
    await Future<void>.delayed(const Duration(milliseconds: 1000));
    onLine('  🎙️ 已录 1s 静音（本底噪声基准）, 开始推测试信号');

    // ---- 4. 按绝对时间表推信号（20ms 一批 = opus 帧节奏）----
    const int chunkMs = 20;
    const int chunkSamples = kSampleRateRecorder * chunkMs ~/ 1000;
    const int chunkBytes = chunkSamples * 2;
    final int totalSamples = signal.length ~/ 2;
    final int totalChunks = totalSamples ~/ chunkSamples;

    final Stopwatch sw = Stopwatch()..start();
    int next = 0;
    final Completer<void> pushed = Completer<void>();
    final Timer timer = Timer.periodic(const Duration(milliseconds: 5), (Timer t) {
      while (next < totalChunks && sw.elapsedMilliseconds >= next * chunkMs) {
        final int off = next * chunkBytes;
        player.handleRawPcm(
          Uint8List.sublistView(signal, off, off + chunkBytes),
        );
        next++;
      }
      if (next >= totalChunks && !pushed.isCompleted) pushed.complete();
    });
    await pushed.future;
    timer.cancel();
    onLine('  🔊 信号推完 ${sw.elapsedMilliseconds}ms');

    // 尾巴：让最后几块播完、AEC 把残留处理掉
    await Future<void>.delayed(const Duration(milliseconds: 400));

    // ---- 5. 收尾 ----
    writeFlag = false;
    w.send({'type': 'isWriteRecordFile', 'isWriteRecordFile': false});
    await fileClosed.future.timeout(
      const Duration(seconds: 5),
      onTimeout: () => onLine('  ⚠️ 等 file-closed 超时'),
    );
    w.send({'type': 'aec_stats'});
    await Future<void>.delayed(const Duration(milliseconds: 200));

    refTimer?.cancel();
    await sub.cancel();
    await rec.stop();
    await rec.dispose();
    await player.dispose();
    w.send({'type': 'dispose'});
    await Future<void>.delayed(const Duration(milliseconds: 200));
    rp.close();
    iso.kill(priority: Isolate.immediate);

    // ---- 6. 统计 ----
    final Uint8List pcm = await f.readAsBytes();
    final double floorDb = _segmentRmsDb(pcm, 0.15, 0.95); // 静音段 = 本底
    final double dbFs = _segmentRmsDb(pcm, 7.0, 10.9); // 信号 1s 起 10s，取最后 4s
    onLine('  💾 ${pcmPath.split('/').last}  '
        '${(pcm.length / 1024).toStringAsFixed(1)}KB  '
        '时长≈${(pcm.length / 2 / kSampleRateRecorder).toStringAsFixed(2)}s');
    onLine('     本底 ${floorDb.toStringAsFixed(1)}dBFS, '
        '回声段 ${dbFs.toStringAsFixed(1)}dBFS');
    return _RunStat(
      dbFs: dbFs,
      floorDb: floorDb,
      frames: frames,
      starved: starved,
      bytesIn: bytesIn,
      bytesOut: bytesOut,
    );
  }

  // ===================================================================
  // 测试信号 / 统计 / 音量
  // ===================================================================

  /// 对数扫频 + 4Hz 音节包络：能量铺满语音带（200~3600Hz），
  /// 且像说话一样时强时弱 —— 恒定正弦会被 AEC 的 NLP 当成稳态噪声特殊处理。
  Uint8List _buildTestSignal() {
    const int sr = kSampleRateRecorder;
    const double seconds = 10.0;
    final int n = (sr * seconds).round();
    final Int16List out = Int16List(n);
    double phase = 0;
    for (int i = 0; i < n; i++) {
      final double t = i / sr;
      const double f0 = 200;
      const double f1 = 3600;
      const double sweep = 1.5; // 每 1.5s 扫一遍
      final double pos = (t % sweep) / sweep;
      final double f = f0 * math.pow(f1 / f0, pos).toDouble();
      phase += 2 * math.pi * f / sr;
      if (phase > 2 * math.pi) phase -= 2 * math.pi;
      final double env =
          0.30 + 0.70 * (0.5 + 0.5 * math.sin(2 * math.pi * 4 * t - math.pi / 2));
      final double s =
          (math.sin(phase) + 0.35 * math.sin(2 * phase)) * env * 0.30;
      out[i] = (s.clamp(-1.0, 1.0) * 32767).round();
    }
    return Uint8List.view(out.buffer, 0, out.lengthInBytes);
  }

  /// 4s 校验窗口（跳过前 1.5s 的 AEC 收敛期）内的 RMS，单位 dBFS。
  double _segmentRmsDb(Uint8List pcm, double fromSec, double toSec) {
    final int total = pcm.length ~/ 2;
    int a = (fromSec * kSampleRateRecorder).round();
    int b = (toSec * kSampleRateRecorder).round();
    if (a < 0) a = 0;
    if (b > total) b = total;
    if (b <= a) return -120;
    final ByteData view = ByteData.view(pcm.buffer, pcm.offsetInBytes, pcm.length);
    double sum = 0;
    for (int i = a; i < b; i++) {
      final double v = view.getInt16(i * 2, Endian.little) / 32768.0;
      sum += v * v;
    }
    final double rms = math.sqrt(sum / (b - a));
    return rms <= 0 ? -120 : 20 * (math.log(rms) / math.ln10);
  }

  /// 真机独有的验证：上行 48k → 16k → opus(20ms) → decode 能不能跑通。
  /// 桌面 Linux 没有 opus_ffi 的封装库，这条只能在设备上验。
  Future<String> _checkOpus(Uint8List pcm48k) async {
    final Stopwatch sw = Stopwatch()..start();
    try {
      // 取 2s
      final int bytes = 2 * kSampleRateRecorder * 2;
      final Uint8List part = Uint8List.sublistView(
        pcm48k,
        0,
        bytes <= pcm48k.length ? bytes : pcm48k.length,
      );
      final Uint8List pcm16k = MyResamplerRate.resample48kTo16k(part);
      final OpusEncoder enc = OpusEncoder(
        sampleRate: 16000,
        channels: Channels.mono,
        application: Application.voip,
      );
      final OpusDecoder dec = OpusDecoder(
        sampleRate: 16000,
        channels: Channels.mono,
      );
      const int frame = 320; // 16k 下 20ms
      final int frames = pcm16k.length ~/ 2 ~/ frame;
      int totalPacket = 0;
      int decoded = 0;
      final Int16List src = Int16List.view(
        pcm16k.buffer,
        pcm16k.offsetInBytes,
        pcm16k.length ~/ 2,
      );
      for (int i = 0; i < frames; i++) {
        final Int16List inFrame = Int16List.sublistView(
          src,
          i * frame,
          (i + 1) * frame,
        );
        final Uint8List pkt = enc.encode(inFrame, inputSize: frame);
        totalPacket += pkt.length;
        decoded += dec.decode(pkt).length;
      }
      enc.dispose();
      dec.dispose();
      final int expect = frames * frame;
      final bool ok = frames > 0 && decoded == expect;
      return '  ${ok ? "✅" : "❌"} $frames 帧(20ms), '
          '平均包 ${frames == 0 ? 0 : (totalPacket / frames).toStringAsFixed(0)}B, '
          '解码样本 $decoded/$expect, 耗时 ${sw.elapsedMilliseconds}ms';
    } catch (e) {
      return '  ❌ opus 不可用: $e';
    }
  }

  /// 音量提示（无法直接改系统音量，只做检测与提示）
  Future<void> _hintVolume() async {
    _log('提示: 请确认媒体音量已调到最大、未插耳机、手机平放在桌面上');
  }

  // ===================================================================
  // UI
  // ===================================================================

  @override
  Widget build(BuildContext context) {
    final ColorScheme cs = Theme.of(context).colorScheme;
    return Scaffold(
      appBar: AppBar(title: const Text('AEC3 真机端到端自测')),
      body: Column(
        children: [
          Container(
            width: double.infinity,
            color: _done
                ? (_verdict.startsWith('✅')
                    ? Colors.green.withValues(alpha: 0.14)
                    : Colors.orange.withValues(alpha: 0.16))
                : cs.surfaceContainerHighest,
            padding: const EdgeInsets.all(12),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  _running
                      ? '⏳ 正在跑（约 20s，别碰手机、别说话）'
                      : (_done ? _verdict : '准备中…'),
                  style: const TextStyle(
                    fontSize: 15,
                    fontWeight: FontWeight.w600,
                    height: 1.4,
                  ),
                ),
                if (_dirPath != null)
                  Padding(
                    padding: const EdgeInsets.only(top: 6),
                    child: SelectableText(
                      _dirPath!,
                      style: const TextStyle(fontSize: 11, color: Colors.grey),
                    ),
                  ),
              ],
            ),
          ),
          Expanded(
            child: Container(
              width: double.infinity,
              color: const Color(0xFF141414),
              child: SingleChildScrollView(
                controller: _scroll,
                padding: const EdgeInsets.all(12),
                child: SelectableText(
                  _lines.isEmpty ? '(等待)' : _lines.join('\n'),
                  style: const TextStyle(
                    fontFamily: 'monospace',
                    fontSize: 12,
                    height: 1.45,
                    color: Color(0xFFD8D8D8),
                  ),
                ),
              ),
            ),
          ),
          SafeArea(
            top: false,
            child: Padding(
              padding: const EdgeInsets.all(10),
              child: Row(
                children: [
                  Expanded(
                    child: FilledButton.icon(
                      onPressed: _running ? null : _runAll,
                      icon: const Icon(Icons.refresh),
                      label: Text(_running ? '运行中…' : '重跑一次'),
                    ),
                  ),
                ],
              ),
            ),
          ),
        ],
      ),
    );
  }
}

class _RunStat {
  final double dbFs;
  final double floorDb;
  final int frames;
  final int starved;
  final int bytesIn;
  final int bytesOut;
  const _RunStat({
    required this.dbFs,
    required this.floorDb,
    required this.frames,
    required this.starved,
    required this.bytesIn,
    required this.bytesOut,
  });
}
