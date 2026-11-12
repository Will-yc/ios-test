#!/usr/bin/env python3
"""分析 AEC 后的落盘 pcm：长时平均频谱、频带能量、峰值频点。

只依赖 numpy。用法：
    python analyze_spectrum.py a.pcm [b.pcm ...]
"""
import sys
import numpy as np

SR = 48000
NFFT = 2048          # 42.7ms 窗
HOP = 1024
WIN = np.hanning(NFFT)

BANDS = [
    ("20-100   Hz", 20, 100),
    ("100-300  Hz", 100, 300),
    ("300-1k   Hz", 300, 1000),
    ("1k-2k    Hz", 1000, 2000),
    ("2k-4k    Hz", 2000, 4000),
    ("4k-8k    Hz", 4000, 8000),
    ("8k-12k   Hz", 8000, 12000),
    ("12k-16k  Hz", 12000, 16000),
    ("16k-20k  Hz", 16000, 20000),
    ("20k-24k  Hz", 20000, 24000),
]


def load(path):
    x = np.fromfile(path, dtype="<i2").astype(np.float64) / 32768.0
    return x


def frame_spectra(x):
    n = 1 + max(0, (len(x) - NFFT) // HOP)
    if n <= 0:
        return None
    idx = np.arange(NFFT)[None, :] + HOP * np.arange(n)[:, None]
    frames = x[idx] * WIN
    spec = np.fft.rfft(frames, axis=1)
    p = (np.abs(spec) ** 2) / (WIN.sum() ** 2) * 2.0   # 单边功率归一化
    return p  # (frames, bins)


def frame_db(p):
    return 10 * np.log10(np.maximum(p, 1e-20))


def analyze(path):
    x = load(path)
    dur = len(x) / SR
    print("=" * 74)
    print(f"{path}   {len(x)} 样本 = {dur:.2f}s")

    p = frame_spectra(x)
    if p is None:
        print("  太短，跳过")
        return
    fdb = frame_db(p)
    freqs = np.fft.rfftfreq(NFFT, 1 / SR)

    # 帧级总功率（dBFS），用来分「有声帧 / 静音帧」
    frame_pow = p.sum(axis=1)
    frame_db_total = 10 * np.log10(np.maximum(frame_pow, 1e-20))
    # 全带 RMS 校准：Parseval 下 sum(p) 约等于带内均方
    frame_rms_db = 10 * np.log10(np.maximum(frame_pow, 1e-20) / (NFFT / 2))

    thr = np.percentile(frame_rms_db, 70) - 12.0     # 相对阈值
    active = frame_rms_db > thr
    print(f"  帧数 {len(freqs) and len(frame_rms_db)}（{NFFT}点/{HOP}跳，{NFFT/SR*1000:.1f}ms）"
          f"  有声帧 {active.sum()} ({active.mean()*100:.0f}%)  阈值 {thr:.1f} dBFS")

    # 长时平均谱（功率平均，再转 dB）
    p_all = p.mean(axis=0)
    p_act = p[active].mean(axis=0) if active.any() else p_all
    p_quiet = p[~active].mean(axis=0) if (~active).any() else p_all

    def band_table(psd, title):
        total = psd.sum()
        print(f"\n  {title}")
        print("    频带               能量占比    绝对电平")
        cum = 0.0
        for name, lo, hi in BANDS:
            m = (freqs >= lo) & (freqs < hi)
            e = psd[m].sum()
            ratio = e / total * 100 if total > 0 else 0
            # 带内 RMS（dBFS）：把该带功率积分换成时域均方
            rms = 10 * np.log10(max(e / (NFFT / 2), 1e-20))
            cum += ratio
            print(f"    {name:12s}  {ratio:7.1f}%    {rms:7.1f} dBFS")
        return cum

    band_table(p_act, "有声帧（语音为主）的频带能量")
    band_table(p_quiet, "静音帧（只剩残余/本底）的频带能量")

    # 峰值频点（有声帧）
    top = np.argsort(p_act)[-8:][::-1]
    print("\n  有声帧里能量最高的 8 个频点：")
    for i in top:
        print(f"    {freqs[i]:7.1f} Hz   {10*np.log10(max(p_act[i],1e-20)):7.1f} dB")

    # 静音帧 vs 有声帧 的差（残余主要落在哪）
    diff = 10 * np.log10(np.maximum(p_act, 1e-20)) - 10 * np.log10(np.maximum(p_quiet, 1e-20))
    print("\n  有声帧 − 静音帧（dB，越大说明该带语音成分越强）：")
    for name, lo, hi in BANDS:
        m = (freqs >= lo) & (freqs < hi)
        if m.any():
            print(f"    {name:12s}  {diff[m].mean():6.1f} dB")

    # 高频占比（回声残留多在中低频，高频多来自齿音/底噪）
    hi_mask = freqs >= 8000
    print(f"\n  8k 以上能量占全带 {p_act[hi_mask].sum()/p_act.sum()*100:.2f}%"
          f"（正常语音通常 <2%）")
    print(f"  全带整体 RMS ≈ {10*np.log10(max(p_act.sum()/(NFFT/2),1e-20)):.1f} dBFS")


if __name__ == "__main__":
    for f in sys.argv[1:]:
        analyze(f)
