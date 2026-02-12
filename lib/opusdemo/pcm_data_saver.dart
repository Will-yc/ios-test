import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:logging/logging.dart';

class PcmDataSaver {
  static const int _wavHeaderSize = 44;
  static final String _prefix = 'PcmDataSaver';
  static final Logger _logger = Logger(_prefix);

  final String _path;

  late final int _sampleRate;
  late final int _sampleBits;
  late final int _channels;
  late final Endian _endian;
  late final File _file;

  int _dataLen = 0;
  RandomAccessFile? _raf;

  PcmDataSaver(
    this._path, {
    int sampleRate = 16000,
    int sampleBits = 16,
    int channels = 1,
    Endian endian = Endian.little,
  }) {
    _sampleRate = sampleRate;
    _sampleBits = sampleBits;
    _channels = channels;
    _endian = endian;
    _file = File(_path);
  }

  /// 打开文件, 写入WAV头(全为0)
  Future<void> open() async {
    try {
      _raf = await _file.open(mode: FileMode.write);
      await _raf?.writeFrom(Uint8List(_wavHeaderSize));
      _logger.fine('$_prefix: Initialized WAV file: $_path');
    } catch (e) {
      await delete();
      _logger.severe('$_prefix: Failed to initialize WAV file: $e');
      rethrow;
    }
  }

  Future<void> openExt() async {
    try {
      _raf = await _file.open(mode: FileMode.write);
    } catch (e) {
      await delete();
      rethrow;
    }
  }

  /// 写入数据
  Future<void> write(List<int> data) async {
    try {
      _dataLen += data.length;
      await _raf?.writeFrom(data);
    } catch (e) {
      _logger.severe('$_prefix: Error writing data: $e');
      await delete();
      rethrow;
    }
  }

  /// 更新文件头信息, 清理资源
  Future<void> close() async {
    try {
      await _raf?.setPosition(0x00);
      final header = await _wavHeader();
      await _raf?.writeFrom(header);

      _logger.fine('$_prefix: Updated WAV header - data size: $_dataLen');
    } catch (e) {
      _logger.severe('$_prefix: Failed to update header: $e');
      rethrow;
    } finally {
      await _cleanup();
    }
  }

  /// 清理资源, 删除文件
  Future<void> delete() async {
    await _cleanup();

    if (await _file.exists()) {
      await _file.delete();
      _logger.info('$_prefix: Deleted file: $_path');
    }
  }

  Future<void> _cleanup() async {
    try {
      await _raf?.close();
      _raf = null;
    } catch (e) {
      _logger.warning('$_prefix: Error during cleanup: $e');
    }
  }

  Future<Uint8List> _wavHeader() async {
    final int frameSize = ((_sampleBits + 7) ~/ 8) * _channels;
    ByteData data = ByteData(_wavHeaderSize);
    data.setUint32(0x04, _dataLen + _wavHeaderSize - 8, _endian); // 文件大小
    data.setUint32(0x10, 16, _endian);
    data.setUint16(0x14, 1, _endian);
    data.setUint16(0x16, _channels, _endian);
    data.setUint32(0x18, _sampleRate, _endian);
    data.setUint32(0x1C, _sampleRate * frameSize, _endian);
    data.setUint16(0x20, frameSize, _endian);
    data.setUint16(0x22, _sampleBits, _endian);
    data.setUint32(0x28, _dataLen, _endian); // 数据大小
    Uint8List bytes = data.buffer.asUint8List();
    bytes.setAll(0x00, ascii.encode('RIFF'));
    bytes.setAll(0x08, ascii.encode('WAVE'));
    bytes.setAll(0x0C, ascii.encode('fmt '));
    bytes.setAll(0x24, ascii.encode('data'));
    return bytes;
  }
}
