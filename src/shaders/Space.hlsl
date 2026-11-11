// DXR shaders for scene "space" (space_rtx_wallpaper.md):
//   - Earth: exact sphere, procedural continents/oceans/ice/clouds, day/night terminator,
//     city lights, ocean sun glint, Fresnel atmosphere rim + limb halo
//   - 2 satellites: gold MLI foil body, solar panels, antenna (boxes via intersection shader),
//     metallic Fresnel reflections (they reflect the Earth and the Sun), Earth-eclipse shadows
//   - starfield, Milky Way band and the Sun disk in the miss shader
// Compiled with: dxc -T lib_6_3

#define MAX_DEPTH 3          // SpaceScene::MaxRecursion() = MAX_DEPTH + 1
#define PI 3.14159265f
#define EARTH_RADIUS 10.0f

struct SceneConstantBuffer
{
    float4 cameraPosition;   // xyz, w = tan(fovY / 2)
    float4 cameraForward;
    float4 cameraRight;
    float4 cameraUp;
    float4 sunDirection;     // xyz towards the sun, w = intensity
    float4 earthTransform;   // w = rotation (radians)
    float4 satellitePos[2];
    float4 params;           // x = time
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
    uint   material;   // 0 gold foil, 1 solar panel, 2 metal
};

RaytracingAccelerationStructure     g_scene  : register(t0);
RWTexture2D<float4>                 g_output : register(u0);
ConstantBuffer<SceneConstantBuffer> g_cb     : register(b0);

// ---------------------------------------------------------------------------
// Noise
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

float3 RotY(float3 v, float a)
{
    float c = cos(a), s = sin(a);
    return float3(c * v.x + s * v.z, v.y, -s * v.x + c * v.z);
}

float3 ACESFilm(float3 x)
{
    const float a = 2.51f, b = 0.03f, c = 2.43f, d = 0.59f, e = 0.14f;
    return saturate((x * (a * x + b)) / (x * (c * x + d) + e));
}

float3 HitWorldPosition()
{
    return WorldRayOrigin() + RayTCurrent() * WorldRayDirection();
}

// ---------------------------------------------------------------------------
// Background: stars, Milky Way, Sun, atmosphere halo
// ---------------------------------------------------------------------------
float3 Stars(float3 d)
{
    float3 col = 0;
    const float scales[2] = { 180.0f, 420.0f };
    [unroll]
    for (int l = 0; l < 2; l++)
    {
        float3 p = d * scales[l];
        float3 cell = floor(p);
        float3 f = frac(p) - 0.5f;
        float h = Hash31(cell);
        if (h > 0.97f)
        {
            float3 off = (float3(Hash31(cell + 1.3f), Hash31(cell + 2.7f), Hash31(cell + 4.1f)) - 0.5f) * 0.6f;
            float dist = length(f - off);
            float b = smoothstep(0.16f, 0.0f, dist) * (h - 0.97f) / 0.03f;
            float3 tint = lerp(float3(0.65f, 0.75f, 1.0f), float3(1.0f, 0.85f, 0.65f), Hash31(cell + 9.0f));
            col += tint * b * b * (l == 0 ? 4.0f : 1.5f);
        }
    }
    // Milky Way: noisy band around a tilted great circle.
    float band = exp(-pow(dot(d, normalize(float3(0.35f, 1.0f, 0.25f))), 2.0f) * 45.0f);
    float dust = Fbm3(d * 9.0f, 5);
    col += float3(0.09f, 0.08f, 0.12f) * band * smoothstep(0.45f, 0.8f, dust) * 0.45f;
    col += float3(0.012f, 0.012f, 0.02f) * band;
    return col;
}

float3 Sun(float3 d)
{
    float s = saturate(dot(d, g_cb.sunDirection.xyz));
    float disk = smoothstep(0.99985f, 0.99993f, s) * 60.0f;
    float glare = pow(s, 900.0f) * 6.0f + pow(s, 40.0f) * 0.06f;
    return float3(1.0f, 0.95f, 0.85f) * (disk + glare);
}

float3 Background(float3 d)
{
    return Stars(d) + Sun(d);
}

// Thin glowing shell above the limb for rays that pass close to the Earth.
float3 AtmosphereHalo(float3 o, float3 d, float tMax)
{
    float tc = clamp(-dot(o, d), 0.0f, tMax);
    float3 q = o + d * tc;
    float h = max(length(q) - EARTH_RADIUS, 0.0f);
    float3 up = normalize(q);
    float lit = saturate(dot(up, g_cb.sunDirection.xyz) + 0.25f);
    float sunset = exp(-abs(dot(up, g_cb.sunDirection.xyz)) * 6.0f);
    float3 col = lerp(float3(0.25f, 0.55f, 1.0f), float3(1.0f, 0.45f, 0.15f), sunset * 0.6f);
    return col * exp(-h / 0.22f) * lit * 1.6f + col * exp(-h / 1.2f) * lit * 0.12f;
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
    ray.TMax      = 10000.0f;
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
    ray.TMax      = 10000.0f;
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

    col *= 1.0f - 0.15f * dot(ndc * 0.7f, ndc * 0.7f);
    col = ACESFilm(col);
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
    payload.color = Background(d) + AtmosphereHalo(WorldRayOrigin(), d, 10000.0f);
}

[shader("miss")]
void ShadowMiss(inout ShadowPayload payload)
{
    payload.visibility = 1.0f;
}

// ---------------------------------------------------------------------------
// Earth: exact sphere (unit sphere in object space, instance scale = EARTH_RADIUS)
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

[shader("closesthit")]
void EarthClosestHit(inout RayPayload payload, in EarthAttributes attr)
{
    float3 N = normalize(attr.normal);
    float3 V = -WorldRayDirection();
    float3 L = g_cb.sunDirection.xyz;
    float sunI = g_cb.sunDirection.w;
    float time = g_cb.params.x;

    // Planet-fixed coordinates (Earth spins around Y).
    float3 p = RotY(N, -g_cb.earthTransform.w);

    // Continents, oceans, ice caps.
    float h = Fbm3(p * 2.1f, 7);
    float land = smoothstep(0.515f, 0.53f, h);
    float lat = abs(p.y);
    float ice = smoothstep(0.80f, 0.86f, lat + (h - 0.5f) * 0.25f);
    float arid = smoothstep(0.45f, 0.65f, Fbm3(p * 3.3f + 11.0f, 4)) * (1.0f - smoothstep(0.2f, 0.6f, lat));
    float3 landCol = lerp(float3(0.04f, 0.10f, 0.03f), float3(0.32f, 0.25f, 0.13f), arid);
    landCol = lerp(landCol, float3(0.20f, 0.18f, 0.16f), smoothstep(0.62f, 0.72f, h));      // mountains
    float3 oceanCol = lerp(float3(0.004f, 0.016f, 0.05f), float3(0.02f, 0.09f, 0.13f), smoothstep(0.44f, 0.515f, h));
    float3 albedo = lerp(oceanCol, landCol, land);
    albedo = lerp(albedo, float3(0.75f, 0.78f, 0.82f), ice);

    // Clouds drift a little faster than the ground.
    float3 pc = RotY(N, -g_cb.earthTransform.w * 1.15f - time * 0.004f);
    float cl = Fbm3(pc * 3.2f + float3(0, time * 0.01f, 0), 6);
    float cloud = smoothstep(0.50f, 0.72f, cl);

    float NdotL = dot(N, L);
    float diffuse = saturate(NdotL);
    float day = smoothstep(-0.12f, 0.22f, NdotL);

    float3 color = albedo * sunI * diffuse;

    // Ocean sun glint.
    float3 H = normalize(L + V);
    float glint = pow(saturate(dot(N, H)), 140.0f) * 1.4f + pow(saturate(dot(N, H)), 20.0f) * 0.05f;
    color += float3(1.0f, 0.9f, 0.75f) * glint * (1.0f - land) * (1.0f - ice) * (1.0f - cloud) * sunI * saturate(NdotL * 4.0f);

    // Clouds (lit white, warm near the terminator).
    float3 cloudLit = lerp(float3(1.0f, 0.55f, 0.3f), float3(0.95f, 0.96f, 1.0f), smoothstep(0.0f, 0.3f, NdotL));
    color = lerp(color, cloudLit * sunI * diffuse * 0.85f, cloud);

    // City lights on the night side.
    float coast = 1.0f - smoothstep(0.53f, 0.60f, h);   // cities cluster near coasts
    float urban = smoothstep(0.52f, 0.66f, Fbm3(p * 9.0f + 5.0f, 4)) * land * (1.0f - ice) * (1.0f - arid * 0.8f) * (0.4f + coast);
    float sparks = smoothstep(0.55f, 0.95f, Noise3(p * 260.0f)) * 1.6f + smoothstep(0.5f, 1.0f, Noise3(p * 90.0f)) * 0.35f;
    float3 night = float3(1.0f, 0.62f, 0.28f) * urban * sparks * (1.0f - day) * (1.0f - cloud * 0.85f) * 0.45f;
    color += night;

    // Atmosphere (simplified Rayleigh via Fresnel, as in the design doc) + sunset band.
    float fresnel = pow(1.0f - saturate(dot(N, V)), 4.0f);
    float3 atmosphere = float3(0.3f, 0.6f, 1.0f) * fresnel * saturate(NdotL + 0.2f) * 1.5f;
    atmosphere += float3(1.0f, 0.4f, 0.1f) * fresnel * exp(-abs(NdotL) * 8.0f) * 0.5f;
    color += atmosphere + float3(0.02f, 0.05f, 0.11f) * day * 0.6f;    // daytime blue haze

    payload.color = color;
}

// ---------------------------------------------------------------------------
// Satellites: union of boxes in object space (+Y away from Earth, +Z along velocity)
// ---------------------------------------------------------------------------
struct Box
{
    float3 c;
    float3 h;
    uint   m;
};

static const Box kBoxes[6] = {
    { float3(0.00f,  0.00f, 0.0f), float3(0.30f, 0.35f, 0.42f), 0 },  // body (gold foil)
    { float3(1.45f,  0.00f, 0.0f), float3(1.05f, 0.015f, 0.38f), 1 }, // solar panel +X
    { float3(-1.45f, 0.00f, 0.0f), float3(1.05f, 0.015f, 0.38f), 1 }, // solar panel -X
    { float3(0.00f,  0.00f, 0.0f), float3(0.42f, 0.03f, 0.03f), 2 },  // panel boom
    { float3(0.00f, -0.50f, 0.0f), float3(0.04f, 0.16f, 0.04f), 2 },  // antenna mast (towards Earth)
    { float3(0.00f, -0.68f, 0.0f), float3(0.24f, 0.025f, 0.24f), 2 }, // antenna dish
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
    [unroll]
    for (int i = 0; i < 6; i++)
    {
        float tn;
        float3 n;
        if (RayBox(o, inv, kBoxes[i], tn, n) && tn >= RayTMin() && tn < best)
        {
            best = tn;
            attr.normal = n;
            attr.material = kBoxes[i].m;
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
    if (attr.material == 0)
    {
        // Crinkled gold MLI foil.
        float3 pert = float3(Noise3(objP * 34.0f), Noise3(objP * 34.0f + 7.1f), Noise3(objP * 34.0f + 3.3f)) - 0.5f;
        nObj = normalize(nObj + pert * 0.28f);
        albedo = float3(0.20f, 0.14f, 0.04f);
        F0 = float3(1.0f, 0.74f, 0.30f);
    }
    else if (attr.material == 1)
    {
        // Solar cells with a silver grid.
        float2 g = frac(objP.xz * float2(3.6f, 3.0f));
        float grid = (g.x < 0.05f || g.y < 0.06f) ? 1.0f : 0.0f;
        albedo = lerp(float3(0.01f, 0.018f, 0.06f), float3(0.35f, 0.35f, 0.38f), grid);
        F0 = lerp(float3(0.05f, 0.06f, 0.09f), float3(0.75f, 0.75f, 0.78f), grid);
    }
    else
    {
        albedo = float3(0.30f, 0.30f, 0.32f);
        F0 = float3(0.80f, 0.80f, 0.82f);
    }

    float3 N = normalize(mul((float3x3)ObjectToWorld3x4(), nObj));
    if (dot(N, D) > 0.0f) N = -N;

    float3 L = g_cb.sunDirection.xyz;
    float sunI = g_cb.sunDirection.w;
    float NdotL = saturate(dot(N, L));
    bool canTrace = payload.depth < MAX_DEPTH;
    float vis = (NdotL > 0.0f && canTrace) ? TraceShadow(P + N * 0.002f, L) : (NdotL > 0.0f ? 1.0f : 0.0f);

    // Metallic Fresnel reflection (traced: reflects the Earth, the other satellite, stars and Sun).
    float3 F = F0 + (1.0f - F0) * pow(1.0f - saturate(dot(N, V)), 5.0f);
    float3 R = reflect(D, N);
    float3 refl = canTrace ? TraceRadiance(P + N * 0.002f, R, payload.depth + 1) : Background(R);

    // Earthshine: light bounced off the lit side of the Earth.
    float3 toEarth = -normalize(P);
    float earthLit = saturate(dot(-toEarth, L) * 0.5f + 0.5f);
    float3 earthshine = float3(0.10f, 0.16f, 0.28f) * earthLit * saturate(dot(N, toEarth) * 0.5f + 0.5f);

    float3 H = normalize(L + V);
    float spec = pow(saturate(dot(N, H)), 250.0f) * 6.0f;

    float3 color = albedo * (sunI * NdotL * vis + earthshine)
                 + refl * F
                 + F * spec * sunI * vis
                 + float3(0.05f, 0.05f, 0.05f) * albedo;
    payload.color = color;
}
