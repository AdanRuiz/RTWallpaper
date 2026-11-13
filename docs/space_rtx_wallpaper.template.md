# Ray Tracing Space Wallpaper (Earth & Satellites RTX)

Este documento contiene la especificación y código fuente completo (HLSL y C++) para el fondo de pantalla interactivo en DirectX Raytracing (DXR). Combina física de luz en tiempo real, texturas 8K, comportamiento meteorológico actualizado cada hora y cinemática orbital.

> Escena `space` de RTWallpaper. Se activa con `Scene=space` en `RTWallpaper.ini`.
> Las secciones de código (§8) se generan desde el código fuente real con `python scripts/gen_space_doc.py`.
>
> El código lo generó Claude (Anthropic), y Adán Ruiz lo revisó y lo fue iterando.

---

## 1. Especificación

| # | Requisito | Implementación |
|---|---|---|
| R1 | Ray tracing en tiempo real | DXR 1.0: TLAS reconstruido cada frame, rayos primarios, de sombra (eclipses, brillo del Sol) y de reflexión (metal de los satélites, hasta 3 rebotes). |
| R2 | Física de la luz | Sol direccional con irradiancia que varía con 1/r²; atmósfera de dispersión simple **Rayleigh + Mie** (alturas de escala 8 km y 1.2 km, 100 km de espesor) con la función de Chapman para la transmitancia; reflejo del Sol en el océano con el modelo de **Cox-Munk** (pendientes de las olas según el viento, Fresnel del agua; se alarga solo en vistas rasantes; el viento varía de forma suave a escala de clima, ~600 km, sin umbrales que dibujen manchas; un 15 % de la superficie se trata como agua en calma, que añade el núcleo brillante dentro del brillo ancho; las sombras de las nubes lo apagan; `SunGlint` multiplica su brillo, 2.5 por defecto, porque el valor físico solo llega al blanco en vistas rasantes como las de la ISS); **destello de lente** (rayos de difracción, halo cromático y fantasmas de colores) y brillo del limbo al amanecer, según la fracción del disco solar visible sobre el limbo y su enrojecimiento; crepúsculo que se apaga de forma exponencial; Fresnel metálico en los satélites; luz reflejada por la Tierra (*earthshine*). |
| R3 | Texturas 8K | Mapa diurno **NASA Blue Marble Next Generation** y mapa nocturno **NASA Black Marble (VIIRS)**, 8192×4096, descargados de NASA GIBS, con mipmaps completos generados en CPU y nivel de mip elegido por la huella de cada píxel en el suelo. |
| R4 | Clima actualizado cada hora | Mapa global de nubes en vivo (8192×4096). Un hilo en segundo plano lo consulta **cada 60 min** con `If-None-Match` (ETag) y solo lo descarga si cambió. Las nubes proyectan sombra sobre el suelo, sobre el mar (apaga el reflejo del Sol y oscurece la bruma del aire bajo la nube) y sobre las cimas de otras nubes; su largo se estira con `CloudShadowLength` para que se vean a esta escala (ver `clouds.md` §5.2). |
| R5 | Velocidad de los satélites real respecto al planeta dibujado | Todo se dibuja en **kilómetros**: Tierra de 6371 km y satélites a su altitud real. Las órbitas salen de los **TLE actuales de Celestrak** (ISS y Hubble), propagadas con Kepler + J2 en doble precisión y con el reloj UTC real. |
| R6 | Distancia Sol–Tierra realista | Efemérides solares (Almanaque Astronómico): distancia de **0.983–1.017 UA (≈ 23 000 radios terrestres)** según la fecha, con el tamaño angular real (0.53°). |
| R7 | La pantalla muestra el 40–60 % del planeta | La cámara busca cada frame la inclinación con la que el disco terrestre cubre la fracción objetivo de la pantalla (cuadrícula de 48×27 rayos y búsqueda binaria). El objetivo oscila entre `CoverageMin` y `CoverageMax` con el movimiento del observador. |
| R8 | Rotación terrestre y cámara cinemática | La Tierra gira según el GMST real, así que el lado iluminado coincide con el de este momento. El observador empieza estacionado sobre **México** (configurable), girando con la Tierra, y tras `FocusMinutes` pasa suavemente a seguir la órbita de la ISS desde más alto (entre 2000 y 5200 km de altitud). |
| R9 | Tormentas eléctricas de noche (efecto, no datos reales) | **Relámpagos, sprites, jets gigantes y elves** sobre el lado nocturno. Los núcleos más densos del mapa de nubes hacen de tormentas: el planeta se divide en celdas de 2°×2° con un posible foco cada una y el tiempo en intervalos de 0.5 s; en cada intervalo una tormenta madura tiene un 22 % de probabilidad de dar un relámpago (ilumina su nube desde dentro, 18–45 km de radio, con uno o dos retornos en ~0.25 s). Algunos disparan además un evento luminoso transitorio sobre la tormenta, con la forma de las fotos de referencia: un **sprite** (20 % de los relámpagos), racimo de 3 a 8 «zanahorias» repartidas en ~50 km, cada una con cabeza brillante a ~70 km, resplandor rojo hacia arriba y filamentos que se abren hacia abajo hasta ~45 km, rojos y violetas en las puntas, bajo un halo rojo tenue a 82 km; un **jet gigante** (5 %), tallo blanco azulado que sale de la nube, se vuelve violeta y se abre en un abanico rojo que se desvanece hacia los 80–90 km; o un **elve** (8 %), anillo rojo tenue a 88 km que se expande hasta ~300 km de diámetro. Sprites y elves duran ~0.2 s (alargado respecto a los 1–100 ms reales para que se vean a 30 FPS) y los jets ~0.4 s. Se dibujan en `RayGen` como emisión a lo largo del rayo primario, delante de la Tierra. No usa datos de rayos reales: `sprites.md` describe un predictor con fuentes que no son abiertas o no caben aquí. `Sprites` multiplica la frecuencia; `0` lo apaga. |

## 2. Escala física (verificada)

`tests/astro_test.cpp` comprueba estos valores contra el código de propagación (`src/space/Astro.hpp`):

| Magnitud | Valor calculado | Referencia |
|---|---|---|
| Altitud de la ISS (TLE 2026-11-11) | 430 km | ~420 km |
| Velocidad orbital de la ISS | **7.65 km/s** | √(μ/r) = 7.66 km/s |
| Periodo de la ISS | **92.9 min** | ~93 min |
| Órbitas por rotación terrestre (día sidéreo / periodo) | **15.45** | ~15.5 (el diseño anterior usaba 16 a ojo) |
| Altitud de Hubble | 478 km | ~480 km |
| Distancia Sol–Tierra (11 nov) | **0.990 UA = 23 248 radios terrestres** | 0.990 UA |
| Diámetro angular del Sol | 0.538° | 0.53–0.54° |
| Declinación solar (11 nov) | −17.5° | −17.5° |
| GMST en J2000 | 280.4606° | 280.46061837° |

Con la Tierra de 6371 km, la ISS se mueve a 7.65 km/s, es decir **una vuelta cada 92.9 min en tiempo real**, y la Tierra gira una vez cada 23 h 56 min. Con `Speed=1` todo va a velocidad real. `Speed=N` acelera el reloj de la simulación y mantiene todas las proporciones.

Lo único que no está a escala, a propósito, es el **tamaño** de los satélites (`SatelliteScale=1000`): la ISS mide 109 m, y a escala real ocuparía menos de 0.01 píxeles. El tamaño no afecta a su posición ni a su velocidad.

## 3. Fuentes de datos

| Dato | Fuente | Frecuencia | Caché |
|---|---|---|---|
| Superficie diurna 8K | NASA GIBS WMS, capa `BlueMarble_NextGeneration` (dominio público, NASA) | una vez | `%LOCALAPPDATA%\RTWallpaper\cache\earth_day_8192.jpg` |
| Luces nocturnas 8K | NASA GIBS WMS, capa `VIIRS_Black_Marble` (dominio público, NASA) | una vez | `earth_night_8192.jpg` |
| Nubes en vivo | `clouds.matteason.co.uk` (proyecto *live-cloud-maps*, compuesto global derivado de satélites meteorológicos) | consulta cada `CloudUpdateMinutes` (60); descarga solo si cambió el ETag | `clouds_8192x4096.png` (+ `.etag`) |
| Elementos orbitales | Celestrak GP, NORAD 25544 (ISS) y 20580 (HST), formato TLE | cada 6 h | `tle_25544.txt`, `tle_20580.txt` |

Sin conexión (o con `Offline=1`) usa la caché. Si tampoco hay caché, dibuja una Tierra procedural y los TLE incluidos en el ejecutable. El registro de cada descarga queda en `cache\space.log`.

## 4. Marcos de referencia y tiempo

* **Reloj:** la simulación arranca en la hora UTC actual (más `TimeOffsetHours`) y avanza con `dt × Speed`.
* **ECI** (inercial, ecuatorial): aquí se calculan los satélites (TEME ≈ ECI) y el Sol.
* **Mundo del renderer** (mano derecha, +Y arriba): `mundo = (eci.x, eci.z, −eci.y)`; +Y es el polo norte.
* **ECEF** (fijo a la Tierra): `ECEF = Rz(GMST) · ECI`. El constant buffer lleva la matriz mundo→ECEF (`earthRow[3]`). El shader obtiene latitud y longitud de la normal y muestrea los mapas equirectangulares (u = 0 en 180° O, v = 0 en el polo norte), así que las nubes en vivo quedan alineadas con la geografía.
* **Propagación orbital:** a partir del TLE, `a = (μ/n²)^(1/3)`. Se aplican la regresión nodal y la precesión del perigeo por J2 (`Ω̇ = −3/2·n·J2·(Re/p)²·cos i`, `ω̇ = 3/4·n·J2·(Re/p)²·(5cos²i − 1)`) y se resuelve la ecuación de Kepler con Newton. El error es de decenas de km por día; no es SGP4, pero basta a esta escala.

## 5. Cámara (observador)

0. **Inicio sobre México:** durante los primeros `FocusMinutes` (20 por defecto) el observador está entre 9° y 15° al sur de `FocusLat`/`FocusLon` (23.6° N, 102.5° O), con un vaivén lateral de ±30°, y mira hacia el norte con el horizonte al fondo. Gira con la Tierra, así que México no sale de la vista: se ve de día con las nubes reales y de noche con las luces de sus ciudades. Después pasa en 3 minutos al modo de seguimiento. Con `FocusMinutes=-1` se queda siempre sobre ese punto.
1. **Punto base (seguimiento):** la dirección de la ISS, limitada a 78° del punto subsolar. Mientras la ISS está de día el observador la sigue; cuando entra en la noche, espera junto al terminador, donde siguen viéndose las nubes reales.
2. **Desfase:** de 9° a 19° por detrás de la ISS a lo largo de su órbita, y hasta ±16° fuera del plano orbital.
3. **Altitud:** 3600 ± 1600 km, en un ciclo de 25 min.
4. **Mirada:** apunta a la ISS, o al terminador en su dirección cuando la ISS está en plena noche, y sube o baja la inclinación hasta que la Tierra cubre la fracción objetivo de la pantalla (entre 40 % y 60 %, con un ciclo de 30 min). La ISS no sale del encuadre.
5. **Orientación:** el "arriba" de la cámara es la vertical local, así que el horizonte aparece nivelado.

### Cielo

* **Estrellas:** puntos del tamaño de un píxel (gaussiana con σ = 0.6 píxeles, así no parpadean), en tres capas con una distribución de magnitudes muy inclinada: muchas tenues y pocas brillantes. Son más densas a lo largo del plano galáctico.
* **Vía Láctea**, como en las fotos de larga exposición, construida en coordenadas galácticas:
  * **nubes estelares violetas** que se vuelven rosadas y blanquecinas hacia el núcleo, con un grano fino de estrellas sin resolver;
  * **nebulosas de emisión H-alfa** rojas y magenta: filamentos de ruido *ridged*, solo en algunas regiones y pegadas al plano;
  * **grietas de polvo oscuro**, filamentosas y anchas como la *Gran Grieta*, que absorben la luz de la galaxia y también la de las estrellas de detrás.
* **Orientación** (`Galaxy=`):
  * `scenic` (por defecto): la banda cruza en diagonal la parte superior de la pantalla, con el núcleo arriba a la derecha. Sigue a la cámara con un filtro lento.
  * `real`: polo norte galáctico en AR 192.86°, Dec +27.13°, y centro galáctico en AR 266.40°, Dec −28.94° (Sagitario). Al girar con la Tierra, a veces queda fuera de cuadro.

## 6. Pipeline DXR

| Elemento | Detalle |
|---|---|
| Geometría | BLAS 0: AABB de la esfera unidad (instancia escalada a 6371 km). BLAS 1 y 2: AABB de la ISS y de Hubble a tamaño real en km (instancias escaladas por `SatelliteScale` y orientadas en el marco LVLH). |
| Hit groups | `EarthHitGroup` (intersección esfera exacta + `EarthClosestHit`), `SatelliteHitGroup` (unión de cajas + `SatelliteClosestHit`). |
| Miss | `Miss`: atmósfera + estrellas + disco solar atenuado por la transmitancia. `ShadowMiss`: visibilidad = 1. |
| Recursión | `MAX_DEPTH = 3`, pipeline con `MaxTraceRecursionDepth = 4`. |
| Recursos | `u0` salida, `t0` TLAS, `b0` constantes, `t1` día (sRGB, máscara de océano en alfa), `t2` noche (sRGB), `t3` nubes (R8), `s0` lineal (wrap U / clamp V). |
| Tonemapping | Reinhard extendido sobre la luminancia, que no altera el tono: las nubes quedan blancas. |

## 7. Configuración (`RTWallpaper.ini`)

```ini
[General]
Scene=space
FPS=60
Speed=1.0            ; 1.0 = tiempo real

[Space]
TextureSize=8192     ; mapas día/noche (8K)
CloudSize=8192       ; 1024 | 2048 | 4096 | 8192
CloudUpdateMinutes=60
SatelliteScale=1000  ; solo tamaño visual
CoverageMin=0.40
CoverageMax=0.60
Offline=0
TimeOffsetHours=0    ; ver la Tierra a otra hora
FocusLat=23.6        ; punto inicial de interés (México)
FocusLon=-102.5
FocusMinutes=20      ; minutos sobre ese punto antes de seguir a la ISS (-1 = siempre)
Galaxy=scenic        ; scenic | real
GalaxyBrightness=1   ; brillo de la Vía Láctea: menos = más transparente, 0 = solo estrellas
Clouds=layered       ; flat | layered | volumetric (= layered por ahora); ver clouds.md
CloudRelief=2        ; exageración del relieve de las cimas (layered)
CloudShadowLength=4  ; largo de las sombras de las nubes (layered): 1 = físico, 0 = solo bajo la nube
SunGlint=2.5         ; brillo del reflejo del Sol en el mar: 1 = físico (Cox-Munk), 0 = sin reflejo
Sprites=1            ; relámpagos, sprites, jets y elves sobre las tormentas de noche: frecuencia (0 = sin efecto)
DevMode=0            ; solo desarrollo: cámara de vista general; en ventana, clic derecho gira y la rueda/pellizco hace zoom
DevSpinSeconds=90    ; solo desarrollo (DevMode=1): una vuelta cada N s (0 = sin giro extra)
```

Cualquier cambio en `[Space]` recrea la escena al guardar el archivo. Los mapas se cargan de la caché en pocos segundos.

---

## 8. Código fuente

<!-- SOURCES -->
