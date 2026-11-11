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
// Chapman function approximation (C. Schüler): relative air mass along a ray towards zenith
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
float3 Stars(float3 d)
{
    float3 col = 0;
    const float scales[2] = { 220.0f, 520.0f };
    [unroll]
    for (int l = 0; l < 2; l++)
    {
        float3 p = d * scales[l];
        float3 cell = floor(p);
        float3 f = frac(p) - 0.5f;
        float h = Hash31(cell);
        if (h > 0.975f)
        {
            float3 off = (float3(Hash31(cell + 1.3f), Hash31(cell + 2.7f), Hash31(cell + 4.1f)) - 0.5f) * 0.6f;
            float b = smoothstep(0.16f, 0.0f, length(f - off)) * (h - 0.975f) / 0.025f;
            float3 tint = lerp(float3(0.65f, 0.75f, 1.0f), float3(1.0f, 0.85f, 0.65f), Hash31(cell + 9.0f));
            col += tint * b * b * (l == 0 ? 2.5f : 1.0f);
        }
    }
    float band = exp(-pow(dot(d, normalize(float3(0.35f, 1.0f, 0.25f))), 2.0f) * 45.0f);
    col += float3(0.05f, 0.045f, 0.07f) * band * smoothstep(0.55f, 0.85f, Fbm3(d * 14.0f, 4)) * 0.12f;
    return col;
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

float3 Background(float3 d)
{
    return Stars(d) + Sun(d);
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
