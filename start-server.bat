@echo off
REM 启动 VoxCPM2 TTS 服务 (OpenAI 兼容 /v1/audio/speech)
setlocal
cd /d "%~dp0"

set "PORT=8099"
if not "%~1"=="" set "PORT=%~1"

echo 正在启动 VoxCPM2 TTS 服务于端口 %PORT% ...
echo 启动需加载 3.3GB 权重, 请等待约 10 秒
echo 停止服务: 按 Ctrl+C  或执行 stop-server.bat
echo.

llama.cpp-omni\build\bin\llama-tts-server.exe ^
  --voxcpm2-base-lm models\VoxCPM2-BaseLM-Q8_0.gguf ^
  --voxcpm2-acoustic models\VoxCPM2-Acoustic-F16.gguf ^
  --port %PORT%

endlocal
