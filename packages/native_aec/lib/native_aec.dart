import 'dart:ffi';
import 'dart:io';
import 'dart:typed_data';

import 'package:ffi/ffi.dart';

/// WebRTC AEC3 动态库句柄。
///
/// · Android：插件 CMake 产出 `libnative_aec.so`
/// · iOS：静态链接进主二进制，符号在主模块里
/// · 桌面（仅本地验证用）：把 .so 放在 LD_LIBRARY_PATH 里即可
final DynamicLibrary _dylib = Platform.isIOS
    ? DynamicLibrary.process()
    : DynamicLibrary.open('libnative_aec.so');

typedef _Aec3CreateC = Pointer<Void> Function(Int32 sampleRate, Int32 channels);
typedef _Aec3CreateD = Pointer<Void> Function(int sampleRate, int channels);

typedef _Aec3HandleOnlyC = Void Function(Pointer<Void> handle);
typedef _Aec3HandleOnlyD = void Function(Pointer<Void> handle);

typedef _Aec3SetFlagC = Void Function(Pointer<Void> handle, Int32 enable);
typedef _Aec3SetFlagD = void Function(Pointer<Void> handle, int enable);

typedef _Aec3SetNlpC = Void Function(Pointer<Void> handle, Int32 level);
typedef _Aec3SetNlpD = void Function(Pointer<Void> handle, int level);

typedef _Aec3PushRefC =
    Int32 Function(Pointer<Void> handle, Pointer<Int16> pcm, Int32 samples);
typedef _Aec3PushRefD =
    int Function(Pointer<Void> handle, Pointer<Int16> pcm, int samples);

typedef _Aec3ProcessC =
    Int32 Function(
      Pointer<Void> handle,
      Pointer<Int16> input,
      Int32 samples,
      Pointer<Int16> output,
    );
typedef _Aec3ProcessD =
    int Function(
      Pointer<Void> handle,
      Pointer<Int16> input,
      int samples,
      Pointer<Int16> output,
    );

typedef _Aec3StatsC =
    Void Function(
      Pointer<Void> handle,
      Pointer<Int32> inDb10,
      Pointer<Int32> outDb10,
      Pointer<Int32> frames,
      Pointer<Int32> starved,
    );
typedef _Aec3StatsD =
    void Function(
      Pointer<Void> handle,
      Pointer<Int32> inDb10,
      Pointer<Int32> outDb10,
      Pointer<Int32> frames,
      Pointer<Int32> starved,
    );

typedef _Aec3VersionC = Pointer<Utf8> Function();
typedef _Aec3VersionD = Pointer<Utf8> Function();

/// AEC3 符号表 —— **必须延迟加载**。
///
/// 顶层 `final` 里的 lookup 会在动态库被 dlopen 的瞬间执行。如果某个 ABI
/// 没有链接 APM，lookup 会抛 ArgumentError，把整个插件一起废掉。
/// 用 lazy + try/catch，拿不到符号就退化成直通。
class _Aec3Ffi {
  const _Aec3Ffi({
    required this.create,
    required this.destroy,
    required this.reset,
    required this.pushRef,
    required this.process,
    required this.stats,
    required this.version,
    this.setHighBandBypass,
    this.setNlpLevel,
  });

  final _Aec3CreateD create;
  final _Aec3HandleOnlyD destroy;
  final _Aec3HandleOnlyD reset;
  final _Aec3PushRefD pushRef;
  final _Aec3ProcessD process;
  final _Aec3StatsD stats;
  final _Aec3VersionD version;
  // 旧版 native 库没有这个符号，缺失时置 null（自动退回旧行为），不能让
  // 整个 FFI 初始化失败 —— 否则录音会连 AEC 一起退化成直通。
  final _Aec3SetFlagD? setHighBandBypass;
  // 同上：旧库没有 NLP 分级符号时置 null，保持创建时的默认档。
  final _Aec3SetNlpD? setNlpLevel;

  static bool _tried = false;
  static _Aec3Ffi? _instance;

  static _Aec3Ffi? get instance {
    if (_tried) return _instance;
    _tried = true;
    _Aec3SetFlagD? setFlag;
    try {
      setFlag = _dylib
          .lookup<NativeFunction<_Aec3SetFlagC>>('aec3_set_high_band_bypass')
          .asFunction();
    } catch (_) {
      setFlag = null; // 旧库：保持旧行为
    }
    _Aec3SetNlpD? setNlp;
    try {
      setNlp = _dylib
          .lookup<NativeFunction<_Aec3SetNlpC>>('aec3_set_nlp_level')
          .asFunction();
    } catch (_) {
      setNlp = null; // 旧库：保持默认档
    }
    try {
      _instance = _Aec3Ffi(
        create: _dylib
            .lookup<NativeFunction<_Aec3CreateC>>('aec3_create')
            .asFunction(),
        destroy: _dylib
            .lookup<NativeFunction<_Aec3HandleOnlyC>>('aec3_destroy')
            .asFunction(),
        reset: _dylib
            .lookup<NativeFunction<_Aec3HandleOnlyC>>('aec3_reset')
            .asFunction(),
        pushRef: _dylib
            .lookup<NativeFunction<_Aec3PushRefC>>('aec3_push_reference')
            .asFunction(),
        process: _dylib
            .lookup<NativeFunction<_Aec3ProcessC>>('aec3_process_capture')
            .asFunction(),
        stats: _dylib
            .lookup<NativeFunction<_Aec3StatsC>>('aec3_get_stats')
            .asFunction(),
        version: _dylib
            .lookup<NativeFunction<_Aec3VersionC>>('aec3_build_info')
            .asFunction(),
        setHighBandBypass: setFlag,
        setNlpLevel: setNlp,
      );
    } catch (_) {
      _instance = null;
    }
    return _instance;
  }
}

/// AEC3 运行统计，用于现场判断"它到底有没有在工作"。
class Aec3Stats {
  final double inputDbfs;
  final double outputDbfs;
  final int processedFrames;
  final int refStarvedFrames;

  const Aec3Stats({
    required this.inputDbfs,
    required this.outputDbfs,
    required this.processedFrames,
    required this.refStarvedFrames,
  });

  /// 回声抑制量（dB）。只开 AEC 时，这个值就是 ERLE 的近似。
  double get suppressionDb => inputDbfs - outputDbfs;

  @override
  String toString() =>
      'in=${inputDbfs.toStringAsFixed(1)}dBFS '
      'out=${outputDbfs.toStringAsFixed(1)}dBFS '
      '抑制=${suppressionDb.toStringAsFixed(1)}dB '
      '帧=$processedFrames 缺参考=$refStarvedFrames';
}

class Aec3Processor {
  Aec3Processor._(this._ffi, this._handle, this.sampleRate);

  final _Aec3Ffi _ffi;
  final Pointer<Void> _handle;
  final int sampleRate;
  bool _disposed = false;

  // 三个复用的原生缓冲（每 20ms 就要用一次，不能每次 calloc/free）
  Pointer<Int16>? _refPtr;
  int _refCap = 0;
  Pointer<Int16>? _capPtr;
  int _capCap = 0;
  Pointer<Int16>? _outPtr;
  int _outCap = 0;

  /// 创建失败（库缺失 / 该 ABI 未链接 APM / 参数不支持）返回 null，
  /// 调用方应降级为直通 —— 不影响录音本身，只是没有回声消除。
  static Aec3Processor? tryCreate({
    int sampleRate = 48000,
    bool highBandBypass = false,
    int nlpLevel = 2,
  }) {
    final ffi = _Aec3Ffi.instance;
    if (ffi == null) return null;
    try {
      final h = ffi.create(sampleRate, 1);
      if (h == nullptr) return null;
      final proc = Aec3Processor._(ffi, h, sampleRate);
      proc._highBandBypass = proc.setHighBandBypass(highBandBypass);
      proc.setNlpLevel(nlpLevel);
      return proc;
    } catch (_) {
      return null;
    }
  }

  /// 本次是否真的启用了高频旁路（旧库缺符号、非 48kHz 时为 false）。
  bool _highBandBypass = false;
  bool get highBandBypassEnabled => _highBandBypass;

  /// 开/关高频旁路。返回是否生效。
  bool setHighBandBypass([bool enable = true]) {
    final set = _ffi.setHighBandBypass;
    if (_disposed || set == null) return false;
    set(_handle, enable ? 1 : 0);
    return enable && sampleRate == 48000;
  }

  /// 当前 NLP（残余抑制）档位。0=默认 / 1=温和 / 2=狠 / 3=极狠。
  int _nlpLevel = 2;
  int get nlpLevel => _nlpLevel;

  /// 切换 NLP 档（对标 TRTC aec_nlp_level）。返回 native 是否支持并执行。
  /// 旧库缺符号时返回 false（保持创建时默认档）。换档会重建 APM、重新收敛 ~1s。
  bool setNlpLevel(int level) {
    final set = _ffi.setNlpLevel;
    if (_disposed || set == null) return false;
    final int clamped = level < 0 ? 0 : (level > 3 ? 3 : level);
    set(_handle, clamped);
    _nlpLevel = clamped;
    return true;
  }

  bool get isDisposed => _disposed;

  /// 喂入"正在播给扬声器"的 PCM（int16-LE 单声道）。
  void pushReference(Uint8List pcm) {
    if (_disposed || pcm.length < 2) return;
    final int samples = pcm.length ~/ 2;
    final Pointer<Int16> p = _refBuffer(samples);
    p.cast<Uint8>().asTypedList(samples * 2).setAll(0, pcm);
    _ffi.pushRef(_handle, p, samples);
  }

  /// 处理一段采集数据，返回消除后的 PCM。
  ///
  /// 返回值长度**可能不等于**输入（按 10ms 帧对齐），调用方必须按实际返回
  /// 长度推进时间轴。返回空列表表示"还不够一帧，攒着"。
  Uint8List processCapture(Uint8List pcm) {
    if (_disposed || pcm.length < 2) return Uint8List(0);
    final int samples = pcm.length ~/ 2;

    _capPtr = _capBuffer(samples);
    _capPtr!.cast<Uint8>().asTypedList(samples * 2).setAll(0, pcm);

    // 输出可能比输入多出不到一帧的残留（内部 pending 回吐）
    final int outNeed = samples + 512;
    _outPtr = _outBuffer(outNeed);

    final int written = _ffi.process(_handle, _capPtr!, samples, _outPtr!);
    if (written <= 0) return Uint8List(0);

    final out = Uint8List(written * 2);
    out.setAll(0, _outPtr!.cast<Uint8>().asTypedList(written * 2));
    return out;
  }

  /// 清内部状态（换文件/续录）：滤波器保留，只清帧缓存与统计。
  void reset() {
    if (_disposed) return;
    _ffi.reset(_handle);
  }

  Aec3Stats? stats() {
    if (_disposed) return null;
    final p = calloc<Int32>(4);
    try {
      _ffi.stats(_handle, p, p + 1, p + 2, p + 3);
      return Aec3Stats(
        inputDbfs: p[0] / 10.0,
        outputDbfs: p[1] / 10.0,
        processedFrames: p[2],
        refStarvedFrames: p[3],
      );
    } finally {
      calloc.free(p);
    }
  }

  void dispose() {
    if (_disposed) return;
    _disposed = true;
    _ffi.destroy(_handle);
    for (final p in [_refPtr, _capPtr, _outPtr]) {
      if (p != null) calloc.free(p);
    }
    _refPtr = null;
    _capPtr = null;
    _outPtr = null;
  }

  // 预留 2 倍容量，避免每帧都 realloc。
  // 容量只在**真正重新分配**时更新，复用路径不动，否则会虚报导致越界写。
  Pointer<Int16> _refBuffer(int need) {
    if (_refPtr != null && _refCap >= need) return _refPtr!;
    if (_refPtr != null) calloc.free(_refPtr!);
    _refCap = need * 2;
    _refPtr = calloc<Int16>(_refCap);
    return _refPtr!;
  }

  Pointer<Int16> _capBuffer(int need) {
    if (_capPtr != null && _capCap >= need) return _capPtr!;
    if (_capPtr != null) calloc.free(_capPtr!);
    _capCap = need * 2;
    _capPtr = calloc<Int16>(_capCap);
    return _capPtr!;
  }

  Pointer<Int16> _outBuffer(int need) {
    if (_outPtr != null && _outCap >= need) return _outPtr!;
    if (_outPtr != null) calloc.free(_outPtr!);
    _outCap = need * 2;
    _outPtr = calloc<Int16>(_outCap);
    return _outPtr!;
  }
}

/// 底层 WebRTC APM 的版本串。null 表示动态库没加载 / 符号缺失。
String? aec3BuildInfo() {
  try {
    final ffi = _Aec3Ffi.instance;
    if (ffi == null) return null;
    final p = ffi.version();
    if (p == nullptr) return null;
    return p.toDartString();
  } catch (_) {
    return null;
  }
}

/// 该平台是否真的具备 AEC3 能力（库加载 + 符号可解析 + 实例可创建）。
bool aec3Available() {
  final p = Aec3Processor.tryCreate();
  if (p == null) return false;
  p.dispose();
  return true;
}
