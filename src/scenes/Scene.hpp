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
    // Mouse input. Only sent in window mode (never to the wallpaper); SetInteractive(true) is
    // called right after the scene is created in window mode.
    virtual void SetInteractive(bool interactive) { (void)interactive; }
    virtual void OnOrbit(float dxPixels, float dyPixels) { (void)dxPixels; (void)dyPixels; }   // right-button drag
    virtual void OnZoom(float steps) { (void)steps; }   // wheel / touchpad pinch; > 0 = closer
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
