# VoxCPM2 音色库管理工具
#
# 实测结论 (RTX 4060 / 3.3GB GGUF):
#   1. 同文本 + 同 seed + 同参数 -> 输出 MD5 完全一致, 100% 确定性复现
#   2. 同描述 + 不同 seed -> 生成不同候选音色 (这是筛选音色的手段)
#   3. 同 seed + 不同文本 -> 基频锚定在同一音色区间, 但谱细节随文本波动
#      (即 seed 是确定性种子, 不是音色锁; 跨文本漂移不可接受时改用 -r 参考克隆)
#
# 本脚本用于: 扫描 seed 生成候选供人工挑选, 并把 (描述, seed) 记入音色库复用。
#
# 用法:
#   powershell voices.ps1 -New             新增音色: 输入描述, 扫多个 seed 生成候选
#   powershell voices.ps1 -List            查看音色库
#   powershell voices.ps1 -Say "文本" -Voice 名字   用指定音色合成
#   powershell voices.ps1 -Delete 名字     删除音色

param(
    [switch]$New,
    [switch]$List,
    [string]$Say,
    [string]$Voice,
    [string]$Delete,
    [string]$Desc,
    [string]$Name,
    [int[]]$Seeds = @(42, 100, 200, 300, 777, 2026),
    [string]$Out = "",
    [string]$Server = "http://127.0.0.1:8099"
)

$ErrorActionPreference = "Stop"
$base = $PSScriptRoot
$libFile = Join-Path $base "voices.json"
$staging = Join-Path $base "staging"

if (-not (Test-Path $libFile)) { @{} | ConvertTo-Json | Set-Content $libFile -Encoding UTF8 }
$lib = Get-Content $libFile -Raw | ConvertFrom-Json -AsHashtable

function Test-Server {
    try { Invoke-RestMethod "$Server/v1/audio/speech/models" -TimeoutSec 3 | Out-Null; return $true }
    catch { return $false }
}

function Invoke-Tts {
    param($Text, $Seed, $OutFile)
    $body = @{ model = "voxcpm"; input = $Text; voice = "default"; seed = $Seed } | ConvertTo-Json
    Invoke-RestMethod "$Server/v1/audio/speech" -Method Post -Body $body `
        -ContentType "application/json" -OutFile $OutFile -TimeoutSec 300
}

# ---------- 新增音色 ----------
if ($New) {
    if (-not $Desc) {
        $Desc = Read-Host "输入音色描述 (性别/年龄/音色/情绪/语速, 例: 年轻女性,温柔甜美,语速舒缓)"
    }
    if (-not $Name) {
        $Name = Read-Host "给这个音色起个名字 (只用于库内查找)"
    }
    $probe = "(随便测试一下声音是否正常,短句即可。)"
    $text = "($Desc)$probe"

    New-Item -ItemType Directory -Force $staging | Out-Null
    Write-Host ""
    Write-Host "正在生成候选音色 (每个 seed 一种音色)..." -ForegroundColor Cyan
    foreach ($s in $Seeds) {
        $f = Join-Path $staging "$Name`_seed$s.wav"
        Invoke-Tts -Text $text -Seed $s -OutFile $f
        Write-Host "  seed $s  ->  $f" -ForegroundColor Gray
    }
    Write-Host ""
    Write-Host "候选已生成, 请试听 staging 目录下的文件后挑选。" -ForegroundColor Green
    Write-Host "挑好满意的 seed 后, 执行:" -ForegroundColor Green
    Write-Host "  powershell voices.ps1 -New -Desc `"$Desc`" -Name $Name -Seeds <你选的seed>" -ForegroundColor Yellow
    Write-Host "再执行 -Say 即可用这个音色长期复现同一声音。"
    exit 0
}

# ---------- 保存选定音色 ----------
if ($Name -and $Desc -and $Seeds.Count -eq 1) {
    $s = $Seeds[0]
    # 复现一次验证确定性, 并作为基准音色
    $baseFile = Join-Path $base "voice_$Name.wav"
    Invoke-Tts -Text "(确定音色基准,用于后续一致性校验。)" -Seed $s -OutFile $baseFile
    $lib[$Name] = @{ desc = $Desc; seed = $s; base_wav = $baseFile }
    $lib | ConvertTo-Json -Depth 4 | Set-Content $libFile -Encoding UTF8
    Write-Host "音色 `"$Name`" 已保存 (描述: $Desc / seed: $s)" -ForegroundColor Green
    exit 0
}

# ---------- 列出音色库 ----------
if ($List) {
    if ($lib.Count -eq 0) { Write-Host "音色库为空, 用 -New 创建" ; exit 0 }
    Write-Host ""
    Write-Host "已保存的音色:" -ForegroundColor Cyan
    $lib.GetEnumerator() | Sort-Object Name | ForEach-Object {
        Write-Host "  [$($_.Key)]  seed=$($_.Value.seed)" -ForegroundColor White
        Write-Host "      描述: $($_.Value.desc)" -ForegroundColor Gray
    }
    Write-Host ""
    exit 0
}

# ---------- 用指定音色合成 ----------
if ($Say) {
    if (-not $Voice) { Write-Error "请用 -Voice 指定音色名"; exit 1 }
    if (-not $lib.ContainsKey($Voice)) { Write-Error "音色 `"$Voice`" 不存在, 用 -List 查看可用音色"; exit 1 }
    if (-not (Test-Server)) { Write-Error "TTS 服务未启动, 请先运行 start-server.bat"; exit 1 }
    $v = $lib[$Voice]
    if (-not $Out) { $Out = Join-Path $base "out_$Voice.wav" }
    Invoke-Tts -Text "($($v.desc))$Say" -Seed $v.seed -OutFile $Out
    Write-Host "已生成: $Out  (音色: $Voice, seed: $($v.seed))" -ForegroundColor Green
    exit 0
}

# ---------- 删除音色 ----------
if ($Delete) {
    if (-not $lib.ContainsKey($Delete)) { Write-Error "音色 `"$Delete`" 不存在"; exit 1 }
    $lib.Remove($Delete)
    $lib | ConvertTo-Json -Depth 4 | Set-Content $libFile -Encoding UTF8
    Write-Host "已删除音色 `"$Delete`"" -ForegroundColor Green
    exit 0
}

Write-Host @"
VoxCPM2 音色库管理

  -New                          新增音色 (扫多个 seed 生成候选)
  -List                         查看音色库
  -Say "文本" -Voice 名字       用指定音色合成
  -Delete 名字                  删除音色

示例:
  powershell voices.ps1 -New -Desc "年轻女性,声音温柔甜美,语速舒缓" -Name 晓雯
  powershell voices.ps1 -List
  powershell voices.ps1 -Say "你好世界" -Voice 晓雯 -Out 你好.wav
"@
