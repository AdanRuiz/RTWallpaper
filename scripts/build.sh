#!/usr/bin/env bash
# Runs inside the rtwallpaper-toolchain container: compiles HLSL -> DXIL and C++ -> RTWallpaper.exe
set -euo pipefail
cd /src
mkdir -p build

echo "[1/2] dxc: src/shaders/*.hlsl -> DXIL (lib_6_3)"
for f in src/shaders/*.hlsl; do
  name=$(basename "$f" .hlsl)
  echo "      $f -> build/$name.hlsl.h (g_p$name)"
  dxc -T lib_6_3 -HV 2021 -O3 -Fh "build/$name.hlsl.h" -Vn "g_p$name" "$f"
done

echo "[2/2] clang-cl: src/main.cpp -> build/RTWallpaper.exe"
X=/xwin
clang-cl --target=x86_64-pc-windows-msvc -fuse-ld=lld \
  /std:c++17 /O2 /EHsc /MT /W3 /DUNICODE /D_UNICODE /D_ALLOW_COMPILER_AND_STL_VERSION_MISMATCH \
  -Wno-unused-command-line-argument -Wno-nonportable-include-path \
  -imsvc $X/crt/include -imsvc $X/sdk/include/ucrt -imsvc $X/sdk/include/um \
  -imsvc $X/sdk/include/shared -imsvc $X/sdk/include/winrt \
  /Ibuild /Ithird_party /Isrc /Isrc/scenes \
  src/main.cpp /Fobuild/main.obj /Febuild/RTWallpaper.exe \
  /link /SUBSYSTEM:WINDOWS \
  /LIBPATH:$X/crt/lib/x86_64 /LIBPATH:$X/sdk/lib/um/x86_64 /LIBPATH:$X/sdk/lib/ucrt/x86_64 \
  d3d12.lib dxgi.lib user32.lib shell32.lib

# Default config next to the exe (never overwrites your edits).
[ -f build/RTWallpaper.ini ] || cp config/RTWallpaper.ini build/RTWallpaper.ini
ls -la build/RTWallpaper.exe build/RTWallpaper.ini
