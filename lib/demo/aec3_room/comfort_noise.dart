import 'dart:math' as math;
import 'dart:typed_data';

/// 底噪垫（Comfort Noise）—— 成品链路最后一道「地板保护」。
///
/// ## 为什么必须加
/// 相关门（−34dB）与底噪门（−19dB）是**串联**的，下行有人说话而本端静音时
/// 两层同时收到最狠，合计 −53dB。室内底噪本来只有 −60dBFS 量级（18 LSB），
/// 再乘 0.0022 就落到 0.04 LSB —— 16bit 取整后是**整段数字静音**。
/// 2026-11-13 真机成品实测：Android 端 48.56s 里有 0.77s 纯零段，集中在
/// 7.0~7.36s 与 12.08~12.25s，各是一段 ~0.4s 的平滑衰减（−54 → −70 → −83
/// → −99 → −113dBFS）然后突然回升 —— 频谱上就是一道竖直断口，听感像掉音。
///
/// ## 做法
/// 不改变门的判决，只在门之后**补差额**：
///  目标电平 = 底噪门估的室内底噪 − 19dB（= 底噪门平时在安静段留下的那个电平），
///  当前帧低于目标时，补 RMS = sqrt(target² − cur²) 的白噪声（与残余不相关，
///  能量可直接相加）；高于目标的帧一个采样都不动。
///
/// 这样安静段（只有底噪门）与回声抑制段（两个门一起）的**地板电平一致**，
/// 频谱上看不出断口，也不会把噪声垫到能听出来的程度（目标上限 −60dBFS）。
class ComfortNoise {
  ComfortNoise({
    this.floorOffsetDb = 19.0,
    this.minTargetDbfs = -84.0,
    this.maxTargetDbfs = -60.0,
  });

  /// 目标地板相对室内底噪的偏移，与 NoiseGate.minGain（−19dB）对齐。
  final double floorOffsetDb;

  /// 目标下限：−84dBFS ≈ 2 LSB，再低就又被量化成 0。
  final double minTargetDbfs;

  /// 目标上限：补出来的噪声必须始终听不见。
  final double maxTargetDbfs;

  /// 室内底噪锚点（dBFS）。只快降、极慢升（0.2dB/s）。
  ///
  /// 不能直接拿底噪门的实时估值当锚：下行持续说话时 AEC 输出一直在噪底之上，
  /// 底噪门的慢升会把估值每秒抬高 ~7.5dB，补给噪声的噪声垫就会被抬到听得见
  /// （甚至误判语音）。这里只记住「最近最安静时的电平」，语言段的抬升进不来。
  double _anchorDb = -90;
  bool _anchorInit = false;

  int _rng = 0x2545F491;

  /// 返回**新的** int16-LE 缓冲；不需要补时原样返回入参。
  Uint8List process(Uint8List pcm, double roomFloorDbfs) {
    if (pcm.length < 2) return pcm;
    final int n = pcm.length ~/ 2;
    final ByteData bd = ByteData.view(pcm.buffer, pcm.offsetInBytes, n * 2);

    double sumSq = 0;
    for (int i = 0; i < n; i++) {
      final double v = bd.getInt16(i * 2, Endian.little).toDouble();
      sumSq += v * v;
    }
    final double curRms = math.sqrt(sumSq / n);

    if (!_anchorInit) {
      // 起播时底噪门的估值可能还停在前几帧的语音电平上，不能直接拿来当锚，
      // 先给一个保守初值（真值更低时立刻跟下去，更高则慢慢爬上来）。
      _anchorDb = math.min(roomFloorDbfs, -70.0);
      _anchorInit = true;
    } else if (roomFloorDbfs < _anchorDb) {
      _anchorDb = roomFloorDbfs;
    } else {
      _anchorDb = math.min(_anchorDb + 0.002, roomFloorDbfs);
    }

    double targetDb = _anchorDb - floorOffsetDb;
    if (targetDb < minTargetDbfs) targetDb = minTargetDbfs;
    if (targetDb > maxTargetDbfs) targetDb = maxTargetDbfs;
    final double targetRms = 32768.0 * math.pow(10, targetDb / 20);

    if (curRms >= targetRms) return pcm;

    // 均匀分布的 RMS 是幅度/√3，按这个把噪声缩到要补的 RMS。
    final double needRms =
        math.sqrt(targetRms * targetRms - curRms * curRms);
    final double scale = needRms * 1.7320508075688772;

    final ByteData out = ByteData(n * 2);
    for (int i = 0; i < n; i++) {
      final int cur = bd.getInt16(i * 2, Endian.little);
      final double u = (_next() / 2147483648.0) - 1.0; // [-1, 1)
      out.setInt16(
        i * 2,
        (cur + u * scale).round().clamp(-32768, 32767),
        Endian.little,
      );
    }
    return out.buffer.asUint8List();
  }

  int _next() {
    int x = _rng;
    x ^= (x << 13) & 0xFFFFFFFF;
    x ^= x >> 17;
    x ^= (x << 5) & 0xFFFFFFFF;
    _rng = x & 0xFFFFFFFF;
    return _rng;
  }

  void reset() {
    _rng = 0x2545F491;
    _anchorDb = -90;
    _anchorInit = false;
  }
}
