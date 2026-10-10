# VoxCPM2 本地部署

基于 **llama.cpp-omni** 量化推理引擎的 VoxCPM2 本地部署，针对 8GB 显存的 RTX 4060 Laptop 优化。

## 环境信息

| 项目 | 配置 |
|---|---|
| GPU | RTX 4060 Laptop，8GB 显存 |
| 模型 | VoxCPM2（20亿参数） |
| 推理引擎 | llama.cpp-omni（GGUF 量化） |
| 模型文件 | BaseLM-Q8_0 (1.61GB) + Acoustic-F16 (1.70GB) |
| 输出采样率 | 48kHz |

## 实测性能（RTX 4060 Laptop 8GB）

| 场景 | RTF | 3.5秒音频耗时 | 模型加载 |
|---|---|---|---|
| 显存被 ComfyUI 占用 6.1GB | 4.48 | 17.9s | 34s |
| **显存空闲 7.9GB（推荐）** | **0.634** | **2.2s** | 8.7s |

> RTF < 1.0 即快于实时。**建议生成前关闭 ComfyUI 等占用显存的程序**，速度差 5.6 倍。
> HTTP 服务模式下单次请求 1-2 秒（含网络开销）。

## 功能

- **音色设计** — 用自然语言描述凭空创建音色，无需参考音频
- **声音克隆** — 从参考音频片段克隆声音
- **极致克隆** — 提供参考音频及其文本，实现高保真续写克隆
- **30 种语言 + 9 种中文方言**

---

## 快速开始

### 方式一：`tts.ps1`（推荐，自动选择服务/CLI）

```powershell
# 音色设计（括号内为音色描述）
powershell tts.ps1 design "(年轻女性,声音温柔甜美)你好,欢迎使用本地语音合成!"

# 流式传输（首包 ~0.1s，适合实时播放；需服务已启动）
powershell tts.ps1 design "(年轻女性,声音温柔甜美)你好!" -Stream

# 响度归一化（消除不同音色的音量差异，强烈推荐多角色场景使用）
powershell tts.ps1 design "(年轻女性,声音温柔甜美)你好!" -Normalize

# 声音克隆（-Reference 参考音频）
powershell tts.ps1 clone "这是克隆出来的声音。" -Reference speaker.wav

# 极致克隆（需提供参考音频的实际文本）
powershell tts.ps1 hifi "要合成的新内容。" -Reference speaker.wav -PromptText "参考音频里说的一句话"

# 公共参数: -Out 输出.wav  -Seed 42  -Cfg 2.0  -Timesteps 10  -Stream  -Normalize
# 归一化目标: -TargetLufs -19  -TruePeak -1.0（默认即推荐值）
```

### 方式二：HTTP 服务（长期常驻）

```powershell
powershell service.ps1 start       # 启动（后台无窗口，日志写 logs/）
powershell service.ps1 status       # 进程/端口/显存/模型
powershell service.ps1 stop         # 停止
powershell service.ps1 restart      # 重启
powershell service.ps1 logs -Tail 50  # 查看日志
powershell service.ps1 test         # 冒烟测试（音色设计/克隆/流式三条路径）
powershell service.ps1 health       # 健康检查，返回退出码（0=健康，可用于监控）
powershell service.ps1 autostart    # 启用开机自启（启动文件夹，无需管理员权限）
powershell service.ps1 noautostart  # 取消开机自启
```

> 开机自启用「启动文件夹 + VBS 隐藏启动」实现，下次登录会自动静默拉起服务于 `8099` 端口。
> 若需换端口：`powershell service.ps1 start -Port 8100`（autostart 写死 8099，需同时改 `autostart-hidden.vbs`）。

服务启动后，任何 OpenAI 兼容客户端都能直接调用：

```bash
# 音色设计
curl http://127.0.0.1:8099/v1/audio/speech \
  -H "Content-Type: application/json" \
  -d '{"model":"voxcpm","input":"(年轻女性,温柔甜美)你好世界！","voice":"default","seed":42}' \
  --output out.wav

# 流式（首包 ~0.1s，边生成边下载）
curl -N http://127.0.0.1:8099/v1/audio/speech/stream \
  -H "Content-Type: application/json" \
  -d '{"model":"voxcpm","input":"(年轻女性,温柔甜美)你好世界！","voice":"default","seed":42}' \
  --output out.wav
```

---

## 流式合成（实测）

HTTP 服务支持真流式（非"先生成完再分块"），分块粒度约 **320ms 音频 / chunk**。

**RTX 4060 Laptop 8GB 实测：**

| 指标 | 数值 |
|---|---|
| **TTFA（首包延迟，热身后）** | **0.10 ~ 0.11 s** |
| TTFA（首次请求，CUDA graph 预热） | ~0.40 s |
| 非流式首包对比 | 1.4 ~ 1.8 s（**流式快 14 倍**） |
| 5.28s 音频总传输耗时 | 2.52 s |
| 1.92s 音频总传输耗时 | 0.85 ~ 0.90 s |

> TTFA 0.10s 已进入实时对话区间（人类对话反应约 200ms），可用于边生成边播放的场景。
> 实现要点：HTTP 用 chunked 传输；AudioVAE 采用 stateful 解码，每个 patch 只算一次，因果卷积上下文跨 chunk 延续（避免 N× 重解码和接缝伪影）；客户端断开时自动取消后续解码。

---

## 响度归一化（LUFS）

**为什么需要**：VoxCPM2 不同音色的输出响度差异极大。实测三个音色归一化前：

| 音色 | 响度 | True Peak |
|---|---|---|
| 轻柔气声 | **-31.42 LUFS** | -15.97 dBTP |
| 标准播音 | -15.59 LUFS | -0.15 dBTP |
| 激昂洪亮 | **-11.98 LUFS** | -0.14 dBTP |

跨度 **19.4 LU**（1 LU 即人耳可辨）。不处理的话，"轻柔"那个音色必须手动把音量拉高 12 dB 才能听清，做多角色配音时体验灾难。

**用法**（基于成熟工具 `ffmpeg-normalize`，非自研逻辑）：

```powershell
# 生成时自动归一化
powershell tts.ps1 design "(年轻女性,温柔甜美)你好!" -Normalize

# 单独归一化已有文件（默认 -19 LUFS）
ffmpeg-normalize out.wav -nt ebu -t -19 -tp -1.0 -c:a pcm_s16le -f -o out_norm.wav

# 批量归一化整个目录，并保持相互间的相对响度（有声书/多角色场景）
ffmpeg-normalize *.wav --batch -nt ebu -t -19 -tp -1.0 -c:a pcm_s16le -f -ext wav

# 只降不升（避免提升已经很响的内容）
ffmpeg-normalize out.wav -nt ebu -t -19 --lower-only -c:a pcm_s16le -f -o out_norm.wav
```

**目标值 -19 LUFS 的依据**：Google Assistant 官方 TTS 规范——"mono 内容建议 -19 LUFS（stereo 内容 -16）"。VoxCPM2 输出正是 mono 48kHz，故取 -19。

**改用成熟方案的原因**：最初我自研了 ffmpeg loudnorm 双趟封装（含 dynamic fallback 和自适应放宽 TP 两层逻辑），后来发现：
1. FFmpeg 官方文档明确 linear 模式不满足条件时会**自动 revert 到 dynamic**——我的 fallback 是多余的
2. `ffmpeg-normalize` 默认结果与我的方案**完全一致**（-18.33 → -17.65）
3. 自研的自适应 TP 逻辑走入歧途，而调对目标值后问题自动消失

已删除自研的 `tools/normalize-audio.ps1`，改为调用 `ffmpeg-normalize`。

**一个曾踩的坑**：试过 `--dual-mono` + 目标 -16，确实能让部分音频精确达标，但它需要 +3dB 换算（bs.1770 对 mono 低估 3dB），且部分音频会受 True Peak 天花板限制而无法达标（有案例只到 -17.65）。改成目标 -19、不用 `--dual-mono` 后，四个测试案例偏差全部 < 0.15 LU，且测量值与目标值口径一致、无需换算。

**实测效果**：

| 音色 | 归一化前 | 归一化后 | 偏差 |
|---|---|---|---|
| 轻柔气声 | -31.42 | **-18.99** | +0.01 |
| 标准播音 | -15.59 | **-19.00** | +0.00 |
| 激昂洪亮 | -11.98 | **-19.00** | +0.00 |

**关于 RMS vs LUFS**：我一度用 RMS 衡量响度（说"波动 16 倍"），这是不专业的——Google 官方文档明确警告 "Peak level is not a good measure of loudness"。
LUFS 的本质是 **K-weighting（模拟人耳频率敏感度）+ gating（忽略静音段）**，一个 RMS 高但以高频为主的音频，听感可能比 RMS 低但中频饱满的更轻，而 RMS 完全捕捉不到。

---

## 音色管理：怎么写描述、怎么复现

### 描述写法

写括号描述时**至少给三个维度**，模糊描述效果接近随机：

```
✗ 差的写法:  (好听的男声)
✓ 好的写法:  (中年男性,低沉磁性,语速偏慢,语气沉稳)
             (年轻女性,声音温柔甜美,语色略带沙哑质感)
             (活泼少女,语速轻快,朝气蓬勃)
```

可用维度：性别、年龄段、音高、语速、情绪、音质纹理。

### 关于音色一致性（重要，实测结论）

很多人反馈"同样描述跑两次音色不一样"。实测后发现根因和边界：

| 方式 | 结果（实测） |
|---|---|
| **同文本 + 同 seed + 同参数** | 输出 MD5 完全一致，**100% 确定性复现** ✅ |
| 同描述 + **不同 seed** | 生成不同候选音色（这是筛选音色的手段，非缺陷） |
| 同 seed + **不同文本** | 基频锚定在同一音色区间，但谱细节随文本波动（seed 不是音色锁） |
| **参考音频克隆（`-r`）** | 基频差 0.3%、谱重心差 0.2%，**音色锁定最可靠** ✅ |

**结论**：`seed` 是确定性种子，不是音色锁。如果跨文本的音色漂移对你不可接受，**用参考音频克隆锚定**——实测锚定精度极高（基频/谱重心差异均 <0.5%）。

```powershell
# 1. 先用音色设计生成满意音色
powershell tts.ps1 design "(年轻女性,温柔甜美)..." -Out 角色A.wav

# 2. 之后一律用克隆模式复用它, 音色稳定一致
powershell tts.ps1 clone "新文本" -Reference 角色A.wav -Out 输出.wav
```

参考音频越长音色越稳（3.5 秒短句可用，10 秒以上更稳）。

可用 `tools/analyze_voice.py` 做客观对比：

```powershell
python tools\analyze_voice.py 角色A.wav 输出.wav
```

### 音色库管理脚本

```powershell
# 扫描多个 seed 生成候选音色供挑选（输出到 staging\）
powershell voices.ps1 -New -Desc "年轻女性,声音温柔甜美,略带沙哑质感" -Name 晓雯

# 查看音色库
powershell voices.ps1 -List

# 用指定音色合成（需先启动 start-server.bat）
powershell voices.ps1 -Say "你好世界" -Voice 晓雯 -Out 你好.wav
```

---

## 高级参数

```
voxcpm2-cli.exe [options] <BaseLM.gguf> <Acoustic.gguf>

  -t, --text TEXT          输入文本（音色描述写在开头括号内）
  -o, --output PATH        输出 wav（默认 output.wav）
  -r, --reference PATH     参考音频，用于声音克隆
      --prompt-wav PATH    提示音频，用于极致克隆
      --prompt-text TEXT   提示音频的转写文本
      --seed N             随机种子（默认 42，固定可复现）
      --cfg F              引导尺度（默认 2.0）
      --timesteps N        CFM 采样步数（默认 10）
      --steps N            最大解码步数（默认 200）
      --n-gpu-layers N     卸载到 GPU 的层数（默认全部）
      --cpu                纯 CPU 推理
      --stream             流式输出
```

| 需求 | 调整方式 |
|---|---|
| 音色不明显 | 提高 `--cfg` 至 2.5~3.0 |
| 音质粗糙 | 提高 `--timesteps` 至 16~20 |
| 想更快 | 降低 `--timesteps` 至 6~8 |
| 显存不足 | `--n-gpu-layers 20` 减少 GPU 层数 |

---

## 目录结构

```
VoxCPM2/
├── service.ps1                   # 服务管理: start/stop/restart/status/logs/test/health/autostart
├── autostart-hidden.vbs          # 开机自启的静默启动器
├── tts.ps1                       # 合成入口（design / clone / hifi / -Stream / -Normalize）
├── tools/
│   └── analyze_voice.py          # 音色特征分析（基频/谱重心/能量分布）
├── logs/                         # 服务日志 server.log / server.err
├── models/
│   ├── VoxCPM2-BaseLM-Q8_0.gguf   # 主语言模型（Q8_0 量化，1.62B 参数）
│   └── VoxCPM2-Acoustic-F16.gguf  # 声学模型（F16 全精度，912M 参数）
├── staging/                       # 候选音色/测试音频
├── build_voxcpm2.bat              # 编译脚本
├── llama.cpp-omni/                # 推理引擎源码
│   └── build/bin/
│       ├── voxcpm2-cli.exe        # 命令行工具
│       └── llama-tts-server.exe   # HTTP 服务
└── src/ ...                       # 官方 PyTorch 实现（备用）
```

## HTTP API 速查

服务默认监听 `http://127.0.0.1:8099`。

| 端点 | 方法 | 用途 |
|---|---|---|
| `/v1/audio/speech` | POST | 合成音频（非流式，返回完整 WAV） |
| `/v1/audio/speech/stream` | POST | 合成音频（流式，chunked 分块） |
| `/v1/audio/speech/models` | GET | 已加载模型信息（健康检查用） |
| `/v1/voxcpm2/init` | POST | 动态加载/切换 GGUF 权重 |

请求体字段：`model`（固定 `"voxcpm"`）、`input`（必填，音色描述写在括号内）、`voice`（占位）、`seed`、`cfg_value`、`inference_timesteps`、`max_steps`、`temperature`、`reference_audio`（base64 WAV，用于克隆）。

## 环境搭建记录

如需在其他机器复现，可参考 `build_voxcpm2.bat`：

- **编译器**：Visual Studio Build Tools 2022 (MSVC 14.44)
- **CUDA**：CUDA Toolkit 13.2
- **构建工具**：CMake 4.4 + Ninja

> **重要**：CUDA 13.x 已移除 MSBuild 集成，用 Visual Studio 生成器编译会报 `No CUDA toolset found`。
> 必须使用 Ninja 生成器 + 显式指定 `CMAKE_CUDA_COMPILER` 指向 `nvcc.exe`（脚本中已配置）。

## License

- 引擎与模型：Apache-2.0，可免费商用
- GGUF 权重由社区从官方 `openbmb/VoxCPM2` 转换而来
