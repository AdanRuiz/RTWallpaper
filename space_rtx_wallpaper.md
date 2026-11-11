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
| R2 | Física de la luz | Sol direccional con irradiancia que varía con 1/r²; atmósfera de dispersión simple **Rayleigh + Mie** (alturas de escala 8 km y 1.2 km, 100 km de espesor) con la función de Chapman para la transmitancia; reflejo del Sol en el océano (Blinn-Phong normalizado + Fresnel de Schlick para agua); Fresnel metálico en los satélites; luz reflejada por la Tierra (*earthshine*). |
| R3 | Texturas 8K | Mapa diurno **NASA Blue Marble Next Generation** y mapa nocturno **NASA Black Marble (VIIRS)**, 8192×4096, descargados de NASA GIBS, con mipmaps completos generados en CPU y nivel de mip elegido por la huella de cada píxel en el suelo. |
| R4 | Clima actualizado cada hora | Mapa global de nubes en vivo (8192×4096). Un hilo en segundo plano lo consulta **cada 60 min** con `If-None-Match` (ETag) y solo lo descarga si cambió. Proyecta sombras de nubes sobre el suelo. |
| R5 | Velocidad de los satélites real respecto al planeta dibujado | Todo se dibuja en **kilómetros**: Tierra de 6371 km y satélites a su altitud real. Las órbitas salen de los **TLE actuales de Celestrak** (ISS y Hubble), propagadas con Kepler + J2 en doble precisión y con el reloj UTC real. |
| R6 | Distancia Sol–Tierra realista | Efemérides solares (Almanaque Astronómico): distancia de **0.983–1.017 UA (≈ 23 000 radios terrestres)** según la fecha, con el tamaño angular real (0.53°). |
| R7 | La pantalla muestra el 40–60 % del planeta | La cámara busca cada frame la inclinación con la que el disco terrestre cubre la fracción objetivo de la pantalla (cuadrícula de 48×27 rayos y búsqueda binaria). El objetivo oscila entre `CoverageMin` y `CoverageMax` con el movimiento del observador. |
| R8 | Rotación terrestre y cámara cinemática | La Tierra gira según el GMST real, así que el lado iluminado coincide con el de este momento. El observador empieza estacionado sobre **México** (configurable), girando con la Tierra, y tras `FocusMinutes` pasa suavemente a seguir la órbita de la ISS desde más alto (entre 2000 y 5200 km de altitud). |

## 2. Escala física (verificada)

`tests/astro_test.cpp` comprueba estos valores contra el código de propagación (`src/space/Astro.h`):

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
```

Cualquier cambio en `[Space]` recrea la escena al guardar el archivo. Los mapas se cargan de la caché en pocos segundos.

---

## 8. Código fuente

### 8.1 Shaders HLSL (`src/shaders/Space.hlsl`)

```hlsl
// DXR shaders for scene "space" (space_rtx_wallpaper.md). World units: kilometres.
//   - Earth (R = 6371 km): NASA Blue Marble day map, Black Marble night lights, live cloud map
//     with cloud shadows, ocean sun glint, physically based single-scattering atmosphere
//     (Rayleigh + Mie, 100 km thick, Chapman approximation for sunlight transmittance)
//   - ISS and Hubble: box models at real dimensions (scaled up by the instance transform),
//     traced metallic reflections, eclipse shadows from the Earth
//   - Sun with its real angular size, starfield
// Compiled with: dxc -T lib_6_3

#define MAX_DEPTH 3          // SpaceScene::MaxRecursion() = MAX_DEPTH + 1
#define PI 3.14159265f

static const float  RE = 6371.0f;            // Earth radius (km)
static const float  RA = 6471.0f;            // top of the atmosphere (km)
static const float  HR = 8.0f;               // Rayleigh scale height (km)
static const float  HM = 1.2f;               // Mie scale height (km)
static const float3 BETA_R = float3(5.802e-3f, 13.558e-3f, 33.1e-3f);   // Rayleigh scattering (1/km)
static const float  BETA_M = 3.996e-3f;      // Mie scattering (1/km)
static const float  BETA_M_EXT = 4.40e-3f;   // Mie extinction (1/km)
static const float  CLOUD_HEIGHT = 8.0f;     // km, for cloud shadows
static const float  T_MAX = 1.0e9f;

struct SceneConstantBuffer
{
    float4 cameraPosition;   // xyz (km), w = tan(fovY / 2)
    float4 cameraForward;
    float4 cameraRight;
    float4 cameraUp;
    float4 sunDirection;     // xyz towards the sun, w = solar irradiance
    float4 sunInfo;          // x = angular radius (rad), y = distance (km), z = exposure
    float4 earthRow[3];      // world -> Earth-fixed (ECEF) rotation rows
    float4 params;           // x = scene time (s), y = has day map, z = has night map, w = has clouds
    float4 textureInfo;      // x = day width, y = night width, z = cloud width
    float4 galaxyCenter;     // world direction of the galactic centre
    float4 galaxyPole;       // world direction of the galactic north pole
};

struct RayPayload
{
    float3 color;
    uint   depth;
};

struct ShadowPayload
{
    float visibility;
};

struct EarthAttributes
{
    float3 normal;
};

struct SatAttributes
{
    float3 normal;     // object space
    uint   material;   // 0 gold foil, 1 solar panel, 2 metal, 3 white, 4 silver foil
};

RaytracingAccelerationStructure     g_scene  : register(t0);
Texture2D<float4>                   g_day    : register(t1);
Texture2D<float4>                   g_night  : register(t2);
Texture2D<float>                    g_clouds : register(t3);
SamplerState                        g_linear : register(s0);
RWTexture2D<float4>                 g_output : register(u0);
ConstantBuffer<SceneConstantBuffer> g_cb     : register(b0);

// ---------------------------------------------------------------------------
// Utilities
// ---------------------------------------------------------------------------
float Hash31(float3 p)
{
    p = frac(p * 0.3183099f + 0.1f);
    p *= 17.0f;
    return frac(p.x * p.y * p.z * (p.x + p.y + p.z));
}

float Noise3(float3 x)
{
    float3 i = floor(x);
    float3 f = frac(x);
    f = f * f * (3.0f - 2.0f * f);
    return lerp(lerp(lerp(Hash31(i + float3(0, 0, 0)), Hash31(i + float3(1, 0, 0)), f.x),
                     lerp(Hash31(i + float3(0, 1, 0)), Hash31(i + float3(1, 1, 0)), f.x), f.y),
                lerp(lerp(Hash31(i + float3(0, 0, 1)), Hash31(i + float3(1, 0, 1)), f.x),
                     lerp(Hash31(i + float3(0, 1, 1)), Hash31(i + float3(1, 1, 1)), f.x), f.y), f.z);
}

float Fbm3(float3 p, int octaves)
{
    float s = 0.0f, a = 0.5f, norm = 0.0f;
    for (int i = 0; i < octaves; i++)
    {
        s += a * Noise3(p);
        norm += a;
        p = p * 2.02f + float3(17.1f, 3.7f, 9.2f);
        a *= 0.5f;
    }
    return s / norm;
}

// Extended Reinhard on luminance: compresses highlights without shifting hue (clouds stay white).
float3 ToneMap(float3 x)
{
    const float white = 4.0f;
    float l = dot(x, float3(0.2126f, 0.7152f, 0.0722f));
    float lt = l * (1.0f + l / (white * white)) / (1.0f + l);
    return saturate(x * (lt / max(l, 1e-5f)));
}

float3 HitWorldPosition()
{
    return WorldRayOrigin() + RayTCurrent() * WorldRayDirection();
}

float3 EarthFixed(float3 v)
{
    return float3(dot(g_cb.earthRow[0].xyz, v), dot(g_cb.earthRow[1].xyz, v), dot(g_cb.earthRow[2].xyz, v));
}

// Equirectangular UV: u = 0 at 180 W, v = 0 at the North Pole.
float2 LatLonUV(float3 ecef)
{
    float lat = asin(clamp(ecef.z, -1.0f, 1.0f));
    float lon = atan2(ecef.y, ecef.x);
    return float2(lon / (2.0f * PI) + 0.5f, 0.5f - lat / PI);
}

// ---------------------------------------------------------------------------
// Atmosphere (single scattering)
// ---------------------------------------------------------------------------
// Chapman function approximation (C. SchÃ¼ler): relative air mass along a ray towards zenith
// angle chi, starting at normalised height h, for a planet of normalised radius X.
float Chapman(float X, float h, float cosChi)
{
    float c = sqrt(X + h);
    if (cosChi >= 0.0f)
        return c / (c * cosChi + 1.0f) * exp(-h);
    float x0 = sqrt(1.0f - cosChi * cosChi) * (X + h);
    float c0 = sqrt(x0);
    return 2.0f * c0 * exp(min(X - x0, 80.0f)) - c / (1.0f - c * cosChi) * exp(-h);
}

// Transmittance of sunlight from the top of the atmosphere down to pos.
float3 SunTransmittance(float3 pos)
{
    float r = length(pos);
    float h = max(r - RE, 0.0f);
    float mu = dot(pos / r, g_cb.sunDirection.xyz);
    float odR = HR * Chapman(RE / HR, h / HR, mu);
    float odM = HM * Chapman(RE / HM, h / HM, mu);
    return exp(-min(BETA_R * odR + BETA_M_EXT * odM, 80.0f));
}

// In-scattered sunlight along o + d*t, t in [0, tMax]; also returns the view transmittance.
// Samples are packed around the point of closest approach, where the air is densest.
float3 Atmosphere(float3 o, float3 d, float tMax, out float3 transmittance)
{
    transmittance = 1.0f;
    float b = dot(o, d);
    float c = dot(o, o) - RA * RA;
    float disc = b * b - c;
    if (disc <= 0.0f) return 0;
    float s = sqrt(disc);
    float t0 = max(-b - s, 0.0f);
    float t1 = min(-b + s, tMax);
    if (t1 <= t0) return 0;
    float tc = clamp(-b, t0, t1);

    float mu = dot(d, g_cb.sunDirection.xyz);
    float phaseR = 3.0f / (16.0f * PI) * (1.0f + mu * mu);
    const float g = 0.76f;
    float phaseM = (1.0f - g * g) / (4.0f * PI * pow(abs(1.0f + g * g - 2.0f * g * mu), 1.5f));

    const int HALF = 6;   // 12 samples per view ray
    float odR = 0.0f, odM = 0.0f;
    float3 sumR = 0, sumM = 0;
    [unroll]
    for (int side = 0; side < 2; side++)
    {
        float len = side == 0 ? tc - t0 : t1 - tc;
        float sgn = side == 0 ? -1.0f : 1.0f;
        if (len <= 0.0f) continue;
        [loop]
        for (int k = 0; k < HALF; k++)
        {
            int i = side == 0 ? (HALF - 1 - k) : k;     // march from the camera outwards
            float u0 = (float)i / HALF, u1 = (float)(i + 1) / HALF, um = 0.5f * (u0 + u1);
            float dt = len * (u1 * u1 - u0 * u0);
            float3 pos = o + d * (tc + sgn * len * um * um);
            float h = max(length(pos) - RE, 0.0f);
            float dR = exp(-h / HR) * dt;
            float dM = exp(-h / HM) * dt;
            odR += 0.5f * dR;
            odM += 0.5f * dM;
            float3 tr = SunTransmittance(pos) * exp(-min(BETA_R * odR + BETA_M_EXT * odM, 80.0f));
            sumR += tr * dR;
            sumM += tr * dM;
            odR += 0.5f * dR;
            odM += 0.5f * dM;
        }
    }
    transmittance = exp(-min(BETA_R * odR + BETA_M_EXT * odM, 80.0f));
    return g_cb.sunDirection.w * (sumR * BETA_R * phaseR + sumM * BETA_M * phaseM);
}

// ---------------------------------------------------------------------------
// Background: stars and the Sun (real angular size)
// ---------------------------------------------------------------------------
// Point-like stars sized to the pixel (no shimmer), with a steep magnitude distribution:
// many faint stars, a few bright ones, denser along the Milky Way band.
float3 Stars(float3 d)
{
    float pixelAngle = 2.0f * g_cb.cameraPosition.w / float(DispatchRaysDimensions().y);
    float sigma = max(pixelAngle * 0.6f, 1e-5f);
    float band = exp(-d.y * d.y * 30.0f);   // denser along the galactic plane (d in galactic coords)
    float3 col = 0;
    const float scales[3] = { 90.0f, 200.0f, 420.0f };
    const float density[3] = { 0.02f, 0.035f, 0.05f };
    const float gain[3] = { 50.0f, 18.0f, 6.0f };
    [unroll]
    for (int l = 0; l < 3; l++)
    {
        float3 p = d * scales[l];
        float3 cell = floor(p);
        float h = Hash31(cell);
        float thr = 1.0f - density[l] * (1.0f + 2.5f * band);
        if (h > thr)
        {
            float3 off = float3(Hash31(cell + 1.3f), Hash31(cell + 2.7f), Hash31(cell + 4.1f)) * 0.8f + 0.1f;
            float3 star = normalize((cell + off) / scales[l]);
            float a = acos(clamp(dot(d, star), -1.0f, 1.0f));
            float mag = pow(Hash31(cell + 5.9f), 6.0f);                      // steep: few bright stars
            float b = exp(-(a * a) / (sigma * sigma)) * mag * gain[l];
            float3 tint = lerp(float3(0.7f, 0.8f, 1.0f), float3(1.0f, 0.88f, 0.7f), Hash31(cell + 9.0f));
            col += tint * b;
        }
    }
    return col;
}

// Ridged noise: thin bright filaments (gas filaments, dust lanes).
float Ridge(float3 p, int octaves)
{
    float s = 0.0f, a = 0.5f, norm = 0.0f;
    for (int i = 0; i < octaves; i++)
    {
        float v = 1.0f - abs(Noise3(p) * 2.0f - 1.0f);
        s += a * v * v;
        norm += a;
        p = p * 2.03f + float3(5.3f, 1.9f, 7.7f);
        a *= 0.5f;
    }
    return s / norm;
}

// Milky Way, as in long-exposure photos: violet star clouds with light tones towards the
// galactic centre, red H-alpha emission nebulae, and dark dust rifts along the plane.
// Everything is anchored to the galactic plane and domain-warped so it reads as gas, not blobs.
// Returns the emitted light; `dust` (0..1) is the absorption, also applied to the stars behind.
// d is in galactic coordinates: x = towards the centre, y = galactic north pole.
float3 MilkyWay(float3 d, out float dust)
{
    float sb = d.y;                                               // sin(galactic latitude)
    float l = atan2(d.z, d.x);                                    // galactic longitude
    float core = exp(-l * l / 0.45f);                             // bulge around the centre

    float3 q = d * 6.0f;
    float3 warp = float3(Fbm3(q + 1.7f, 3), Fbm3(q + 9.2f, 3), Fbm3(q + 4.4f, 3)) - 0.5f;
    float3 w = q + warp * 0.55f;
    float bw = sb + (Fbm3(d * 4.0f + 2.3f, 3) - 0.5f) * 0.08f;   // wavy band edges
    float width = 0.045f + 0.06f * core;
    float band = exp(-bw * bw / (width * width));

    // Star clouds: violet, turning pinkish-white where dense and near the core.
    float clouds = Fbm3(w * 3.2f, 5);
    float grain = 0.55f + 0.9f * Noise3(d * 900.0f) * Noise3(d * 260.0f + 3.1f);   // unresolved star clouds
    float glow = band * grain * (0.2f + 0.8f * smoothstep(0.35f, 0.75f, clouds)) * (0.35f + 1.65f * core);
    float3 violet = float3(0.40f, 0.28f, 0.78f);
    float3 light = float3(0.98f, 0.86f, 0.95f);
    float3 col = lerp(violet, light, smoothstep(0.55f, 0.85f, clouds) * (0.25f + 0.75f * core)) * glow;

    // H-alpha emission nebulae: red/magenta filaments close to the plane, only in some regions.
    float ha = smoothstep(0.60f, 0.85f, Ridge(w * 4.5f + 5.0f, 4)) * exp(-bw * bw / (0.07f * 0.07f));
    float haRegion = smoothstep(0.52f, 0.72f, Fbm3(d * 3.0f + 7.7f, 3));
    col += float3(0.95f, 0.12f, 0.20f) * ha * haRegion * 1.6f;

    // Dark rifts: filamentary and broad dust lanes right on the plane (like the Great Rift).
    float lanes = smoothstep(0.55f, 0.90f, Ridge(w * 3.6f + 11.0f, 5)) * exp(-sb * sb / (0.035f * 0.035f));
    float broad = smoothstep(0.45f, 0.70f, Fbm3(w * 1.2f + 3.0f, 4)) * exp(-sb * sb / (0.035f * 0.035f));
    dust = saturate(lanes * 0.9f + broad * 0.65f);
    return col * (1.0f - dust) * 1.5f;
}

float3 Sun(float3 d)
{
    float cosA = dot(d, g_cb.sunDirection.xyz);
    float r = g_cb.sunInfo.x;                             // ~0.00465 rad at 1 AU
    return float3(1.0f, 0.96f, 0.9f) * smoothstep(cos(r * 1.15f), cos(r * 0.85f), cosA) * 2000.0f;
}

// Lens glare around the Sun (camera effect), only when the Sun is actually visible.
float3 SunGlare(float3 d)
{
    float r = g_cb.sunInfo.x;
    float a = acos(clamp(dot(d, g_cb.sunDirection.xyz), -1.0f, 1.0f));
    return float3(1.0f, 0.95f, 0.88f) * (24.0f * exp(-a / (r * 5.0f)) + 0.5f * exp(-a / (r * 40.0f)));
}

// World direction -> galactic coordinates. The frame comes from the constant buffer: either the
// real astronomical orientation or a "scenic" one that keeps the band in view.
float3 ToGalactic(float3 d)
{
    float3 x = g_cb.galaxyCenter.xyz, y = g_cb.galaxyPole.xyz;
    return float3(dot(d, x), dot(d, y), dot(d, cross(y, x)));
}

float3 Background(float3 d)
{
    float3 g = ToGalactic(d);
    float dust;
    float3 galaxy = MilkyWay(g, dust);
    return Stars(g) * (1.0f - 0.85f * dust) + galaxy + Sun(d);
}

// ---------------------------------------------------------------------------
// Ray helpers
// ---------------------------------------------------------------------------
float3 TraceRadiance(float3 origin, float3 dir, uint depth)
{
    RayDesc ray;
    ray.Origin    = origin;
    ray.Direction = dir;
    ray.TMin      = 0.001f;
    ray.TMax      = T_MAX;
    RayPayload p;
    p.color = 0;
    p.depth = depth;
    TraceRay(g_scene, RAY_FLAG_NONE, 0xFF, 0, 1, 0, ray, p);
    return p.color;
}

float TraceShadow(float3 origin, float3 dir)
{
    RayDesc ray;
    ray.Origin    = origin;
    ray.Direction = dir;
    ray.TMin      = 0.001f;
    ray.TMax      = T_MAX;
    ShadowPayload p;
    p.visibility = 0.0f;
    TraceRay(g_scene,
             RAY_FLAG_ACCEPT_FIRST_HIT_AND_END_SEARCH | RAY_FLAG_SKIP_CLOSEST_HIT_SHADER,
             0xFF, 0, 1, 1, ray, p);
    return p.visibility;
}

// ---------------------------------------------------------------------------
// Ray generation
// ---------------------------------------------------------------------------
[shader("raygeneration")]
void RayGen()
{
    uint2 idx = DispatchRaysIndex().xy;
    uint2 dim = DispatchRaysDimensions().xy;

    float2 ndc = ((float2(idx) + 0.5f) / float2(dim)) * 2.0f - 1.0f;
    ndc.y = -ndc.y;
    float aspect = float(dim.x) / float(dim.y);
    float tanH = g_cb.cameraPosition.w;
    float3 dir = normalize(g_cb.cameraForward.xyz
                         + ndc.x * aspect * tanH * g_cb.cameraRight.xyz
                         + ndc.y * tanH * g_cb.cameraUp.xyz);

    float3 col = TraceRadiance(g_cb.cameraPosition.xyz, dir, 0);

    // Glare: a shadow ray towards the Sun (hidden behind the Earth => no glare), only for pixels
    // within ~35 degrees of the Sun where the glare is not negligible.
    if (dot(dir, g_cb.sunDirection.xyz) > 0.82f)
    {
        float sunVisible = TraceShadow(g_cb.cameraPosition.xyz, g_cb.sunDirection.xyz);
        col += SunGlare(dir) * sunVisible * SunTransmittance(g_cb.cameraPosition.xyz);
    }

    col *= 1.0f - 0.12f * dot(ndc * 0.7f, ndc * 0.7f);
    col = ToneMap(col * g_cb.sunInfo.z);
    col = pow(col, 1.0f / 2.2f);
    col += (Hash31(float3(idx, 0.5f)) - 0.5f) / 255.0f;
    g_output[idx] = float4(col, 1.0f);
}

// ---------------------------------------------------------------------------
// Miss shaders
// ---------------------------------------------------------------------------
[shader("miss")]
void Miss(inout RayPayload payload)
{
    float3 d = WorldRayDirection();
    float3 T;
    float3 sky = Atmosphere(WorldRayOrigin(), d, T_MAX, T);
    payload.color = sky + Background(d) * T;
}

[shader("miss")]
void ShadowMiss(inout ShadowPayload payload)
{
    payload.visibility = 1.0f;
}

// ---------------------------------------------------------------------------
// Earth: exact sphere (unit sphere in object space, instance scale = 6371 km)
// ---------------------------------------------------------------------------
[shader("intersection")]
void SphereIntersection()
{
    float3 o = ObjectRayOrigin();
    float3 d = ObjectRayDirection();
    float a = dot(d, d);
    float b = dot(o, d);
    float c = dot(o, o) - 1.0f;
    float disc = b * b - a * c;
    if (disc < 0.0f) return;
    float sq = sqrt(disc);
    float t0 = (-b - sq) / a;
    float t1 = (-b + sq) / a;
    EarthAttributes attr;
    if (t0 >= RayTMin() && t0 <= RayTCurrent())
    {
        attr.normal = normalize(o + t0 * d);
        ReportHit(t0, 0, attr);
    }
    else if (t1 >= RayTMin() && t1 <= RayTCurrent())
    {
        attr.normal = normalize(o + t1 * d);
        ReportHit(t1, 0, attr);
    }
}

float CloudOpacity(float a)
{
    return pow(saturate((a - 0.32f) / 0.63f), 1.6f);
}

// Mip level so that one texel roughly matches the pixel footprint on the ground.
float TextureLod(float width, float3 N, float3 V)
{
    float pixelAngle = 2.0f * g_cb.cameraPosition.w / float(DispatchRaysDimensions().y);
    float footprint = RayTCurrent() * pixelAngle / max(dot(N, V), 0.2f);   // km
    float texel = 2.0f * PI * RE / max(width, 1.0f);                       // km
    return log2(max(footprint / texel, 1.0f));
}

float3 ProceduralAlbedo(float3 ecef, out float ocean)
{
    float h = Fbm3(ecef * 2.1f, 6);
    float land = smoothstep(0.515f, 0.53f, h);
    ocean = 1.0f - land;
    float ice = smoothstep(0.80f, 0.86f, abs(ecef.z) + (h - 0.5f) * 0.25f);
    float3 c = lerp(float3(0.01f, 0.03f, 0.08f), float3(0.12f, 0.14f, 0.07f), land);
    return lerp(c, float3(0.75f, 0.78f, 0.82f), ice);
}

[shader("closesthit")]
void EarthClosestHit(inout RayPayload payload, in EarthAttributes attr)
{
    float3 N = normalize(attr.normal);
    float3 P = N * RE;
    float3 D = WorldRayDirection();
    float3 V = -D;
    float3 L = g_cb.sunDirection.xyz;
    float  E = g_cb.sunDirection.w;
    float  NdotL = dot(N, L);

    float3 ecef = EarthFixed(N);
    float2 uv = LatLonUV(ecef);

    // Surface: NASA Blue Marble (rgb) + ocean mask (a), or procedural fallback.
    float3 albedo;
    float ocean;
    if (g_cb.params.y > 0.5f)
    {
        float4 day = g_day.SampleLevel(g_linear, uv, TextureLod(g_cb.textureInfo.x, N, V));
        albedo = day.rgb;
        ocean = day.a;
    }
    else
    {
        albedo = ProceduralAlbedo(ecef, ocean);
    }

    // Live clouds (coverage) and their shadows on the ground.
    float cloud = 0.0f, cloudShadow = 1.0f;
    if (g_cb.params.w > 0.5f)
    {
        float lodC = TextureLod(g_cb.textureInfo.z, N, V);
        // The live map is infrared-derived: cold ground and thin cirrus read as partly cloudy.
        // Keep dense clouds opaque and make thin ones translucent.
        cloud = CloudOpacity(g_clouds.SampleLevel(g_linear, uv, lodC));
        if (NdotL > 0.0f)
        {
            float3 Le = EarthFixed(L);
            float3 tang = Le - ecef * dot(ecef, Le);
            float3 ns = normalize(ecef + tang * (CLOUD_HEIGHT / RE) / max(NdotL, 0.1f));
            cloudShadow = 1.0f - 0.65f * CloudOpacity(g_clouds.SampleLevel(g_linear, LatLonUV(ns), lodC));
        }
    }

    // Direct sunlight, attenuated by the atmosphere above this point, plus blue skylight.
    float3 Tsun = SunTransmittance(P);
    float3 irradiance = E * Tsun * saturate(NdotL);
    float3 skylight = E * float3(0.03f, 0.05f, 0.09f) * saturate(NdotL + 0.15f);
    float3 color = albedo * (irradiance * cloudShadow + skylight);

    // Ocean sun glint (normalised Blinn-Phong + Schlick Fresnel for water).
    float3 H = normalize(L + V);
    float F = 0.02f + 0.98f * pow(1.0f - saturate(dot(V, H)), 5.0f);
    const float shininess = 700.0f;
    float spec = pow(saturate(dot(N, H)), shininess) * (shininess + 8.0f) / (8.0f * PI) * F;
    color += irradiance * spec * ocean * cloudShadow * (1.0f - cloud);

    // Clouds: bright, slightly forward-scattering, light wraps a bit past the terminator.
    float3 cloudLight = (E * SunTransmittance(P + N * CLOUD_HEIGHT) * saturate(NdotL + 0.05f) + skylight * 2.0f) * 0.8f;
    color = lerp(color, cloudLight, cloud);

    // City lights (NASA Black Marble): keep the warm lights, drop the bluish moonlit terrain.
    if (g_cb.params.z > 0.5f)
    {
        float3 night = g_night.SampleLevel(g_linear, uv, TextureLod(g_cb.textureInfo.y, N, V)).rgb;
        float lights = saturate((night.r + night.g) * 0.5f - night.b * 0.75f) * 6.0f;
        float dark = 1.0f - smoothstep(-0.08f, 0.06f, NdotL);
        color += float3(1.0f, 0.70f, 0.38f) * lights * dark * (1.0f - 0.8f * cloud) * 1.5f;
    }

    // Aerial perspective: view-ray transmittance + in-scattering.
    float3 T;
    float3 inscatter = Atmosphere(WorldRayOrigin(), D, RayTCurrent(), T);
    payload.color = color * T + inscatter;
}

// ---------------------------------------------------------------------------
// Satellites: union of boxes, real dimensions in km
// (+Y away from the Earth, +Z along the velocity, +X along the orbit normal)
// ---------------------------------------------------------------------------
struct Box
{
    float3 c;
    float3 h;
    uint   m;
};

// International Space Station: 109 m truss, 8 solar wings (35 x 12 m), modules, radiators.
static const Box kIss[13] = {
    { float3( 0.000f,  0.0000f,  0.000f), float3(0.0545f, 0.0022f, 0.0022f), 2 },  // integrated truss
    { float3( 0.000f, -0.0045f,  0.000f), float3(0.0022f, 0.0022f, 0.0260f), 3 },  // pressurised modules
    { float3( 0.000f, -0.0045f,  0.012f), float3(0.0110f, 0.0020f, 0.0020f), 3 },  // node / lab cross
    { float3( 0.040f,  0.0000f,  0.0205f), float3(0.0058f, 0.0002f, 0.0173f), 1 }, // solar wings
    { float3( 0.040f,  0.0000f, -0.0205f), float3(0.0058f, 0.0002f, 0.0173f), 1 },
    { float3( 0.052f,  0.0000f,  0.0205f), float3(0.0058f, 0.0002f, 0.0173f), 1 },
    { float3( 0.052f,  0.0000f, -0.0205f), float3(0.0058f, 0.0002f, 0.0173f), 1 },
    { float3(-0.040f,  0.0000f,  0.0205f), float3(0.0058f, 0.0002f, 0.0173f), 1 },
    { float3(-0.040f,  0.0000f, -0.0205f), float3(0.0058f, 0.0002f, 0.0173f), 1 },
    { float3(-0.052f,  0.0000f,  0.0205f), float3(0.0058f, 0.0002f, 0.0173f), 1 },
    { float3(-0.052f,  0.0000f, -0.0205f), float3(0.0058f, 0.0002f, 0.0173f), 1 },
    { float3( 0.018f, -0.0030f, -0.0070f), float3(0.0065f, 0.0002f, 0.0110f), 3 }, // radiators
    { float3(-0.018f, -0.0030f, -0.0070f), float3(0.0065f, 0.0002f, 0.0110f), 3 },
};

// Hubble Space Telescope: 13.2 m x 4.2 m tube, aperture door, 2 solar arrays (7.1 x 2.6 m).
static const Box kHubble[5] = {
    { float3( 0.0000f, 0.0000f,  0.0000f), float3(0.0021f, 0.0021f, 0.0066f), 4 },  // optical tube
    { float3( 0.0000f, 0.0000f, -0.0072f), float3(0.0022f, 0.0022f, 0.0006f), 4 },  // aft shroud
    { float3( 0.0000f, 0.0016f,  0.0076f), float3(0.0021f, 0.0004f, 0.0012f), 2 },  // aperture door
    { float3( 0.0058f, 0.0000f,  0.0000f), float3(0.0035f, 0.0002f, 0.0013f), 1 },  // solar arrays
    { float3(-0.0058f, 0.0000f,  0.0000f), float3(0.0035f, 0.0002f, 0.0013f), 1 },
};

bool RayBox(float3 o, float3 inv, Box b, out float tn, out float3 n)
{
    float3 t0 = (b.c - b.h - o) * inv;
    float3 t1 = (b.c + b.h - o) * inv;
    float3 tmin = min(t0, t1);
    float3 tmax = max(t0, t1);
    tn = max(max(tmin.x, tmin.y), tmin.z);
    float tf = min(min(tmax.x, tmax.y), tmax.z);
    if (tn == tmin.x)      n = float3(-sign(inv.x), 0, 0);
    else if (tn == tmin.y) n = float3(0, -sign(inv.y), 0);
    else                   n = float3(0, 0, -sign(inv.z));
    return tn <= tf && tf > 0.0f;
}

[shader("intersection")]
void SatelliteIntersection()
{
    float3 o = ObjectRayOrigin();
    float3 inv = 1.0f / ObjectRayDirection();
    float best = RayTCurrent();
    bool hit = false;
    SatAttributes attr;
    attr.normal = float3(0, 1, 0);
    attr.material = 0;
    uint count = InstanceID() == 0 ? 13 : 5;
    for (uint i = 0; i < count; i++)
    {
        Box b;
        if (InstanceID() == 0) b = kIss[i];
        else b = kHubble[i];
        float tn;
        float3 n;
        if (RayBox(o, inv, b, tn, n) && tn >= RayTMin() && tn < best)
        {
            best = tn;
            attr.normal = n;
            attr.material = b.m;
            hit = true;
        }
    }
    if (hit) ReportHit(best, 0, attr);
}

[shader("closesthit")]
void SatelliteClosestHit(inout RayPayload payload, in SatAttributes attr)
{
    float3 P = HitWorldPosition();
    float3 D = WorldRayDirection();
    float3 V = -D;
    float3 objP = ObjectRayOrigin() + RayTCurrent() * ObjectRayDirection();
    float3 nObj = attr.normal;

    float3 albedo, F0;
    if (attr.material == 0 || attr.material == 4)
    {
        // Crinkled multi-layer insulation: gold (0) or silver (4).
        float3 q = objP * 2500.0f;
        float3 pert = float3(Noise3(q), Noise3(q + 7.1f), Noise3(q + 3.3f)) - 0.5f;
        nObj = normalize(nObj + pert * 0.25f);
        albedo = attr.material == 0 ? float3(0.20f, 0.14f, 0.04f) : float3(0.25f, 0.25f, 0.27f);
        F0 = attr.material == 0 ? float3(1.0f, 0.74f, 0.30f) : float3(0.90f, 0.90f, 0.92f);
    }
    else if (attr.material == 1)
    {
        // Solar cells with a silver grid (~1.5 m cells).
        float2 g = frac(objP.xz * 650.0f);
        float grid = (g.x < 0.06f || g.y < 0.06f) ? 1.0f : 0.0f;
        albedo = lerp(float3(0.02f, 0.025f, 0.07f), float3(0.35f, 0.35f, 0.38f), grid);
        F0 = lerp(float3(0.05f, 0.06f, 0.09f), float3(0.75f, 0.75f, 0.78f), grid);
    }
    else if (attr.material == 3)
    {
        albedo = float3(0.55f, 0.55f, 0.55f);
        F0 = float3(0.06f, 0.06f, 0.06f);
    }
    else
    {
        albedo = float3(0.30f, 0.30f, 0.32f);
        F0 = float3(0.80f, 0.80f, 0.82f);
    }

    float3 N = normalize(mul((float3x3)ObjectToWorld3x4(), nObj));
    if (dot(N, D) > 0.0f) N = -N;

    float3 L = g_cb.sunDirection.xyz;
    float  E = g_cb.sunDirection.w;
    float  NdotL = saturate(dot(N, L));
    bool   canTrace = payload.depth < MAX_DEPTH;
    float  vis = NdotL > 0.0f ? (canTrace ? TraceShadow(P + N * 0.01f, L) : 1.0f) : 0.0f;   // Earth eclipse
    float3 sun = E * SunTransmittance(P) * vis;

    // Traced metallic reflection: the Earth, the other satellite, stars and the Sun.
    float3 F = F0 + (1.0f - F0) * pow(1.0f - saturate(dot(N, V)), 5.0f);
    float3 R = reflect(D, N);
    float3 refl = canTrace ? TraceRadiance(P + N * 0.01f, R, payload.depth + 1) : Background(R);

    // Earthshine: sunlight reflected by the lit side of the Earth (albedo ~0.3).
    float3 up = normalize(P);
    float earthLit = saturate(dot(up, L) * 0.5f + 0.5f);
    float3 earthshine = E * 0.3f * earthLit * saturate(dot(N, -up) * 0.5f + 0.5f) * float3(0.6f, 0.75f, 1.0f) * 0.4f;

    float3 H = normalize(L + V);
    float spec = pow(saturate(dot(N, H)), 250.0f) * 6.0f;

    payload.color = albedo * (sun * NdotL + earthshine) + refl * F + F * spec * sun;
}
```

### 8.2 Escena y cámara (C++) (`src/scenes/SpaceScene.h`)

```cpp
#pragma once
// Scene "space" (space_rtx_wallpaper.md): the real Earth, right now, at real scale.
//
//  - Units: kilometres. Earth radius 6371 km, satellites at their real altitudes.
//  - Time: real UTC clock (x Speed). Earth rotation (GMST), Sun position (solar ephemeris,
//    ~1 AU away, real angular size) and satellite positions all follow the simulated clock.
//  - Satellites: ISS and Hubble propagated from current Celestrak TLEs (Kepler + J2 secular).
//  - Textures (background thread, cached in %LOCALAPPDATA%\RTWallpaper\cache):
//      t1 day   - NASA Blue Marble Next Generation (GIBS), RGB + ocean mask in alpha
//      t2 night - NASA Black Marble (VIIRS) city lights
//      t3 clouds- live global cloud map, re-checked every hour (ETag, only re-downloaded if changed)
//  - Camera: starts parked over a chosen place (default Mexico), turning with the Earth; after
//    FocusMinutes it glides over to ride behind and above the ISS while it is in daylight (when the
//    ISS crosses to the night side the observer waits near the terminator). It always pitches so the
//    Earth covers 40-60 % of the screen.
#include <atomic>
#include <memory>
#include <mutex>
#include <thread>
#include <shlobj.h>
#include "Scene.h"
#include "space/Astro.h"
#include "space/Http.h"
#include "space/Image.h"
#include "Space.hlsl.h"   // generated by dxc: g_pSpace[]

class SpaceScene : public Scene
{
public:
    struct Settings
    {
        UINT textureSize = 8192;       // width of the day/night maps (height = width / 2), max 8192
        UINT cloudSize = 8192;         // 1024 | 2048 | 4096 | 8192
        UINT cloudUpdateMinutes = 60;  // how often the live cloud map is re-checked
        float satelliteScale = 1000.f; // visual size multiplier (real size would be sub-pixel)
        float coverageMin = 0.40f;     // fraction of the screen covered by the Earth
        float coverageMax = 0.60f;
        bool offline = false;          // never download (use cache / procedural fallback)
        double focusLat = 23.6;        // initial point of interest (default: Mexico)
        double focusLon = -102.5;
        double focusMinutes = 20;      // minutes over the focus point before following the ISS; < 0 = always
        bool galaxyReal = false;       // true: real galactic orientation; false: "scenic", band kept in view
        double timeOffsetHours = 0;    // show the Earth at another time (0 = now)
    };

private:
    // Must match SceneConstantBuffer in shaders/Space.hlsl.
    struct Constants
    {
        CameraConstants camera;
        DirectX::XMFLOAT4 sunDirection;   // world, towards the sun; w = irradiance
        DirectX::XMFLOAT4 sunInfo;        // x = angular radius (rad), y = distance (km), z = exposure
        DirectX::XMFLOAT4 earthRow[3];    // world -> ECEF rotation (rows)
        DirectX::XMFLOAT4 params;         // x = scene time (s), y = has day map, z = has night map, w = has clouds
        DirectX::XMFLOAT4 textureInfo;    // x = day width, y = night width, z = cloud width
        DirectX::XMFLOAT4 galaxyCenter;   // world direction of the galactic centre
        DirectX::XMFLOAT4 galaxyPole;     // world direction of the galactic north pole
    };

    struct Shared
    {
        std::mutex mutex;
        std::vector<TextureUpload> pending;
        astro::Orbit orbits[2];
        std::atomic<bool> stop{ false };
    };

    static constexpr float FOV_Y = 45.0f;
    static constexpr double REFOLLOW_PERIOD = 1500.0;  // s, camera altitude cycle

    Settings m_settings;
    std::shared_ptr<Shared> m_shared;
    double m_startUnix = 0;
    double m_simSeconds = 0;
    float m_hasTexture[3] = {};
    float m_textureWidth[3] = {};
    float m_lastPitch = 0.0f;
    astro::Vec3 m_galaxyCenter{}, m_galaxyPole{};   // smoothed scenic galaxy frame

public:
    explicit SpaceScene(const std::wstring& iniPath)
    {
        LoadSettings(iniPath);
        FILETIME ft;
        GetSystemTimePreciseAsFileTime(&ft);
        ULARGE_INTEGER u = { { ft.dwLowDateTime, ft.dwHighDateTime } };
        m_startUnix = (double)(u.QuadPart - 116444736000000000ULL) / 1e7 + m_settings.timeOffsetHours * 3600.0;

        m_shared = std::make_shared<Shared>();
        // Fallback orbits until fresh TLEs arrive (real elements, epoch 2026-11-11).
        m_shared->orbits[0] = astro::Orbit::FromTle("ISS (ZARYA)",
            "1 25544U 98067A   26315.20707527  .00009235  00000+0  17362-3 0  9997",
            "2 25544  51.6322 292.5559 0007316  12.7435 347.3737 15.49310717594546");
        m_shared->orbits[1] = astro::Orbit::FromTle("HST",
            "1 20580U 90037B   26314.89250324  .00006442  00000+0  19351-3 0  9990",
            "2 20580  28.4707 156.7631 0002117 354.3305   5.7267 15.32255871811082");
        std::thread(Worker, m_shared, m_settings).detach();
    }

    ~SpaceScene() override { m_shared->stop = true; }

    const wchar_t* Name() const override { return L"space"; }
    D3D12_SHADER_BYTECODE Library() const override { return { g_pSpace, sizeof(g_pSpace) }; }
    UINT InstanceCount() const override { return 3; }
    UINT MaxRecursion() const override { return 4; }   // MAX_DEPTH (3) + 1

    std::vector<HitGroupDef> HitGroups() const override
    {
        return {
            { L"EarthHitGroup", L"EarthClosestHit", L"SphereIntersection" },
            { L"SatelliteHitGroup", L"SatelliteClosestHit", L"SatelliteIntersection" },
        };
    }

    std::vector<GeometryDef> Geometry() const override
    {
        GeometryDef earth;                 // unit sphere, scaled to 6371 km by the instance
        earth.aabb = { -1, -1, -1, 1, 1, 1 };
        GeometryDef iss;                   // ISS bounding box in km (real size, before satelliteScale)
        iss.aabb = { -0.062f, -0.010f, -0.042f, 0.062f, 0.010f, 0.042f };
        GeometryDef hubble;
        hubble.aabb = { -0.011f, -0.004f, -0.010f, 0.011f, 0.004f, 0.010f };
        return { earth, iss, hubble };
    }

    void PollTextures(std::vector<TextureUpload>& out) override
    {
        std::lock_guard<std::mutex> lock(m_shared->mutex);
        for (TextureUpload& t : m_shared->pending)
        {
            if (t.slot < 3)
            {
                m_hasTexture[t.slot] = 1.0f;
                m_textureWidth[t.slot] = (float)t.mips[0].width;
            }
            out.push_back(std::move(t));
        }
        m_shared->pending.clear();
    }

    UINT Update(float dt, float aspect, void* constants, InstanceDef* instances) override
    {
        using namespace DirectX;
        using astro::Vec3;
        Constants& cb = *static_cast<Constants*>(constants);
        m_simSeconds += dt;
        const double now = m_startUnix + m_simSeconds;
        const double tau = m_simSeconds;

        astro::Orbit orbits[2];
        {
            std::lock_guard<std::mutex> lock(m_shared->mutex);
            orbits[0] = m_shared->orbits[0];
            orbits[1] = m_shared->orbits[1];
        }

        // --- Earth orientation: world -> ECEF (rotation by GMST around the pole) ---
        const double theta = astro::Gmst(now);
        const float c = (float)std::cos(theta), s = (float)std::sin(theta);
        cb.earthRow[0] = XMFLOAT4(c, 0, -s, 0);
        cb.earthRow[1] = XMFLOAT4(-s, 0, -c, 0);
        cb.earthRow[2] = XMFLOAT4(0, 1, 0, 0);

        // --- Sun: real direction, distance and angular size ---
        const Vec3 sunEci = astro::SunPositionEci(now);
        const double sunDist = sunEci.Length();
        const Vec3 sunDir = astro::EciToWorld(sunEci).Normalized();
        cb.sunDirection = XMFLOAT4((float)sunDir.x, (float)sunDir.y, (float)sunDir.z,
                                   (float)(20.0 * (astro::AU / sunDist) * (astro::AU / sunDist)));
        cb.sunInfo = XMFLOAT4((float)std::asin(astro::SUN_RADIUS / sunDist), (float)sunDist, 0.16f, 0);

        // --- Satellites ---
        Vec3 satPos[2], satVel[2];
        for (int i = 0; i < 2; i++)
        {
            satPos[i] = astro::EciToWorld(orbits[i].PositionEci(now));
            satVel[i] = astro::EciToWorld(orbits[i].PositionEci(now + 1.0)) - satPos[i];   // km/s
        }

        instances[0] = InstanceDef{ 0, 0, 0 };
        instances[0].SetTranslationScale(0, 0, 0, (float)astro::EARTH_RADIUS);
        for (int i = 0; i < 2; i++)
        {
            // Local frame: +Y away from the Earth, +Z along the velocity, +X = orbit normal.
            Vec3 y = satPos[i].Normalized();
            Vec3 z = (satVel[i] - y * astro::Dot(satVel[i], y)).Normalized();
            Vec3 x = astro::Cross(y, z);
            const double k = m_settings.satelliteScale;
            InstanceDef& inst = instances[1 + i];
            inst = InstanceDef{ (UINT)(1 + i), 1, (UINT)i };
            float m[3][4] = {
                { (float)(x.x * k), (float)(y.x * k), (float)(z.x * k), (float)satPos[i].x },
                { (float)(x.y * k), (float)(y.y * k), (float)(z.y * k), (float)satPos[i].y },
                { (float)(x.z * k), (float)(y.z * k), (float)(z.z * k), (float)satPos[i].z },
            };
            memcpy(inst.transform, m, sizeof(m));
        }

        // --- Observer ---
        // Follows the ISS from higher up while it is in daylight. The observer's ground point is the
        // ISS's, but never more than DAY_LIMIT from the subsolar point, so when the ISS flies into the
        // night the observer waits at the terminator (where the real clouds are still visible).
        const Vec3 p = satPos[0];
        const Vec3 r = p.Normalized();
        const Vec3 n = astro::Cross(p, satVel[0]).Normalized();   // orbit normal
        const Vec3 along = astro::Cross(n, r);                     // direction of travel
        auto osc = [&](double period, double phase) { return std::sin(2 * astro::PI * tau / period + phase); };
        const double altitude = 3600.0 + 1600.0 * osc(REFOLLOW_PERIOD, 0.0);         // km above the surface
        const double lag = (14.0 + 5.0 * osc(2100.0, 1.0)) * astro::DEG;              // behind the ISS
        const double side = (16.0 * osc(2700.0, 2.0)) * astro::DEG;                   // out of the orbital plane

        const double issFromSun = std::acos(std::clamp(astro::Dot(r, sunDir), -1.0, 1.0));
        Vec3 ground = r;
        if (issFromSun > DAY_LIMIT)
            ground = RotateTowards(sunDir, r, DAY_LIMIT);
        Vec3 camDir = (ground * std::cos(lag) - along * std::sin(lag)).Normalized();
        camDir = (camDir * std::cos(side) + n * std::sin(side)).Normalized();

        // Look at the ISS; once it is deep in the night, look at the terminator in its direction instead.
        const double w = SmoothStep(DAY_LIMIT + 5 * astro::DEG, DAY_LIMIT + 30 * astro::DEG, issFromSun);
        const Vec3 dusk = RotateTowards(sunDir, r, DAY_LIMIT + 20 * astro::DEG) * astro::EARTH_RADIUS;
        Vec3 lookAt = p * (1.0 - w) + dusk * w;

        // Focus mode: hover south of the focus point (turning with the Earth) and look at it, with
        // the horizon beyond. Blends into the ISS-following mode after focusMinutes.
        const double focusWeight = m_settings.focusMinutes < 0 ? 1.0
            : 1.0 - SmoothStep(m_settings.focusMinutes * 60.0, m_settings.focusMinutes * 60.0 + 180.0, tau);
        if (focusWeight > 0.0)
        {
            const double lat = m_settings.focusLat * astro::DEG, lon = m_settings.focusLon * astro::DEG;
            const Vec3 ecef = { std::cos(lat) * std::cos(lon), std::cos(lat) * std::sin(lon), std::sin(lat) };
            // ECEF -> world is the transpose of the world -> ECEF rows sent to the shader.
            const Vec3 focus = Vec3{ c, 0, -s } * ecef.x + Vec3{ -s, 0, -c } * ecef.y + Vec3{ 0, 1, 0 } * ecef.z;
            Vec3 south = (Vec3{ 0, -1, 0 } - focus * -focus.y).Normalized();
            Vec3 east = astro::Cross(south, focus).Normalized();
            const double swing = 30.0 * osc(1500.0, 0.3) * astro::DEG;        // slow sideways drift
            const Vec3 away = (south * std::cos(swing) + east * std::sin(swing)).Normalized();
            const double back = (12.0 + 3.0 * osc(1900.0, 1.2)) * astro::DEG; // distance south of the target
            const Vec3 focusCam = (focus * std::cos(back) + away * std::sin(back)).Normalized();
            camDir = (camDir * (1.0 - focusWeight) + focusCam * focusWeight).Normalized();
            lookAt = lookAt * (1.0 - focusWeight) + focus * (astro::EARTH_RADIUS * focusWeight);
        }
        const Vec3 cam = camDir * (astro::EARTH_RADIUS + altitude);

        const float target = m_settings.coverageMin + (m_settings.coverageMax - m_settings.coverageMin) *
                                                         (float)(0.5 + 0.5 * osc(1800.0, 0.5));
        const Vec3 toSat = (lookAt - cam).Normalized();
        Vec3 upPerp = (camDir - toSat * astro::Dot(camDir, toSat)).Normalized();
        auto forwardFor = [&](double pitch) { return (toSat * std::cos(pitch) + upPerp * std::sin(pitch)).Normalized(); };

        // Binary search the pitch (looking up = less Earth). The ISS stays inside the frame.
        const double half = FOV_Y * 0.5 * astro::DEG;
        double lo = -0.5 * half, hi = 0.85 * half;
        for (int it = 0; it < 18; it++)
        {
            double mid = 0.5 * (lo + hi);
            if (EarthCoverage(cam, forwardFor(mid), camDir, aspect) > target) lo = mid; else hi = mid;
        }
        double pitch = 0.5 * (lo + hi);
        // Smooth out frame-to-frame jitter of the search.
        m_lastPitch = (m_lastPitch == 0.0f) ? (float)pitch : m_lastPitch + 0.1f * ((float)pitch - m_lastPitch);
        const Vec3 fwd = forwardFor(m_lastPitch);
        cb.camera = MakeCameraDir(XMVectorSet((float)cam.x, (float)cam.y, (float)cam.z, 0),
                                  XMVectorSet((float)fwd.x, (float)fwd.y, (float)fwd.z, 0), FOV_Y,
                                  XMVectorSet((float)camDir.x, (float)camDir.y, (float)camDir.z, 0));

        UpdateGalaxyFrame(fwd, camDir, cb);
        cb.params = XMFLOAT4((float)m_simSeconds, m_hasTexture[0], m_hasTexture[1], m_hasTexture[2]);
        cb.textureInfo = XMFLOAT4(m_textureWidth[0], m_textureWidth[1], m_textureWidth[2], 0);
        return sizeof(Constants);
    }

private:
    static constexpr double DAY_LIMIT = 78.0 * astro::DEG;   // max observer distance from the subsolar point

    // Galactic frame for the sky. Real: galactic north pole RA 192.86 Dec +27.13, centre RA 266.40
    // Dec -28.94 (converted to world = (eci.x, eci.z, -eci.y)). Scenic: the band crosses the upper
    // part of the screen diagonally with the bright centre to the upper right; the frame follows the
    // camera slowly, so the sky still drifts gently.
    void UpdateGalaxyFrame(const astro::Vec3& fwd, const astro::Vec3& upHint, Constants& cb)
    {
        using astro::Vec3;
        Vec3 center, pole;
        if (m_settings.galaxyReal)
        {
            center = { -0.05487, -0.48388, 0.87342 };
            pole = { -0.86776, 0.45599, 0.19762 };
        }
        else
        {
            const Vec3 right = astro::Cross(fwd, upHint).Normalized();
            const Vec3 up = astro::Cross(right, fwd);
            Vec3 c = (fwd * 0.92 + up * 0.30 + right * 0.32).Normalized();   // ~18 deg up, ~19 deg right: inside the frame
            Vec3 across = (right * std::cos(28 * astro::DEG) - up * std::sin(28 * astro::DEG));
            Vec3 p = astro::Cross(c, across).Normalized();
            if (m_galaxyPole.Length() < 0.5) { m_galaxyCenter = c; m_galaxyPole = p; }
            const double k = 0.01;   // low-pass: ignore frame-to-frame camera jitter
            m_galaxyCenter = (m_galaxyCenter * (1 - k) + c * k).Normalized();
            m_galaxyPole = (m_galaxyPole * (1 - k) + p * k);
            m_galaxyPole = (m_galaxyPole - m_galaxyCenter * astro::Dot(m_galaxyPole, m_galaxyCenter)).Normalized();
            center = m_galaxyCenter;
            pole = m_galaxyPole;
        }
        cb.galaxyCenter = DirectX::XMFLOAT4((float)center.x, (float)center.y, (float)center.z, 0);
        cb.galaxyPole = DirectX::XMFLOAT4((float)pole.x, (float)pole.y, (float)pole.z, 0);
    }

    static double SmoothStep(double a, double b, double x)
    {
        double t = std::clamp((x - a) / (b - a), 0.0, 1.0);
        return t * t * (3 - 2 * t);
    }

    // Unit vector at `angle` from `from`, in the plane towards `to`.
    static astro::Vec3 RotateTowards(const astro::Vec3& from, const astro::Vec3& to, double angle)
    {
        astro::Vec3 perp = to - from * astro::Dot(from, to);
        if (perp.Length() < 1e-9) return from;
        perp = perp.Normalized();
        return (from * std::cos(angle) + perp * std::sin(angle)).Normalized();
    }

    // Fraction of the screen covered by the Earth's disk, from a coarse grid of rays.
    static float EarthCoverage(const astro::Vec3& cam, const astro::Vec3& fwd, const astro::Vec3& upHint, float aspect)
    {
        using astro::Vec3;
        const Vec3 right = astro::Cross(fwd, upHint).Normalized();
        const Vec3 up = astro::Cross(right, fwd);
        const double t = std::tan(FOV_Y * 0.5 * astro::DEG);
        const double R2 = astro::EARTH_RADIUS * astro::EARTH_RADIUS;
        const double c = astro::Dot(cam, cam) - R2;
        const int NX = 48, NY = 27;
        int hits = 0;
        for (int j = 0; j < NY; j++)
            for (int i = 0; i < NX; i++)
            {
                double x = ((i + 0.5) / NX * 2 - 1) * aspect * t;
                double y = ((j + 0.5) / NY * 2 - 1) * t;
                Vec3 d = (fwd + right * x + up * y).Normalized();
                double b = astro::Dot(cam, d);
                if (b < 0 && b * b - c >= 0) hits++;
            }
        return (float)hits / (NX * NY);
    }

    void LoadSettings(const std::wstring& ini)
    {
        const wchar_t* sec = L"Space";
        wchar_t buf[64];
        UINT ts = GetPrivateProfileIntW(sec, L"TextureSize", 8192, ini.c_str());
        m_settings.textureSize = std::clamp(ts, 512u, 8192u);
        UINT cs = GetPrivateProfileIntW(sec, L"CloudSize", 8192, ini.c_str());
        m_settings.cloudSize = cs >= 8192 ? 8192 : cs >= 4096 ? 4096 : cs >= 2048 ? 2048 : 1024;
        m_settings.cloudUpdateMinutes = std::max(5u, GetPrivateProfileIntW(sec, L"CloudUpdateMinutes", 60, ini.c_str()));
        GetPrivateProfileStringW(sec, L"SatelliteScale", L"1000", buf, 64, ini.c_str());
        m_settings.satelliteScale = std::clamp((float)_wtof(buf), 1.0f, 10000.0f);
        GetPrivateProfileStringW(sec, L"CoverageMin", L"0.40", buf, 64, ini.c_str());
        m_settings.coverageMin = std::clamp((float)_wtof(buf), 0.05f, 0.95f);
        GetPrivateProfileStringW(sec, L"CoverageMax", L"0.60", buf, 64, ini.c_str());
        m_settings.coverageMax = std::clamp((float)_wtof(buf), m_settings.coverageMin, 0.95f);
        m_settings.offline = GetPrivateProfileIntW(sec, L"Offline", 0, ini.c_str()) != 0;
        GetPrivateProfileStringW(sec, L"TimeOffsetHours", L"0", buf, 64, ini.c_str());
        m_settings.timeOffsetHours = std::clamp(_wtof(buf), -8760.0, 8760.0);
        GetPrivateProfileStringW(sec, L"FocusLat", L"23.6", buf, 64, ini.c_str());
        m_settings.focusLat = std::clamp(_wtof(buf), -90.0, 90.0);
        GetPrivateProfileStringW(sec, L"FocusLon", L"-102.5", buf, 64, ini.c_str());
        m_settings.focusLon = std::clamp(_wtof(buf), -180.0, 180.0);
        GetPrivateProfileStringW(sec, L"FocusMinutes", L"20", buf, 64, ini.c_str());
        m_settings.focusMinutes = _wtof(buf);
        GetPrivateProfileStringW(sec, L"Galaxy", L"scenic", buf, 64, ini.c_str());
        m_settings.galaxyReal = _wcsicmp(buf, L"real") == 0;
    }

    // -----------------------------------------------------------------------
    // Background thread: TLEs, Earth textures and the hourly cloud map.
    // -----------------------------------------------------------------------
    static std::wstring CacheDir()
    {
        wchar_t* base = nullptr;
        std::wstring dir;
        if (SUCCEEDED(SHGetKnownFolderPath(FOLDERID_LocalAppData, 0, nullptr, &base)))
            dir = std::wstring(base) + L"\\RTWallpaper";
        CoTaskMemFree(base);
        CreateDirectoryW(dir.c_str(), nullptr);
        dir += L"\\cache";
        CreateDirectoryW(dir.c_str(), nullptr);
        return dir + L"\\";
    }

    static bool FileExists(const std::wstring& p) { return GetFileAttributesW(p.c_str()) != INVALID_FILE_ATTRIBUTES; }

    static double FileAgeSeconds(const std::wstring& p)
    {
        WIN32_FILE_ATTRIBUTE_DATA d;
        if (!GetFileAttributesExW(p.c_str(), GetFileExInfoStandard, &d)) return 1e30;
        FILETIME now;
        GetSystemTimeAsFileTime(&now);
        ULARGE_INTEGER a = { { d.ftLastWriteTime.dwLowDateTime, d.ftLastWriteTime.dwHighDateTime } };
        ULARGE_INTEGER b = { { now.dwLowDateTime, now.dwHighDateTime } };
        return (double)(b.QuadPart - a.QuadPart) / 1e7;
    }

    static std::string ReadText(const std::wstring& p)
    {
        HANDLE f = CreateFileW(p.c_str(), GENERIC_READ, FILE_SHARE_READ, nullptr, OPEN_EXISTING, 0, nullptr);
        if (f == INVALID_HANDLE_VALUE) return "";
        std::string s(4096, '\0');
        DWORD read = 0;
        ReadFile(f, s.data(), (DWORD)s.size(), &read, nullptr);
        CloseHandle(f);
        s.resize(read);
        return s;
    }

    static void Log(const std::wstring& dir, const char* msg)
    {
        HANDLE f = CreateFileW((dir + L"space.log").c_str(), FILE_APPEND_DATA, FILE_SHARE_READ, nullptr, OPEN_ALWAYS, 0, nullptr);
        if (f == INVALID_HANDLE_VALUE) return;
        SYSTEMTIME st;
        GetSystemTime(&st);
        char line[512];
        int n = snprintf(line, sizeof(line), "%04d-%02d-%02d %02d:%02d:%02dZ %s\r\n", st.wYear, st.wMonth, st.wDay,
                         st.wHour, st.wMinute, st.wSecond, msg);
        DWORD w;
        WriteFile(f, line, (DWORD)n, &w, nullptr);
        CloseHandle(f);
    }

    static bool SleepUnlessStopped(Shared& sh, DWORD ms)
    {
        for (DWORD t = 0; t < ms && !sh.stop; t += 250) Sleep(250);
        return !sh.stop;
    }

    static void RefreshTles(Shared& sh, const Settings& st, const std::wstring& dir)
    {
        const int ids[2] = { 25544, 20580 };   // ISS, Hubble
        for (int i = 0; i < 2; i++)
        {
            std::wstring file = dir + L"tle_" + std::to_wstring(ids[i]) + L".txt";
            if (!st.offline && FileAgeSeconds(file) > 6 * 3600)   // Celestrak asks for at most a few fetches a day
            {
                std::wstring url = L"https://celestrak.org/NORAD/elements/gp.php?CATNR=" + std::to_wstring(ids[i]) + L"&FORMAT=TLE";
                http::Download(url, file, L"", 30000);
            }
            astro::Orbit o;
            if (astro::ParseTle(ReadText(file), o))
            {
                std::lock_guard<std::mutex> lock(sh.mutex);
                sh.orbits[i] = o;
                char msg[160];
                snprintf(msg, sizeof(msg), "TLE %s: alt %.0f km, inc %.2f deg, period %.1f min", o.name.c_str(),
                         o.semiMajorAxis - astro::EARTH_RADIUS, o.inclination / astro::DEG, o.PeriodSeconds() / 60);
                Log(dir, msg);
            }
        }
    }

    static std::wstring GibsUrl(const wchar_t* layer, UINT w)
    {
        return std::wstring(L"https://gibs.earthdata.nasa.gov/wms/epsg4326/best/wms.cgi?SERVICE=WMS&REQUEST=GetMap"
                            L"&VERSION=1.3.0&STYLES=&FORMAT=image/jpeg&CRS=EPSG:4326&BBOX=-90,-180,90,180&LAYERS=") +
               layer + L"&WIDTH=" + std::to_wstring(w) + L"&HEIGHT=" + std::to_wstring(w / 2);
    }

    static void PushTexture(Shared& sh, TextureUpload&& t)
    {
        std::lock_guard<std::mutex> lock(sh.mutex);
        sh.pending.push_back(std::move(t));
    }

    // slot 0 = day (ocean mask in alpha), slot 1 = night lights.
    static void LoadEarthMap(Shared& sh, const Settings& st, const std::wstring& dir, UINT slot)
    {
        const UINT w = st.textureSize;
        const wchar_t* layer = slot == 0 ? L"BlueMarble_NextGeneration" : L"VIIRS_Black_Marble";
        std::wstring file = dir + (slot == 0 ? L"earth_day_" : L"earth_night_") + std::to_wstring(w) + L".jpg";
        if (!FileExists(file) && !st.offline)
        {
            Log(dir, slot == 0 ? "downloading NASA Blue Marble (GIBS)..." : "downloading NASA Black Marble (GIBS)...");
            http::Download(GibsUrl(layer, w), file, L"", 300000);
        }
        image::Rgba img;
        if (sh.stop || !image::Load(file, w, w / 2, img))
        {
            Log(dir, "earth map not available, using procedural surface");
            return;
        }
        if (slot == 0)
        {
            // Ocean mask (for the sun glint): dark, blue-dominant pixels.
            for (size_t i = 0; i < img.pixels.size(); i += 4)
            {
                float r = img.pixels[i] / 255.f, g = img.pixels[i + 1] / 255.f, b = img.pixels[i + 2] / 255.f;
                float lum = 0.3f * r + 0.59f * g + 0.11f * b;
                float m = std::clamp((b - std::max(r, g)) * 14.f, 0.f, 1.f) * std::clamp((0.22f - lum) * 10.f, 0.f, 1.f);
                img.pixels[i + 3] = (uint8_t)(m * 255.f + 0.5f);
            }
        }
        PushTexture(sh, image::MakeMips(slot, DXGI_FORMAT_R8G8B8A8_UNORM_SRGB, 4, img.width, img.height, std::move(img.pixels)));
        Log(dir, slot == 0 ? "day map ready" : "night map ready");
    }

    static bool LoadClouds(Shared& sh, const std::wstring& file, const std::wstring& dir)
    {
        image::Rgba img;
        if (!image::Load(file, 0, 0, img)) return false;
        std::vector<uint8_t> alpha((size_t)img.width * img.height);
        for (size_t i = 0; i < alpha.size(); i++) alpha[i] = img.pixels[i * 4 + 3];
        PushTexture(sh, image::MakeMips(2, DXGI_FORMAT_R8_UNORM, 1, img.width, img.height, std::move(alpha)));
        Log(dir, "cloud map loaded");
        return true;
    }

    static void Worker(std::shared_ptr<Shared> shp, Settings st)
    {
        Shared& sh = *shp;
        CoInitializeEx(nullptr, COINIT_MULTITHREADED);
        SetThreadPriority(GetCurrentThread(), THREAD_PRIORITY_BELOW_NORMAL);
        const std::wstring dir = CacheDir();

        RefreshTles(sh, st, dir);

        const std::wstring size = std::to_wstring(st.cloudSize) + L"x" + std::to_wstring(st.cloudSize / 2);
        const std::wstring cloudFile = dir + L"clouds_" + size + L".png";
        const std::wstring cloudUrl = L"https://clouds.matteason.co.uk/images/" + size + L"/clouds-alpha.png";
        if (FileExists(cloudFile)) LoadClouds(sh, cloudFile, dir);   // show the last map immediately

        if (!sh.stop) LoadEarthMap(sh, st, dir, 0);
        if (!sh.stop) LoadEarthMap(sh, st, dir, 1);

        ULONGLONG lastTle = GetTickCount64();
        while (!sh.stop)
        {
            if (!st.offline)
            {
                http::Result r = http::Download(cloudUrl, cloudFile, cloudFile + L".etag", 300000);
                if (r == http::Result::Downloaded) LoadClouds(sh, cloudFile, dir);
                else if (r == http::Result::NotModified) Log(dir, "cloud map unchanged (304)");
                else Log(dir, "cloud map download failed");
            }
            if (GetTickCount64() - lastTle > 6ull * 3600 * 1000)
            {
                RefreshTles(sh, st, dir);
                lastTle = GetTickCount64();
            }
            SleepUnlessStopped(sh, st.cloudUpdateMinutes * 60u * 1000u);
        }
        CoUninitialize();
    }
};
```

### 8.3 Astronomía y mecánica orbital (C++) (`src/space/Astro.h`)

```cpp
#pragma once
// Astronomy and orbital mechanics for the "space" scene (double precision, km, seconds).
//
// Frames:
//   ECI   - Earth-centred inertial (equatorial, x = vernal equinox, z = north pole). TLEs give TEME,
//           which we treat as ECI (difference < 1 arcmin, irrelevant at wallpaper scale).
//   ECEF  - Earth-fixed: ECI rotated by GMST around z.
//   World - renderer frame (right-handed, +Y up): world = (eci.x, eci.z, -eci.y).
#include <cmath>
#include <cstdlib>
#include <cstring>
#include <string>

namespace astro
{
constexpr double PI = 3.14159265358979323846;
constexpr double DEG = PI / 180.0;
constexpr double MU_EARTH = 398600.4418;      // km^3/s^2
constexpr double EARTH_RADIUS = 6371.0;       // km (mean, used for drawing)
constexpr double EARTH_EQ_RADIUS = 6378.137;  // km (WGS-84, used for J2)
constexpr double J2 = 1.08262668e-3;
constexpr double AU = 149597870.7;            // km
constexpr double SUN_RADIUS = 695700.0;       // km
constexpr double SIDEREAL_DAY = 86164.0905;   // s

struct Vec3
{
    double x = 0, y = 0, z = 0;
    Vec3 operator+(const Vec3& o) const { return { x + o.x, y + o.y, z + o.z }; }
    Vec3 operator-(const Vec3& o) const { return { x - o.x, y - o.y, z - o.z }; }
    Vec3 operator*(double s) const { return { x * s, y * s, z * s }; }
    double Length() const { return std::sqrt(x * x + y * y + z * z); }
    Vec3 Normalized() const { double l = Length(); return l > 0 ? *this * (1.0 / l) : *this; }
};
inline double Dot(const Vec3& a, const Vec3& b) { return a.x * b.x + a.y * b.y + a.z * b.z; }
inline Vec3 Cross(const Vec3& a, const Vec3& b)
{
    return { a.y * b.z - a.z * b.y, a.z * b.x - a.x * b.z, a.x * b.y - a.y * b.x };
}
inline Vec3 EciToWorld(const Vec3& e) { return { e.x, e.z, -e.y }; }

// Days since 1970-01-01 for a civil date (Howard Hinnant's algorithm).
inline long long DaysFromCivil(int y, unsigned m, unsigned d)
{
    y -= m <= 2;
    const long long era = (y >= 0 ? y : y - 399) / 400;
    const unsigned yoe = (unsigned)(y - era * 400);
    const unsigned doy = (153 * (m + (m > 2 ? -3 : 9)) + 2) / 5 + d - 1;
    const unsigned doe = yoe * 365 + yoe / 4 - yoe / 100 + doy;
    return era * 146097 + (long long)doe - 719468;
}

inline double JulianDate(double unixSeconds) { return unixSeconds / 86400.0 + 2440587.5; }

// Greenwich Mean Sidereal Time (radians).
inline double Gmst(double unixSeconds)
{
    const double d = JulianDate(unixSeconds) - 2451545.0;
    double g = std::fmod(280.46061837 + 360.98564736629 * d, 360.0);
    if (g < 0) g += 360.0;
    return g * DEG;
}

// Sun position in ECI (km). Low-precision solar ephemeris (Astronomical Almanac), ~0.01 deg.
inline Vec3 SunPositionEci(double unixSeconds)
{
    const double n = JulianDate(unixSeconds) - 2451545.0;
    const double L = (280.460 + 0.9856474 * n) * DEG;
    const double g = (357.528 + 0.9856003 * n) * DEG;
    const double lambda = L + (1.915 * std::sin(g) + 0.020 * std::sin(2 * g)) * DEG;
    const double eps = (23.439 - 0.0000004 * n) * DEG;
    const double r = (1.00014 - 0.01671 * std::cos(g) - 0.00014 * std::cos(2 * g)) * AU;
    return { r * std::cos(lambda), r * std::cos(eps) * std::sin(lambda), r * std::sin(eps) * std::sin(lambda) };
}

// ---------------------------------------------------------------------------
// Two-line elements + Kepler propagation with J2 secular perturbations.
// ---------------------------------------------------------------------------
struct Orbit
{
    std::string name;
    double epochUnix = 0;
    double inclination = 0, raan = 0, eccentricity = 0, argPerigee = 0, meanAnomaly = 0;  // rad
    double meanMotion = 0;   // rad/s
    double semiMajorAxis = 0; // km
    bool valid = false;

    double PeriodSeconds() const { return 2 * PI / meanMotion; }

    // Circular-orbit fallback (used when no TLE is available).
    static Orbit Circular(const char* name, double altitudeKm, double inclinationDeg, double raanDeg, double epochUnix)
    {
        Orbit o;
        o.name = name;
        o.semiMajorAxis = EARTH_RADIUS + altitudeKm;
        o.meanMotion = std::sqrt(MU_EARTH / (o.semiMajorAxis * o.semiMajorAxis * o.semiMajorAxis));
        o.inclination = inclinationDeg * DEG;
        o.raan = raanDeg * DEG;
        o.epochUnix = epochUnix;
        o.valid = true;
        return o;
    }

    static double Field(const std::string& line, size_t start, size_t len)
    {
        return std::atof(line.substr(start, len).c_str());
    }

    // Parses the two element lines (columns per the NORAD TLE format).
    static Orbit FromTle(const std::string& name, const std::string& l1, const std::string& l2)
    {
        Orbit o;
        o.name = name;
        if (l1.size() < 63 || l2.size() < 63 || l1[0] != '1' || l2[0] != '2') return o;
        int yy = (int)Field(l1, 18, 2);
        double day = Field(l1, 20, 12);
        int year = yy < 57 ? 2000 + yy : 1900 + yy;
        o.epochUnix = (double)DaysFromCivil(year, 1, 1) * 86400.0 + (day - 1.0) * 86400.0;
        o.inclination = Field(l2, 8, 8) * DEG;
        o.raan = Field(l2, 17, 8) * DEG;
        o.eccentricity = std::atof(("0." + l2.substr(26, 7)).c_str());
        o.argPerigee = Field(l2, 34, 8) * DEG;
        o.meanAnomaly = Field(l2, 43, 8) * DEG;
        const double revPerDay = Field(l2, 52, 11);
        o.meanMotion = revPerDay * 2 * PI / 86400.0;
        o.semiMajorAxis = std::cbrt(MU_EARTH / (o.meanMotion * o.meanMotion));
        o.valid = revPerDay > 0;
        return o;
    }

    // Position in ECI (km) at a unix time.
    Vec3 PositionEci(double unixSeconds) const
    {
        const double dt = unixSeconds - epochUnix;
        const double e = eccentricity;
        const double p = semiMajorAxis * (1 - e * e);
        const double k = 1.5 * meanMotion * J2 * (EARTH_EQ_RADIUS / p) * (EARTH_EQ_RADIUS / p);
        const double cosI = std::cos(inclination);
        const double raanNow = raan - k * cosI * dt;                                 // nodal regression
        const double argpNow = argPerigee + 0.5 * k * (5 * cosI * cosI - 1) * dt;    // apsidal precession

        double M = std::fmod(meanAnomaly + meanMotion * dt, 2 * PI);
        double E = M;
        for (int i = 0; i < 8; i++) E -= (E - e * std::sin(E) - M) / (1 - e * std::cos(E));   // Kepler's equation
        const double nu = std::atan2(std::sqrt(1 - e * e) * std::sin(E), std::cos(E) - e);
        const double r = semiMajorAxis * (1 - e * std::cos(E));

        // Perifocal -> ECI: R3(-raan) R1(-i) R3(-argp)
        const double u = argpNow + nu;
        const double cO = std::cos(raanNow), sO = std::sin(raanNow);
        const double cu = std::cos(u), su = std::sin(u);
        const double sI = std::sin(inclination);
        return { r * (cO * cu - sO * su * cosI), r * (sO * cu + cO * su * cosI), r * (su * sI) };
    }
};

// Splits a Celestrak "FORMAT=TLE" response (3 lines per object) into orbits.
inline bool ParseTle(const std::string& text, Orbit& out)
{
    std::string lines[3];
    int n = 0;
    size_t pos = 0;
    while (pos < text.size() && n < 3)
    {
        size_t end = text.find('\n', pos);
        if (end == std::string::npos) end = text.size();
        std::string line = text.substr(pos, end - pos);
        while (!line.empty() && (line.back() == '\r' || line.back() == ' ')) line.pop_back();
        if (!line.empty()) lines[n++] = line;
        pos = end + 1;
    }
    if (n < 3) return false;
    out = Orbit::FromTle(lines[0], lines[1], lines[2]);
    return out.valid;
}
} // namespace astro
```

### 8.4 Descargas HTTP con ETag (C++) (`src/space/Http.h`)

```cpp
#pragma once
// Minimal HTTPS GET to a file with WinHTTP, honouring ETags (If-None-Match) so unchanged
// resources are not downloaded again.
#include <windows.h>
#include <winhttp.h>
#include <string>
#include <vector>

namespace http
{
enum class Result { Downloaded, NotModified, Failed };

inline std::wstring ReadSmallFile(const std::wstring& path)
{
    HANDLE f = CreateFileW(path.c_str(), GENERIC_READ, FILE_SHARE_READ, nullptr, OPEN_EXISTING, 0, nullptr);
    if (f == INVALID_HANDLE_VALUE) return L"";
    char buf[512] = {};
    DWORD read = 0;
    ReadFile(f, buf, sizeof(buf) - 1, &read, nullptr);
    CloseHandle(f);
    std::string s(buf, read);
    return std::wstring(s.begin(), s.end());
}

inline void WriteSmallFile(const std::wstring& path, const std::wstring& text)
{
    std::string s(text.begin(), text.end());
    HANDLE f = CreateFileW(path.c_str(), GENERIC_WRITE, 0, nullptr, CREATE_ALWAYS, 0, nullptr);
    if (f == INVALID_HANDLE_VALUE) return;
    DWORD written;
    WriteFile(f, s.data(), (DWORD)s.size(), &written, nullptr);
    CloseHandle(f);
}

// Downloads url into outPath (via a temp file, replaced atomically on success).
// If etagPath is given, sends If-None-Match with the stored ETag and saves the new one.
inline Result Download(const std::wstring& url, const std::wstring& outPath, const std::wstring& etagPath = L"",
                       DWORD timeoutMs = 120000)
{
    URL_COMPONENTS uc = { sizeof(uc) };
    wchar_t host[256] = {}, path[2048] = {};
    uc.lpszHostName = host;
    uc.dwHostNameLength = _countof(host);
    uc.lpszUrlPath = path;
    uc.dwUrlPathLength = _countof(path);
    wchar_t extra[2048] = {};
    uc.lpszExtraInfo = extra;
    uc.dwExtraInfoLength = _countof(extra);
    if (!WinHttpCrackUrl(url.c_str(), 0, 0, &uc)) return Result::Failed;
    std::wstring object = std::wstring(path) + extra;

    Result result = Result::Failed;
    HINTERNET session = WinHttpOpen(L"RTWallpaper/1.0", WINHTTP_ACCESS_TYPE_AUTOMATIC_PROXY,
                                    WINHTTP_NO_PROXY_NAME, WINHTTP_NO_PROXY_BYPASS, 0);
    if (!session) return result;
    WinHttpSetTimeouts(session, 15000, 15000, timeoutMs, timeoutMs);
    HINTERNET conn = WinHttpConnect(session, host, uc.nPort, 0);
    HINTERNET req = conn ? WinHttpOpenRequest(conn, L"GET", object.c_str(), nullptr, WINHTTP_NO_REFERER,
                                              WINHTTP_DEFAULT_ACCEPT_TYPES,
                                              uc.nScheme == INTERNET_SCHEME_HTTPS ? WINHTTP_FLAG_SECURE : 0)
                         : nullptr;
    if (req)
    {
        std::wstring headers;
        std::wstring etag = etagPath.empty() ? L"" : ReadSmallFile(etagPath);
        if (!etag.empty() && GetFileAttributesW(outPath.c_str()) != INVALID_FILE_ATTRIBUTES)
            headers = L"If-None-Match: " + etag + L"\r\n";
        if (WinHttpSendRequest(req, headers.empty() ? WINHTTP_NO_ADDITIONAL_HEADERS : headers.c_str(),
                               headers.empty() ? 0 : (DWORD)-1L, WINHTTP_NO_REQUEST_DATA, 0, 0, 0) &&
            WinHttpReceiveResponse(req, nullptr))
        {
            DWORD status = 0, size = sizeof(status);
            WinHttpQueryHeaders(req, WINHTTP_QUERY_STATUS_CODE | WINHTTP_QUERY_FLAG_NUMBER, WINHTTP_HEADER_NAME_BY_INDEX,
                                &status, &size, WINHTTP_NO_HEADER_INDEX);
            if (status == 304)
            {
                result = Result::NotModified;
            }
            else if (status == 200)
            {
                std::wstring tmp = outPath + L".part";
                HANDLE f = CreateFileW(tmp.c_str(), GENERIC_WRITE, 0, nullptr, CREATE_ALWAYS, 0, nullptr);
                bool ok = f != INVALID_HANDLE_VALUE;
                std::vector<char> buf(1 << 20);
                DWORD got = 0;
                ULONGLONG total = 0;
                while (ok && WinHttpReadData(req, buf.data(), (DWORD)buf.size(), &got) && got > 0)
                {
                    DWORD written;
                    ok = WriteFile(f, buf.data(), got, &written, nullptr) && written == got;
                    total += got;
                }
                if (f != INVALID_HANDLE_VALUE) CloseHandle(f);
                if (ok && total > 0 && MoveFileExW(tmp.c_str(), outPath.c_str(), MOVEFILE_REPLACE_EXISTING))
                {
                    result = Result::Downloaded;
                    if (!etagPath.empty())
                    {
                        wchar_t newTag[512] = {};
                        DWORD len = sizeof(newTag);
                        if (WinHttpQueryHeaders(req, WINHTTP_QUERY_ETAG, WINHTTP_HEADER_NAME_BY_INDEX, newTag, &len,
                                                WINHTTP_NO_HEADER_INDEX))
                            WriteSmallFile(etagPath, newTag);
                    }
                }
                else
                {
                    DeleteFileW(tmp.c_str());
                }
            }
        }
        WinHttpCloseHandle(req);
    }
    if (conn) WinHttpCloseHandle(conn);
    WinHttpCloseHandle(session);
    return result;
}
} // namespace http
```

### 8.5 Decodificación de imágenes y mipmaps (C++) (`src/space/Image.h`)

```cpp
#pragma once
// Image decoding with WIC (JPEG/PNG/TIFF...), optional resize, and CPU mip-chain generation.
#include <windows.h>
#include <wincodec.h>
#include <wrl/client.h>
#include <string>
#include <vector>
#include "scenes/Scene.h"

namespace image
{
struct Rgba
{
    UINT width = 0, height = 0;
    std::vector<uint8_t> pixels;   // RGBA8, row-major
};

// Decodes any WIC-supported file into RGBA8, scaled to (width, height) if non-zero.
// Call from a thread that has initialised COM.
inline bool Load(const std::wstring& path, UINT width, UINT height, Rgba& out)
{
    using Microsoft::WRL::ComPtr;
    ComPtr<IWICImagingFactory> factory;
    if (FAILED(CoCreateInstance(CLSID_WICImagingFactory, nullptr, CLSCTX_INPROC_SERVER, IID_PPV_ARGS(&factory))))
        return false;
    ComPtr<IWICBitmapDecoder> decoder;
    if (FAILED(factory->CreateDecoderFromFilename(path.c_str(), nullptr, GENERIC_READ,
                                                  WICDecodeMetadataCacheOnDemand, &decoder)))
        return false;
    ComPtr<IWICBitmapFrameDecode> frame;
    if (FAILED(decoder->GetFrame(0, &frame))) return false;

    ComPtr<IWICBitmapSource> source = frame;
    UINT w = 0, h = 0;
    frame->GetSize(&w, &h);
    if (width && height && (w != width || h != height))
    {
        ComPtr<IWICBitmapScaler> scaler;
        if (FAILED(factory->CreateBitmapScaler(&scaler)) ||
            FAILED(scaler->Initialize(source.Get(), width, height, WICBitmapInterpolationModeFant)))
            return false;
        source = scaler;
        w = width;
        h = height;
    }
    ComPtr<IWICFormatConverter> conv;
    if (FAILED(factory->CreateFormatConverter(&conv)) ||
        FAILED(conv->Initialize(source.Get(), GUID_WICPixelFormat32bppRGBA, WICBitmapDitherTypeNone, nullptr, 0,
                                WICBitmapPaletteTypeCustom)))
        return false;
    out.width = w;
    out.height = h;
    out.pixels.resize((size_t)w * h * 4);
    return SUCCEEDED(conv->CopyPixels(nullptr, w * 4, (UINT)out.pixels.size(), out.pixels.data()));
}

// Builds a full mip chain with a 2x2 box filter. bpp = bytes per pixel (1 or 4).
inline TextureUpload MakeMips(UINT slot, DXGI_FORMAT format, UINT bpp, UINT width, UINT height, std::vector<uint8_t> level0)
{
    TextureUpload t;
    t.slot = slot;
    t.format = format;
    t.bytesPerPixel = bpp;
    t.mips.push_back({ width, height, std::move(level0) });
    while (t.mips.back().width > 1 || t.mips.back().height > 1)
    {
        const TextureUpload::Mip& src = t.mips.back();
        UINT w = std::max(1u, src.width / 2), h = std::max(1u, src.height / 2);
        TextureUpload::Mip dst = { w, h, std::vector<uint8_t>((size_t)w * h * bpp) };
        for (UINT y = 0; y < h; y++)
        {
            UINT y0 = std::min(y * 2, src.height - 1), y1 = std::min(y * 2 + 1, src.height - 1);
            for (UINT x = 0; x < w; x++)
            {
                UINT x0 = std::min(x * 2, src.width - 1), x1 = std::min(x * 2 + 1, src.width - 1);
                for (UINT c = 0; c < bpp; c++)
                {
                    UINT s = src.data[((size_t)y0 * src.width + x0) * bpp + c] + src.data[((size_t)y0 * src.width + x1) * bpp + c] +
                             src.data[((size_t)y1 * src.width + x0) * bpp + c] + src.data[((size_t)y1 * src.width + x1) * bpp + c];
                    dst.data[((size_t)y * w + x) * bpp + c] = (uint8_t)((s + 2) / 4);
                }
            }
        }
        t.mips.push_back(std::move(dst));
    }
    return t;
}
} // namespace image
```

### 8.6 Interfaz de escena (C++) (`src/scenes/Scene.h`)

```cpp
#pragma once
// Interface every wallpaper scene implements. The renderer is generic: a scene provides
// its DXIL library, hit groups, bottom-level geometry, and per-frame constants + instances.
//
// Shader conventions (every scene's HLSL must export these):
//   RayGen, Miss (radiance, miss index 0), ShadowMiss (miss index 1)
//   Global root signature: u0 output texture, t0 TLAS, b0 constants,
//   t1..t4 optional scene textures (null until the scene uploads them), s0 linear sampler
//   (wrap in U, clamp in V: suits equirectangular maps).
#include <d3d12.h>
#include <DirectXMath.h>
#include <cmath>
#include <cstring>
#include <string>
#include <vector>

static constexpr UINT kMaxSceneConstants = 1024;   // bytes
static constexpr UINT kMaxSceneTextures = 4;        // t1..t4

// CPU image handed to the renderer (full mip chain, tightly packed rows).
struct TextureUpload
{
    UINT slot = 0;                                  // 0..kMaxSceneTextures-1 => t1..t4
    DXGI_FORMAT format = DXGI_FORMAT_R8G8B8A8_UNORM;
    UINT bytesPerPixel = 4;
    struct Mip { UINT width, height; std::vector<uint8_t> data; };
    std::vector<Mip> mips;
};

struct HitGroupDef
{
    const wchar_t* name;
    const wchar_t* closestHit;
    const wchar_t* intersection;   // nullptr => triangle geometry
};

struct GeometryDef
{
    bool procedural = true;            // true: one AABB, false: triangle list
    D3D12_RAYTRACING_AABB aabb = {};
    std::vector<float> vertices;       // xyz per vertex (triangle list)
};

struct InstanceDef
{
    UINT geometry = 0;   // index into Geometry()
    UINT hitGroup = 0;   // index into HitGroups()
    UINT id = 0;         // InstanceID() in HLSL
    float transform[3][4] = { { 1, 0, 0, 0 }, { 0, 1, 0, 0 }, { 0, 0, 1, 0 } };

    void SetTranslationScale(float x, float y, float z, float s)
    {
        for (int r = 0; r < 3; r++)
            for (int c = 0; c < 4; c++)
                transform[r][c] = (r == c) ? s : 0.0f;
        transform[0][3] = x;
        transform[1][3] = y;
        transform[2][3] = z;
    }
};

class Scene
{
public:
    virtual ~Scene() = default;
    virtual const wchar_t* Name() const = 0;
    virtual D3D12_SHADER_BYTECODE Library() const = 0;
    virtual std::vector<HitGroupDef> HitGroups() const = 0;
    virtual std::vector<GeometryDef> Geometry() const = 0;
    virtual UINT InstanceCount() const = 0;
    virtual UINT MaxRecursion() const = 0;
    virtual UINT PayloadSize() const { return 16; }
    virtual UINT AttributeSize() const { return 16; }
    // Advance the animation by dt seconds (already multiplied by the Speed setting).
    // aspect = viewport width / height. Writes shader constants (returns their size,
    // at most kMaxSceneConstants) and InstanceCount() instances.
    virtual UINT Update(float dt, float aspect, void* constants, InstanceDef* instances) = 0;
    // Textures that became ready since the last call (e.g. loaded by a background thread).
    virtual void PollTextures(std::vector<TextureUpload>& out) { (void)out; }
};

// Camera basis as consumed by the shaders: position.w = tan(fovY / 2).
struct CameraConstants
{
    DirectX::XMFLOAT4 position, forward, right, up;
};

inline CameraConstants MakeCameraDir(DirectX::FXMVECTOR eye, DirectX::FXMVECTOR forward, float fovYDegrees,
                                     DirectX::FXMVECTOR upHint)
{
    using namespace DirectX;
    XMVECTOR fwd = XMVector3Normalize(forward);
    XMVECTOR right = XMVector3Normalize(XMVector3Cross(fwd, upHint));
    XMVECTOR up = XMVector3Cross(right, fwd);
    CameraConstants c;
    XMStoreFloat4(&c.position, eye);
    c.position.w = tanf(XMConvertToRadians(fovYDegrees) * 0.5f);
    XMStoreFloat4(&c.forward, fwd);
    XMStoreFloat4(&c.right, right);
    XMStoreFloat4(&c.up, up);
    return c;
}

inline CameraConstants MakeCamera(DirectX::FXMVECTOR eye, DirectX::FXMVECTOR target, float fovYDegrees)
{
    using namespace DirectX;
    return MakeCameraDir(eye, XMVectorSubtract(target, eye), fovYDegrees, XMVectorSet(0, 1, 0, 0));
}
```

### 8.7 Pruebas de escala física (C++) (`tests/astro_test.cpp`)

```cpp
// Sanity checks for src/space/Astro.h (built and run on Linux inside the toolchain container):
//   clang++-18 -std=c++17 -O2 -Isrc tests/astro_test.cpp -o /tmp/astro_test && /tmp/astro_test
#include <cstdio>
#include "space/Astro.h"

using namespace astro;

static int failures = 0;
static void Check(bool ok, const char* what, double value)
{
    printf("%-55s %14.4f  %s\n", what, value, ok ? "OK" : "FAIL");
    if (!ok) failures++;
}

int main()
{
    Orbit iss = Orbit::FromTle("ISS (ZARYA)",
        "1 25544U 98067A   26315.20707527  .00009235  00000+0  17362-3 0  9997",
        "2 25544  51.6322 292.5559 0007316  12.7435 347.3737 15.49310717594546");
    Orbit hst = Orbit::FromTle("HST",
        "1 20580U 90037B   26314.89250324  .00006442  00000+0  19351-3 0  9990",
        "2 20580  28.4707 156.7631 0002117 354.3305   5.7267 15.32255871811082");

    const double t = iss.epochUnix + 3600.0;
    Vec3 p = iss.PositionEci(t), p2 = iss.PositionEci(t + 1.0);
    double alt = p.Length() - EARTH_RADIUS, v = (p2 - p).Length();
    Check(iss.valid && hst.valid, "TLEs parsed", 1);
    Check(alt > 380 && alt < 450, "ISS altitude (km)", alt);
    Check(v > 7.60 && v < 7.72, "ISS speed (km/s)", v);
    Check(std::fabs(v - std::sqrt(MU_EARTH / p.Length())) < 0.02, "ISS speed vs circular sqrt(mu/r) (km/s)", std::sqrt(MU_EARTH / p.Length()));
    Check(iss.PeriodSeconds() / 60 > 91 && iss.PeriodSeconds() / 60 < 94, "ISS period (min)", iss.PeriodSeconds() / 60);
    Check(SIDEREAL_DAY / iss.PeriodSeconds() > 15.3 && SIDEREAL_DAY / iss.PeriodSeconds() < 15.7, "Orbits per Earth rotation (sidereal day / period)", SIDEREAL_DAY / iss.PeriodSeconds());
    double lat = std::asin(p.z / p.Length()) / DEG;
    Check(std::fabs(lat) <= 51.7, "ISS latitude within inclination (deg)", lat);

    Vec3 h = hst.PositionEci(t);
    Check(h.Length() - EARTH_RADIUS > 450 && h.Length() - EARTH_RADIUS < 560, "Hubble altitude (km)", h.Length() - EARTH_RADIUS);

    // Sun: distance ~1 AU, angular diameter ~0.53 deg, declination about -17.5 deg on 11 Nov.
    const double nov11 = (double)DaysFromCivil(2026, 11, 11) * 86400.0 + 12 * 3600.0;
    Vec3 s = SunPositionEci(nov11);
    double au = s.Length() / AU, dec = std::asin(s.z / s.Length()) / DEG;
    Check(au > 0.985 && au < 0.995, "Sun distance on 2026-11-11 (AU)", au);
    Check(s.Length() / EARTH_RADIUS > 23000, "Sun distance (Earth radii)", s.Length() / EARTH_RADIUS);
    Check(dec > -18.5 && dec < -16.5, "Sun declination on 2026-11-11 (deg)", dec);
    Check(std::fabs(2 * std::asin(SUN_RADIUS / s.Length()) / DEG - 0.54) < 0.02, "Sun angular diameter (deg)", 2 * std::asin(SUN_RADIUS / s.Length()) / DEG);

    // GMST at J2000.0 epoch is 280.46 deg.
    Check(std::fabs(Gmst((2451545.0 - 2440587.5) * 86400.0) / DEG - 280.4606) < 1e-3, "GMST at J2000 (deg)", Gmst((2451545.0 - 2440587.5) * 86400.0) / DEG);

    // Subsolar longitude at 12:00 UTC should be close to 0 (equation of time ~ +16 min in Nov => ~ -4 deg).
    double ra = std::atan2(s.y, s.x), lon = std::remainder(ra - Gmst(nov11), 2 * PI) / DEG;
    Check(std::fabs(lon) < 6, "Subsolar longitude at 12:00 UTC (deg)", lon);

    printf(failures ? "\n%d FAILED\n" : "\nall passed\n", failures);
    return failures;
}
```

