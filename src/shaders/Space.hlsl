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
    float4 cloudInfo;        // x = mode (0 flat, 1 layered), y = cloud-top relief exaggeration
    float4 sunVisibility;    // rgb = Sun seen by the camera (limb coverage x atmosphere), w = fraction of the disc
    float4 sunLimb;          // x = glow of the limb when the Sun is just behind it (0..1)
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

#include "Common.hlsli"

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
    // Mie: haze (g = 0.76) plus a narrow forward lobe (g = 0.95) for larger aerosols, so the limb
    // blazes where the Sun is about to rise behind it.
    const float g = 0.76f, g2 = 0.95f;
    float phaseM = 0.8f * (1.0f - g * g) / (4.0f * PI * pow(abs(1.0f + g * g - 2.0f * g * mu), 1.5f))
                 + 0.2f * (1.0f - g2 * g2) / (4.0f * PI * pow(abs(1.0f + g2 * g2 - 2.0f * g2 * mu), 1.5f));

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

// Lens glare around the Sun (camera effect). Evaluated over the whole image: it fades smoothly
// to zero, with no cut-off circle.
float3 SunGlare(float3 d)
{
    float r = g_cb.sunInfo.x;
    float a = acos(clamp(dot(d, g_cb.sunDirection.xyz), -1.0f, 1.0f));
    return float3(1.0f, 0.95f, 0.88f) * (24.0f * exp(-a / (r * 5.0f)) + 0.35f * exp(-a / (r * 30.0f)));
}

// Sunrise behind the limb: the thin shell of air at the limb forward-scatters a warm blaze, an
// arc along the limb centred where the Sun is about to appear. It lives in the air only: rays
// that pass high above the limb or hit the ground well inside the disc get none of it (otherwise
// the dark Earth would look transparent).
float3 LimbGlow(float3 o, float3 d)
{
    float b = dot(o, d);
    float hc = (b < 0.0f ? sqrt(max(dot(o, o) - b * b, 0.0f)) : length(o)) - RE;   // closest approach altitude
    float shell = hc >= 0.0f ? exp(-hc / 18.0f) : exp(hc / 5.0f);
    float r = g_cb.sunInfo.x;
    float a = acos(clamp(dot(d, g_cb.sunDirection.xyz), -1.0f, 1.0f));
    return float3(1.0f, 0.72f, 0.45f) * shell * (40.0f * exp(-a / (r * 6.0f)) + 2.0f * exp(-a / (r * 40.0f)));
}

// Lens flare of a multi-element camera lens: star-shaped diffraction spikes and a chromatic halo
// around the Sun, plus coloured ghost reflections on the line from the Sun through the image
// centre. p and s are aspect-corrected screen coordinates of the pixel and of the Sun.
float3 LensFlare(float2 p, float2 s, float2 dimSun)
{
    float3 col = 0;
    float2 v = p - s;
    float dS = length(v);

    // Diffraction spikes (6-blade aperture) and a faint wide star.
    float ang = atan2(v.y, v.x);
    float spikes = pow(abs(cos(ang * 3.0f)), 180.0f) + 0.4f * pow(abs(cos(ang * 3.0f + 0.52f)), 400.0f);
    col += float3(1.0f, 0.95f, 0.85f) * spikes * exp(-dS / 0.10f) * 6.0f;

    // Chromatic halo: a thin ring, red outside, blue inside.
    const float haloR = 0.42f;
    col += float3(exp(-pow((dS - haloR * 1.02f) / 0.012f, 2.0f)),
                  exp(-pow((dS - haloR) / 0.012f, 2.0f)),
                  exp(-pow((dS - haloR * 0.98f) / 0.012f, 2.0f))) * 0.18f;

    // Ghosts: position along the Sun -> centre axis (1 = Sun, 0 = centre, < 0 = beyond it).
    const float  kPos[7] = { 0.55f, 0.28f, -0.18f, -0.42f, -0.72f, -1.0f, -1.35f };
    const float  kRad[7] = { 0.060f, 0.025f, 0.110f, 0.045f, 0.200f, 0.085f, 0.032f };
    const float3 kCol[7] = { float3(0.35f, 0.85f, 0.55f), float3(1.0f, 0.65f, 0.30f), float3(0.55f, 0.35f, 1.0f),
                             float3(0.25f, 0.75f, 1.0f), float3(1.0f, 0.40f, 0.65f), float3(0.60f, 1.0f, 0.45f),
                             float3(1.0f, 0.85f, 0.55f) };
    [unroll]
    for (int i = 0; i < 7; i++)
    {
        float d = length(p - s * kPos[i]);
        float disc = smoothstep(kRad[i], kRad[i] * 0.75f, d);              // soft-edged aperture image
        float rim = exp(-pow((d - kRad[i]) / (kRad[i] * 0.08f), 2.0f));     // brighter rim
        float ring = (i == 4) ? 1.0f : 0.0f;                                // one large ring-shaped ghost
        col += kCol[i] * lerp(disc * 0.5f + rim * 0.35f, rim, ring) * 0.22f;
    }
    // Flares fade as the Sun leaves the frame.
    float onScreen = 1.0f - smoothstep(1.0f, 1.8f, max(abs(dimSun.x), abs(dimSun.y)));
    return col * onScreen;
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
    return TraceVisibility(origin, dir, T_MAX, 0.0f);
}

// ---------------------------------------------------------------------------
// Ray generation
// ---------------------------------------------------------------------------
[shader("raygeneration")]
void RayGen()
{
    uint2 idx = DispatchRaysIndex().xy;
    uint2 dim = DispatchRaysDimensions().xy;

    float2 ndc;
    float3 dir = CameraRayDirection(idx, dim, ndc);

    float3 col = TraceRadiance(g_cb.cameraPosition.xyz, dir, 0);

    // Glare and lens flare, scaled by how much of the Sun the camera sees: the fraction of the
    // disc above the Earth's limb, reddened by the air it grazes (computed once per frame on the
    // CPU, see SpaceScene::SunVisibility). Hidden Sun => no glare, no flare.
    float3 sunSeen = g_cb.sunVisibility.rgb;
    if (g_cb.sunLimb.x > 0.001f)
        col += LimbGlow(g_cb.cameraPosition.xyz, dir) * g_cb.sunLimb.x;
    if (g_cb.sunVisibility.w > 0.0f)
    {
        col += SunGlare(dir) * sunSeen;
        float3 L = g_cb.sunDirection.xyz;
        float f = dot(L, g_cb.cameraForward.xyz);
        if (f > 0.05f)
        {
            float aspect = float(dim.x) / float(dim.y);
            float tanH = g_cb.cameraPosition.w;
            float2 sunNdc = float2(dot(L, g_cb.cameraRight.xyz) / (f * tanH * aspect), dot(L, g_cb.cameraUp.xyz) / (f * tanH));
            col += LensFlare(ndc * float2(aspect, 1.0f), sunNdc * float2(aspect, 1.0f), sunNdc) * sunSeen;
        }
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
    EarthAttributes attr;
    float t;
    if (UnitSphereHit(t, attr.normal))
        ReportHit(t, 0, attr);
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

// ---------------------------------------------------------------------------
// Layered (2.5D) clouds, clouds.md phase C1: cloud-top height estimated from the opacity map,
// parallax, relief on the tops, long shadows, tops lit after sunset, two-stream light.
// ---------------------------------------------------------------------------
static const float CLOUD_TOP_MAX = 12.0f;   // km

float3 WorldFromEarth(float3 v)
{
    return g_cb.earthRow[0].xyz * v.x + g_cb.earthRow[1].xyz * v.y + g_cb.earthRow[2].xyz * v.z;
}

// Cloud-top height (km) estimated from opacity: thin and medium layers stay at 2-4 km, only the
// densest cores (thunderstorms) climb to 12 km. Read from a coarser mip so towers get rounded
// tops and their edges taper down.
float CloudTopKm(float2 uv, float lod)
{
    float a = CloudOpacity(g_clouds.SampleLevel(g_linear, uv, lod + 1.5f));
    float k = smoothstep(0.6f, 1.0f, a);
    return 2.0f + (CLOUD_TOP_MAX - 2.0f) * k * k;
}

// First crossing of the view ray with the sphere of radius RE + h (the camera is always above).
float3 RayAtHeight(float3 o, float3 d, float h, float3 fallback)
{
    float r = RE + h;
    float b = dot(o, d);
    float disc = b * b - (dot(o, o) - r * r);
    if (disc < 0.0f) return fallback;
    float t = -b - sqrt(disc);
    return t > 0.0f ? o + d * t : fallback;
}

// Fraction of the solar disc above the Earth's limb seen from height h (km) over the unit
// normal n: the horizon dips by acos(RE / (RE + h)), so high tops stay lit after sunset.
// The ramp after it dims grazing light: only tower sides face the Sun at the very end of the day.
float EarthSunVisibility(float3 n, float3 L, float h)
{
    float elev = asin(clamp(dot(n, L), -1.0f, 1.0f));
    float dip = acos(RE / (RE + h));
    float above = elev + dip;                                  // Sun altitude over this horizon (rad)
    return smoothstep(-g_cb.sunInfo.x, g_cb.sunInfo.x, above) * (0.3f + 0.7f * saturate(above / 0.1f));
}

// Shadow cast by clouds on a point at height h0 (km), n = unit ECEF normal, Le = Sun (ECEF).
// The sun ray reaches height z at horizontal distance s(z) (Earth curvature included:
// z = h0 + s*tanE + s^2 / 2RE); a cloud there whose top is above z blocks the Sun.
// Sampling by height level instead of by distance covers both short (high Sun) and
// hundreds-of-km (grazing Sun) shadows with the same 8 samples.
float CloudShadowLayered(float3 n, float3 Le, float h0, float lod, float strength)
{
    float sinE = dot(n, Le);
    float3 t = Le - n * sinE;
    float tl = length(t);
    if (tl < 1e-4f) return 1.0f - strength * CloudOpacity(g_clouds.SampleLevel(g_linear, LatLonUV(n), lod));
    t /= tl;
    float tanE = sinE / tl;
    float texel = 2.0f * PI * RE / max(g_cb.textureInfo.z, 1.0f);
    float occ = 0.0f;
    [loop]
    for (int k = 0; k < 8; k++)
    {
        float z = lerp(h0 + 0.3f, CLOUD_TOP_MAX + 0.5f, (k + 0.5f) / 8.0f);
        float dz = z - h0;
        if (dz <= 0.0f) continue;
        float q = sqrt(tanE * tanE + 2.0f * dz / RE);
        float s = tanE > 0.0f ? 2.0f * dz / (tanE + q) : RE * (q - tanE);   // stable both ways
        if (s > 700.0f) break;
        float ang = s / RE;
        float3 m = n * cos(ang) + t * sin(ang);                            // great-circle step
        float2 uvk = LatLonUV(m);
        float lodK = max(lod, log2(max(s * 0.15f / texel, 1.0f)));         // softer far shadows
        float a = CloudOpacity(g_clouds.SampleLevel(g_linear, uvk, lodK));
        float top = CloudTopKm(uvk, lodK);
        occ = max(occ, a * smoothstep(z - 1.5f, z + 1.5f, top));
    }
    return 1.0f - strength * occ;
}

// Normal of the cloud tops from the height-field gradient (world space).
float3 CloudTopNormal(float3 N, float3 ecef, float2 uv, float lod)
{
    float3 east = cross(WorldFromEarth(float3(0.0f, 0.0f, 1.0f)), N);
    float el = length(east);
    if (el < 1e-3f) return N;                                              // poles
    east /= el;
    float3 north = cross(N, east);
    // Gradient of a smoother height (1.5 mips coarser than CloudTopKm's own blur): the tops show
    // towers and fronts, not foam-like bubbles from texel-level noise in the opacity map.
    float lodN = lod + 1.5f;
    float w = max(g_cb.textureInfo.z, 1.0f);
    float stepU = exp2(lodN + 1.5f) / w;                                   // one coarse texel
    float stepKm = 2.0f * PI * RE * stepU;
    float coslat = max(sqrt(saturate(1.0f - ecef.z * ecef.z)), 0.05f);
    float dE = (CloudTopKm(uv + float2(stepU, 0), lodN) - CloudTopKm(uv - float2(stepU, 0), lodN)) / (2.0f * stepKm * coslat);
    float dN = (CloudTopKm(uv - float2(0, 2.0f * stepU), lodN) - CloudTopKm(uv + float2(0, 2.0f * stepU), lodN)) / (2.0f * stepKm);
    float k = g_cb.cloudInfo.y;
    return normalize(N - k * (dE * east + dN * north));
}

// Billow noise: |2n - 1| of a smooth value noise. Its highs are round lumps and its zeros sharp
// creases, which is what cauliflower cloud tops look like; summed over octaves the lumps come in
// very irregular sizes. Octaves whose features get smaller than ~2 pixels fade out (no shimmer).
float BillowTops(float3 q, float footprintKm, float baseKm)
{
    float s = 0.0f, norm = 0.0f, a = 1.0f, km = baseKm;
    [unroll]
    for (int i = 0; i < 3; i++)
    {
        float w = a * (1.0f - smoothstep(0.35f, 0.8f, footprintKm / km));
        s += w * abs(Noise3(q) * 2.0f - 1.0f);
        norm += a;
        q = q * 2.07f + float3(3.1f, 7.7f, 1.3f);
        a *= 0.55f;
        km *= 0.483f;
    }
    return s / norm;
}

// Cauliflower tops of big, tall, dense cloud masses (cumulonimbus, cumulus congestus). mask
// selects where they grow. Returns a shading factor (darker in the creases) and the lean of the
// top normal (ECEF) from the gradient of the billow height, so each lump has a lit side and a
// side in shadow. The domain is warped a little so the lumps do not line up.
float CumulusTops(float3 ecef, float footprint, float mask, out float3 tiltEcef)
{
    tiltEcef = 0;
    const float BASE_KM = 70.0f;                             // lumps of ~70, 34 and 16 km
    float3 q = ecef * (RE / BASE_KM);
    q += (float3(Noise3(q * 0.31f), Noise3(q * 0.31f + 5.2f), Noise3(q * 0.31f + 9.7f)) - 0.5f) * 1.2f;
    float h0 = BillowTops(q, footprint, BASE_KM);

    float3 east = float3(-ecef.y, ecef.x, 0.0f);
    float el = length(east);
    east = el > 1e-4f ? east / el : float3(1.0f, 0.0f, 0.0f);
    float3 north = cross(ecef, east);
    const float d = 0.12f;                                   // finite-difference step (base cells)
    float hE = BillowTops(q + east * d, footprint, BASE_KM);
    float hN = BillowTops(q + north * d, footprint, BASE_KM);
    tiltEcef = -((hE - h0) * east + (hN - h0) * north) / d * 0.35f * mask;

    float crease = smoothstep(0.0f, 0.30f, h0);              // 0 in the creases, 1 on the lumps
    return lerp(1.0f, lerp(0.85f, 1.0f, crease), mask);
}

// Sun glitter on the sea (Cox & Munk 1954). The surface is a field of facets with Gaussian slopes
// of variance sigma2; the glint is the share of facets tilted to mirror the Sun towards the
// camera. Returns radiance per unit of solar irradiance (perpendicular to the Sun), in the same
// units as albedo * E for the land. Elongated at grazing angles by the geometry itself.
float SunGlitter(float3 N, float3 V, float3 L, float sigma2)
{
    float3 H = normalize(L + V);
    float cosB = saturate(dot(N, H));                        // facet tilt from the mean surface
    float cosV = max(dot(N, V), 0.03f);
    float cos2 = max(cosB * cosB, 1e-4f);
    float p = exp(-(1.0f - cos2) / cos2 / sigma2) / (PI * sigma2);
    float F = 0.02f + 0.98f * pow(1.0f - saturate(dot(V, H)), 5.0f);   // Fresnel of water
    return PI * F * p / (4.0f * cosV * cos2 * cos2);
}

// Wind over the sea, fixed to the ground. What the glint reveals from orbit is not the waves
// (metres long) but patches of different roughness: regional wind (calm = tight, bright glint;
// windy = wide, dull) and slicks / wind rows at 5-50 km, here a warped multi-octave pattern.
// Returns the slope variance (Cox-Munk: 0.003 + 0.00512 * wind m/s).
float OceanRoughness(float3 ecef, float footprintKm)
{
    float3 q = ecef * RE;                                                  // km
    float wind = lerp(2.5f, 11.0f, Fbm3(q / 420.0f, 3));                   // m/s, weather-scale patches
    float3 s = q / 40.0f;
    s += (float3(Noise3(s * 0.4f), Noise3(s * 0.4f + 4.1f), Noise3(s * 0.4f + 8.3f)) - 0.5f) * 2.0f;
    float slick = Fbm3(s, 4);
    float detail = 1.0f - smoothstep(6.0f, 20.0f, footprintKm);           // unresolved => average
    wind *= lerp(1.0f, lerp(0.35f, 1.25f, smoothstep(0.30f, 0.70f, slick)), detail);
    return 0.003f + 0.00512f * wind;
}

float PhaseHG(float mu, float g)
{
    return (1.0f - g * g) / (4.0f * PI * pow(abs(1.0f + g * g - 2.0f * g * mu), 1.5f));
}

// Night-side city lights from the Black Marble map (warm lights only).
float CityLights(float3 night)
{
    return saturate((night.r + night.g) * 0.5f - night.b * 0.75f) * 6.0f;
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

    // Direct sunlight, attenuated by the atmosphere above this point, plus blue skylight.
    float3 Tsun = SunTransmittance(P);
    float3 irradiance = E * Tsun * saturate(NdotL);
    // Twilight fades exponentially after sunset (it used to be a linear ramp that hit zero at
    // -8.6 deg, which read as a dark line on the night side): -2 deg ~ 1/3, -6 deg ~ 1/20,
    // -12 deg ~ 1/400 of the light at sunset. A faint floor (starlight, airglow) keeps the night
    // side from being pure black.
    float twilight = NdotL >= 0.0f ? NdotL + 0.15f : 0.15f * exp(NdotL / 0.035f);
    float3 skylight = E * (float3(0.03f, 0.05f, 0.09f) * twilight + float3(0.0005f, 0.0006f, 0.0009f));

    // Live clouds. cloud = opacity (hides the ground), cloudLight = light reflected by the
    // clouds (already weighted by their coverage), cloudShadow = shadow on the ground.
    float cloud = 0.0f, cloudShadow = 1.0f;
    float3 cloudLight = 0;
    if (g_cb.params.w > 0.5f)
    {
        float lodC = TextureLod(g_cb.textureInfo.z, N, V);
        if (g_cb.cloudInfo.x < 0.5f)
        {
            // Flat: one layer at CLOUD_HEIGHT. The live map is infrared-derived: cold ground and
            // thin cirrus read as partly cloudy, so dense clouds stay opaque and thin ones translucent.
            cloud = CloudOpacity(g_clouds.SampleLevel(g_linear, uv, lodC));
            if (NdotL > 0.0f)
            {
                float3 Le = EarthFixed(L);
                float3 tang = Le - ecef * dot(ecef, Le);
                float3 ns = normalize(ecef + tang * (CLOUD_HEIGHT / RE) / max(NdotL, 0.1f));
                cloudShadow = 1.0f - 0.65f * CloudOpacity(g_clouds.SampleLevel(g_linear, LatLonUV(ns), lodC));
            }
            cloudLight = (E * SunTransmittance(P + N * CLOUD_HEIGHT) * saturate(NdotL + 0.05f) + skylight * 2.0f) * 0.8f * cloud;
        }
        else
        {
            // Layered: find where the view ray meets the cloud tops (parallax, 2 iterations).
            float3 o = WorldRayOrigin();
            float h = CloudTopKm(uv, lodC);
            float3 Pc = RayAtHeight(o, D, h, P);
            float3 ecefC = EarthFixed(normalize(Pc));
            float2 uvC = LatLonUV(ecefC);
            h = CloudTopKm(uvC, lodC);
            Pc = RayAtHeight(o, D, h, P);
            float3 Nc0 = normalize(Pc);
            ecefC = EarthFixed(Nc0);
            uvC = LatLonUV(ecefC);
            h = CloudTopKm(uvC, lodC);

            cloud = CloudOpacity(g_clouds.SampleLevel(g_linear, uvC, lodC));
            float3 Le = EarthFixed(L);
            if (NdotL > -0.05f)
                cloudShadow = CloudShadowLayered(ecef, Le, 0.0f, lodC, 0.75f);

            // Cauliflower tops only on tall, dense, large cloud masses: high estimated top, opaque
            // here and over a wide area (8 mips coarser = the mass, not a lone dense pixel).
            float footprint = RayTCurrent() * 2.0f * g_cb.cameraPosition.w / float(DispatchRaysDimensions().y)
                            / max(dot(N, V), 0.2f);
            float mass = CloudOpacity(g_clouds.SampleLevel(g_linear, uvC, lodC + 3.0f));
            float towers = smoothstep(4.0f, 10.0f, h) * smoothstep(0.6f, 1.0f, mass) * smoothstep(0.5f, 0.95f, cloud);
            float3 tilt = 0;
            float crevice = 1.0f;
            if (towers > 0.0f)
            {
                float3 tiltEcef;
                crevice = CumulusTops(ecefC, footprint, towers, tiltEcef);
                tilt = WorldFromEarth(tiltEcef);
            }

            if (cloud > 0.002f)
            {
                // Two-stream reflectance of a cloud slab: optical depth from opacity, g = 0.85.
                float tau = -log(1.0f - 0.98f * cloud) * 8.0f;
                float R = 0.15f * tau / (1.0f + 0.15f * tau);

                // Sunlight on the tops: atmosphere above them, the Earth's limb (tops stay lit
                // after sunset), shadows from taller clouds, and the relief of the tops.
                float3 NcBase = CloudTopNormal(Nc0, ecefC, uvC, lodC);
                float3 Nc = normalize(NcBase + tilt);
                float sunVis = EarthSunVisibility(Nc0, L, h) * CloudShadowLayered(ecefC, Le, h, lodC, 0.45f);   // light leaks through clouds
                float wrap = saturate((dot(NcBase, L) + 0.25f) / 1.25f);
                float3 direct = E * SunTransmittance(Nc0 * (RE + h)) * sunVis * wrap;

                // Phase function: matters for thin clouds (silver lining towards the Sun).
                float mu = dot(L, D);
                float phase = 4.0f * PI * (0.7f * PhaseHG(mu, 0.8f) + 0.3f * PhaseHG(mu, -0.3f));
                direct *= lerp(1.0f, phase, exp(-tau * 0.25f));

                // Ambient: blue sky above, light bounced by the ground below.
                // Skylight on clouds, desaturated: shaded parts look grey, not blue.
                float3 sky2 = skylight * 2.0f;
                float3 ambient = lerp(dot(sky2, float3(0.2126f, 0.7152f, 0.0722f)), sky2, 0.4f) + albedo * irradiance * 0.3f;

                // City lights glowing through the clouds at night (blurred, warm).
                float3 glow = 0;
                if (g_cb.params.z > 0.5f)
                {
                    float3 nightBlur = g_night.SampleLevel(g_linear, uv, TextureLod(g_cb.textureInfo.y, N, V) + 3.0f).rgb;
                    float dark = 1.0f - smoothstep(-0.08f, 0.06f, NdotL);
                    glow = float3(1.0f, 0.70f, 0.38f) * CityLights(nightBlur) * dark * 0.25f;
                }
                // The lumps keep the colour of the cloud layer: they only scale its brightness
                // (lit side brighter, side away from the Sun and creases darker), mixed at ~55 %
                // over the smooth layer so they read as texture of the same cloud.
                const float LUMP_MIX = 0.55f;
                float wrapLump = saturate((dot(Nc, L) + 0.25f) / 1.25f);
                float lump = clamp((wrapLump + 0.2f) / (wrap + 0.2f), 0.65f, 1.3f) * crevice;
                cloudLight = R * ((direct + ambient) * lerp(1.0f, lump, LUMP_MIX) + glow);
            }
        }
    }

    float3 color = albedo * (irradiance * cloudShadow + skylight);

    // Ocean sun glitter (Cox & Munk): wind-dependent, broken up by wind patches, slicks and
    // swell, cut by the shadows of the clouds.
    if (ocean > 0.01f && NdotL > 0.0f)
    {
        float footprint = RayTCurrent() * 2.0f * g_cb.cameraPosition.w / float(DispatchRaysDimensions().y);
        float sigma2 = OceanRoughness(ecef, footprint);
        color += E * Tsun * SunGlitter(N, V, L, sigma2) * ocean * cloudShadow * (1.0f - cloud);
    }

    // Clouds over the ground.
    color = color * (1.0f - cloud) + cloudLight;

    // City lights (NASA Black Marble): keep the warm lights, drop the bluish moonlit terrain.
    if (g_cb.params.z > 0.5f)
    {
        float3 night = g_night.SampleLevel(g_linear, uv, TextureLod(g_cb.textureInfo.y, N, V)).rgb;
        float lights = CityLights(night);
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
