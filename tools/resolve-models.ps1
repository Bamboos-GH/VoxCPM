# VoxCPM2 模型解析器（T49 P1，dot-source 共享）
#
# 用法（被 service.ps1 / tts.ps1 dot-source）：
#   $null = . (Join-Path $root "tools\resolve-models.ps1")
#   $m = Resolve-VoxCPM2Models -Root $root [-BaseLmOverride x.gguf] [-AcousticOverride y.gguf]
#
# 返回 @{ BaseLm=绝对路径; Acoustic=绝对路径; Source='active.json'|'default'|'args'; Warning=字符串 }
#
# 回退策略（T49 R3 两层，按失败模式单独定价）：
#   配置不可读/缺失/缺字段/JSON 解析失败 -> fail-OPEN：回退默认组合（Q8_0+F16，生产现役）+ Warning。
#     理由：平台桥接（services/api voxcpm.py）只调 `service.ps1 start -Port N`，不感知本配置；
#     fail-fast 在这里会直接把生产 TTS 打断。
#   配置可读但指向的文件不存在 -> fail-FAST：抛错退出。
#     理由：显式配置意图不可静默降级（否则 A/B 会拿错模型出结论）。
#   -BaseLm/-Acoustic 参数覆盖同理会话显式意图：文件缺失 fail-fast。
#
# 模型来源双口径：active.json 在 models/ 下，入 git（.gitignore 有 !models/active.json 例外）。

function Resolve-VoxCPM2Models {
    param(
        [Parameter(Mandatory=$true)][string]$Root,
        [string]$BaseLmOverride,
        [string]$AcousticOverride
    )

    $result = @{
        BaseLm  = Join-Path $Root "models\VoxCPM2-BaseLM-Q8_0.gguf"     # 默认组合 = T44 生产现役
        Acoustic = Join-Path $Root "models\VoxCPM2-Acoustic-F16.gguf"
        Source  = "default"
        Warning = ""
    }

    # ---- 参数覆盖（显式意图：fail-fast）----
    if ($BaseLmOverride -or $AcousticOverride) {
        if ($BaseLmOverride)   { $result.BaseLm   = $BaseLmOverride }
        if ($AcousticOverride) { $result.Acoustic  = $AcousticOverride }
        $result.Source = "args"
        foreach ($p in @($result.BaseLm, $result.Acoustic)) {
            if (-not (Test-Path $p)) {
                throw "指定的模型文件不存在: $p （显式参数不可降级，请检查路径）"
            }
        }
        return $result
    }

    # ---- active.json 选择器 ----
    $cfg = Join-Path $Root "models\active.json"
    if (Test-Path $cfg) {
        $j = $null
        try {
            $j = Get-Content $cfg -Raw -Encoding UTF8 | ConvertFrom-Json
        } catch {
            $result.Warning = "active.json 解析失败，回退默认组合: $($_.Exception.Message)"
        }
        if ($j -and $j.base_lm -and $j.acoustic) {
            $bl = Join-Path $Root "models\$($j.base_lm)"
            $ac = Join-Path $Root "models\$($j.acoustic)"
            foreach ($p in @($bl, $ac)) {
                if (-not (Test-Path $p)) {
                    throw "active.json 指向的文件不存在: $p （显式配置不可静默降级；用 models.ps1 list/use 修复）"
                }
            }
            $result.BaseLm  = $bl
            $result.Acoustic = $ac
            $result.Source  = "active.json"
            return $result
        }
        if (-not $result.Warning) {
            $result.Warning = "active.json 缺 base_lm/acoustic 字段，回退默认组合"
        }
    } else {
        $result.Warning = "active.json 不存在，回退默认组合（Q8_0+F16）"
    }

    return $result
}
