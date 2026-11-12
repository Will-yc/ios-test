import 'dart:io';
import 'dart:isolate';
import 'dart:math' as math;
import 'dart:typed_data';

import 'package:my_flutter_app/demo/util/my_dual_resampler_rate.dart';
import 'package:native_aec/native_aec.dart';
import 'package:my_flutter_app/demo/aec3_room/howl_notch.dart';
import 'package:my_flutter_app/demo/aec3_room/noise_gate.dart';
import 'package:my_flutter_app/demo/aec3_room/residual_gate.dart';
import 'package:opus_ffi/opus_ffi.dart';

/// 采集采样率：48k 原始字节直接落盘（成品 .pcm 就是这个）。
const int kSampleRateRecorder = 48000;
const int kChannels = 1;

/// 上行采样率：跟原工程（my_dual_recorder_main_page）完全一致，
/// 对讲只传 16k opus（24kbps 级别），成品求质、传输求通是两条独立需求。
const int kSampleRateUplink = 16000;

/// 高频旁路（TRTC 式全频带）开关。默认开。
///
/// 成品走的是「48k 采集 → AEC3(48k) → 48k 落盘」，与上行 16k opus 无关，
/// 所以本地成品可以做到 20kHz 带宽；但 WebRTC AEC3 在 48kHz 下会把低子带的
/// 抑制增益套到 8kHz 以上的高子带，而参考信号（16k opus）在 8kHz 以上恒为
/// 零 —— 那里根本没有回声，只会把本端人声的齿音/空气感压掉 30~40dB。
/// 开启后 0~8kHz 取 AEC 输出、8kHz 以上原样取采集，样本数与时间轴不变。
/// 用 `--dart-define=FULLBAND=false` 可退回旧行为做 A/B 对照。
/// 注意用 String.fromEnvironment：bool.fromEnvironment 读不到 dart-define 字符串。
const bool kHighBandBypass =
    String.fromEnvironment('FULLBAND', defaultValue: 'true') == 'true';

/// 下行相关门（成品彻底无回声）开关。默认开。
///
/// AEC3 按比例消回声，双讲时会漏掉远端残余 + 厂商音效非线性，成品里仍能
/// 听到「对方的声音」。开启后，凡「与下行参考高度相关的帧」整帧压低到接近
/// 静音，代价是双讲（双方同时说）时本端也被压低 —— 成品优先的取舍。
/// 用 `--dart-define=RESIDUAL_GATE=false` 可退回纯 AEC3 行为做对照。
const bool kResidualGate =
    String.fromEnvironment('RESIDUAL_GATE', defaultValue: 'true') == 'true';

/// 采集侧底噪门开关。默认开。
///
/// AEC3 的 NS 被有意关掉（怕改频响），所以**静音期的底噪原样进成品**：
/// 真机安静段里 120~130Hz 窄带嗡鸣占能量 ~36%、12~18kHz 有嘶声、iOS 整体
/// 底噪 −57dBFS。这一层只压「明显不像语音」的帧，语音帧立刻全开。
/// 用 `--dart-define=NOISE_GATE=false` 退回旧行为做 A/B。
const bool kNoiseGate =
    String.fromEnvironment('NOISE_GATE', defaultValue: 'true') == 'true';

/// 采集侧啸叫陷波开关。默认开。
///
/// 两台设备**不在同一空间**也照样啸叫，因为回路不是靠「两机之间的空气」闭合的：
///   A 麦 → 上行 → B 外放 → B 麦 → 上行 → A 外放 → A 麦
/// 声耦合只发生在各自「自己的扬声器→自己的麦克风」，房间不共享切不断这条环。
/// AEC3 若没把这段自回声消干净（参考延迟对不上就会这样），回路增益 >1 就自激，
/// 且峰频会在 1.5~3kHz 之间跳 —— 听感是一整片吼叫/杂音，不是单音哨。
/// 这一层把「已确认的啸叫窄峰」直接挖掉，把该频点的环路增益压到 1 以下。
/// 用 `--dart-define=HOWL_NOTCH=false` 退回旧行为做 A/B。
const bool kHowlNotch =
    String.fromEnvironment('HOWL_NOTCH', defaultValue: 'true') == 'true';

/// 陷波频率下限（Hz）。**低于这个值一律不挖** —— 人声基频 80~400Hz、
/// 低次谐波 400~1200Hz 都在这之下；实测啸叫落在 1.5~3kHz。
/// 真机回归：页面检测器曾把 375Hz（男声基频）锁成啸叫，挖掉 −22dB 后
/// 人声发空、听感明显变差。页面侧已按频段 + 连续确认过滤，这里是兜底。
const double kNotchMinHz = 1200.0;

/// 上行 AGC 开关。默认**关**。
///
/// 它原本只为补偿 iOS 裸麦的数字增益，但在外放对讲里它处在环路内部：
/// 啸叫一起来，AGC 就把被压下去的振荡重新拉回稳态，振荡永远熄不掉
/// （实测两端的 1.9kHz 包络稳定在 −33dBFS 长达 30 秒、并伴 3.5Hz 抽吸）。
/// 需要时用 `--dart-define=UPSTREAM_AGC=true` 打开。
const bool kUpstreamAgc =
    String.fromEnvironment('UPSTREAM_AGC', defaultValue: 'false') == 'true';

/// 后台音频处理与 I/O 线程（必须是顶层函数）。
///
/// 移植自 `zyxc-record-app/lib/module/chat/audio/my_dual_audio_processing_worker.dart`，
/// 只保留「验证 AEC3 无耳机」需要的那部分链路：
///
///   mic(48k) → AEC3(48k) ─┬─→ .pcm 落盘（成品，AEC 后的字节）
///                         └─→ 48k→16k → opus(20ms) → WS 二进制
///
/// 原工程的转码/上传/元数据/sidecar 分支全部去掉 —— 本工程只验证外放 AEC。
void audioProcessingWorker(SendPort mainSendPort) {
  final workerReceivePort = ReceivePort();
  mainSendPort.send(workerReceivePort.sendPort);

  Future<void> processMessages() async {
    OpusEncoder? encoder;
    IOSink? fileSink;

    /// 诊断用：AEC **之前**的原始采集（只在该开关打开时有值）。
    /// 有了它就能离线直接算 ERLE / 看残余，不必靠人耳判断「还有没有回声」。
    IOSink? rawSink;

    bool isWriteRecordFile = false;
    bool isFirstChunk = true;

    /// AEC 按 10ms 帧对齐，首块可能被"憋住"。若把第二块的 captureTime 当起点，
    /// 时间轴会整体后移一个 chunk。记住第一块被吞掉那一刻的时刻。
    int? pendingCaptureTime;

    /// 累计字节：进 AEC 前 / 出 AEC 后。用来核对「样本守恒」（只允许差 < 1 帧）。
    int bytesIn = 0;
    int bytesOut = 0;

    final BytesBuilder ioBuffer = BytesBuilder();
    const int ioBufferThreshold = 12 * 1024;
    final BytesBuilder accumulationBuffer = BytesBuilder();

    // 上行 AGC 只在 iOS 启用（补偿 iOS 裸麦相对 Android 缺失的数字增益）。
    // 它只作用于「上行 opus」那条新 buffer，落盘 .pcm 一个采样都不变。
    // 默认关：它处在啸叫回路里，会把振荡托在稳态（见 kUpstreamAgc 注释）。
    final _UpstreamAgc? upstreamAgc =
        (Platform.isIOS && kUpstreamAgc) ? _UpstreamAgc() : null;

    // 采集侧啸叫陷波（AEC 之后）。null = 不启用。
    final HowlNotch? notch = kHowlNotch
        ? HowlNotch(sampleRate: kSampleRateRecorder)
        : null;

    // 外放回声消除（WebRTC AEC3）。null = 直通（未启用或库不可用）。
    Aec3Processor? aec;

    // 下行相关门（AEC 之后的「宁可错杀」清尾层）。只作用于落盘链路，
    // 不碰上行 opus。开关 FULLBAND/RESIDUAL_GATE 控制。
    ResidualGate? gate;

    // 采集侧底噪门（AEC + 陷波 + 相关门之后）。上行一份、成品一份：
    // 两个独立实例（各自维护噪底/增益状态），互不串状态。
    // 旧版只把底噪门接在上行，落盘成品绕过了它 —— 真机成品静音期
    // 只压了 1.7dB（应 ~19dB），就是这条旁路造成的。
    final NoiseGate? noiseGate =
        kNoiseGate ? NoiseGate(sampleRate: kSampleRateRecorder) : null;
    final NoiseGate? noiseGateOut =
        kNoiseGate ? NoiseGate(sampleRate: kSampleRateRecorder) : null;

    await for (final message in workerReceivePort) {
      if (message is! Map) continue;
      final String type = message['type'];

      try {
        switch (type) {
          case 'init':
            // 换文件前先把上一段攒在 ioBuffer 里的残留冲进**旧** sink
            if (ioBuffer.isNotEmpty && fileSink != null) {
              fileSink.add(ioBuffer.takeBytes());
            }
            await fileSink?.close();
            await rawSink?.flush();
            await rawSink?.close();
            rawSink = null;
            encoder?.dispose();

            // 每个分段开始都必须回到"首块"状态（这个 isolate 只建一次，
            // 但 init 每轮开录都会发过来）。
            isFirstChunk = true;
            pendingCaptureTime = null;
            bytesIn = 0;
            bytesOut = 0;
            ioBuffer.clear();
            accumulationBuffer.clear();
            upstreamAgc?.reset();

            // AEC3：续录只清帧缓存/统计，保留自适应滤波器（重新收敛要 ~1s）
            if (message['aecEnabled'] == true) {
              aec ??= Aec3Processor.tryCreate(
                sampleRate: kSampleRateRecorder,
                highBandBypass: kHighBandBypass,
              );
              aec?.reset();
              if (aec == null) {
                mainSendPort.send({'type': 'aec-unavailable'});
              }
            } else {
              aec?.dispose();
              aec = null;
            }

            // 下行相关门：默认开（成品彻底无回声）。--dart-define=RESIDUAL_GATE=false 可关。
            if (kResidualGate) {
              gate ??= ResidualGate(
                sampleRate: kSampleRateRecorder,
                // 页面侧 REF_DELAY 只是给 AEC3 用的「较小延迟」，
                // 与本门要对齐的真实回声延迟（播放缓冲 + 声学，实测 321~352ms）
                // 不是一回事 —— 这里让门自己搜，assumedDelayMs 只当初始值。
                assumedDelayMs: 300,
              );
            } else {
              gate = null;
            }
            gate?.reset();
            // 陷波器跨分段保留会带着上一段的振荡状态，这里一并清掉
            notch?.reset();
            noiseGate?.reset();
            noiseGateOut?.reset();

            final String? filePath = message['filePath'];
            if (filePath != null && filePath.isNotEmpty) {
              fileSink = File(filePath).openWrite();
            }
            // 诊断轨道：AEC 之前的原始字节（只有显式要才开）
            final String? rawPath = message['rawFilePath'];
            if (rawPath != null && rawPath.isNotEmpty) {
              rawSink = File(rawPath).openWrite();
            }

            encoder = OpusEncoder(
              sampleRate: kSampleRateUplink,
              channels: Channels.mono,
              application: Application.voip,
            );
            mainSendPort.send({
              'type': 'init-over',
              'highBandBypass': aec?.highBandBypassEnabled ?? false,
              'residualGate': gate != null,
              'howlNotch': notch != null,
              'noiseGate': noiseGate != null,
              'upstreamAgc': upstreamAgc != null,
            });
            break;

          case 'isWriteRecordFile':
            isWriteRecordFile = message['isWriteRecordFile'];
            if (!isWriteRecordFile && fileSink != null) {
              // 关文件前必须把 ioBuffer 残留冲进 sink（否则最后 ~125ms 永久丢失）
              if (ioBuffer.isNotEmpty) {
                fileSink.add(ioBuffer.takeBytes());
              }
              await fileSink.flush();
              await fileSink.close();
              fileSink = null;
              await rawSink?.flush();
              await rawSink?.close();
              rawSink = null;
              // 告诉主线程「这段文件的字节已经全部落盘」，导出 wav 必须等它，
              // 否则会读到缺尾巴的文件（wav 头里的长度是对的，内容却短一截）。
              mainSendPort.send({'type': 'file-closed'});
            }
            break;

          case 'pcm_chunk':
            Uint8List chunk = message['data'];
            isWriteRecordFile = message['isWriteRecordFile'];
            int captureTime = message['captureTime'];

            // 🔴 回声消除必须发生在写盘与编码之前：外放时扬声器漏进麦克风的
            //    对方声音一旦写进 .pcm 就是永久性成品污染，后处理修不回来。
            if (rawSink != null) {
              // 诊断轨道写的是 AEC 之前的原样字节，用来离线算真实 ERLE
              try {
                rawSink.add(chunk);
              } catch (_) {}
            }
            if (aec != null) {
              bytesIn += chunk.length;
              pendingCaptureTime ??= captureTime;
              chunk = aec.processCapture(chunk);
              // 返回空 = 还不够一个 10ms 帧（内部攒着），本次既不写盘也不编码
              if (chunk.isEmpty) break;
              captureTime = pendingCaptureTime;
              pendingCaptureTime = null;
              bytesOut += chunk.length;
            }

            // 采集侧啸叫陷波：把已确认的自激窄峰挖掉（上行与成品同时生效）。
            if (notch != null && chunk.isNotEmpty) {
              chunk = notch.process(chunk);
            }

            // 底噪门：只压「明显不像语音」的帧（静音期嗡鸣 / 高频嘶声）。
            // 放在相关门**之前**取一份给上行用，但**不改动 chunk 本身** ——
            // 相关门的判决必须基于未被压过的真实能量，否则弱语音会被
            // 「能量远低于参考」这条兜底判成残余，整句被砍掉。
            final Uint8List upChunk = (noiseGate != null && chunk.isNotEmpty)
                ? noiseGate.process(chunk)
                : chunk;

            // 下行相关门：给落盘成品用的那一份（上行不经过它 ——
            // 对讲时把对方声音整段压掉会让对讲变成半双工，成品干净就够了）。
            // 判决基于未被底噪门压过的真实能量；底噪门在相关门**之后**
            // 作用于成品，顺序与文档一致：AEC→陷波→相关门→底噪门→落盘。
            Uint8List outChunk = (gate != null && chunk.isNotEmpty)
                ? gate.process(chunk)
                : chunk;
            if (noiseGateOut != null && outChunk.isNotEmpty) {
              outChunk = noiseGateOut.process(outChunk);
            }

            // =================== 1. 文件写入（成品：AEC 后的 48k pcm）===================
            if (isWriteRecordFile && fileSink != null && outChunk.isNotEmpty) {
              ioBuffer.add(outChunk);
              if (isFirstChunk) {
                fileSink.add(ioBuffer.takeBytes());
                await fileSink.flush();
                final int chunkDurationMs =
                    (outChunk.length ~/ 2) * 1000 ~/ kSampleRateRecorder;
                // captureTime ≈ 这段音频结束时刻，减掉时长得到起点
                mainSendPort.send({
                  'type': 'first_chunk_time',
                  'time': captureTime - chunkDurationMs,
                });
                isFirstChunk = false;
              }
              if (ioBuffer.length >= ioBufferThreshold) {
                try {
                  fileSink.add(ioBuffer.takeBytes());
                } catch (e) {
                  mainSendPort.send({'type': 'flush-error', 'data': '$e'});
                }
              }
            }

            // =================== 2. 上行 Opus 编码 ===================
            if (encoder != null && chunk.isNotEmpty) {
              Uint8List resampled = MyResamplerRate.resample48kTo16k(upChunk);
              if (upstreamAgc != null) {
                resampled = upstreamAgc.process(resampled);
              }
              accumulationBuffer.add(resampled);
              const int frameBytes = 320 * 2; // 16k 下 20ms
              while (accumulationBuffer.length >= frameBytes) {
                final allBytes = accumulationBuffer.takeBytes();
                final frame = Uint8List.sublistView(allBytes, 0, frameBytes);
                if (allBytes.length > frameBytes) {
                  accumulationBuffer.add(
                    Uint8List.sublistView(allBytes, frameBytes),
                  );
                }
                final pcmInput = Int16List.view(frame.buffer, frame.offsetInBytes, 320);
                final opusPacket = encoder.encode(pcmInput, inputSize: 320);
                mainSendPort.send({'type': 'opus_packet', 'data': opusPacket});
              }
            }
            break;

          case 'aec_reset':
            // 延迟标定结束后重置 AEC（标定那 3s 故意不喂参考，滤波器状态已失效）。
            // 只重置算法句柄，绝不动 fileSink / encoder，否则成品会断流。
            aec?.reset();
            // 标定期间参考与采集都不连续，两个门的历史同样作废：
            // 留着旧的 lag / 噪底只会在标定后头几百毫秒做错判决。
            gate?.reset();
            noiseGate?.reset();
            noiseGateOut?.reset();
            break;

          case 'howl_notch':
            // 页面侧守卫检出的啸叫频点（可能多个），直接下发给陷波器。
            // 第二道闸：低于 [kNotchMinHz] 的目标一律丢弃。人声基频（80~400Hz）
            // 与低次谐波都在下面，挖了等于把人说话挖空 —— 真机上 375Hz 被锁过
            // 一次，人声直接发空。页面侧已按频段+连续确认过滤，这里兜底。
            final List<dynamic> hz = (message['hz'] as List<dynamic>?) ?? const [];
            final List<double> targets = hz
                .map((e) => (e as num).toDouble())
                .where((f) => f >= kNotchMinHz)
                .toList();
            notch?.setTargets(targets);
            mainSendPort.send({
              'type': 'howl_notch_ack',
              'active': notch?.activeHz ?? const <double>[],
            });
            break;

          case 'ref_chunk':
            // 播放侧喂进来的参考信号：**正在送给扬声器**的那份 PCM。
            // 与 pcm_chunk 走同一个端口，Dart 的 SendPort 是 FIFO，
            // 「先参考、后采集」的投递顺序天然成立（APM 的硬性要求）。
            aec?.pushReference(message['data']);
            // 同时喂给下行相关门（用于判定「这帧里有多少是回声」）
            gate?.pushReference(message['data']);
            break;

          case 'flush_chunk':
            if (ioBuffer.isNotEmpty && fileSink != null) {
              fileSink.add(ioBuffer.takeBytes());
            }
            await fileSink?.flush();
            break;

          case 'aec_stats':
            final st = aec?.stats();
            mainSendPort.send({
              'type': 'aec_stats',
              'inDbfs': st?.inputDbfs,
              'outDbfs': st?.outputDbfs,
              'frames': st?.processedFrames ?? 0,
              'starved': st?.refStarvedFrames ?? 0,
              'bytesIn': bytesIn,
              'bytesOut': bytesOut,
              // 相关门的对齐状态：真机上「lag 是不是一个合理值」直接决定
              // 这层门有没有在工作 —— 之前它永远算不出 lag，所以从没生效过。
              'gateLagMs': gate?.currentLagMs ?? -1,
              'gateRho': gate?.lastRho,
              'gateGain': gate?.currentGain,
              'noiseFloor': noiseGate?.floorDbfs,
              'noiseGain': noiseGate?.gain,
            });
            break;

          case 'dispose':
            isWriteRecordFile = false;
            if (ioBuffer.isNotEmpty && fileSink != null) {
              fileSink.add(ioBuffer.takeBytes());
            }
            if (fileSink != null) {
              await fileSink.flush();
              await fileSink.close();
              fileSink = null;
            }
            await rawSink?.flush();
            await rawSink?.close();
            rawSink = null;
            encoder?.dispose();
            encoder = null;
            // AEC3 句柄必须跟着 isolate 一起收回，否则每次开录漏一份滤波器内存
            aec?.dispose();
            aec = null;
            accumulationBuffer.clear();
            ioBuffer.clear();
            mainSendPort.send({'type': 'disposed'});
            workerReceivePort.close();
            break;
        }
      } catch (e) {
        mainSendPort.send({'type': 'error', 'data': '音频处理异常($type): $e'});
        if (type == 'dispose') {
          mainSendPort.send({'type': 'disposed'});
          workerReceivePort.close();
        }
      }
    }
  }

  processMessages();
}

/// iOS 上行 AGC —— 只作用于「实时对讲」的上行 opus 链路。
/// 落盘 .pcm 与导出 wav 完全不经过它（两条分支不共享内存）。
class _UpstreamAgc {
  static const double _targetPeakDb = -6.0;
  static const double _maxGainDb = 24.0;
  static const double _voiceMarginDb = 8.0;
  static const int _warmupFrames = 8;
  static const int _frameSamples = 320;

  double _gainDb = 0.0;
  double _noiseFloorDb = 0.0;
  int _warmup = _warmupFrames;
  int _framePeak = 0;
  int _framePos = 0;
  double _linear = 1.0;

  void reset() {
    _gainDb = 0.0;
    _noiseFloorDb = 0.0;
    _warmup = _warmupFrames;
    _framePeak = 0;
    _framePos = 0;
    _linear = 1.0;
  }

  Uint8List process(Uint8List pcm) {
    if (pcm.isEmpty) return pcm;
    final ByteData view = ByteData.view(
      pcm.buffer,
      pcm.offsetInBytes,
      pcm.lengthInBytes,
    );
    final int samples = pcm.length ~/ 2;

    for (int i = 0; i < samples; i++) {
      final int raw = view.getInt16(i * 2, Endian.little);
      final int abs = raw < 0 ? -raw : raw;
      if (abs > _framePeak) _framePeak = abs;
      if (++_framePos >= _frameSamples) {
        _update();
        _framePeak = 0;
        _framePos = 0;
      }
      if (_linear == 1.0) continue;
      int v = (raw * _linear).round();
      if (v > 32767) {
        v = 32767;
      } else if (v < -32768) {
        v = -32768;
      }
      view.setInt16(i * 2, v, Endian.little);
    }
    return pcm;
  }

  void _update() {
    final int peak = _framePeak;
    final double peakDb =
        peak < 1 ? -90.0 : 20 * (math.log(peak / 32768.0) / math.ln10);

    if (_warmup > 0) {
      if (peakDb < _noiseFloorDb) _noiseFloorDb = peakDb;
      _warmup--;
      _gainDb = 0.0;
      _linear = 1.0;
      if (_warmup == 0 && _noiseFloorDb > -25.0) _noiseFloorDb = -25.0;
      return;
    }

    if (peakDb < _noiseFloorDb) {
      _noiseFloorDb += (peakDb - _noiseFloorDb) * 0.3;
    } else {
      _noiseFloorDb += (peakDb - _noiseFloorDb) * 0.002;
    }
    if (_noiseFloorDb < -80.0) _noiseFloorDb = -80.0;
    if (_noiseFloorDb > -25.0) _noiseFloorDb = -25.0;

    double targetDb = _gainDb;
    if (peakDb > _noiseFloorDb + _voiceMarginDb && peakDb < _targetPeakDb) {
      targetDb = _targetPeakDb - peakDb;
      if (targetDb > _maxGainDb) targetDb = _maxGainDb;
    }
    if (targetDb < 0.0) targetDb = 0.0;

    _gainDb += (targetDb - _gainDb) * (targetDb < _gainDb ? 0.5 : 0.08);
    _linear = _gainDb < 0.05 ? 1.0 : math.pow(10, _gainDb / 20).toDouble();
  }
}
