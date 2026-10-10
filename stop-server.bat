@echo off
REM 停止 VoxCPM2 TTS 服务
taskkill /IM llama-tts-server.exe /F 2>nul
if %errorlevel%==0 (
    echo TTS 服务已停止
) else (
    echo 未发现正在运行的 TTS 服务
)
