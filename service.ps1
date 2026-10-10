# VoxCPM2 TTS 服务管理
#
# 用法:
#   powershell service.ps1 start            启动服务(后台, 日志写 logs/)
#   powershell service.ps1 stop              停止服务
#   powershell service.ps1 restart           重启
#   powershell service.ps1 status            状态: 进程/端口/显存/已加载模型
#   powershell service.ps1 logs [-Tail 50]   查看日志
#   powershell service.ps1 health            仅健康检查(返回退出码)
#   powershell service.ps1 autostart         启用开机自启(启动文件夹, 无需管理员)
#   powershell service.ps1 noautostart       取消开机自启
#   powershell service.ps1 test              跑一轮完整冒烟测试

param(
    [Parameter(Mandatory=$true, Position=0)]
    [ValidateSet('start','stop','restart','status','logs','health','autostart','noautostart','test')]
    [string]$Action,

    [int]$Port = 8099,
    [int]$Tail = 40,
    [string]$TaskName = "VoxCPM2-TTS-Server"
)

$ErrorActionPreference = "Stop"
$root = $PSScriptRoot
$exe = Join-Path $root "llama.cpp-omni\build\bin\llama-tts-server.exe"
$base = Join-Path $root "models\VoxCPM2-BaseLM-Q8_0.gguf"
$acoustic = Join-Path $root "models\VoxCPM2-Acoustic-F16.gguf"
$logDir = Join-Path $root "logs"
$logFile = Join-Path $logDir "server.log"
$errFile = Join-Path $logDir "server.err"
$procName = "llama-tts-server"
$baseUrl = "http://127.0.0.1:$Port"

function Get-ServerProc {
    Get-Process -Name $procName -ErrorAction SilentlyContinue |
        Where-Object { $_.Path -like "*VoxCPM2*" }
}

function Test-Api {
    try {
        Invoke-RestMethod "$baseUrl/v1/audio/speech/models" -TimeoutSec 3 -ErrorAction Stop | Out-Null
        $true
    } catch { $false }
}

function Show-Status {
    $p = Get-ServerProc
    Write-Output ""
    Write-Output "=== VoxCPM2 TTS 服务状态 ==="
    if ($p) {
        $p = $p | Select-Object -First 1
        Write-Output ("  进程     : PID {0}  {1}" -f $p.Id, $procName)
        Write-Output ("  工作集   : {0:N0} MB" -f ($p.WorkingSet64/1MB))
        Write-Output ("  启动时间 : {0}" -f $p.StartTime)
        $up = Test-Api
        Write-Output ("  API      : {0}  {1}" -f $baseUrl, $(if($up){"在线"}else{"无响应"}))
        if ($up) {
            try {
                $m = Invoke-RestMethod "$baseUrl/v1/audio/speech/models" -TimeoutSec 5
                foreach ($d in $m.data) {
                    Write-Output ("  模型     : {0}  {1}kHz  feat_dim={2}  patch={3}" -f $d.id, ($d.sample_rate/1000), $d.feat_dim, $d.patch_size)
                }
            } catch { Write-Output "  模型信息 : 读取失败" }
        }
    } else {
        Write-Output "  进程     : 未运行"
    }
    $startup = [Environment]::GetFolderPath('Startup')
    $hasAuto = Test-Path (Join-Path $startup "$TaskName.lnk")
    Write-Output ("  开机自启 : {0}" -f $(if($hasAuto){"已启用"}else{"未启用"}))
    if (Test-Path $logFile) {
        Write-Output ("  日志     : {0}  ({1:N0} KB, 更新于 {2})" -f $logFile, ((Get-Item $logFile).Length/1KB), (Get-Item $logFile).LastWriteTime)
    }
    try {
        $gpu = nvidia-smi --query-gpu=name,memory.used,memory.total,memory.free --format=csv,noheader
        Write-Output "  GPU      : $gpu"
    } catch {}
    Write-Output ""
}

switch ($Action) {

    'start' {
        if (Get-ServerProc) { Write-Output "服务已在运行 (PID $((Get-ServerProc | Select-Object -First 1).Id))"; break }
        foreach ($f in @($exe, $base, $acoustic)) {
            if (-not (Test-Path $f)) { throw "缺少文件: $f" }
        }
        New-Item -ItemType Directory -Force $logDir | Out-Null
        Write-Output "正在启动 $procName (端口 $Port) ..."
        Start-Process -FilePath $exe `
            -ArgumentList @("--voxcpm2-base-lm", $base, "--voxcpm2-acoustic", $acoustic, "--port", "$Port") `
            -WindowStyle Hidden -RedirectStandardOutput $logFile -RedirectStandardError $errFile | Out-Null
        $ok = $false
        for ($i = 0; $i -lt 60; $i++) {
            Start-Sleep -Seconds 2
            if (Test-Api) { $ok = $true; break }
            if (-not (Get-ServerProc)) {
                Write-Error "服务进程已退出。查看日志: Get-Content $errFile -Tail 30"
                exit 1
            }
            Write-Progress -Activity "加载模型中(约 3.3GB 权重)..." -Status "$($i*2)s"
        }
        Write-Progress -Activity "加载模型" -Completed
        if ($ok) { Show-Status } else { Write-Error "启动超时(120s), 请检查日志"; exit 1 }
    }

    'stop' {
        $p = Get-ServerProc
        if (-not $p) { Write-Output "服务未在运行"; break }
        $ids = ($p.Id) -join ", "
        $p | Stop-Process -Force
        Start-Sleep -Milliseconds 1500
        if (Get-ServerProc) { Get-ServerProc | Stop-Process -Force }
        Write-Output "已停止服务 (PID $ids)"
    }

    'restart' {
        $p = Get-ServerProc
        if ($p) { $p | Stop-Process -Force; Start-Sleep -Seconds 2 }
        & $PSCommandPath start -Port $Port
    }

    'status' { Show-Status }

    'health' {
        if (Test-Api) { Write-Output "OK"; exit 0 } else { Write-Output "DOWN"; exit 1 }
    }

    'logs' {
        if (-not (Test-Path $logFile)) { Write-Output "无日志文件"; break }
        Write-Output "===== $logFile (最后 $Tail 行) ====="
        Get-Content $logFile -Tail $Tail
        if ((Test-Path $errFile) -and ((Get-Item $errFile).Length -gt 0)) {
            Write-Output "`n===== $errFile (最后 $Tail 行) ====="
            Get-Content $errFile -Tail $Tail
        }
    }

    'autostart' {
        # 启动文件夹 + VBS 隐藏启动, 无需管理员权限
        $startup = [Environment]::GetFolderPath('Startup')
        $lnk = Join-Path $startup "$TaskName.lnk"
        $vbs = Join-Path $root "autostart-hidden.vbs"
        if (-not (Test-Path $vbs)) { throw "缺少启动器: $vbs" }
        $ws = New-Object -ComObject WScript.Shell
        $s = $ws.CreateShortcut($lnk)
        $s.TargetPath = "wscript.exe"
        $s.Arguments = [char]34 + $vbs + [char]34
        $s.WorkingDirectory = $root
        $s.Description = "VoxCPM2 TTS HTTP 服务 (登录时自动启动, 无窗口)"
        $s.Save()
        Write-Output "已启用开机自启: $lnk"
        Write-Output "  下次登录会自动静默启动服务于端口 $Port"
        Write-Output "  取消: powershell service.ps1 noautostart"
    }

    'noautostart' {
        $startup = [Environment]::GetFolderPath('Startup')
        $lnk = Join-Path $startup "$TaskName.lnk"
        if (Test-Path $lnk) { Remove-Item $lnk -Force; Write-Output "已移除开机自启" }
        else { Write-Output "未启用开机自启" }
    }

    'test' {
        Write-Output "=== 冒烟测试 ==="
        if (-not (Test-Api)) { Write-Output "服务未启动, 请先执行 start"; exit 1 }

        # 用 .NET 请求发送 body, 避免命令行长度限制(base64 音频很大)
        function Send-Tts {
            param($Endpoint, $BodyObj, $OutFile)
            $payload = $BodyObj | ConvertTo-Json -Depth 3 -Compress
            $bytes = [Text.Encoding]::UTF8.GetBytes($payload)
            $req = [System.Net.HttpWebRequest]::Create("$baseUrl$Endpoint")
            $req.Method = "POST"; $req.ContentType = "application/json; charset=utf-8"
            $req.ContentLength = $bytes.Length; $req.Timeout = 180000
            $os = $req.GetRequestStream(); $os.Write($bytes,0,$bytes.Length); $os.Close()
            $resp = $req.GetResponse(); $rs = $resp.GetResponseStream()
            $fs = [IO.File]::Create($OutFile); $buf = New-Object byte[] 8192
            try { while (($n = $rs.Read($buf,0,$buf.Length)) -gt 0) { $fs.Write($buf,0,$n) } }
            finally { $fs.Close(); $rs.Close(); $resp.Close() }
        }

        $refPath = Join-Path $root "示例_音色设计.wav"
        $refB64 = if (Test-Path $refPath) { [Convert]::ToBase64String([IO.File]::ReadAllBytes($refPath)) } else { $null }
        $cases = @(
            @{n="音色设计"; ep="/v1/audio/speech";       b=@{model="voxcpm";input="(年轻女性,温柔甜美)冒烟测试,音色设计。"; voice="default";seed=42}},
            @{n="流式端点"; ep="/v1/audio/speech/stream"; b=@{model="voxcpm";input="(中年男性,低沉磁性)冒烟测试,流式端点。"; voice="default";seed=42}}
        )
        if ($refB64) {
            $cases += @{n="克隆模式"; ep="/v1/audio/speech"; b=@{model="voxcpm";input="冒烟测试,克隆模式。"; voice="default";seed=42;reference_audio=$refB64}}
        }
        $i = 0
        foreach ($x in $cases) {
            $i++; $out = Join-Path $root "smoke_$i.wav"
            $sw = [Diagnostics.Stopwatch]::StartNew()
            try { Send-Tts -Endpoint $x.ep -BodyObj $x.b -OutFile $out } catch { Write-Output "  请求失败: $($_.Exception.Message)" }
            $sw.Stop()
            $len = if (Test-Path $out) { ((Get-Item $out).Length - 44)/2/48000 } else { 0 }
            $st = if ((Test-Path $out) -and ((Get-Item $out).Length -gt 44)) { "[OK]" } else { "[FAIL]" }
            Write-Output ("  {0} {1,-8} 音频 {2,5:N2}s  耗时 {3,5:N2}s" -f $st, $x.n, $len, $sw.Elapsed.TotalSeconds)
            Remove-Item $out -Force -ErrorAction SilentlyContinue
        }
        Write-Output "=== 测试完成 ==="
    }
}
