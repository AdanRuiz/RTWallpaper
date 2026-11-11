# RTWallpaper — fondos de pantalla con Ray Tracing real (DXR)

Fondos de escritorio animados para Windows que usan **DirectX Raytracing (DXR 1.0)** nativo en la GPU, en tiempo real.
Incluye varias escenas que se eligen en un archivo de configuración.

| Escena | Diseño | Qué hay |
|---|---|---|
| `marble` | [`ray_tracing_windows_desktop_wallpaper.md`](ray_tracing_windows_desktop_wallpaper.md) | Piso de mármol negro con reflexión Fresnel y sombras; 3 esferas de cuarzo exactas con refracción de Snell, reflexión interna total y absorción de Beer; 2 luces de neón; movimiento con OpenSimplex2 ([FastNoiseLite](https://github.com/Auburn/FastNoiseLite)). |
| `space` | [`space_rtx_wallpaper.md`](space_rtx_wallpaper.md) | La Tierra (procedural: continentes, océanos con brillo del sol, hielo, nubes, luces de ciudades en el lado nocturno, atmósfera Fresnel y halo en el borde); 2 satélites LEO (16 órbitas por rotación terrestre) con foil dorado, paneles solares y reflejos metálicos trazados, eclipses al pasar por la sombra de la Tierra; Sol, estrellas y Vía Láctea; cámara en deriva cinemática. |

Las texturas de la Tierra que menciona el diseño (`g_EarthDayMap`/`g_EarthNightMap`) se reemplazaron por superficie procedural, así el `.exe` no depende de archivos externos.

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

## Configuración (`RTWallpaper.ini`)

Está junto al `.exe` (se crea solo si falta). **Los cambios se aplican al guardar**, sin reiniciar:

```ini
[General]
; Escena: marble | space
Scene=space
; Límite de FPS (menos = menos GPU)
FPS=60
; Velocidad de la animación (1.0 = como en el diseño, 0.5 = la mitad)
Speed=1.0
```

También puedes cambiar de escena desde el icono de la bandeja (modo fondo) o con **Tab** (modo ventana).

## Uso

```powershell
build\RTWallpaper.exe               # en una ventana (Esc para salir)
build\RTWallpaper.exe --wallpaper   # como fondo, detrás de los iconos del escritorio
build\RTWallpaper.exe --stop        # detiene la instancia de fondo
```

Opciones: `--scene marble|space` y `--fps N` (tienen prioridad sobre el .ini), `--debug` (capa de depuración de D3D12).

En modo `--wallpaper`:
- Aparece un icono en la bandeja del sistema con: lista de escenas, **Editar configuración**, **Pausar** y **Salir**.
- Se pausa sola cuando hay una app o juego en pantalla completa (GPU a 0%).
- Funciona con el layout del escritorio de Windows 11 24H2+ y con el clásico (WorkerW).
- Para que arranque con Windows: crea un acceso directo con `--wallpaper` en `shell:startup`.

### Con Lively Wallpaper (opcional)

Como en el documento original: en Lively, **Add Wallpaper → Browse** y elige `RTWallpaper.exe` (sin argumentos).

## Estructura

```
src/main.cpp             renderer DXR genérico, config .ini, modo wallpaper, bandeja
src/scenes/Scene.h       interfaz de escena (librería DXIL, hit groups, geometría, animación)
src/scenes/*Scene.h      escenas: MarbleScene, SpaceScene
src/shaders/*.hlsl       shaders DXR de cada escena (se compilan todos automáticamente)
config/RTWallpaper.ini   configuración por defecto
third_party/             FastNoiseLite.h (MIT)
docker/                  toolchain de compilación cruzada
scripts/build.sh         compilación dentro del contenedor
build.ps1                punto de entrada en Windows
```

## Añadir una escena

1. Crea `src/shaders/MiEscena.hlsl` exportando `RayGen`, `Miss`, `ShadowMiss` y tus hit groups (root signature: `u0` salida, `t0` TLAS, `b0` constantes).
2. Crea `src/scenes/MiEscenaScene.h` que herede de `Scene` e incluya `MiEscena.hlsl.h` (`g_pMiEscena`).
3. Regístrala en `kSceneNames` / `CreateScene` en `src/main.cpp`.
