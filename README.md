# RTWallpaper — fondo de pantalla con Ray Tracing real (DXR)

Fondo de escritorio animado para Windows que usa **DirectX Raytracing (DXR 1.0)** nativo en la GPU, en tiempo real.
Implementa la escena descrita en [`ray_tracing_windows_desktop_wallpaper.md`](ray_tracing_windows_desktop_wallpaper.md):

- **Piso de mármol negro pulido**: vetas procedurales, reflexión Fresnel (rayos de reflexión reales), sombras con rayos de sombra.
- **3 esferas de cuarzo**: esferas exactas (shader de intersección sobre AABB), refracción de Snell, reflexión Fresnel, reflexión interna total y absorción de Beer (cuarzo claro, amatista y aguamarina).
- **2 luces de neón** (azul cobalto y ámbar) en órbita, más tubos de neón en el entorno.
- **Movimiento orgánico** de las esferas con ruido OpenSimplex2 ([FastNoiseLite](https://github.com/Auburn/FastNoiseLite)).

El acelerador (TLAS) se reconstruye cada frame con las nuevas posiciones. Profundidad de recursión: 5 rebotes.

## Requisitos

- Windows 10/11 y una GPU con soporte DXR (NVIDIA RTX, AMD RX 6000+, Intel Arc).
- Para compilar: solo **Docker Desktop** (no hace falta Visual Studio).

## Compilar

```powershell
.\build.ps1
```

La primera vez crea la imagen `rtwallpaper-toolchain` (Ubuntu + `clang-cl`/`lld-link` + MSVC CRT y Windows SDK descargados con [xwin](https://github.com/Jake-Shadle/xwin) + [DXC](https://github.com/microsoft/DirectXShaderCompiler) para Linux).
Al construirla aceptas la licencia de Microsoft del SDK/CRT. Después compila:

1. `src/Raytracing.hlsl` → DXIL (`lib_6_3`, firmado con `libdxil.so`) embebido como header.
2. `src/main.cpp` → `build/RTWallpaper.exe` (x64, CRT estático, sin dependencias).

## Uso

```powershell
build\RTWallpaper.exe               # en una ventana (Esc para salir)
build\RTWallpaper.exe --wallpaper   # como fondo, detrás de los iconos del escritorio
build\RTWallpaper.exe --stop        # detiene la instancia de fondo
```

Opciones: `--fps N` (límite de FPS, por defecto 60), `--debug` (capa de depuración de D3D12).

En modo `--wallpaper`:
- Aparece un icono en la bandeja del sistema con **Pausar / Salir**.
- Se pausa sola cuando hay una app o juego en pantalla completa (GPU a 0%).
- Funciona con el layout del escritorio de Windows 11 24H2+ y con el clásico (WorkerW).
- Para que arranque con Windows: crea un acceso directo con `--wallpaper` en `shell:startup`.

### Con Lively Wallpaper (opcional)

Como en el documento original: en Lively, **Add Wallpaper → Browse** y elige `RTWallpaper.exe` (sin argumentos).

## Estructura

```
src/Raytracing.hlsl      shaders DXR (raygen, miss, closest hit, intersection)
src/main.cpp             D3D12: dispositivo, BLAS/TLAS, pipeline state object, shader table, modo wallpaper
src/SceneAnimator.h      animación con FastNoiseLite (esferas, luces, cámara)
third_party/             FastNoiseLite.h (MIT)
docker/                  toolchain de compilación cruzada
scripts/build.sh         compilación dentro del contenedor
build.ps1                punto de entrada en Windows
```
