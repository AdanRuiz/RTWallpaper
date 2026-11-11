# Relieve y sombras largas en el terminador (escena `space`)

> Especificación, no implementada todavía. Extiende la escena `space` ([`space_rtx_wallpaper.md`](space_rtx_wallpaper.md)) para que la luz rasante del amanecer y el atardecer revele el relieve: laderas iluminadas, valles en sombra y sombras de montañas y nubes de cientos de kilómetros, como en las fotos tomadas desde la ISS.

## 1. Objetivo

Cerca del terminador (la línea día/noche) el Sol está a pocos grados sobre el horizonte, así que cualquier relieve proyecta sombras enormes:

| Objeto | Altura | Sol a 5° | Sol a 1° |
|---|---|---|---|
| Sierra Madre | 3 km | 34 km | 172 km |
| Andes / Himalaya | 6 km | 69 km | 344 km |
| Cumulonimbo | 12 km | 137 km | 688 km |

*Longitud de la sombra en terreno plano: `L = H / tan(e)`, con `e` la elevación del Sol.*

A escala de pantalla (≈5–10 km por píxel con el 40–60 % del planeta visible), solo son visibles cerca del terminador. Ahí es donde se concentra todo el trabajo.

**Fuera de alcance:** convertir el planeta en una malla de triángulos para DXR. A 8K serían ~33 M de triángulos y más de 1 GB de BLAS, sin ventaja visual frente a un mapa de alturas.

## 2. Fases

| Fase | Qué añade | Coste GPU estimado* | Prioridad |
|---|---|---|---|
| 1 | Sombreado del relieve (normales a partir del mapa de alturas) | < 0.3 ms | Imprescindible |
| 2 | Sombras proyectadas por el terreno (ray marching sobre el mapa de alturas) | 0.5–1.5 ms | Imprescindible |
| 3 | Altura variable de las nubes: sombras largas y cimas iluminadas tras el ocaso | 0.3–0.6 ms | Recomendada |
| 4 | Rayos crepusculares en la atmósfera (haces de luz y sombra en el aire) | 2–5 ms | Opcional |

\* RTX 4060 Laptop, 2560×1440 + 1920×1080 a 30 FPS. Hoy la escena usa ~35 % de GPU, y el objetivo es no pasar del 45 % con las fases 1–3.

## 3. Datos de elevación

### 3.1 Fuente

* **Preferida:** NOAA **ETOPO 2022**, 60 segundos de arco, *ice surface* (superficie del hielo en Groenlandia y la Antártida). Es de dominio público. Incluye batimetría, que se descarta: el mar se fija a 0 m porque se ve la superficie del agua.
* **Alternativa:** GEBCO 2024 (misma resolución, uso libre con atribución).
* **No sirven:** las capas de GIBS de relieve sombreado (`ASTER_GDEM_Greyscale_Shaded_Relief`, `SRTM_Color_Index`), porque son imágenes ya sombreadas o coloreadas, no alturas.

Las URL exactas y las licencias se verifican al implementar.

### 3.2 Preprocesado (una vez, fuera de la app)

Script nuevo, `scripts/make_relief.py` (numpy + rasterio, ejecutado en el contenedor de Docker):

1. Lee el GeoTIFF de ETOPO y fija `max(h, 0)` (mar = 0 m).
2. Remuestrea a equirectangular **8192×4096** (y 4096×2048) con filtro de área. Usa la misma convención de UV que `LatLonUV` en `Space.hlsl`: u = longitud, v = latitud, con la misma orientación que el mapa de día. Se comprueba superponiendo las costas.
3. Codifica las alturas en 16 bits: `valor = round(h_m / 9000 * 65535)`, con 9000 m = 1.0, lo que da una resolución de 0.14 m.
4. Guarda `earth_relief_8192.png` (PNG en gris de 16 bits, ~25–35 MB) y `earth_relief_4096.png`.

### 3.3 Distribución

* Ambos PNG se publican como **assets de un release** de GitHub (`relief-data-v1`), no en el repositorio.
* La app los descarga con `http::Download` (ETag) a `%LOCALAPPDATA%\RTWallpaper\cache\` la primera vez, igual que los mapas de la NASA. Al ser estáticos, no se vuelven a descargar.
* Con `Offline=1` o si la descarga falla, la fase 1–2 se desactiva sin errores (`params` indica si hay mapa de relieve).
* Créditos en el README: ETOPO 2022 (NOAA NCEI).

### 3.4 Carga en la GPU

* `image::Load` hoy convierte todo a RGBA8. Hace falta una variante `image::LoadGray16` que use WIC con `GUID_WICPixelFormat16bppGray`.
* Formato **`DXGI_FORMAT_R16G16_UNORM`**, en el slot **3 (t4, libre hoy)**:
  * **R** = altura media del texel (mips con promedio, para el sombreado);
  * **G** = altura **máxima** del texel (mips con máximo, para saltar zonas planas en el ray marching).
* `image::MakeMips` necesita un modo de filtro por canal (promedio para R, máximo para G).
* Memoria: 8192×4096×4 B ≈ 128 MB, 171 MB con mips. Con `ReliefSize=4096` son 43 MB.
* `textureInfo.w` = ancho del mapa de relieve.
* `params` ya está lleno (x = tiempo, y/z/w = hay día/noche/nubes), así que se añade `float4 reliefInfo` a `Constants`: x = hay relieve, y = exageración, z = flags (sombras de terreno, alturas de nubes), w = reservado.

## 4. Fase 1: sombreado del relieve

En `EarthClosestHit`, después de calcular `ecef` y `uv`:

```hlsl
// Altura en km (con exageración), muestreada con el LOD de la huella del píxel.
float HeightKm(float2 uv, float lod) { return g_relief.SampleLevel(g_linear, uv, lod).r * 9.0f * g_cb.reliefInfo.y; }
```

1. **Pendientes:** diferencias centrales a un texel de distancia en el mip elegido:
   * `dx_km = 2π·RE·cos(lat) / W · 2^lod` (este–oeste; `cos(lat)` limitado a ≥ 0.02 cerca de los polos);
   * `dy_km = π·RE / H · 2^lod` (norte–sur).
2. **Base tangente** en coordenadas fijas a la Tierra: `east = normalize(cross(z, n))` y `north = cross(n, east)`. Cerca de los polos se usa una alternativa estable.
3. **Normal perturbada:** `N' = normalize(N − (dh/dEast)·east − (dh/dNorth)·north)`.
4. `N'` se usa **solo** en el término difuso del suelo y en la sombra de nubes. El brillo especular del mar, la atmósfera y las luces nocturnas siguen con `N`. El mar no tiene relieve: si el canal `ocean` del mapa de día es 1, `N' = N`.
5. **LOD:** el de `TextureLod(textureInfo.w, N, V)`, así el relieve no parpadea al alejarse.

**Exageración** (`ReliefExaggeration`, por defecto 1.5): el relieve real es sutil a escala planetaria. La exageración afecta al sombreado y a las sombras, nunca a la geometría (la esfera sigue siendo exacta).

## 5. Fase 2: sombras proyectadas por el terreno

Un rayo marcha sobre el mapa de alturas desde el punto `P`, en dirección al Sol, comparando la altura del rayo con la del terreno. No hay mallas ni rayos DXR adicionales: es un bucle en el closest hit de la Tierra.

### 5.1 Cuándo se aplica

* La elevación del Sol en el punto es `e = asin(dot(N, L))`, sobre la esfera, sin relieve.
* Se aplica solo si **−3° < e < 12°**. Con `e > 12°` las sombras miden menos de 2 km (subpíxel), y en los bordes de la franja se mezcla suavemente.
* Con `e < 0` el punto está más allá del terminador geométrico, pero **un pico aún puede ver el Sol**: un pico de altura `h` lo ve mientras `e > −sqrt(2h/RE)` (≈ −2.4° para 6 km). Eso da las cumbres iluminadas en la zona de noche.

### 5.2 Algoritmo

```
h0   = altura del terreno en P (km)
t    = dirección al Sol proyectada en el plano tangente, en ECEF, normalizada
sMax = min(600 km, (8.85 km − h0) / max(tan(e), 0.005))   // más lejos el rayo ya está sobre el Everest
for i in 0..N-1 (N = 24):
    s  = 1 km · (sMax / 1 km)^(i / (N-1))                   // pasos exponenciales: finos cerca de P
    zR = h0 + s·tan(e) + s² / (2·RE)                        // altura del rayo sobre la esfera (curvatura incluida)
    q  = punto en la esfera a distancia s de P sobre el gran círculo de dirección t
    Hm = canal G (máximo) en q, con lod = log2(paso_i / texel_km)
    if Hm < zR: continue                                    // nada en este tramo puede tapar el Sol
    H  = canal R (medio) en q, con el mismo lod
    occ = min(occ, (zR − H) / s)                            // margen angular (rad) sobre el terreno
vis = saturate(occ / (2·α) + 0.5)                           // α = radio angular del Sol = sunInfo.x (0.267°)
```

* **Penumbra:** el Sol no es un punto. Si `occ` está a menos de ±α del borde, la sombra queda en penumbra, lo que da sombras suaves y realistas sin rayos extra.
* **Salida temprana:** si `zR` supera 8.85 km, ningún punto más lejano puede tapar el Sol.
* La visibilidad del terreno multiplica a la sombra de nubes y a la de la Tierra: `luz = E · vis_terreno · cloudShadow · ...`.
* **Coste:** 24 lecturas de textura con mips, solo en la franja del terminador (~10–20 % de los píxeles de la Tierra). Las lecturas del canal G con LOD alto evitan la mayoría de las lecturas finas.

### 5.3 Alternativa si el coste no cabe: mapa de sombras precalculado

El Sol se mueve 0.25° por minuto. Un hilo de CPU puede recalcular la visibilidad de la franja del terminador en un mapa de 4096×2048 (R8) cada 20 s, con el mismo algoritmo y 8 hilos. La GPU mezcla los dos últimos mapas según el tiempo para evitar saltos: con `e = 1°`, en 20 s la sombra cambia ~8 %. Coste por frame: una lectura de textura. Requiere un slot más (`kMaxSceneTextures` = 5).

Se implementa primero el ray marching en el shader (más simple, sin infraestructura nueva). Se pasa al precálculo solo si las mediciones lo piden.

## 6. Fase 3: nubes con altura

Hoy las nubes son una capa plana a `CLOUD_HEIGHT = 8 km`, y su sombra se proyecta con un solo desplazamiento. El mapa de nubes no trae alturas, así que se estiman a partir de la opacidad:

```
hCloud(a) = 2 km + 10 km · smoothstep(0.55, 1.0, a)   // velos finos a ~2–4 km, núcleos densos (cumulonimbos) hasta 12 km
```

1. **Sombra de nubes:** ray marching de 8 pasos (de 2 a 150 km, o hasta `12 km / tan(e)`) desde `P` hacia el Sol sobre el mapa de nubes. En cada paso, una nube a distancia `s` hace sombra si `hCloud(a) > s·tan(e) + s²/(2·RE)`. La sombra acumulada es `1 − 0.65·opacidad` como hoy, pero con su longitud real.
2. **Cimas iluminadas tras el ocaso:** la iluminación de la nube se evalúa a su altura `hCloud` (hoy es fija a 8 km en `SunTransmittance(P + N·CLOUD_HEIGHT)`). Las cimas de los cumulonimbos siguen al sol, rosadas y anaranjadas, cuando el suelo ya está de noche. Es el efecto más visible en las fotos de la ISS.
3. **Autosombra simple:** el lado de la nube opuesto al Sol se oscurece según el gradiente de opacidad en la dirección `t`. Son 2 lecturas extra.

## 7. Fase 4 (opcional): rayos crepusculares

Los haces de luz y sombra visibles en el aire requieren saber, en cada muestra de `Atmosphere` (12 por rayo), si ese punto del aire está a la sombra de una montaña o de una nube:

* versión barata: solo las 4 muestras más bajas (< 15 km), en una consulta reducida (8 pasos) al mapa de alturas o de nubes; solo en la franja del terminador;
* coste estimado: 2–5 ms. Requiere medir antes de aceptarla; si no cabe, se descarta.

## 8. Configuración (`[Space]`)

```ini
Relief=1                  ; 0 = esfera lisa (comportamiento actual)
ReliefSize=8192           ; 4096 | 8192 (mapa de alturas)
ReliefExaggeration=1.5    ; 1 = relieve real; afecta al sombreado y a las sombras
ReliefShadows=1           ; sombras proyectadas por el terreno (fase 2)
CloudHeights=1            ; altura de nubes estimada, sombras largas y cimas iluminadas (fase 3)
CrepuscularRays=0         ; fase 4 (opcional, cara)
```

Como el resto de `[Space]`, un cambio en esta sección recrea la escena en caliente.

**Desactivar:** con `Relief=0` la escena queda **exactamente como hoy**: no se descarga el mapa de alturas, no se reserva memoria en la GPU (el slot t4 queda con un SRV nulo) y el shader se salta todo el código de relieve con una sola comprobación de `reliefInfo.x`. Cada efecto se puede apagar por separado: `ReliefShadows=0` deja solo el sombreado de laderas.

## 9. Cambios por archivo

| Archivo | Cambio |
|---|---|
| `scripts/make_relief.py` | Nuevo: ETOPO → PNG de 16 bits 8192/4096 |
| `src/space/Image.hpp` | `LoadGray16` (WIC 16bpp gris) y mips por canal (promedio / máximo) |
| `src/scenes/SpaceScene.hpp` | Descarga y carga del relieve en el slot 3, `reliefInfo` en `Constants` y lectura de las claves del .ini |
| `src/shaders/Space.hlsl` | `g_relief : register(t4)`, `HeightKm`, normal perturbada, `TerrainVisibility`, sombras y altura de nubes |
| `src/main.cpp` | Claves nuevas en el .ini por defecto |
| `config/RTWallpaper.ini` | Ídem |
| `tests/astro_test.cpp` | Pruebas de la geometría de sombras (§10) |
| `README.md`, `docs/space_rtx_wallpaper.template.md` | Documentación, configuración y créditos de ETOPO |

## 10. Verificación

**Pruebas numéricas** (CPU, `tests/astro_test.cpp`, con la misma fórmula que el shader):

* sombra de 6 km con el Sol a 1°: 344 km ± 2 % sin curvatura, y más corta con curvatura;
* un pico de 6 km ve el Sol hasta `e = −2.4°`;
* `zR(s)` con curvatura coincide con la distancia exacta rayo–esfera a < 1 m para s ≤ 600 km;
* codificación: `9000 m → 65535`, `0 m → 0` y el mar queda en 0.

**Pruebas visuales:** con `TimeOffsetHours` se fuerza el momento y se comparan con fotos de la ISS.

* Andes al amanecer local: sombras largas hacia el oeste;
* Himalaya al atardecer: cumbres iluminadas con el valle del Ganges ya de noche;
* Sierra Madre Occidental (vista inicial sobre México) al atardecer;
* tormentas tropicales cerca del terminador: cimas rosadas y sombras de cientos de km;
* sin parpadeo al moverse la cámara ni al cambiar de LOD; el mar sigue liso.

**Rendimiento:**

* medir la GPU (Administrador de tareas o `--debug`) con las fases 1, 1+2 y 1+2+3 activas, en los dos monitores;
* criterio de aceptación: ≤ 45 % de GPU y 30 FPS estables con las fases 1–3;
* si no se cumple: bajar N a 16 pasos, usar `ReliefSize=4096` o pasar al mapa precalculado (§5.3).

## 11. Riesgos

* **Exageración:** demasiado relieve hace que la Tierra parezca una maqueta. Mantener ≤ 2 y validar contra fotos reales.
* **Alturas de nubes estimadas:** la opacidad no es altura. Puede haber nieblas densas con sombras largas falsas. Hay que suavizar la curva y limitar la longitud.
* **Costuras:** en la línea de cambio de fecha (u = 0/1) las diferencias y el ray marching deben usar el wrap en U (el sampler ya lo hace) y el clamp en V cerca de los polos.
* **Tamaño de descarga:** 25–35 MB la primera vez; con `ReliefSize=4096`, ~8 MB.
