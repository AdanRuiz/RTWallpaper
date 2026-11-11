// DXR ray tracing shaders for the wallpaper scene:
//   - polished black marble floor (Fresnel reflection, procedural veins, shadows)
//   - 3 quartz spheres (exact spheres via intersection shader, Snell refraction,
//     Fresnel reflection, total internal reflection, Beer absorption)
//   - 2 animated neon point lights (cobalt blue + warm amber)
// Compiled with: dxc -T lib_6_3

#define MAX_DEPTH 5          // must match MAX_DEPTH in main.cpp (pipeline recursion = MAX_DEPTH + 1)
#define BRANCH_DEPTH 2       // glass spawns both reflection + refraction rays only up to this depth

struct SceneConstantBuffer
{
    float4 cameraPosition;   // xyz, w = tan(fovY / 2)
    float4 cameraForward;
    float4 cameraRight;
    float4 cameraUp;
    float4 spherePositions[3];  // xyz, w = radius
    float4 lightPositions[2];
    float4 lightColors[2];      // rgb, w = intensity
    float4 params;              // x = time
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

struct SphereAttributes
{
    float3 normal;
};

RaytracingAccelerationStructure     g_scene  : register(t0);
RWTexture2D<float4>                 g_output : register(u0);
ConstantBuffer<SceneConstantBuffer> g_cb     : register(b0);

// ---------------------------------------------------------------------------
// Helpers
// ---------------------------------------------------------------------------
float3 HitWorldPosition()
{
    return WorldRayOrigin() + RayTCurrent() * WorldRayDirection();
}

float Hash21(float2 p)
{
    p = frac(p * float2(123.34f, 456.21f));
    p += dot(p, p + 45.32f);
    return frac(p.x * p.y);
}

float ValueNoise(float2 p)
{
    float2 i = floor(p);
    float2 f = frac(p);
    float2 u = f * f * (3.0f - 2.0f * f);
    float a = Hash21(i);
    float b = Hash21(i + float2(1, 0));
    float c = Hash21(i + float2(0, 1));
    float d = Hash21(i + float2(1, 1));
    return lerp(lerp(a, b, u.x), lerp(c, d, u.x), u.y);
}

float Fbm(float2 p)
{
    float s = 0.0f, a = 0.5f;
    for (int i = 0; i < 5; i++)
    {
        s += a * ValueNoise(p);
        p = p * 2.03f + 17.1f;
        a *= 0.5f;
    }
    return s;
}

float3 MarbleAlbedo(float2 p)
{
    float n    = Fbm(p * 0.35f);
    float v    = sin(p.x * 0.9f + p.y * 0.45f + n * 7.0f);
    float vein = 1.0f - smoothstep(0.0f, 0.10f, abs(v));
    float fine = 1.0f - smoothstep(0.0f, 0.04f, abs(sin(p.x * 2.3f - p.y * 1.7f + Fbm(p * 0.9f + 3.7f) * 9.0f)));
    float3 base    = lerp(float3(0.006f, 0.006f, 0.008f), float3(0.022f, 0.021f, 0.027f), Fbm(p * 1.7f));
    float3 veinCol = float3(0.30f, 0.28f, 0.26f);
    return base + veinCol * (vein * 0.55f + fine * 0.22f);
}

float AngleDiff(float a, float b)
{
    float d = a - b;
    return abs(atan2(sin(d), cos(d)));
}

// Dark studio environment with a few soft neon panels so the glass has something to refract.
float3 EnvColor(float3 d)
{
    float el = d.y;
    float az = atan2(d.x, d.z);
    float3 col = lerp(float3(0.006f, 0.005f, 0.012f), float3(0.0015f, 0.0015f, 0.004f), saturate(el * 1.5f));
    col += float3(0.05f, 0.02f, 0.08f) * exp(-abs(el) * 30.0f);            // faint violet horizon line

    // Thin vertical neon tubes far away (soft halo + bright core).
    float band = smoothstep(-0.02f, 0.05f, el) * smoothstep(0.55f, 0.25f, el);
    float2 tubes[4] = { float2(-2.45f, 0), float2(-2.85f, 0), float2(2.45f, 1), float2(2.85f, 1) };
    [unroll]
    for (int k = 0; k < 4; k++)
    {
        float  a    = AngleDiff(az, tubes[k].x);
        float  tube = exp(-a * a * 20000.0f) * 2.5f + exp(-a * a * 600.0f) * 0.12f;
        float3 tint = tubes[k].y > 0.5f ? float3(1.0f, 0.45f, 0.05f) : float3(0.05f, 0.35f, 1.0f);
        col += tint * tube * band;
    }
    col += float3(0.50f, 0.08f, 0.45f) * band * exp(-AngleDiff(az, 0.0f) * 4.0f) * 0.15f; // magenta wash behind camera
    return col;
}

// Volumetric-looking glow of the neon point lights along a ray segment [0, tMax].
float3 LightGlow(float3 o, float3 d, float tMax)
{
    float3 g = 0;
    [unroll]
    for (uint i = 0; i < 2; i++)
    {
        float3 L  = g_cb.lightPositions[i].xyz;
        float  s  = clamp(dot(L - o, d), 0.0f, tMax);
        float3 q  = o + d * s - L;
        float  r2 = dot(q, q);
        float3 c  = g_cb.lightColors[i].rgb * g_cb.lightColors[i].w;
        g += c * (0.0015f / (r2 + 0.0008f) + 0.02f * exp(-r2 * 2.0f));
    }
    return g;
}

float3 TraceRadiance(float3 origin, float3 dir, uint depth)
{
    RayDesc ray;
    ray.Origin    = origin;
    ray.Direction = dir;
    ray.TMin      = 0.001f;
    ray.TMax      = 1000.0f;
    RayPayload p;
    p.color = 0;
    p.depth = depth;
    TraceRay(g_scene, RAY_FLAG_NONE, 0xFF, 0, 1, 0, ray, p);
    return p.color;
}

// Glass spheres only partially block light (cheap stand-in for transmitted light).
float TraceShadow(float3 origin, float3 dir, float maxT)
{
    RayDesc ray;
    ray.Origin    = origin;
    ray.Direction = dir;
    ray.TMin      = 0.001f;
    ray.TMax      = maxT;
    ShadowPayload p;
    p.visibility = 0.35f;
    TraceRay(g_scene,
             RAY_FLAG_ACCEPT_FIRST_HIT_AND_END_SEARCH | RAY_FLAG_SKIP_CLOSEST_HIT_SHADER,
             0xFF, 0, 1, 1, ray, p);
    return p.visibility;
}

float3 ACESFilm(float3 x)
{
    const float a = 2.51f, b = 0.03f, c = 2.43f, d = 0.59f, e = 0.14f;
    return saturate((x * (a * x + b)) / (x * (c * x + d) + e));
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
    float tanH   = g_cb.cameraPosition.w;

    float3 dir = normalize(g_cb.cameraForward.xyz
                         + ndc.x * aspect * tanH * g_cb.cameraRight.xyz
                         + ndc.y * tanH * g_cb.cameraUp.xyz);

    float3 col = TraceRadiance(g_cb.cameraPosition.xyz, dir, 0);

    col *= 1.0f - 0.22f * dot(ndc * 0.75f, ndc * 0.75f);   // vignette
    col  = ACESFilm(col * 1.1f);
    col  = pow(col, 1.0f / 2.2f);
    col += (Hash21(float2(idx)) - 0.5f) / 255.0f;            // dither against banding

    g_output[idx] = float4(col, 1.0f);
}

// ---------------------------------------------------------------------------
// Miss shaders
// ---------------------------------------------------------------------------
[shader("miss")]
void Miss(inout RayPayload payload)
{
    float3 d = WorldRayDirection();
    payload.color = EnvColor(d) + LightGlow(WorldRayOrigin(), d, 1000.0f);
}

[shader("miss")]
void ShadowMiss(inout ShadowPayload payload)
{
    payload.visibility = 1.0f;
}

// ---------------------------------------------------------------------------
// Closest hit: black marble floor (Fresnel reflection + direct neon lighting)
// ---------------------------------------------------------------------------
[shader("closesthit")]
void FloorClosestHit(inout RayPayload payload, in BuiltInTriangleIntersectionAttributes attribs)
{
    float3 P = HitWorldPosition();
    float3 D = WorldRayDirection();
    float  t = RayTCurrent();
    float3 N = float3(0, 1, 0);
    float3 V = -D;

    float3 albedo = MarbleAlbedo(P.xz);
    bool   canTrace = payload.depth < MAX_DEPTH;

    // Analytic ambient occlusion / contact shadow under each sphere.
    float ao = 1.0f;
    [unroll]
    for (uint s = 0; s < 3; s++)
    {
        float3 v  = g_cb.spherePositions[s].xyz - P;
        float  d2 = dot(v, v);
        float  r  = g_cb.spherePositions[s].w;
        ao *= 1.0f - saturate(dot(N, v) * rsqrt(d2)) * saturate(r * r / d2);
    }

    float3 col = albedo * 0.25f * ao;   // faint ambient
    [unroll]
    for (uint i = 0; i < 2; i++)
    {
        float3 toL   = g_cb.lightPositions[i].xyz - P;
        float  dist  = length(toL);
        float3 L     = toL / dist;
        float  atten = 1.0f / (1.0f + 0.1f * dist + 0.05f * dist * dist);
        float  NdotL = saturate(dot(N, L));
        float  vis   = canTrace ? TraceShadow(P + N * 0.001f, L, dist) : 1.0f;
        float3 H     = normalize(L + V);
        float  spec  = pow(saturate(dot(N, H)), 60.0f) * 0.5f;
        float3 lc    = g_cb.lightColors[i].rgb * g_cb.lightColors[i].w;
        col += lc * atten * vis * NdotL * (albedo * ao + spec);
    }

    // Fresnel (Schlick) mirror reflection, slightly weaker on the rougher veins.
    float  R0      = 0.10f;
    float  fresnel = R0 + (1.0f - R0) * pow(1.0f - saturate(dot(N, V)), 5.0f);
    float3 R       = reflect(D, N);
    float3 refl    = canTrace ? TraceRadiance(P + N * 0.001f, R, payload.depth + 1) : EnvColor(R);
    float  gloss   = 1.0f - saturate(dot(albedo, 1.0f) * 1.2f);
    col += refl * fresnel * gloss;

    // Distance fog hides the floor edge.
    float fog = exp(-t * 0.035f);
    col = lerp(EnvColor(D), col, fog);
    col += LightGlow(WorldRayOrigin(), D, t);

    payload.color = col;
}

// ---------------------------------------------------------------------------
// Intersection: exact unit sphere in object space (instance transform = translation)
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

    SphereAttributes attr;
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

// ---------------------------------------------------------------------------
// Closest hit: quartz / glass spheres (Snell refraction + Fresnel + TIR + absorption)
// ---------------------------------------------------------------------------
[shader("closesthit")]
void QuartzClosestHit(inout RayPayload payload, in SphereAttributes attr)
{
    float3 P = HitWorldPosition();
    float3 D = WorldRayDirection();
    float3 N = normalize(attr.normal);

    bool   entering = dot(D, N) < 0.0f;
    float3 n        = entering ? N : -N;
    const float ior = 1.54f;           // quartz
    float  eta      = entering ? (1.0f / ior) : ior;

    float3 glow = LightGlow(WorldRayOrigin(), D, RayTCurrent());

    if (payload.depth >= MAX_DEPTH)
    {
        payload.color = EnvColor(D) + glow;
        return;
    }

    float  cosi    = saturate(-dot(D, n));
    float  R0      = 0.045f;
    float  fresnel = R0 + (1.0f - R0) * pow(1.0f - cosi, 5.0f);
    float3 refrDir = refract(D, n, eta);
    bool   tir     = dot(refrDir, refrDir) < 1e-6f;
    if (tir) fresnel = 1.0f;

    uint   nextDepth = payload.depth + 1;
    float3 col = 0;
    if (tir || payload.depth < BRANCH_DEPTH)
        col += fresnel * TraceRadiance(P + n * 0.001f, reflect(D, n), nextDepth);
    if (!tir)
        col += (1.0f - fresnel) * TraceRadiance(P - n * 0.001f, refrDir, nextDepth);

    // Ray hit the sphere from inside: the segment it just travelled was inside the quartz.
    if (!entering)
    {
        static const float3 tints[3] = {
            float3(0.05f, 0.05f, 0.04f),   // clear quartz
            float3(0.10f, 0.35f, 0.04f),   // amethyst (absorbs green)
            float3(0.30f, 0.06f, 0.02f),   // aqua
        };
        col *= exp(-tints[InstanceID() % 3] * RayTCurrent());
    }

    payload.color = col + glow;
}
