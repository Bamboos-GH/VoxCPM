"""对比同一 seed 在不同文本下生成的音频, 验证音色是否保持一致。
音色由频谱包络/基频统计决定, 与文本内容无关。
"""
import sys, wave, numpy as np

def load(path):
    with wave.open(path, 'rb') as w:
        n, sr = w.getnframes(), w.getframerate()
        d = np.frombuffer(w.readframes(n), dtype=np.int16).astype(np.float32) / 32768.0
    if d.ndim > 1: d = d.mean(axis=1)
    return d, sr

def pitch_stats(d, sr):
    # 自相关基频检测 (只在有声段)
    win = int(sr * 0.04)
    pitches = []
    for i in range(0, len(d) - win, win // 2):
        seg = d[i:i+win] * np.hanning(win)
        if np.sqrt((seg**2).mean()) < 0.01: continue
        ac = np.correlate(seg, seg, 'full')[win-1:]
        lo, hi = int(sr/400), int(sr/70)
        if hi >= len(ac): continue
        k = lo + int(np.argmax(ac[lo:hi]))
        f = sr / k
        if 70 <= f <= 400: pitches.append(f)
    return np.array(pitches)

def timbre(d, sr):
    # 频谱重心 + 频谱斜率 (反映音色明亮度)
    n = 1 << int(np.ceil(np.log2(len(d))))
    S = np.abs(np.fft.rfft(d, n))
    fr = np.fft.rfftfreq(n, 1/sr)
    m = fr > 100
    centroid = (S[m]*fr[m]).sum() / S[m].sum() if S[m].sum() > 0 else 0
    # 1-4kHz 能量占比 (人声共振峰区)
    band = ((fr > 1000) & (fr < 4000)).sum()
    ratio = S[(fr>1000) & (fr<4000)].sum() / S[m].sum()
    return centroid, ratio

files = sys.argv[1:]
print(f"{'文件':<22}{'基频中位':>10}{'基频IQR':>9}{'谱重心Hz':>10}{'1-4k占比':>10}{'RMS':>7}")
print("-"*68)
rows=[]
for f in files:
    d, sr = load(f)
    p = pitch_stats(d, sr)
    c, r = timbre(d, sr)
    med = np.median(p) if len(p) else 0
    iqr = (np.percentile(p,75)-np.percentile(p,25)) if len(p) else 0
    rms = np.sqrt((d**2).mean())
    rows.append((f, med, iqr, c, r, rms))
    name = f.split('\\')[-1].split('/')[-1]
    print(f"{name:<22}{med:>10.1f}{iqr:>9.1f}{c:>10.0f}{r:>10.3f}{rms:>7.3f}")

# 计算同 seed 组内的音色离散度
seed = 777
group = [r for r in rows if 'reuse' in r[0]]
cand = [r for r in rows if 'cand_777' in r[0]]
g = group + cand
if len(g) > 1:
    feats = np.array([[r[1], r[3], r[4]] for r in g], dtype=float)
    # 归一化后计算两两距离
    fn = (feats - feats.mean(0)) / (feats.std(0) + 1e-9)
    dmax = 0
    for i in range(len(fn)):
        for j in range(i+1, len(fn)):
            dmax = max(dmax, np.linalg.norm(fn[i]-fn[j]))
    print("-"*68)
    print(f"同 seed(777) 跨 4 段不同文本的最大音色特征距离: {dmax:.3f}")
    print("(<1.0 表示音色高度一致, >2.0 表示差异明显)")
