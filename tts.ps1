# VoxCPM2 语音合成入口
#
# 用法:
#   powershell tts.ps1 design "(年轻女性,温柔甜美)你好世界"            -> out.wav
#   powershell tts.ps1 design "..." -Out 我的.wav -Stream              -> 流式(首包 ~0.1s)
#   powershell tts.ps1 design "..." -Normalize                         -> 响度归一化(-16 LUFS)
#   powershell tts.ps1 clone  "要合成的话" speaker.wav                 -> 克隆音色
#   powershell tts.ps1 hifi    "新内容" speaker.wav "参考音频的文本"   -> 极致克隆
#
# 公共参数:
#   -Stream      流式传输 (首包延迟 ~0.1s, 非流式 ~1.4s; 需服务已启动)
#   -Normalize   生成后响度归一化 (ffmpeg-normalize, EBU R128 + dual-mono)
#   -Out 输出.wav  -Seed 42  -Cfg 2.0  -Timesteps 10
#   -TargetLufs -16  -TruePeak -1.0   (归一化目标, 默认即推荐值)
#   -Server http://127.0.0.1:8099

param(
    [Parameter(Mandatory=$true, Position=0)]
    [ValidateSet('design','clone','hifi')]
    [string]$Mode,

    [Parameter(Mandatory=$true, Position=1)]
    [string]$Text,

    [string]$Reference,        # clone/hifi 模式的参考音频
    [string]$PromptText,       # hifi 模式的参考音频转写
    [string]$Out = "",
    [int]$Seed = 42,
    [double]$Cfg = 2.0,
    [int]$Timesteps = 10,
    [switch]$Stream,           # 流式传输
    [switch]$Normalize,        # 生成后响度归一化 (EBU R128 / LUFS)
    [double]$TargetLufs = -19.0,
    [double]$TruePeak = -1.0,
    [string]$Server = "http://127.0.0.1:8099"
)

$ErrorActionPreference = "Stop"
$root = $PSScriptRoot
$cli = Join-Path $root "llama.cpp-omni\build\bin\voxcpm2-cli.exe"
$base = Join-Path $root "models\VoxCPM2-BaseLM-Q8_0.gguf"
$acoustic = Join-Path $root "models\VoxCPM2-Acoustic-F16.gguf"

if (-not $Out) {
    $stamp = Get-Date -Format "HHmmss"
    $Out = Join-Path $root "out_${Mode}_$stamp.wav"
}
$Out = [IO.Path]::GetFullPath($Out)

function Test-ServerUp {
    try { Invoke-RestMethod "$Server/v1/audio/speech/models" -TimeoutSec 3 | Out-Null; $true }
    catch { $false }
}

# 测量音频响度 (返回 I 和 TP)。ffmpeg 的 stderr 需临时放宽错误级别后才不会中断脚本。
function Invoke-LoudnessMeasure {
    param($File, [string]$Target = "-16", [string]$Peak = "-1")
    $errFile = [IO.Path]::Combine([IO.Path]::GetTempPath(), ("voxcpm_m_{0}.log" -f [Guid]::NewGuid().ToString('N')))
    $argv = @("-hide_banner","-nostats","-i", $File, "-af", "loudnorm=I=${Target}:TP=${Peak}:print_format=json", "-ar","48000","-f","null","-")
    Start-Process -FilePath (Get-Command ffmpeg).Source -ArgumentList $argv -Wait -WindowStyle Hidden `
        -RedirectStandardError $errFile | Out-Null
    $text = Get-Content $errFile -Raw
    Remove-Item $errFile -Force -ErrorAction SilentlyContinue
    $m = [regex]::Match($text, '\{\s*"input_i".*?\}', [Text.RegularExpressions.RegexOptions]::Singleline)
    if (-not $m.Success) { return @{ I = "?"; TP = "?" } }
    $j = $m.Value | ConvertFrom-Json
    return @{ I = $j.input_i; TP = $j.input_tp }
}

# ---------- HTTP 请求 (流式 / 非流式) ----------
function Invoke-HttpTts {
    param($Body, $OutFile, [switch]$AsStream)

    $payload = $Body | ConvertTo-Json -Depth 3 -Compress
    $bytes = [Text.Encoding]::UTF8.GetBytes($payload)

    $req = [System.Net.HttpWebRequest]::Create("$Server/v1/audio/speech$(if($AsStream){'/stream'})")
    $req.Method = "POST"
    $req.ContentType = "application/json; charset=utf-8"
    $req.ContentLength = $bytes.Length
    $req.Timeout = 300000
    $req.ReadWriteTimeout = 300000

    $os = $req.GetRequestStream()
    $os.Write($bytes, 0, $bytes.Length)
    $os.Close()

    $resp = $req.GetResponse()
    $rs = $resp.GetResponseStream()
    $fs = [IO.File]::Create($OutFile)

    $timer = [Diagnostics.Stopwatch]::StartNew()
    $i = 0; $ttfa = $null; $total = 0
    $buf = New-Object byte[] 8192
    try {
        while (($n = $rs.Read($buf, 0, $buf.Length)) -gt 0) {
            $fs.Write($buf, 0, $n)
            $total += $n; $i++
            # 首个音频数据到达 (跳过 44 字节 WAV 头)
            if ($null -eq $ttfa -and $total -gt 44) { $ttfa = $timer.Elapsed.TotalSeconds }
        }
    } finally {
        $fs.Close(); $rs.Close(); $resp.Close()
    }
    return [pscustomobject]@{ Chunks = $i; TTFA = $ttfa }
}

$sw = [Diagnostics.Stopwatch]::StartNew()
$usedStream = $false
$ttfa = $null

if ($Stream) {
    if (-not (Test-ServerUp)) {
        Write-Warning "服务未启动, 流式需要 HTTP 服务。改用 CLI 模式(会自动加载模型)。"
    } else {
        $body = @{ model = "voxcpm"; input = $Text; voice = "default"; seed = $Seed }
        if ($Reference) {
            if (-not (Test-Path $Reference)) { throw "参考音频不存在: $Reference" }
            $body["reference_audio"] = [Convert]::ToBase64String([IO.File]::ReadAllBytes($Reference))
        }
        $r = Invoke-HttpTts -Body $body -OutFile $Out -AsStream
        $ttfa = $r.TTFA
        $usedStream = $true
        Write-Host "[流式模式]" -ForegroundColor DarkCyan
    }
}

if (-not $usedStream) {
    if (Test-ServerUp) {
        # ---------- HTTP 服务模式 (快, 模型常驻) ----------
        $body = @{ model = "voxcpm"; input = $Text; voice = "default"; seed = $Seed }
        if ($Reference) {
            if (-not (Test-Path $Reference)) { throw "参考音频不存在: $Reference" }
            $body["reference_audio"] = [Convert]::ToBase64String([IO.File]::ReadAllBytes($Reference))
        }
        $null = Invoke-HttpTts -Body $body -OutFile $Out
        Write-Host "[服务模式]" -ForegroundColor DarkCyan
    }
    else {
        # ---------- CLI 模式 (未启动服务, 直接推理) ----------
        if (-not (Test-Path $cli)) { throw "未找到 voxcpm2-cli.exe: $cli" }
        $args = @("-t", $Text, "-o", $Out, "--seed", "$Seed", "--cfg", "$Cfg", "--timesteps", "$Timesteps")
        if ($Mode -in @('clone','hifi')) {
            if (-not $Reference) { throw "clone/hifi 模式需要 -Reference 参考音频" }
            $args += @("-r", $Reference)
        }
        if ($Mode -eq 'hifi') {
            if (-not $PromptText) { throw "hifi 模式需要 -PromptText (参考音频的转写文本)" }
            $args += @("--prompt-wav", $Reference, "--prompt-text", $PromptText)
        }
        & $cli @args $base $acoustic | Out-Null
        Write-Host "[CLI 模式]" -ForegroundColor DarkCyan
    }
}

$sw.Stop()
if (-not (Test-Path $Out)) { throw "生成失败, 未输出文件" }

# 解析 wav 头显示摘要
$fs = [IO.File]::OpenRead($Out)
try {
    $br = [IO.BinaryReader]::new($fs)
    [void]$br.ReadBytes(20)                       # RIFF + fmt chunk
    [void]$br.ReadUInt16()                        # audio format
    $ch = [int]$br.ReadUInt16()                   # channels
    $sr = [int]$br.ReadUInt32()                   # sample rate
    $br.Close()
} finally { $fs.Close() }
$frames = ((Get-Item $Out).Length - 44) / (2 * $ch)

Write-Host ("  音频 {0:N2}s | {1}kHz | 总耗时 {2:N2}s" -f ($frames/$sr), ($sr/1000), $sw.Elapsed.TotalSeconds) -ForegroundColor White
if ($ttfa) {
  Write-Host ("  首包延迟(TTFA) {0:N3}s  <- 流式实时播放的关键指标" -f $ttfa) -ForegroundColor Yellow
}
Write-Host "  已保存: $Out" -ForegroundColor Green

# ---------- 响度归一化后处理 ----------
if ($Normalize) {
    $fn = Get-Command ffmpeg-normalize -ErrorAction SilentlyContinue
    if (-not $fn) { throw "未找到 ffmpeg-normalize, 请先安装: pip install ffmpeg-normalize" }

    Write-Host "`n响度归一化 (目标 ${TargetLufs} LUFS, EBU R128):" -ForegroundColor Cyan

    # 输出到临时文件后替换, 避免同文件读写
    $tmp = [IO.Path]::Combine([IO.Path]::GetTempPath(), ("voxcpm_norm_{0}.wav" -f [Guid]::NewGuid().ToString('N')))

    # ffmpeg-normalize (slhck): EBU R128 双趟归一化
    #   默认目标 -19 LUFS 依据 Google Assistant 官方 TTS 规范: mono 内容建议 -19 LUFS
    #   (stereo 内容 -16)。VoxCPM2 输出正是 mono 48kHz, 故取 -19。
    #   不用 --dual-mono: 那个需要 +3dB 换算, 且会让部分音频受 True Peak 天花板限制而无法达标
    #   (实测目标 -16 + dual-mono 时有案例只到 -17.65; 目标 -19 则四个案例偏差全部 <0.15 LU)。
    $stdFile = [IO.Path]::Combine([IO.Path]::GetTempPath(), ("voxcpm_norm_{0}.out" -f [Guid]::NewGuid().ToString('N')))
    $errFile2 = [IO.Path]::Combine([IO.Path]::GetTempPath(), ("voxcpm_norm_{0}.err" -f [Guid]::NewGuid().ToString('N')))
    $nargv = @($Out, "-nt","ebu","-t","$TargetLufs","-tp","$TruePeak","-c:a","pcm_s16le","-f","-o",$tmp)
    Start-Process -FilePath $fn.Source -ArgumentList $nargv -Wait -WindowStyle Hidden `
        -RedirectStandardOutput $stdFile -RedirectStandardError $errFile2 | Out-Null
    if (-not (Test-Path $tmp)) { throw "归一化失败, 详见: $errFile2" }
    Remove-Item $stdFile, $errFile2 -Force -ErrorAction SilentlyContinue

    # 响度对比: 前后都用 BS.1770 直接测量 mono 文件, 口径一致(不混用 dual-mono 换算视角)
    $before = Invoke-LoudnessMeasure -File $Out -Target "$TargetLufs" -Peak "$TruePeak"
    $after  = Invoke-LoudnessMeasure -File $tmp -Target "$TargetLufs" -Peak "$TruePeak"

    if ($after.I -ne "?") {
        Write-Host ("  响度 {0} -> {1} LUFS   (目标 ${TargetLufs}, 偏差 {2:+0.00;-0.00} LU)" -f $before.I, $after.I, ([double]$after.I - $TargetLufs)) -ForegroundColor Green
        Write-Host ("  True Peak {0} dBTP (上限 ${TruePeak})" -f $after.TP) -ForegroundColor Green
    } else {
        Write-Host "  归一化完成 (未能解析测量值, 不影响输出文件)" -ForegroundColor Green
    }

    Move-Item $tmp $Out -Force
}
