# VoxCPM2 模型档位管理（T49 P1）
#
# 用法：
#   powershell models.ps1 list                  列出候选池 + 当前激活档（来源：active.json/默认/参数）
#   powershell models.ps1 use -Tier a           切到 A 组合（Q4_K_M + Q8_0，~3.6GB）【GA 默认档】
#   powershell models.ps1 use -Tier double8     切到双八（Q8_0 + Q8_0，~4.2GB，人耳近乎透明）
#   powershell models.ps1 use -Tier baseline    切回基线（Q8_0 + F16，~5.1GB，T44 现役原档）
#   powershell models.ps1 use -BaseLm X -Acoustic Y   自定义组合（文件名须在 models/ 下）
#
# 切换 = 写 active.json + 提示 restart；回滚 = 一条命令（use -Tier double8/baseline + restart）。
# active.json 入 git（.gitignore 已开例外）；候选 .gguf 不入库（体积大，按 README_local 重获）。
#
# T49 实测口径（2026-10-13，RTX 4060 8GB，干净态）：
#   baseline  5120MiB｜double8 4211MiB｜a ~3593MiB（A/B 见 memory/tasks/20261013-T49）

param(
    [Parameter(Mandatory=$true, Position=0)]
    [ValidateSet('list','use')]
    [string]$Action,

    [ValidateSet('a','double8','baseline')]
    [string]$Tier,

    [string]$BaseLm,
    [string]$Acoustic
)

$ErrorActionPreference = "Stop"
$root = $PSScriptRoot
$modelsDir = Join-Path $root "models"
$activeJson = Join-Path $modelsDir "active.json"

# 档位定义（文件名 -> 一句话口径）
$TIERS = @{
    a        = @{ BaseLm = "VoxCPM2-BaseLM-Q4_K_M.gguf"; Acoustic = "VoxCPM2-Acoustic-Q8_0.gguf";  Desc = "A 组合（Q4_K_M+Q8_0，~3.6GB，GA 默认档，人耳已签字）" }
    double8  = @{ BaseLm = "VoxCPM2-BaseLM-Q8_0.gguf";  Acoustic = "VoxCPM2-Acoustic-Q8_0.gguf";  Desc = "双八（Q8_0+Q8_0，~4.2GB，数字近乎透明）" }
    baseline = @{ BaseLm = "VoxCPM2-BaseLM-Q8_0.gguf";  Acoustic = "VoxCPM2-Acoustic-F16.gguf";    Desc = "基线（Q8_0+F16，~5.1GB，T44 生产原档）" }
}

function Show-List {
    Write-Output "=== VoxCPM2 模型候选池（models\）==="
    Get-ChildItem $modelsDir -Filter "*.gguf" | Sort-Object Name | ForEach-Object {
        "  {0,-32} {1,7:N2} GB" -f $_.Name, ($_.Length / 1GB)
    }
    Write-Output ""
    if (Test-Path $activeJson) {
        try {
            $j = Get-Content $activeJson -Raw -Encoding UTF8 | ConvertFrom-Json
            Write-Output "当前激活（active.json）："
            Write-Output "  base_lm   = $($j.base_lm)"
            Write-Output "  acoustic  = $($j.acoustic)"
            foreach ($t in $TIERS.Keys) {
                if ($TIERS[$t].BaseLm -eq $j.base_lm -and $TIERS[$t].Acoustic -eq $j.acoustic) {
                    Write-Output "  => 档位「$t」：$($TIERS[$t].Desc)"
                }
            }
        } catch {
            Write-Output "当前激活：active.json 解析失败（启动将回退默认组合并告警）"
        }
    } else {
        Write-Output "当前激活：active.json 不存在（启动回退默认组合 Q8_0+F16）"
    }
    Write-Output ""
    Write-Output "可用档位："
    foreach ($t in @("a","double8","baseline")) {
        $ok = (Test-Path (Join-Path $modelsDir $TIERS[$t].BaseLm)) -and (Test-Path (Join-Path $modelsDir $TIERS[$t].Acoustic))
        $mark = if ($ok) { "[就绪]" } else { "[缺文件]" }
        Write-Output ("  $mark {0,-9} {1}" -f $t, $TIERS[$t].Desc)
    }
    Write-Output ""
    Write-Output "切换：powershell models.ps1 use -Tier <a|double8|baseline> 然后 powershell service.ps1 restart"
}

switch ($Action) {
    'list' { Show-List }

    'use' {
        if ($Tier) {
            $BaseLm = $TIERS[$Tier].BaseLm
            $Acoustic = $TIERS[$Tier].Acoustic
        }
        if (-not $BaseLm -or -not $Acoustic) {
            Write-Error "use 需要 -Tier <a|double8|baseline>，或同时给 -BaseLm 和 -Acoustic（文件名须在 models\ 下）"
            exit 2
        }
        # 校验文件存在（fail-fast：不写半截配置）
        foreach ($f in @($BaseLm, $Acoustic)) {
            if (-not (Test-Path (Join-Path $modelsDir $f))) {
                Write-Error "models\ 下不存在: $f（用 models.ps1 list 看候选池）"
                exit 2
            }
        }
        # 原子写（临时文件 + move）
        $cfg = [ordered]@{ base_lm = $BaseLm; acoustic = $Acoustic }
        $tmp = "$activeJson.tmp"
        $cfg | ConvertTo-Json | Set-Content $tmp -Encoding UTF8
        Move-Item $tmp $activeJson -Force
        $tierNote = ""
        foreach ($t in $TIERS.Keys) {
            if ($TIERS[$t].BaseLm -eq $BaseLm -and $TIERS[$t].Acoustic -eq $Acoustic) { $tierNote = "（档位「$t」）" }
        }
        Write-Output "已写入 active.json：base_lm=$BaseLm acoustic=$Acoustic $tierNote"
        Write-Output "生效：powershell service.ps1 restart（约 5s；真话看 logs\server.err 的 BaseLM:/Acoustic: 两行）"
    }
}
