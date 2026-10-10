"""用 ASR 听写 VoxCPM2 生成的音频, 验证文本规范化(数字/日期/缩写)是否正常。
用法: python tools/verify_tts_text.py 生成的.wav "原始输入文本" [--model small]

默认用 small 模型: tiny 对数字/繁体识别不可靠(实测把 2026 听成 2016、5999 听成 59999),
会误导结论。small 才够做数字正确性判断。
"""
import sys
import warnings
warnings.filterwarnings("ignore")
from faster_whisper import WhisperModel

wav = sys.argv[1]
expected = sys.argv[2]

model_size = "small"
if "--model" in sys.argv:
    model_size = sys.argv[sys.argv.index("--model") + 1]

# fast-whisper CPU 推理(int8), 不占 GPU 显存
model = WhisperModel(model_size, device="cpu", compute_type="int8")
segments, info = model.transcribe(wav, language="zh", beam_size=5)
text = "".join(s.text for s in segments)
print(f"[期望]   {expected}")
print(f"[听写]   {text.strip()}")

# 抽出期望中的数字/英文串, 看是否出现在听写里
import re
tokens = re.findall(r'[A-Za-z]{2,}|\d+(?:\.\d+)?', expected)
if tokens:
    heard = text.replace(" ", "").replace(",", "").replace("，", "")
    miss = [t for t in tokens if t not in heard]
    print(f"[关键]   {tokens}")
    print(f"[缺失]   {miss if miss else '无'}")
    if miss:
        print("[结论]   有 token 未听出, 需进一步排查(TTS 读错 或 ASR 误识)")
    else:
        print("[结论]   关键 token 均听出, 文本规范化无明显问题")
