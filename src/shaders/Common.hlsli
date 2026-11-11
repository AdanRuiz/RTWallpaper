// Helpers shared by every scene shader. Include it after the scene declares:
//   g_cb     (with cameraPosition.xyz + tan(fov/2) in .w, cameraForward, cameraRight, cameraUp)
//   g_scene  (the TLAS) and struct ShadowPayload { float visibility; }
// Shadow rays use hit group 0 with stride 1 and miss shader 1 (ShadowMiss sets visibility = 1).

// Primary ray direction through the centre of pixel idx; ndc is in [-1, 1] with +y up.
float3 CameraRayDirection(uint2 idx, uint2 dim, out float2 ndc)
{
    ndc = ((float2(idx) + 0.5f) / float2(dim)) * 2.0f - 1.0f;
    ndc.y = -ndc.y;
    float aspect = float(dim.x) / float(dim.y);
    float tanH = g_cb.cameraPosition.w;
    return normalize(g_cb.cameraForward.xyz
                   + ndc.x * aspect * tanH * g_cb.cameraRight.xyz
                   + ndc.y * tanH * g_cb.cameraUp.xyz);
}

// Any-hit visibility test: returns 1 if nothing is hit before maxT, otherwise `occluded`.
float TraceVisibility(float3 origin, float3 dir, float maxT, float occluded)
{
    RayDesc ray;
    ray.Origin    = origin;
    ray.Direction = dir;
    ray.TMin      = 0.001f;
    ray.TMax      = maxT;
    ShadowPayload p;
    p.visibility = occluded;
    TraceRay(g_scene,
             RAY_FLAG_ACCEPT_FIRST_HIT_AND_END_SEARCH | RAY_FLAG_SKIP_CLOSEST_HIT_SHADER,
             0xFF, 0, 1, 1, ray, p);
    return p.visibility;
}

// Exact intersection with the unit sphere in object space (for procedural AABB geometry).
// Returns the nearest t inside [RayTMin, RayTCurrent] and the object-space normal there.
bool UnitSphereHit(out float t, out float3 normal)
{
    t = 0.0f;
    normal = float3(0.0f, 1.0f, 0.0f);
    float3 o = ObjectRayOrigin();
    float3 d = ObjectRayDirection();
    float a = dot(d, d);
    float b = dot(o, d);
    float c = dot(o, o) - 1.0f;
    float disc = b * b - a * c;
    if (disc < 0.0f) return false;

    float sq = sqrt(disc);
    float t0 = (-b - sq) / a;
    float t1 = (-b + sq) / a;
    if (t0 >= RayTMin() && t0 <= RayTCurrent())      t = t0;
    else if (t1 >= RayTMin() && t1 <= RayTCurrent()) t = t1;
    else return false;
    normal = normalize(o + t * d);
    return true;
}
