# Toolchain to cross-compile a native Windows x64 DirectX 12 / DXR app from Linux.
# Usually built through ../build.ps1 (which has a fallback for broken Docker DNS).
FROM ubuntu:24.04
COPY setup-toolchain.sh /tmp/setup-toolchain.sh
RUN bash /tmp/setup-toolchain.sh && rm /tmp/setup-toolchain.sh
ENV LD_LIBRARY_PATH=/dxc/lib
WORKDIR /src
# The build only reads the toolchain and writes into the mounted /src: no root needed.
# "ubuntu" (uid 1000) ships with the base image.
USER ubuntu
# One-shot build container, nothing to health-check.
HEALTHCHECK NONE
