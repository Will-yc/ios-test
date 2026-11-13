#!/usr/bin/env python3
"""成品体检：一次扫出「数字静音断口 / 常驻窄带凹陷 / 分带断带」三类硬伤。

背景（2026-11-13 真机）：门控串联把安静段压到 16bit 量化以下，成品里出现
0.3~0.5s 的纯零段，频谱上是一道竖直断口（用户叫「频谱断裂」）。人耳听是
掉音，普通看波形看不出来，必须逐采样找「≥5ms 的连续零」再看断口前后的电平
衰减形状（平滑淡出 = 增益门；突变 = 丢包，本脚本能直接分开）。

另外两件事顺手查：
  2. 常驻窄带凹陷：逐帧把每个频点与邻域均值比，统计「低 12dB」的帧占比。
     语音谱谷也有 10~20%，但真正的陷波（22dB、常驻）会高出一大截且很窄。
  3. 分带电平：看 8kHz（AEC 高频旁路的分频点）附近有没有断带。

用法：
  python3 tool/analyze_product_health.py <a.wav> [b.wav ...]
纯标准库（wave + 自写 FFT），无需 numpy。
"""
import math
import sys
import wave


def load(path):
    w = wave.open(path, 'rb')
    sr, ch, n = w.getframerate(), w.getnchannels(), w.getnframes()
    raw = w.readframes(n)
    w.close()
    a = list(struct_unpack(raw))
    if ch > 1:
        a = a[0::ch]
    return a, sr


def struct_unpack(raw):
    # array('h') 比 struct.unpack 快一个量级，且是标准库
    import array
    arr = array.array('h')
    arr.frombytes(raw)
    return arr


def fft(xs):
    n = len(xs)
    j = 0
    for i in range(1, n):
        b = n >> 1
        while j & b:
            j ^= b
            b >>= 1
        j ^= b
        if i < j:
            xs[i], xs[j] = xs[j], xs[i]
    l = 2
    while l <= n:
        ang = -2 * math.pi / l
        wl = complex(math.cos(ang), math.sin(ang))
        for i in range(0, n, l):
            w = 1 + 0j
            half = l // 2
            for k in range(i, i + half):
                u = xs[k]
                v = xs[k + half] * w
                xs[k] = u + v
                xs[k + half] = u - v
                w *= wl
        l <<= 1
    return xs


def rms_dbfs(seg):
    if not seg:
        return -999.0
    s = sum(v * v for v in seg) / len(seg)
    return 20 * math.log10(math.sqrt(s) / 32768 + 1e-12)


def zero_runs(a, sr):
    need = int(0.005 * sr)
    runs = []
    i, n = 0, len(a)
    while i < n:
        if a[i] == 0:
            j = i
            while j < n and a[j] == 0:
                j += 1
            if j - i >= need:
                runs.append((i, j - i))
            i = j
        else:
            i += 1
    return runs


def psd(a, sr, t, n=4096):
    s = int(t * sr)
    seg = list(a[s:s + n])
    if len(seg) < n:
        return None
    m = sum(seg) / n
    for i in range(n):
        seg[i] = (seg[i] - m) * (0.5 - 0.5 * math.cos(2 * math.pi * i / n))
    x = fft([complex(v, 0) for v in seg])
    return [abs(v) ** 2 for v in x[:n // 2]]


BANDS = [(300, 1000), (1000, 2000), (2000, 4000), (4000, 6000),
         (6000, 7400), (7400, 7900), (7900, 8300), (8300, 9000),
         (9000, 12000), (12000, 16000), (16000, 20000)]


def band_levels(a, sr):
    n = 4096
    tot = {b: 0.0 for b in BANDS}
    cnt = 0
    t = 0.0
    dur = len(a) / sr
    while t < dur - 0.2:
        p = psd(a, sr, t, n)
        if p:
            voice = sum(p[int(300 * n / sr):int(4000 * n / sr)])
            if voice > 1e6:  # 只看有语音能量的帧
                for b in BANDS:
                    k0, k1 = int(b[0] * n / sr), int(b[1] * n / sr)
                    tot[b] += sum(p[k0:k1]) / max(1, k1 - k0)
                cnt += 1
        t += 0.1
    return {b: 10 * math.log10(tot[b] / max(1, cnt) / n + 1e-12) for b in BANDS}, cnt


def spectrum_dips(a, sr):
    """长时平均谱上的窄带凹陷（真正的陷波会在平均谱里留 -12dB 以下的坑）。

    不用「逐帧比邻域」：单帧谱的 bin 间起伏本来就是 ±10dB 量级，逐帧比邻域会
    有一半频点过线（2048 点实测报 45~59%，全是虚警）。常驻陷波看平均谱更准；
    **间歇**陷波看 `_stats.log` 里的 `notch=` 字段（每秒一行）。
    """
    n = 4096
    nb = n // 2
    acc = [0.0] * nb
    frames = 0
    t = 0.0
    dur = len(a) / sr
    while t < dur - 0.2:
        p = psd(a, sr, t, n)
        if p is not None and sum(p[int(300 * n / sr):int(4000 * n / sr)]) > 1e6:
            for k in range(nb):
                acc[k] += p[k]
            frames += 1
        t += 0.05
    if not frames:
        return [], 0
    pre = [0.0] * (nb + 1)
    for k in range(nb):
        pre[k + 1] = pre[k] + acc[k]
    half = int(300 * n / sr)
    lo, hi = int(1000 * n / sr), int(9500 * n / sr)
    dips = []
    for k in range(lo, hi):
        k0, k1 = max(1, k - half), min(nb, k + half + 1)
        e0, e1 = max(1, k - 3), min(nb, k + 4)
        ref = ((pre[k1] - pre[k0]) - (pre[e1] - pre[e0])) / max(1, (k1 - k0) - (e1 - e0))
        if ref > 0 and acc[k] > 0:
            d = 10 * math.log10(acc[k] / ref)
            if d < -12:  # 22dB 陷波会明显过线，正常谱谷到不了
                dips.append((k * sr / n, d))
    out = []
    for f, d in dips:
        if out and f - out[-1][1] <= 60:
            if d < out[-1][2]:
                out[-1] = (out[-1][0], f, d)
        else:
            out.append((f, f, d))
    return out, frames


def main(paths):
    for p in paths:
        a, sr = load(p)
        dur = len(a) / sr
        print('==', p.split('/')[-1], 'dur %.2fs' % dur, 'rms %.1f' % rms_dbfs(a))
        runs = zero_runs(a, sr)
        print('  数字静音(>=5ms): %d 段，合计 %.2fs' % (len(runs), sum(r[1] for r in runs) / sr))
        for s, L in runs[:6]:
            pre = rms_dbfs(a[max(0, s - int(0.1 * sr)):s])
            post = rms_dbfs(a[s + L:s + L + int(0.1 * sr)])
            print('    %7.3fs 长 %5.0fms  前100ms %6.1f  后100ms %6.1f'
                  % (s / sr, L * 1000 / sr, pre, post))
        dips, frames = spectrum_dips(a, sr)
        if dips:
            print('  常驻窄带凹陷（长时谱 -12dB 以下，%d 语音帧）' % frames,
                  ' '.join('%.0f~%.0fHz:%.0fdB' % (f0, f1, d) for f0, f1, d in dips[:6]))
        else:
            print('  常驻窄带凹陷：无（%d 语音帧，长时谱 1~9.5kHz 无 -12dB 以下窄坑）' % frames)
        lv, cnt = band_levels(a, sr)
        print('  分带电平（%d 语音帧）' % cnt)
        print('   ', '  '.join('%d-%d:%d' % (b[0], b[1], round(lv[b])) for b in BANDS))


if __name__ == '__main__':
    main(sys.argv[1:])
