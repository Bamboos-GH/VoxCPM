@echo off
setlocal
REM ============================================================
REM  VoxCPM2 llama-quantize 构建脚本 (T49)
REM  用途: 构建 llama.cpp 标准量化工具, 用于 BaseLM Q8_0 -> Q4_K
REM  背景: 声学侧 k-quant 走 ggml-cpy 算子矩阵不支持(见 memory T49);
REM        BaseLM 是 minicpm4 标准架构, llama-quantize 原生支持。
REM  注意: build 树在 T44 搬迁后需重 configure(旧绝对路径失效);
REM         CMakeCache/CMakeFiles 损坏时删除后重跑本脚本。
REM ============================================================
call "C:\Program Files (x86)\Microsoft Visual Studio\2022\BuildTools\VC\Auxiliary\Build\vcvars64.bat" || exit /b 1
set "PATH=C:\Program Files\NVIDIA GPU Computing Toolkit\CUDA\v13.2\bin;D:\Kit\Python\Scripts;%PATH%"
cd /d "D:\Data\OpenCode\DeckTalk\engines\voxcpm2\llama.cpp-omni"

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

echo === Building llama-quantize ===
cmake --build build --target llama-quantize -j %NUMBER_OF_PROCESSORS% || exit /b 1

echo === BUILD OK ===
dir /b build\bin\llama-quantize.exe
