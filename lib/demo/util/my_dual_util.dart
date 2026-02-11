import 'dart:io';
import 'dart:math';
import 'dart:typed_data';

import 'package:audio_session/audio_session.dart';
import 'package:fftea/impl.dart';
import 'package:fftea/util.dart';

import 'package:flutter/foundation.dart';
import 'package:flutter_easyloading/flutter_easyloading.dart';
import 'package:mic_info/mic_info.dart';
import 'package:mic_info/model/mic_info_model.dart';

import 'package:path_provider/path_provider.dart';
import 'package:record/record.dart';
import 'package:share_plus/share_plus.dart';

class DualUtil {
  static Future<bool> checkInitialHeadphoneState(
    AudioSession audioSession,
  ) async {
    bool isHeadphonesConnected = false;
    try {
      final devices = await audioSession.getDevices();
      isHeadphonesConnected = devices.any(_isHeadphones);
    } catch (e) {
      debugPrint("❌ 检查耳机状态失败111: $e");
    }
    return isHeadphonesConnected;
  }

  static bool _isHeadphones(AudioDevice device) {
    return device.type == AudioDeviceType.wiredHeadphones ||
        device.type == AudioDeviceType.wiredHeadset ||
        device.type == AudioDeviceType.bluetoothA2dp ||
        device.type == AudioDeviceType.bluetoothSco ||
        device.type == AudioDeviceType.usbAudio;
  }

  static Future<InputDevice?> getActiveMicrophone(
    AudioRecorder recorder,
  ) async {
    try {
      // 调用 mic_info 库来获取当前活动的麦克风列表
      final List<MicInfoDevice> activeMics =
          await MicInfo.getActiveMicrophones();

      MicInfoDevice? selectedMic = activeMics.first;

      if (activeMics.isNotEmpty) {
        final devices = await recorder.listInputDevices();
        InputDevice? activeDev;
        devices.forEach((item) {
          if (item.id == selectedMic.id) {
            activeDev = item;
          }
        });
        debugPrint('检查设备: ${activeDev?.label} (ID: ${activeDev?.id})');
        debugPrint(
          '成功找到活动麦克风: ${activeMics.first.productName} (ID: ${activeMics.first.id})',
        );
        return activeDev;
      } else {
        // 如果列表为空，表示没有检测到任何活动的麦克风。
        debugPrint('未检测到活动的麦克风。请确保录音已开始且应用有麦克风权限。');
        return null;
      }
    } catch (e) {
      // 捕获可能发生的任何平台异常（例如权限问题）。
      debugPrint('查询活动麦克风时出错: $e');
      return null;
    }
  }

  static Future<int?> getPcmDurationInSeconds(
    String? pcmPath,
    int sampleRate,
    int channels,
  ) async {
    if (pcmPath == null) {
      return 0;
    }

    try {
      final file = File(pcmPath);
      // 检查文件是否存在，避免异常
      if (!await file.exists()) {
        return 0;
      }

      final fileSizeBytes = await file.length();
      if (fileSizeBytes == 0) return 0;

      // 每个样本的字节数。s16le -> 16 bit -> 2 bytes
      const bytesPerSample = 2;

      // 计算精确时长（double类型）
      final double preciseDuration =
          fileSizeBytes / (sampleRate * channels * bytesPerSample);
      // 四舍五入为最接近的整数
      final int roundedDuration = preciseDuration.round();
      return roundedDuration;
    } catch (e) {
      return 0;
    }
  }

  static Future<String> savePcmToWavFile(
    List<int> _rawPcmBytes,
    int sampleRate,
    int channels,
  ) async {
    if (_rawPcmBytes.isEmpty) {
      debugPrint("没有收集到任何 PCM 数据。");
      return "";
    }

    final pcmUint8List = Uint8List.fromList(_rawPcmBytes);
    final wavBytes = _encodePcmToWav(pcmUint8List, sampleRate, channels);

    final dir = await getApplicationDocumentsDirectory();
    final wavPath =
        '${dir.path}/recorded_audio_${DateTime.now().millisecondsSinceEpoch}.wav';

    final file = File(wavPath);
    await file.writeAsBytes(wavBytes, flush: true);
    // _rawPcmBytes.clear();

    // List<Map<String, String>> list = [
    //   {
    //     'file': path,
    //     'mimeType': "audio/wav",
    //   }
    // ];
    // shareWavFiles(list);

    debugPrint("WAV 文件已保存到: $wavPath");
    return wavPath;
  }

  static Future<String> savePcmFile(List<int> _rawPcmBytes) async {
    if (_rawPcmBytes.isEmpty) {
      debugPrint("没有收集到任何 PCM 数据。");
      return "";
    }

    final pcmUint8List = Uint8List.fromList(_rawPcmBytes);

    final dir = await getApplicationDocumentsDirectory();
    final filePath =
        '${dir.path}/recorded_audio_${DateTime.now().millisecondsSinceEpoch}.pcm';

    final file = File(filePath);
    await file.writeAsBytes(pcmUint8List, flush: true);
    // _rawPcmBytes.clear();

    // List<Map<String, String>> list = [
    //   {
    //     'file': path,
    //     'mimeType': "audio/wav",
    //   }
    // ];
    // shareWavFiles(list);

    debugPrint("PCM 文件已保存到: $filePath");
    return filePath;
  }

  static Uint8List _encodePcmToWav(
    Uint8List pcmData,
    int sampleRate,
    int channels,
  ) {
    int bytesPerSample = 2;
    final dataLength = pcmData.length;
    final fileLength = 36 + dataLength;
    final byteRate = sampleRate * channels * bytesPerSample;
    final blockAlign = channels * bytesPerSample;

    final buffer = ByteData(44);
    var offset = 0;

    // RIFF Chunk - ⭐ 标识符用 Big Endian
    buffer.setUint32(offset, 0x52494646, Endian.big); // "RIFF"
    offset += 4;
    buffer.setUint32(offset, fileLength, Endian.little); // 文件大小用 Little Endian
    offset += 4;
    buffer.setUint32(offset, 0x57415645, Endian.big); // "WAVE"
    offset += 4;

    // FMT Chunk
    buffer.setUint32(offset, 0x666d7420, Endian.big); // "fmt "
    offset += 4;
    buffer.setUint32(offset, 16, Endian.little);
    offset += 4;
    buffer.setUint16(offset, 1, Endian.little); // PCM = 1
    offset += 2;
    buffer.setUint16(offset, channels, Endian.little);
    offset += 2;
    buffer.setUint32(offset, sampleRate, Endian.little);
    offset += 4;
    buffer.setUint32(offset, byteRate, Endian.little);
    offset += 4;
    buffer.setUint16(offset, blockAlign, Endian.little);
    offset += 2;
    buffer.setUint16(offset, bytesPerSample * 8, Endian.little);
    offset += 2;

    // Data Chunk
    buffer.setUint32(offset, 0x64617461, Endian.big); // "data"
    offset += 4;
    buffer.setUint32(offset, dataLength, Endian.little);

    final wavHeader = buffer.buffer.asUint8List();
    final wavFile = Uint8List(wavHeader.length + pcmData.length);
    wavFile.setAll(0, wavHeader);
    wavFile.setAll(wavHeader.length, pcmData);

    return wavFile;
  }

  static Future<void> shareWavFiles(List<Map<String, String>> fileMap) async {
    final filesToShare = <XFile>[];

    fileMap.forEach((map) {
      String? path = map['file'];
      String? mimeType = map['mimeType'];
      if (path == null || path.isEmpty) return;

      final file = File(path);
      if (!file.existsSync() ||
          file.statSync().type != FileSystemEntityType.file) {
        debugPrint('文件不存在或不是有效文件：$path');
        return;
      }

      if (File(path).existsSync()) {
        filesToShare.add(XFile(path!, mimeType: mimeType, name: path));
      }
    });

    if (filesToShare.isNotEmpty) {
      await Share.shareXFiles(filesToShare, text: '文件保存', subject: '录音');

      fileMap.forEach((map) {
        deleteAudioFile(map['file']!);
      });
      debugPrint("已分享录音文件给用户");
    } else {
      debugPrint("没有可分享的文件");
    }
  }

  static Future<bool> deleteAudioFile(String inputPcmPath) async {
    try {
      final pcmFile = File(inputPcmPath);
      if (await pcmFile.exists()) {
        await pcmFile.delete();
        if (kDebugMode) {
          print("已删除文件: $inputPcmPath");
        }
        return true;
      }
    } catch (e) {
      if (kDebugMode) {
        print("删除文件失败: $e");
      }
      return false;
    }
    return false;
  }

  static Future<double> findMaxFrequency(
    BytesBuilder audioBuffer,
    int sampleRate,
  ) async {
    // --- 新增：从 BytesBuilder 获取 Uint8List ---
    final Uint8List audioBytes = audioBuffer.toBytes();

    if (audioBytes.isEmpty) {
      print("音频缓冲区为空，无法进行分析。");
      return 0.0;
    }

    // --- 1. 设置与Java版本完全一致的参数 ---
    const int nfft = 512;
    const double frameStrideSeconds = 0.01;
    const double emphasisCoefficient = 0.97;

    final int frameStepSamples = (sampleRate * frameStrideSeconds).round();
    final int numSamples = audioBytes.lengthInBytes ~/ 2;

    // 确保有足够的数据进行至少一次FFT
    if (numSamples < nfft) {
      print("音频数据不足，无法进行完整的FFT分析。需要 $nfft 个样本，但只有 $numSamples 个。");
      return 0.0;
    }

    // --- 2. 将原始16-bit PCM字节转换为Float64List ---
    final samples = Float64List(numSamples);
    final byteData = audioBytes.buffer.asByteData();
    for (int i = 0; i < numSamples; i++) {
      samples[i] = byteData.getInt16(i * 2, Endian.little) / 32768.0;
    }

    // --- 3. 手动实现Hamming窗 ---
    final hammingWindow = Float64List(nfft);
    for (int i = 0; i < nfft; i++) {
      hammingWindow[i] = 0.54 - 0.46 * cos(2 * pi * i / (nfft - 1));
    }

    final fft = FFT(nfft);
    double overallMaxFrequency = 0.0;
    double previousSample = 0.0;

    // --- 4. 主循环：像Java一样对音频进行分帧处理 ---
    for (int i = 0; i + nfft <= numSamples; i += frameStepSamples) {
      final frame = Float64List(nfft);
      for (int j = 0; j < nfft; j++) {
        frame[j] = samples[i + j];
      }

      final emphasisFrame = Float64List(nfft);
      for (int j = 0; j <= nfft; j++) {
        double currentSample = frame[j];
        emphasisFrame[j] = currentSample - emphasisCoefficient * previousSample;
        previousSample = currentSample;
      }

      for (int j = 0; j < nfft; j++) {
        emphasisFrame[j] *= hammingWindow[j];
      }

      final freq = fft.realFft(emphasisFrame);
      final Float64List magnitudes = freq.magnitudes();

      double maxMagnitude = -1;
      int maxMagnitudeIndex = -1;

      // 从索引 1 开始以避免直流分量，并只检查到 nfft / 2 (奈奎斯特频率)
      for (int j = 1; j <= nfft / 2; j++) {
        if (magnitudes[j] > maxMagnitude) {
          maxMagnitude = magnitudes[j];
          maxMagnitudeIndex = j;
        }
      }

      if (maxMagnitudeIndex != -1) {
        final double frequencyResolution = sampleRate / nfft;
        final double currentMaxFrequency =
            maxMagnitudeIndex * frequencyResolution;

        if (currentMaxFrequency > overallMaxFrequency) {
          overallMaxFrequency = currentMaxFrequency;
        }
      }
    }

    print("\n----------------------------------------------------");
    print("分析完成。整个文件的最高频率是: ${overallMaxFrequency.toStringAsFixed(2)} Hz");
    print("----------------------------------------------------");

    return overallMaxFrequency;
  }

  static String formatDuration(int seconds) {
    final hours = seconds ~/ 3600;
    final minutes = (seconds % 3600) ~/ 60;
    final secs = seconds % 60;

    if (hours > 0) {
      return '${hours.toString().padLeft(2, '0')}:${minutes.toString().padLeft(2, '0')}:${secs.toString().padLeft(2, '0')}';
    } else {
      return '${minutes.toString().padLeft(2, '0')}:${secs.toString().padLeft(2, '0')}';
    }
  }

  static Future<InputDevice?> findBuiltInMicNew({
    required AudioRecorder recorder,
    AudioSession? audioSession,
  }) async {
    try {
      // 第一阶段：从两个API获取设备信息
      final recorderDevices = await recorder.listInputDevices();
      debugPrint('AudioRecorder发现 ${recorderDevices.length} 个输入设备');

      // 如果没有audioSession参数，则使用简化的查找逻辑
      if (audioSession == null) {
        return _findByRecorderOnly(recorderDevices);
      }

      final sessionDevices = await audioSession.getDevices();
      debugPrint('AudioSession发现 ${sessionDevices.length} 个音频设备');

      // 第二阶段：筛选出内置麦克风类型的设备ID
      final builtInMicIds = <String>[];

      for (final device in sessionDevices) {
        if (device.isInput && device.type == AudioDeviceType.builtInMic) {
          builtInMicIds.add(device.id);
          debugPrint('AudioSession内置麦克风: ID=${device.id}, 类型=${device.type}');
        }
      }

      if (builtInMicIds.isEmpty) {
        debugPrint('警告：AudioSession未发现内置麦克风类型，回退到Recorder查找');
        return _findByRecorderOnly(recorderDevices);
      }

      // 第三阶段：在Recorder设备中匹配并优先选择底部麦克风
      return _selectBestMicFromRecorder(recorderDevices, builtInMicIds);
    } catch (e) {
      debugPrint('查找内置麦克风时发生异常: $e');
      return null;
    }
  }

  /// 仅使用AudioRecorder设备列表的查找逻辑（兼容模式）
  static InputDevice? _findByRecorderOnly(List<InputDevice> devices) {
    if (devices.isEmpty) {
      debugPrint('错误：没有发现任何输入设备');
      return null;
    }

    // 打印所有设备信息以便调试
    for (final device in devices) {
      debugPrint('设备: ID=${device.id}, 标签="${device.label}"');
    }

    // 查找优先级
    InputDevice? selectedDevice;

    // 1. 优先查找底部麦克风（最适合对话）
    selectedDevice = _tryFindDeviceNew(devices, (label) {
      final lowerLabel = label.toLowerCase();
      return lowerLabel.contains('bottom') ||
          lowerLabel.contains('primary') ||
          (lowerLabel.contains('built-in') && lowerLabel.contains('mic'));
    });

    if (selectedDevice != null) {
      debugPrint('策略1: 找到底部/主麦克风 "${selectedDevice.label}"');
      return selectedDevice;
    }

    // 2. 查找任何内置麦克风
    selectedDevice = _tryFindDeviceNew(devices, (label) {
      final lowerLabel = label.toLowerCase();
      return lowerLabel.contains('built-in') ||
          lowerLabel.contains('internal') ||
          lowerLabel.contains('device mic');
    });

    if (selectedDevice != null) {
      debugPrint('策略2: 找到内置麦克风 "${selectedDevice.label}"');
      return selectedDevice;
    }

    // 3. 排除蓝牙和耳机，选择第一个看起来像手机麦克风的设备
    selectedDevice = _tryFindDeviceNew(devices, (label) {
      final lowerLabel = label.toLowerCase();
      return lowerLabel.contains('mic') &&
          !lowerLabel.contains('bluetooth') &&
          !lowerLabel.contains('headset') &&
          !label.contains('headphones');
    });

    if (selectedDevice != null) {
      debugPrint('策略3: 找到通用手机麦克风 "${selectedDevice.label}"');
      return selectedDevice;
    }

    // 4. 最终回退：使用第一个设备
    selectedDevice = devices.first;
    debugPrint('策略4: 未找到理想麦克风，使用第一个设备 "${selectedDevice.label}"');
    return selectedDevice;
  }

  /// 从Recorder设备中选择最佳的麦克风
  static InputDevice? _selectBestMicFromRecorder(
    List<InputDevice> recorderDevices,
    List<String> builtInMicIds,
  ) {
    // 首先筛选出AudioSession确认的内置麦克风
    final validDevices = recorderDevices
        .where((device) => builtInMicIds.contains(device.id))
        .toList();

    if (validDevices.isEmpty) {
      debugPrint('警告：Recorder设备与AudioSession ID不匹配，使用所有设备');
      return _findByRecorderOnly(recorderDevices);
    }

    debugPrint('找到 ${validDevices.length} 个已验证的内置麦克风');

    // 优先选择策略
    InputDevice? selectedDevice;

    // 1. 优先：明确标识为"bottom"的麦克风（最适合对话）
    selectedDevice = _tryFindDeviceNew(validDevices, (label) {
      return label.toLowerCase().contains('bottom');
    });

    if (selectedDevice != null) {
      debugPrint(
        '最佳选择：底部麦克风 "${selectedDevice.label}" (ID: ${selectedDevice.id})',
      );
      return selectedDevice;
    }

    // 2. 备选：主麦克风或默认麦克风
    selectedDevice = _tryFindDeviceNew(validDevices, (label) {
      final lowerLabel = label.toLowerCase();
      return lowerLabel.contains('primary') ||
          lowerLabel.contains('default') ||
          lowerLabel.contains('main');
    });

    if (selectedDevice != null) {
      debugPrint(
        '次佳选择：主麦克风 "${selectedDevice.label}" (ID: ${selectedDevice.id})',
      );
      return selectedDevice;
    }

    // 3. 最后：选择第一个已验证的内置麦克风
    selectedDevice = validDevices.first;
    debugPrint(
      '最终选择：第一个内置麦克风 "${selectedDevice.label}" (ID: ${selectedDevice.id})',
    );
    return selectedDevice;
  }

  /// 通用设备查找辅助方法
  static InputDevice? _tryFindDeviceNew(
    List<InputDevice> devices,
    bool Function(String label) matcher,
  ) {
    try {
      return devices.firstWhere(
        (device) => matcher(device.label.toLowerCase()),
      );
    } catch (e) {
      return null;
    }
  }

  /// 获取设备详细描述（用于调试和日志）
  static String getDeviceDescription(InputDevice device) {
    final label = device.label.toLowerCase();
    String type = '未知类型';

    if (label.contains('bottom'))
      type = '底部麦克风';
    else if (label.contains('back'))
      type = '后置麦克风';
    else if (label.contains('built-in'))
      type = '内置麦克风';
    else if (label.contains('headset'))
      type = '耳机麦克风';
    else if (label.contains('bluetooth'))
      type = '蓝牙麦克风';

    return '$type (${device.label}, ID: ${device.id})';
  }

  String formatTime(int days, int hours, int minutes, int seconds) {
    List<String> parts = [];
    if (days > 0) parts.add('$days天');
    if (hours > 0) parts.add('$hours小时');
    if (minutes > 0) parts.add('$minutes分钟');
    if (seconds > 0 || parts.isEmpty) parts.add('$seconds秒');
    return parts.join('');
  }

  static void updateProgressFromLog(
    int currentTimeMs,
    int totalDurationMs,
    DateTime lastProgressUpdateTime,
    double convertPcmToOpusProgress,
  ) {
    if (totalDurationMs > 0) {
      // 计算进度，确保在0-1范围内
      double progress = (currentTimeMs / totalDurationMs).clamp(0.0, 1.0);

      // 限制更新频率（避免过于频繁的UI更新）
      final now = DateTime.now();
      final timeSinceLastUpdate = now
          .difference(lastProgressUpdateTime)
          .inMilliseconds;

      // 只有当进度变化超过0.5%或距离上次更新超过200ms时才更新
      if ((progress - convertPcmToOpusProgress).abs() >= 0.005 ||
          timeSinceLastUpdate >= 200 ||
          progress == 1.0) {
        convertPcmToOpusProgress = progress;
        lastProgressUpdateTime = now;

        // 计算剩余时间
        int remainingMs = totalDurationMs - currentTimeMs;
        String remainingText = DualUtil.formatRemainingTime(remainingMs);

        // 更新进度显示
        if (progress < 1.0) {
          EasyLoading.showProgress(
            progress,
            status:
                '音频转码中... ${(progress * 100).toStringAsFixed(0)}%\n$remainingText',
          );
        } else {
          // 转码完成
          EasyLoading.showProgress(1.0, status: '转码完成，正在保存...');
        }

        debugPrint(
          "Pcm转Opus进度: ${(progress * 100).toStringAsFixed(1)}% ($currentTimeMs/$totalDurationMs ms)",
        );
      }
    } else {
      debugPrint("无法计算进度: 总时长为0");
    }
  }

  static int? parseTimeFromLog(String message) {
    // 进度行格式: size=   1536kB time=00:01:02.85 bitrate= 200.2kbits/s speed= 126x
    if (message.contains("time=") && message.contains("size=")) {
      // 使用正则表达式提取时间
      final timeMatch = RegExp(
        r'time=(\d{2}):(\d{2}):(\d{2}\.\d+)',
      ).firstMatch(message);

      if (timeMatch != null) {
        try {
          final hours = int.parse(timeMatch.group(1)!);
          final minutes = int.parse(timeMatch.group(2)!);
          final seconds = double.parse(timeMatch.group(3)!);
          final currentTimeMs =
              (hours * 3600 + minutes * 60 + seconds) * 1000 ~/ 1;

          debugPrint(
            "从日志解析到时间: ${hours}:${minutes}:${seconds} -> ${currentTimeMs}ms",
          );
          return currentTimeMs;
        } catch (e) {
          debugPrint("解析时间失败: $e");
          return null;
        }
      }
    }
    return null;
  }

  // 辅助函数：格式化剩余时间
  static String formatRemainingTime(int remainingMs) {
    if (remainingMs <= 0) return "即将完成";

    final remainingSeconds = remainingMs ~/ 1000;
    final remainingMinutes = remainingSeconds ~/ 60;
    final remainingHours = remainingMinutes ~/ 60;

    if (remainingHours > 0) {
      return "剩余约${remainingHours}小时${remainingMinutes % 60}分钟";
    } else if (remainingMinutes > 0) {
      return "剩余约${remainingMinutes}分钟${remainingSeconds % 60}秒";
    } else if (remainingSeconds > 0) {
      return "剩余约${remainingSeconds}秒";
    } else {
      return "即将完成";
    }
  }

  /// 将 PCM16 little-endian 字节转换为 Int16 样本
  static List<int> bytesToInt16Samples(Uint8List bytes) {
    final sampleCount = bytes.length ~/ 2;
    final samples = List<int>.filled(sampleCount, 0);

    for (int i = 0; i < sampleCount; i++) {
      final low = bytes[i * 2];
      final high = bytes[i * 2 + 1];
      int sample = (high << 8) | low;

      // 有符号转换
      if (sample >= 32768) {
        sample -= 65536;
      }
      samples[i] = sample;
    }

    return samples;
  }
}
