import 'dart:io';
import 'dart:isolate';
import 'dart:math' as math;
import 'dart:typed_data';

import 'package:my_flutter_app/demo/util/my_dual_resampler_rate.dart';
import 'package:native_aec/native_aec.dart';
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
    final _UpstreamAgc? upstreamAgc = Platform.isIOS ? _UpstreamAgc() : null;

    // 外放回声消除（WebRTC AEC3）。null = 直通（未启用或库不可用）。
    Aec3Processor? aec;

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

            // =================== 1. 文件写入（成品：AEC 后的 48k pcm）===================
            if (isWriteRecordFile && fileSink != null && chunk.isNotEmpty) {
              ioBuffer.add(chunk);
              if (isFirstChunk) {
                fileSink.add(ioBuffer.takeBytes());
                await fileSink.flush();
                final int chunkDurationMs =
                    (chunk.length ~/ 2) * 1000 ~/ kSampleRateRecorder;
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
              Uint8List resampled = MyResamplerRate.resample48kTo16k(chunk);
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

          case 'ref_chunk':
            // 播放侧喂进来的参考信号：**正在送给扬声器**的那份 PCM。
            // 与 pcm_chunk 走同一个端口，Dart 的 SendPort 是 FIFO，
            // 「先参考、后采集」的投递顺序天然成立（APM 的硬性要求）。
            aec?.pushReference(message['data']);
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
