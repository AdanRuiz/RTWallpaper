#!/usr/bin/env bash
# Runs inside the rtwallpaper-toolchain container: compiles HLSL -> DXIL and C++ -> RTWallpaper.exe
set -euo pipefail
cd /src
mkdir -p build

echo "[1/2] dxc: src/Raytracing.hlsl -> DXIL (lib_6_3)"
dxc -T lib_6_3 -HV 2021 -O3 -Fh build/Raytracing.hlsl.h -Vn g_pRaytracing src/Raytracing.hlsl

echo "[2/2] clang-cl: src/main.cpp -> build/RTWallpaper.exe"
X=/xwin
clang-cl --target=x86_64-pc-windows-msvc -fuse-ld=lld \
  /std:c++17 /O2 /EHsc /MT /W3 /DUNICODE /D_UNICODE /D_ALLOW_COMPILER_AND_STL_VERSION_MISMATCH \
  -Wno-unused-command-line-argument -Wno-nonportable-include-path \
  -imsvc $X/crt/include -imsvc $X/sdk/include/ucrt -imsvc $X/sdk/include/um \
  -imsvc $X/sdk/include/shared -imsvc $X/sdk/include/winrt \
  /Ibuild /Ithird_party /Isrc \
  src/main.cpp /Fobuild/main.obj /Febuild/RTWallpaper.exe \
  /link /SUBSYSTEM:WINDOWS \
  /LIBPATH:$X/crt/lib/x86_64 /LIBPATH:$X/sdk/lib/um/x86_64 /LIBPATH:$X/sdk/lib/ucrt/x86_64 \
  d3d12.lib dxgi.lib user32.lib shell32.lib

ls -la build/RTWallpaper.exe
