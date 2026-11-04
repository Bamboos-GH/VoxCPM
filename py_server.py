"""VoxCPM2 Python 运行时服务壳（T354 · 契约同形替代 llama.cpp-omni C++ 路径）。

背景（2026-11-04）：C++ 本体 = llama.cpp-omni 构建产物，fresh clone 无源无构建，
本机缺 CUDA toolkit；Kit python 已有 voxcpm 2.0.3 + torch cu130 ⇒ 以 Python 引擎
实现**同一 HTTP 契约**（contracts/openapi.json），由 run_voxcpm2_foreground 在
exe 缺失时回落拉起——catalog/客户端/监管器零改动，机器间可并存两种运行时。

契约面（逐条对 openapi.json 快照）：
- POST /v1/audio/speech          → 完整 WAV（binary）
- POST /v1/audio/speech/stream   → 分块 WAV（★偏差：Python 引擎无增量生成接口，
  实现为全量生成后分块 yield——首包不快于全量，客户端语义不受影响，诚实登记）
- GET  /v1/audio/speech/models   → 就绪/信息（catalog readiness 单源）
- POST /v1/voxcpm2/init          → 200 no-op（契约「登记备查，后端不消费」）

语义映射：
- reference_audio(b64 WAV) → prompt_wav_path（参考音频=音色锚，同 C++ 口径）
- seed → torch.manual_seed（确定性意图等价；C++ 为引擎内种子，实现层不同）
- cfg_value / inference_timesteps → 直传 generate
- 输出采样率 = 模型 16kHz（C++ 为 48kHz；下游 _standardize_wav 归一，契约不受影响）
- 无 prompt_text（C++ 同样只吃参考音频；克隆行为差异诚实登记，待人裁后如需可加 ASR 前置）

用法（解释器 = Kit python 共享环境，aligner 判例同源）：
    python py_server.py --port 8123 --models-dir <models_root>/voxcpm2
环境开关：VOXCPM2_PY_OPTIMIZE=1 启用 torch.compile（默认关——Windows 编译期开销大）。
"""

from __future__ import annotations

import argparse
import base64
import io
import json
import os
import tempfile
import threading
from pathlib import Path

# ★模块顶层导入：`from __future__ import annotations`（PEP 563 字符串注解）下，
# FastAPI 的类型解析拿不到 create_app 局部作用域的名字——Request 局部导入会被
# 当成 query 参数（实测 422 "query req Field required"）。
from fastapi import FastAPI, Request, Response
from fastapi.responses import JSONResponse, StreamingResponse

_MODEL = None
_MODEL_LOCK = threading.Lock()
_SAMPLE_RATE = 16000
_MODEL_DIR: Path | None = None


def _models_dir(argv: list[str]) -> Path:
    """--models-dir（catalog 渲染）> DECKTALK_MODELS_DIR/voxcpm2 > 仓内同级 models。"""
    if "--models-dir" in argv:
        root = Path(argv[argv.index("--models-dir") + 1])
    else:
        root = Path(os.environ.get("DECKTALK_MODELS_DIR") or ".") / "voxcpm2"
    # 兼容两布局：目录本身即 HF 权重（含 config.json），或其下 hf/ 子目录（原版权重）
    if (root / "config.json").is_file():
        return root
    return root / "hf"


def _load(model_dir: Path):
    """懒加载（首次请求触发；uvicorn lifespan 前不阻塞监管器探测）。"""
    global _MODEL, _SAMPLE_RATE
    with _MODEL_LOCK:
        if _MODEL is not None:
            return _MODEL
        import torch
        from voxcpm import VoxCPM

        optimize = os.environ.get("VOXCPM2_PY_OPTIMIZE", "0") == "1"
        device = "cuda" if torch.cuda.is_available() else "cpu"
        print(f"[py_server] loading VoxCPM from {model_dir} (device={device}, "
              f"optimize={optimize})", flush=True)
        _MODEL = VoxCPM.from_pretrained(
            str(model_dir), load_denoiser=False, optimize=optimize, device=device)
        try:
            cfg = json.loads((model_dir / "config.json").read_text(encoding="utf-8"))
            _SAMPLE_RATE = int(cfg.get("sample_rate", 16000))
        except Exception:
            pass
        print(f"[py_server] model ready (sr={_SAMPLE_RATE})", flush=True)
        # ★真实输出率以模型实例为准：wrapper 持 tts_model（VoxCPM2Model.sample_rate =
        # audio_vae.out_sample_rate = 48000）；config 顶层 16000 是**编码率**——写错头
        # 会让时长虚胖 3 倍、RTF 虚假劣化（实测踩过）。
        for holder in (_MODEL, getattr(_MODEL, "tts_model", None)):
            sr = getattr(holder, "sample_rate", None)
            if sr:
                _SAMPLE_RATE = int(sr)
                break
        print(f"[py_server] output sample_rate corrected → {_SAMPLE_RATE}", flush=True)
        return _MODEL


def _wav_bytes(waveform) -> bytes:
    import soundfile as sf

    buf = io.BytesIO()
    sf.write(buf, waveform, _SAMPLE_RATE, subtype="PCM_16", format="WAV")
    return buf.getvalue()


def _reference_to_temp(reference_b64: str | None) -> str | None:
    if not reference_b64:
        return None
    fd, tmp = tempfile.mkstemp(suffix=".wav")
    with os.fdopen(fd, "wb") as f:
        f.write(base64.b64decode(reference_b64))
    return tmp


def create_app():
    app = FastAPI(title="voxcpm2-py", version="0.1.0")

    @app.get("/v1/audio/speech/models")
    async def models():
        loaded = _MODEL is not None
        return {"model": "voxcpm", "loaded": loaded, "runtime": "python",
                "sample_rate": _SAMPLE_RATE}

    @app.post("/v1/voxcpm2/init")
    async def init_weights():
        # 契约语义 = 动态加载/切换 GGUF 权重（后端不消费）；Python 运行时按需加载，
        # 此处仅确保已装载并回执。
        _load(_MODEL_DIR)
        return {"ok": True, "runtime": "python"}

    async def _synthesize(req: Request) -> bytes:
        import anyio
        import torch

        body = await req.json()
        text = str(body.get("input") or "")
        if not text:
            return JSONResponse(status_code=422, content={
                "detail": "input is required"})
        seed = body.get("seed")
        if seed is not None:
            torch.manual_seed(int(seed))
            if torch.cuda.is_available():
                torch.cuda.manual_seed_all(int(seed))
        reference = _reference_to_temp(body.get("reference_audio"))
        try:
            model = _load(_MODEL_DIR)
            wave = await anyio.to_thread.run_sync(
                lambda: model.generate(
                    text,
                    prompt_wav_path=reference,
                    cfg_value=float(body.get("cfg_value") or 2.0),
                    inference_timesteps=int(body.get("inference_timesteps") or 10),
                ))
        finally:
            if reference and os.path.exists(reference):
                os.unlink(reference)
        return _wav_bytes(wave)

    @app.post("/v1/audio/speech")
    async def speech(req: Request):
        data = await _synthesize(req)
        if isinstance(data, Response):
            return data
        return Response(content=data, media_type="audio/wav")

    @app.post("/v1/audio/speech/stream")
    async def speech_stream(req: Request):
        # 契约偏差（见模块头注）：全量生成后分块 yield——非真流式
        data = await _synthesize(req)
        if isinstance(data, Response):
            return data

        async def _chunks():
            step = 64 * 1024
            for i in range(0, len(data), step):
                yield data[i:i + step]

        from fastapi.responses import StreamingResponse
        return StreamingResponse(_chunks(), media_type="audio/wav")

    return app


def main(argv: list[str]) -> int:
    global _MODEL_DIR
    ap = argparse.ArgumentParser()
    ap.add_argument("--port", required=True)
    ap.add_argument("--models-dir", default=None)
    args = ap.parse_args(argv)
    argv_eff = ["--models-dir", args.models_dir] if args.models_dir else []
    _MODEL_DIR = _models_dir(argv_eff)
    import uvicorn

    uvicorn.run(create_app(), host="127.0.0.1", port=int(args.port), log_level="warning")
    return 0


if __name__ == "__main__":
    raise SystemExit(main(__import__("sys").argv[1:]))
