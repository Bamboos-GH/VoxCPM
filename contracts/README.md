# VoxCPM2 契约锁（T44 P1-6，2026-10-12）

## 这是什么

`openapi.json` = llama-tts-server HTTP 面的**手写真源**（C++ 服务无自动 openapi，T109/heygem 同款纪律）。
api 仓 `services/api/contracts/voxcpm2-openapi.json` 是本文件的**同步拷贝**；
api 侧 `tests/unit/test_svc_contracts.py` 校验「client 依赖的路径/方法在快照中存在」。

**谁改坏契约，谁的红灯**：引擎侧改接口 → 改本文件 → 同步拷贝到 api 仓（两端任一测试红 = 未同步）。

## 快照与实现的符合性

- 快照依据：`README_local.md`「HTTP API 速查」节（本机实测口径）+ `service.ps1` 冒烟三路径。
- **活体验证挂账**：T44 P0（GPU 窗口）起服后逐路径 curl 核对（快照为手写，未经自动生成，
  首次真机对账前按"未证实"对待响应体内部结构——消费方只判状态码 + WAV 字节）。
- llama-tts-server 为 C++ 实现，无 Python 源可 AST 静态比对（heygem 的引擎侧腿在这里不可复制）；
  引擎侧防漂移 = 上述活体对账 + 本文件版本号演进。

## 消费面

| 消费方 | 路径 | 用途 |
|---|---|---|
| `app/services/voxcpm_service.py::VoxCPM2Service.synthesize` | POST /v1/audio/speech | 非流式合成（生产管线 tts stage voxcpm2 分支） |
| `VoxCPM2Service.synthesize_stream` | POST /v1/audio/speech/stream | 流式合成（试听透传，真流式判定=首包<0.5s） |
| `VoxCPM2Service.models` / `gpu_release is_voxcpm_alive` | GET /v1/audio/speech/models | 探活 |
| （未消费） | POST /v1/voxcpm2/init | 动态换权重，登记备查 |
