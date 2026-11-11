#pragma once
// Interface every wallpaper scene implements. The renderer is generic: a scene provides
// its DXIL library, hit groups, bottom-level geometry, and per-frame constants + instances.
//
// Shader conventions (every scene's HLSL must export these):
//   RayGen, Miss (radiance, miss index 0), ShadowMiss (miss index 1)
//   Global root signature: u0 output texture, t0 TLAS, b0 constants.
#include <d3d12.h>
#include <DirectXMath.h>
#include <cmath>
#include <cstring>
#include <vector>

static constexpr UINT kMaxSceneConstants = 1024;   // bytes

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
    // Advance the animation by dt seconds. Writes shader constants (returns their size,
    // at most kMaxSceneConstants) and InstanceCount() instances.
    virtual UINT Update(float dt, void* constants, InstanceDef* instances) = 0;
};

// Camera basis as consumed by the shaders: position.w = tan(fovY / 2).
struct CameraConstants
{
    DirectX::XMFLOAT4 position, forward, right, up;
};

inline CameraConstants MakeCamera(DirectX::FXMVECTOR eye, DirectX::FXMVECTOR target, float fovYDegrees)
{
    using namespace DirectX;
    XMVECTOR fwd = XMVector3Normalize(XMVectorSubtract(target, eye));
    XMVECTOR right = XMVector3Normalize(XMVector3Cross(fwd, XMVectorSet(0, 1, 0, 0)));
    XMVECTOR up = XMVector3Cross(right, fwd);
    CameraConstants c;
    XMStoreFloat4(&c.position, eye);
    c.position.w = tanf(XMConvertToRadians(fovYDegrees) * 0.5f);
    XMStoreFloat4(&c.forward, fwd);
    XMStoreFloat4(&c.right, right);
    XMStoreFloat4(&c.up, up);
    return c;
}
