import 'dart:io';
import 'dart:typed_data';

/// 把裸 PCM（int16-LE / mono）转成标准 WAV。
///
/// 为什么不用 `DualUtil.savePcmToWavFile`：那个实现会把整段 PCM 读进内存
/// （48k/16bit 单声道 10 分钟 = 57MB，再乘上传成 wav 的副本），验证机上是
/// 真会被 OOM killer 干掉的。这里改成「算好长度 → 写 44 字节头 → 分块拷贝」。
Future<String> pcmFileToWav(
  String pcmPath,
  String wavPath, {
  int sampleRate = 48000,
  int channels = 1,
}) async {
  final src = File(pcmPath);
  final len = await src.length();
  // 奇数长度是坏尾字节，直接丢掉（否则 WAV data 段块对齐错乱）
  final dataLen = len - (len % (2 * channels));

  final out = File(wavPath).openWrite();
  try {
    out.add(_wavHeader(dataLen, sampleRate, channels));

    final raf = await src.open();
    try {
      const int chunkSize = 1 << 20; // 1MB
      int remaining = dataLen;
      while (remaining > 0) {
        final n = remaining < chunkSize ? remaining : chunkSize;
        final bytes = await raf.read(n);
        if (bytes.isEmpty) break;
        out.add(bytes);
        remaining -= bytes.length;
      }
    } finally {
      await raf.close();
    }
    await out.flush();
  } finally {
    await out.close();
  }
  return wavPath;
}

Uint8List _wavHeader(int dataLen, int sampleRate, int channels) {
  const int bytesPerSample = 2;
  final int byteRate = sampleRate * channels * bytesPerSample;
  final int blockAlign = channels * bytesPerSample;
  final bd = ByteData(44);

  void str(int offset, String s) {
    for (int i = 0; i < s.length; i++) {
      bd.setUint8(offset + i, s.codeUnitAt(i));
    }
  }

  str(0, 'RIFF');
  bd.setUint32(4, 36 + dataLen, Endian.little);
  str(8, 'WAVE');
  str(12, 'fmt ');
  bd.setUint32(16, 16, Endian.little); // PCM 子块大小
  bd.setUint16(20, 1, Endian.little); // format = PCM
  bd.setUint16(22, channels, Endian.little);
  bd.setUint32(24, sampleRate, Endian.little);
  bd.setUint32(28, byteRate, Endian.little);
  bd.setUint16(32, blockAlign, Endian.little);
  bd.setUint16(34, 16, Endian.little); // bits per sample
  str(36, 'data');
  bd.setUint32(40, dataLen, Endian.little);
  return bd.buffer.asUint8List();
}
