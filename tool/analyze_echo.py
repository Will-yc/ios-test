#!/usr/bin/env python3
"""离线分析 AEC 自测产出的两段 pcm（aec_on.pcm / aec_off.pcm）。

真机上「AEC 开关两段的 RMS 差」会被本底噪声截断，乍看只有 10~15dB，
其实强回声段能压 20dB 以上、弱回声段已经压到本底。这个脚本把这层拆开：

  1. 整段互相关 -> 端到端延迟（送进播放器 -> 扬声器 -> 麦克风的真实延迟）
     以及「麦克风里的回声有多少是参考的线性副本」（相关系数）
  2. 逐秒算语音带(500-2500Hz)抑制量 -> 看出收敛过程与「受本底限制」的坑

用法：
  python3 tool/analyze_echo.py <目录>          # 目录里放 aec_on.pcm / aec_off.pcm
  python3 tool/analyze_echo.py . --seconds 10  # 指定测试信号时长
"""
import argparse
import os
import sys

import numpy as np

SR = 48000  # 与 kSampleRateRecorder 一致


def build_signal(seconds):
    """必须与 e2e_selftest_page.dart 的 _buildTestSignal 逐行一致。"""
    n = int(SR * seconds)
    t = np.arange(n) / SR
    f0, f1, sweep = 200.0, 3600.0, 1.5
    pos = (t % sweep) / sweep
    f = f0 * (f1 / f0) ** pos
    phase = 2 * np.pi * np.cumsum(f) / SR
    env = 0.30 + 0.70 * (0.5 + 0.5 * np.sin(2 * np.pi * 4 * t - np.pi / 2))
    s = (np.sin(phase) + 0.35 * np.sin(2 * phase)) * env * 0.30
    return (np.clip(s, -1, 1) * 32767).astype(np.int16)


def xcorr(mic, ref):
    n = 1 << 20
    a = np.fft.rfft(mic.astype(np.float64), n)
    b = np.fft.rfft(ref.astype(np.float64), n)
    r = np.fft.irfft(a * np.conj(b), n)
    idx = int(np.argmax(np.abs(r)))
    if idx > n // 2:
        idx -= n
    denom = np.linalg.norm(mic) * np.linalg.norm(ref)
    return idx, (float(r[idx] / denom) if denom > 0 else 0.0)


def band_rms_db(pcm, a, b, lo=500, hi=2500):
    seg = pcm[int(a * SR):int(b * SR)].astype(np.float64) / 32768.0
    if seg.size < 64:
        return -120.0
    spec = np.fft.rfft(seg * np.hanning(seg.size))
    freqs = np.fft.rfftfreq(seg.size, 1 / SR)
    m = (freqs >= lo) & (freqs <= hi)
    energy = np.sum(np.abs(spec[m]) ** 2)
    rms = np.sqrt(energy) / (seg.size / 2) * np.sqrt(2)
    return 20 * np.log10(max(rms, 1e-9))


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("dir", nargs="?", default=".")
    ap.add_argument("--seconds", type=float, default=10.0,
                    help="测试信号时长（要与 App 侧一致）")
    ap.add_argument("--silence", type=float, default=1.0,
                    help="每次录音开头的静音段时长（本底噪声基准）")
    args = ap.parse_args()

    on_p = os.path.join(args.dir, "aec_on.pcm")
    off_p = os.path.join(args.dir, "aec_off.pcm")
    for p in (on_p, off_p):
        if not os.path.exists(p):
            sys.exit(f"缺少 {p}")

    on = np.fromfile(on_p, dtype="<i2")
    off = np.fromfile(off_p, dtype="<i2")
    sig = build_signal(args.seconds)
    print(f"信号 {args.seconds:.0f}s，录音 on={on.size/SR:.2f}s "
          f"off={off.size/SR:.2f}s，静音段 {args.silence:.1f}s")

    # ---- 1. 延迟与线性相关度 ----
    print("\n[1] 端到端延迟与线性相关度（整段，信号起点对齐）")
    for name, pcm in (("AEC关", off), ("AEC开", on)):
        start = int(args.silence * SR)
        mic = pcm[start:start + sig.size]
        if mic.size < sig.size:
            print(f"  {name}: 数据不足")
            continue
        d, c = xcorr(mic, sig)
        print(f"  {name}: 延迟 {d/SR*1000:7.1f} ms, 相关系数 {c:+.3f}")
    print("  相关系数接近 0 = 残余里已经没有参考的线性副本（回声真被消掉了）")

    # ---- 2. 逐秒抑制 ----
    print("\n[2] 逐秒语音带(500-2500Hz)抑制量")
    print("   信号秒   AEC关    AEC开   抑制dB   备注")
    for k in range(int(args.seconds)):
        a = args.silence + k
        b = a + 1.0
        if int(b * SR) > min(on.size, off.size):
            break
        d_off = band_rms_db(off, a, b)
        d_on = band_rms_db(on, a, b)
        note = "← 回声弱，已压到本底" if d_on < d_off - 25 else ""
        print(f"   {k:>3}    {d_off:7.1f}  {d_on:7.1f}  "
              f"{d_off - d_on:6.1f}   {note}")
    print("\n强回声段的抑制量才是真实 ERLE；弱段受本底噪声限制，读数偏小。")


if __name__ == "__main__":
    main()
