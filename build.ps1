# Builds build\RTWallpaper.exe using Docker (no Visual Studio needed).
#   .\build.ps1            build (creates the toolchain image the first time)
#   .\build.ps1 -Rebuild   recreate the toolchain image
param([switch]$Rebuild)
$ErrorActionPreference = 'Stop'
$image = 'rtwallpaper-toolchain'
$root = $PSScriptRoot

docker image inspect $image *> $null
if ($Rebuild -or $LASTEXITCODE -ne 0) {
    Write-Host '==> Building toolchain image (clang-cl + Windows SDK via xwin + DXC)...'
    docker build -t $image "$root\docker"
    if ($LASTEXITCODE -ne 0) {
        # Docker Desktop sometimes has broken DNS during 'docker build'; retry with an explicit DNS server.
        Write-Host '==> docker build failed, retrying with docker run --dns 1.1.1.1 + commit...'
        docker rm -f rtw-setup *> $null
        docker run --name rtw-setup --dns 1.1.1.1 -v "${root}\docker:/setup:ro" ubuntu:24.04 bash /setup/setup-toolchain.sh
        if ($LASTEXITCODE -ne 0) { throw 'Toolchain setup failed' }
        docker commit -c 'ENV LD_LIBRARY_PATH=/dxc/lib' -c 'WORKDIR /src' -c 'USER ubuntu' rtw-setup $image | Out-Null
        docker rm rtw-setup | Out-Null
    }
}

New-Item -ItemType Directory -Force "$root\build" | Out-Null
# The container builds as the non-root "ubuntu" user; builds before v1.0.1 ran as root and left
# build\ owned by root inside the mount, so hand it over once.
docker run --rm -v "${root}:/src" $image test -w build
if ($LASTEXITCODE -ne 0) {
    Write-Host '==> Fixing ownership of build\ (created by an older root build)...'
    docker run --rm --user 0 -v "${root}:/src" $image chown -R 1000:1000 build
}

Write-Host '==> Compiling shaders + exe...'
docker run --rm -v "${root}:/src" $image bash scripts/build.sh
if ($LASTEXITCODE -ne 0) { throw 'Build failed' }
Write-Host "==> OK: $root\build\RTWallpaper.exe"
