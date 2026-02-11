import 'dart:typed_data';
import 'dart:math';

import 'package:flutter/material.dart';

class MyResamplerRate {
  /// 48kHz 转 16kHz
  /// 采用 FIR 低通滤波器防混叠，然后进行 3:1 抽取
  /// // 简单的 3:1 抽取 (Decimation)，不带滤波 (性能极快，但有混叠风险)
  // 如果你的设备性能吃紧，建议先用这个测试，看延迟是否消失。
  static Uint8List resample48kTo16kFast(Uint8List input) {
    if (input.isEmpty) return Uint8List(0);

    // 48k -> 16k 是 3:1
    // 输入长度
    final int inputLen = input.length;
    // 确保处理范围，防止越界
    final int safeLimit = inputLen - 6;

    // 预估输出大小 (除以3)
    // 必须确保是偶数 (2 bytes per sample)
    final int outputLen = (inputLen ~/ 6) * 2;
    final Uint8List output = Uint8List(outputLen);

    final ByteData inputView =
        ByteData.view(input.buffer, input.offsetInBytes, input.lengthInBytes);
    final ByteData outputView = ByteData.view(output.buffer);

    int outputIndex = 0;

    // 循环步长为 6 (3个样本 * 2字节)
    for (int i = 0; i < safeLimit; i += 6) {
      if (outputIndex + 2 <= outputLen) {
        // 直接取当前采样点
        final int sample = inputView.getInt16(i, Endian.little);
        outputView.setInt16(outputIndex, sample, Endian.little);
        outputIndex += 2;
      }
    }

    return output;
  }

  static Uint8List resample48kTo16k(Uint8List input) {
    if (input.isEmpty) return Uint8List(0);

    // 1. 关键修复：正确获取 ByteData 视图，处理 offset
    final ByteData inputView =
        ByteData.view(input.buffer, input.offsetInBytes, input.lengthInBytes);

    final int inputSamples = input.length ~/ 2;
    // 48k -> 16k 是 3:1 的关系
    final int outputSamples = inputSamples ~/ 3;
    final Uint8List output = Uint8List(outputSamples * 2);
    final ByteData outputView = ByteData.view(output.buffer);

    // 2. 滤波器参数配置
    // 目标是 16kHz，奈奎斯特频率是 8kHz。
    // 我们需要滤除 8kHz 以上的声音，防止混叠。
    // 截止频率设为 7000Hz 以留出滚降空间。
    const double cutoffFrequency = 7000.0;
    const double sampleRate = 48000.0;
    const int filterLength = 15; // 滤波器阶数，越高越精准但越慢，15是平衡点

    // 3. 生成或缓存滤波器系数 (实际项目中建议设为静态常量以避免重复计算)
    final List<double> filterCoefficients =
        _createLowPassFIR(cutoffFrequency, sampleRate, filterLength);

    final int halfFilterLen = filterLength ~/ 2;

    // 4. 处理循环：滤波 + 抽取
    for (int i = 0; i < outputSamples; i++) {
      // 这里的 i 对应输出的第 i 个点
      // 在输入中的中心位置是 i * 3
      final int centerIndex = i * 3;

      double filteredValue = 0.0;

      // 卷积运算 (应用 FIR 滤波器)
      for (int j = 0; j < filterLength; j++) {
        // 计算对应的输入索引
        final int inputIndex = centerIndex - halfFilterLen + j;

        // 边界检查：如果超出范围，为了简单起见，将其视为0或者取边界值
        if (inputIndex >= 0 && inputIndex < inputSamples) {
          final int sample = inputView.getInt16(inputIndex * 2, Endian.little);
          filteredValue += sample * filterCoefficients[j];
        }
      }

      // 5. 限制范围 (Clipping) 并写入
      int result = filteredValue.round();
      if (result > 32767)
        result = 32767;
      else if (result < -32768) result = -32768;

      outputView.setInt16(i * 2, result, Endian.little);
    }

    return output;
  }

  /// 48kHz 转 8kHz 的高质量重采样
  /// 采用 FIR 低通滤波器防混叠，然后进行 6:1 抽取
  static Uint8List resample48kTo8k(Uint8List input) {
    if (input.isEmpty) return Uint8List(0);

    // 1. 关键修复：正确获取 ByteData 视图，处理 offset
    // 必须加上 offsetInBytes，否则会读取到错误的内存区域（导致电音/噪音）
    final ByteData inputView =
        ByteData.view(input.buffer, input.offsetInBytes, input.lengthInBytes);

    final int inputSamples = input.length ~/ 2;
    // 48k -> 8k 是 6:1 的关系
    final int outputSamples = inputSamples ~/ 6;
    final Uint8List output = Uint8List(outputSamples * 2);
    final ByteData outputView = ByteData.view(output.buffer);

    // 2. 滤波器参数配置
    // 目标是 8kHz，奈奎斯特频率是 4kHz。
    // 为了防止混叠，必须滤除 4kHz 以上的信号。
    // 电话音质标准通常截止在 3.4kHz 左右，我们设为 3500Hz 安全且清晰。
    const double cutoffFrequency = 3500.0;
    const double sampleRate = 48000.0;

    // 滤波器阶数 (Taps)
    // 6倍抽取比3倍抽取需要更陡峭的滤波器来防止混叠。
    // 这里增加到 31 (必须是奇数)，比之前的 11 更平滑，能更好去除高频噪音。
    const int filterLength = 31;
    const int halfFilterLen = filterLength ~/ 2;

    // 3. 生成滤波器系数 (FIR)
    final List<double> filterCoefficients =
        _createLowPassFIR(cutoffFrequency, sampleRate, filterLength);

    // 4. 处理循环：卷积滤波 + 抽取
    for (int i = 0; i < outputSamples; i++) {
      // 这里的 i 对应输出的第 i 个点
      // 在输入中的中心位置是 i * 6 (步长为6)
      final int centerIndex = i * 6;

      double filteredValue = 0.0;

      // 卷积运算
      for (int j = 0; j < filterLength; j++) {
        // 计算对应的输入索引
        final int inputIndex = centerIndex - halfFilterLen + j;

        // 边界检查：防止数组越界
        if (inputIndex >= 0 && inputIndex < inputSamples) {
          final int sample = inputView.getInt16(inputIndex * 2, Endian.little);
          filteredValue += sample * filterCoefficients[j];
        }
      }

      // 5. 限制范围 (Clipping) 并写入
      int result = filteredValue.round();
      if (result > 32767)
        result = 32767;
      else if (result < -32768) result = -32768;

      outputView.setInt16(i * 2, result, Endian.little);
    }

    return output;
  }

  // 生成 FIR 低通滤波器系数 (Sinc 函数 + Hamming 窗)
  static List<double> _createLowPassFIR(
      double cutoffFreq, double sampleRate, int length) {
    final List<double> coefficients = List<double>.filled(length, 0.0);
    final double omegaC = 2.0 * pi * cutoffFreq / sampleRate;
    final int halfLength = length ~/ 2;

    for (int i = 0; i < length; i++) {
      final int n = i - halfLength;

      // 计算 Sinc 函数
      if (n == 0) {
        coefficients[i] = omegaC / pi;
      } else {
        coefficients[i] = sin(omegaC * n) / (pi * n);
      }

      // 应用 Hamming Window 以减少旁瓣
      final double window = 0.54 - 0.46 * cos(2 * pi * i / (length - 1));
      coefficients[i] *= window;
    }

    // 归一化系数，保证增益为 1 (音量不变)
    double sum = coefficients.reduce((a, b) => a + b);
    for (int i = 0; i < length; i++) {
      coefficients[i] /= sum;
    }

    return coefficients;
  }
}
