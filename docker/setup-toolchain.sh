#!/usr/bin/env bash
# Installs the cross-compilation toolchain (runs inside an ubuntu:24.04 container).
#   - clang-cl + lld-link (LLVM 18)
#   - MSVC CRT + Windows SDK headers/libs via xwin (accepting Microsoft's license)
#   - DXC for Linux (with libdxil.so so DXIL gets validated/signed)
set -euo pipefail
export DEBIAN_FRONTEND=noninteractive

apt-get update
apt-get install -y --no-install-recommends clang-18 lld-18 llvm-18 curl ca-certificates jq tar
rm -rf /var/lib/apt/lists/*
ln -sf /usr/lib/llvm-18/bin/clang /usr/local/bin/clang-cl
ln -sf /usr/bin/lld-link-18 /usr/local/bin/lld-link

# Optional GitHub token (CI): read from a mounted file so it is never stored in the image.
auth=()
if [ -n "${GH_TOKEN_FILE:-}" ] && [ -s "$GH_TOKEN_FILE" ]; then
  auth=(-H "Authorization: Bearer $(cat "$GH_TOKEN_FILE")")
fi

# xwin
url=$(curl -sSL "${auth[@]}" https://api.github.com/repos/Jake-Shadle/xwin/releases/latest \
      | jq -r '.assets[] | select(.name | test("x86_64-unknown-linux-musl.tar.gz$")) | .browser_download_url')
curl -sSL "$url" | tar xz -C /tmp
mv /tmp/xwin-*/xwin /usr/local/bin/xwin
xwin --accept-license --cache-dir /tmp/xwin-cache splat --output /xwin
rm -rf /tmp/xwin-cache /tmp/xwin-*

# DXC
url=$(curl -sSL "${auth[@]}" https://api.github.com/repos/microsoft/DirectXShaderCompiler/releases/latest \
      | jq -r '.assets[] | select(.name | test("linux.*\\.tar\\.gz$")) | .browser_download_url' | head -n1)
mkdir -p /dxc
curl -sSL "$url" | tar xz -C /dxc
ln -sf /dxc/bin/dxc /usr/local/bin/dxc

echo "Toolchain ready."
