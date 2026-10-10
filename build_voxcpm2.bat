@echo off
setlocal
call "C:\Program Files (x86)\Microsoft Visual Studio\2022\BuildTools\VC\Auxiliary\Build\vcvars64.bat" || exit /b 1
set "PATH=C:\Program Files\NVIDIA GPU Computing Toolkit\CUDA\v13.2\bin;D:\Kit\Python\Scripts;%PATH%"
cd /d "D:\Data\OpenCode\VoxCPM2\llama.cpp-omni"

echo === Configuring with Ninja + CUDA arch 89 ===
cmake -B build -S . ^
  -G Ninja ^
  -DCMAKE_BUILD_TYPE=Release ^
  -DGGML_CUDA=ON ^
  -DCMAKE_CUDA_COMPILER="C:/Program Files/NVIDIA GPU Computing Toolkit/CUDA/v13.2/bin/nvcc.exe" ^
  -DCMAKE_CUDA_ARCHITECTURES=89 ^
  -DLLAMA_CURL=OFF ^
  -DBUILD_SHARED_LIBS=OFF ^
  -DGGML_CCACHE=OFF || exit /b 1

echo === Building voxcpm2-cli + llama-tts-server ===
cmake --build build --target voxcpm2-cli llama-tts-server -j %NUMBER_OF_PROCESSORS% || exit /b 1

echo === BUILD OK ===
dir /b build\bin\*.exe
