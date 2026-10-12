# VoxCPM2 许可取证（T44 P0-3，2026-10-12）

> 依据 AGENTS「引擎许可口径」纪律：引入任何引擎前逐件取原文。本目录为取证结论留档。

| 件 | 许可 | 出处（原文位置） |
|---|---|---|
| VoxCPM2 引擎代码 + 官方模型 | **Apache-2.0** | 本仓 `LICENSE`（11,298B，逐字头校验）；HF 模型卡 `OpenBMB/VoxCPM2` = `license: apache-2.0`（hf-mirror.com 取证，2026-10-12；与仓内 LICENSE **双源一致**） |
| llama.cpp-omni 推理引擎 | **MIT**（Copyright 2023-2026 The ggml authors） | `llama.cpp-omni/LICENSE`（21 行 MIT 全文） |
| GGUF 权重（社区转换件） | 继承上游 Apache-2.0 | 转换自官方 openbmb/VoxCPM2（README_local.md:339）；上游模型卡 Apache-2.0 ⇒ 转换件同许可。权重文件：`models/VoxCPM2-BaseLM-Q8_0.gguf`（1.61GB）+ `VoxCPM2-Acoustic-F16.gguf`（1.70GB） |

## 结论

**可免费商用，无 bilibili 类附加条款**（对比 IndexTTS 的 Model Use License：无 §3.4c 类"禁拿输出改进模型"约束、无克隆授权 DISCLAMER 义务——但 DeckTalk 产品面对克隆音色仍自行保留授权留痕字段，属产品纪律而非许可义务）。

## 备注

- 本仓 = OpenBMB/VoxCPM fork + 3 笔本地补丁（本地部署层/service 管理/日志），补丁随仓 Apache-2.0。
- llama.cpp-omni 为**嵌套独立仓**（自带 .git，上游 tc-mb/llama.cpp-omni 可重 clone；.gitignore 已排除其构建产物）。
- 取证时间：2026-10-12（T44 P0-3，会话留痕见 DeckTalk memory/tasks/20261012-T44-*/）。
