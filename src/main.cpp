// RTWallpaper: real-time DirectX Raytracing (DXR 1.0) desktop wallpaper with switchable scenes.
//
// Usage:
//   RTWallpaper.exe                 windowed (also what Lively Wallpaper uses). Tab = next scene
//   RTWallpaper.exe --wallpaper     draw behind the desktop icons (tray icon: scenes, pause, exit)
//   RTWallpaper.exe --stop          stop a running --wallpaper instance
//   Options: --scene NAME, --fps N, --debug (D3D12 debug layer)
// Settings live in RTWallpaper.ini next to the exe and are reloaded when the file is saved.
#define WIN32_LEAN_AND_MEAN
#define NOMINMAX
#include <windows.h>
#include <shellapi.h>
#include <d3d12.h>
#include <dxgi1_6.h>
#include <wrl/client.h>
#include <algorithm>
#include <cstdio>
#include <cstdlib>
#include <cstring>
#include <cwchar>
#include <memory>
#include <string>
#include <vector>

#include "scenes/MarbleScene.h"
#include "scenes/SpaceScene.h"

using Microsoft::WRL::ComPtr;

static constexpr UINT  kFrameCount = 2;
static constexpr DXGI_FORMAT kFormat = DXGI_FORMAT_R8G8B8A8_UNORM;
static constexpr UINT  WM_TRAY = WM_APP + 1;
static constexpr UINT  kCmdPause = 1, kCmdExit = 2, kCmdEditConfig = 3, kCmdSceneBase = 100;
static const wchar_t*  kWindowClass = L"RTWallpaperWindow";
static const wchar_t*  kStopEvent   = L"Local\\RTWallpaper.Stop";

// ---------------------------------------------------------------------------
// Scene registry: add new scenes here.
// ---------------------------------------------------------------------------
static const wchar_t* kSceneNames[] = { L"marble", L"space" };

static std::unique_ptr<Scene> CreateScene(const std::wstring& name, const std::wstring& iniPath)
{
    if (!_wcsicmp(name.c_str(), L"space")) return std::make_unique<SpaceScene>(iniPath);
    return std::make_unique<MarbleScene>();   // default / unknown names
}

// ---------------------------------------------------------------------------
// Helpers
// ---------------------------------------------------------------------------
static void Fail(const char* what, HRESULT hr)
{
    char buf[512];
    snprintf(buf, sizeof(buf), "%s\n\nHRESULT = 0x%08X", what, (unsigned)hr);
    MessageBoxA(nullptr, buf, "RTWallpaper", MB_ICONERROR | MB_OK);
    ExitProcess(1);
}
#define CHECK(x) do { HRESULT hr_ = (x); if (FAILED(hr_)) Fail(#x, hr_); } while (0)

static UINT64 AlignUp(UINT64 v, UINT64 a) { return (v + a - 1) & ~(a - 1); }

static D3D12_RESOURCE_BARRIER Transition(ID3D12Resource* r, D3D12_RESOURCE_STATES before, D3D12_RESOURCE_STATES after)
{
    D3D12_RESOURCE_BARRIER b = {};
    b.Type = D3D12_RESOURCE_BARRIER_TYPE_TRANSITION;
    b.Transition.pResource = r;
    b.Transition.Subresource = D3D12_RESOURCE_BARRIER_ALL_SUBRESOURCES;
    b.Transition.StateBefore = before;
    b.Transition.StateAfter = after;
    return b;
}

static D3D12_RESOURCE_BARRIER UavBarrier(ID3D12Resource* r)
{
    D3D12_RESOURCE_BARRIER b = {};
    b.Type = D3D12_RESOURCE_BARRIER_TYPE_UAV;
    b.UAV.pResource = r;
    return b;
}

// ---------------------------------------------------------------------------
// Configuration (RTWallpaper.ini next to the exe)
// ---------------------------------------------------------------------------
struct Config
{
    std::wstring scene = L"marble";
    int fps = 60;
    float speed = 1.0f;
};

static const char kDefaultIni[] =
    "; RTWallpaper configuration. Changes are applied as soon as the file is saved.\r\n"
    "[General]\r\n"
    "; Scene to render: marble | space\r\n"
    "Scene=marble\r\n"
    "; Frame rate cap (lower = less GPU usage)\r\n"
    "FPS=30\r\n"
    "; Animation speed multiplier (1.0 = as designed / real time, 0.5 = half speed)\r\n"
    "Speed=1.0\r\n"
    "\r\n"
    "[Space]\r\n"
    "; Earth day/night map width in pixels (height = width/2). 8192 = 8K\r\n"
    "TextureSize=8192\r\n"
    "; Live cloud map width: 1024 | 2048 | 4096 | 8192\r\n"
    "CloudSize=8192\r\n"
    "; Minutes between cloud map checks (only re-downloaded if it changed)\r\n"
    "CloudUpdateMinutes=60\r\n"
    "; Visual size multiplier for the satellites (1 = real size, sub-pixel)\r\n"
    "SatelliteScale=1000\r\n"
    "; Fraction of the screen covered by the Earth (the camera varies between both)\r\n"
    "CoverageMin=0.40\r\n"
    "CoverageMax=0.60\r\n"
    "; 1 = never download (use the cache or the procedural Earth)\r\n"
    "Offline=0\r\n"
    "; Show the Earth at another time, in hours from now (0 = live)\r\n"
    "TimeOffsetHours=0\r\n"
    "; Initial point of interest (default Mexico) and minutes over it before following the ISS (-1 = always)\r\n"
    "FocusLat=23.6\r\n"
    "FocusLon=-102.5\r\n"
    "FocusMinutes=20\r\n"
    "; Milky Way orientation: scenic (always in view) | real (astronomical)\r\n"
    "Galaxy=scenic\r\n";

static std::wstring ConfigPath()
{
    wchar_t path[MAX_PATH];
    GetModuleFileNameW(nullptr, path, MAX_PATH);
    if (wchar_t* slash = wcsrchr(path, L'\\')) slash[1] = 0;
    return std::wstring(path) + L"RTWallpaper.ini";
}

static FILETIME ConfigWriteTime(const std::wstring& path)
{
    WIN32_FILE_ATTRIBUTE_DATA data = {};
    GetFileAttributesExW(path.c_str(), GetFileExInfoStandard, &data);
    return data.ftLastWriteTime;
}

static Config LoadConfig(const std::wstring& path)
{
    if (GetFileAttributesW(path.c_str()) == INVALID_FILE_ATTRIBUTES)
    {
        HANDLE f = CreateFileW(path.c_str(), GENERIC_WRITE, 0, nullptr, CREATE_NEW, FILE_ATTRIBUTE_NORMAL, nullptr);
        if (f != INVALID_HANDLE_VALUE)
        {
            DWORD written;
            WriteFile(f, kDefaultIni, sizeof(kDefaultIni) - 1, &written, nullptr);
            CloseHandle(f);
        }
    }
    Config c;
    wchar_t buf[64];
    GetPrivateProfileStringW(L"General", L"Scene", L"marble", buf, 64, path.c_str());
    c.scene = buf;
    c.fps = std::clamp((int)GetPrivateProfileIntW(L"General", L"FPS", 60, path.c_str()), 1, 1000);
    GetPrivateProfileStringW(L"General", L"Speed", L"1.0", buf, 64, path.c_str());
    c.speed = std::clamp((float)_wtof(buf), 0.0f, 100.0f);
    return c;
}

// ---------------------------------------------------------------------------
// Renderer (scene-agnostic DXR)
// ---------------------------------------------------------------------------
class Renderer
{
public:
    void Init(HWND hwnd, bool debug);
    void LoadScene(const Scene& scene);
    void Resize(UINT w, UINT h);
    void Render(const void* constants, UINT constantsSize, const InstanceDef* instances, UINT count);
    void UploadTexture(const TextureUpload& t);
    void WaitGpu();
    float Aspect() const { return (float)m_width / (float)std::max(1u, m_height); }
    const wchar_t* AdapterName() const { return m_adapterName; }

private:
    ComPtr<ID3D12Resource> MakeBuffer(UINT64 size, D3D12_HEAP_TYPE heap, D3D12_RESOURCE_STATES state,
                                      D3D12_RESOURCE_FLAGS flags = D3D12_RESOURCE_FLAG_NONE);
    ComPtr<ID3D12Resource> MakeUpload(const void* data, UINT64 size);
    void CreateOutput();
    void CreateRootSignature();
    void CreatePipeline(const Scene& scene);
    void BuildGeometry(const Scene& scene);
    void ClearTextures();
    D3D12_CPU_DESCRIPTOR_HANDLE CpuDescriptor(UINT i) const
    {
        D3D12_CPU_DESCRIPTOR_HANDLE h = m_heap->GetCPUDescriptorHandleForHeapStart();
        h.ptr += (SIZE_T)i * m_descriptorSize;
        return h;
    }

    HWND m_hwnd = nullptr;
    UINT m_width = 0, m_height = 0;
    wchar_t m_adapterName[128] = {};

    ComPtr<IDXGIFactory6> m_factory;
    ComPtr<ID3D12Device5> m_device;
    ComPtr<ID3D12CommandQueue> m_queue;
    ComPtr<IDXGISwapChain3> m_swapChain;
    ComPtr<ID3D12Resource> m_backBuffers[kFrameCount];
    ComPtr<ID3D12CommandAllocator> m_alloc;
    ComPtr<ID3D12GraphicsCommandList4> m_list;
    ComPtr<ID3D12Fence> m_fence;
    UINT64 m_fenceValue = 0;
    HANDLE m_fenceEvent = nullptr;

    ComPtr<ID3D12DescriptorHeap> m_heap;     // [0] output UAV, [1..4] scene textures t1..t4
    UINT m_descriptorSize = 0;
    ComPtr<ID3D12Resource> m_output;
    ComPtr<ID3D12Resource> m_textures[kMaxSceneTextures];
    ComPtr<ID3D12RootSignature> m_rootSig;
    ComPtr<ID3D12Resource> m_constantBuffer;
    uint8_t* m_cbData = nullptr;

    // Per-scene resources.
    ComPtr<ID3D12StateObject> m_pso;
    ComPtr<ID3D12Resource> m_shaderTable;
    UINT m_hitGroupCount = 0;
    std::vector<ComPtr<ID3D12Resource>> m_geometryBuffers, m_blas;
    ComPtr<ID3D12Resource> m_tlas, m_tlasScratch, m_instanceBuffer;
    D3D12_RAYTRACING_INSTANCE_DESC* m_instances = nullptr;
    UINT m_instanceCount = 0;
    D3D12_BUILD_RAYTRACING_ACCELERATION_STRUCTURE_INPUTS m_tlasInputs = {};
};

ComPtr<ID3D12Resource> Renderer::MakeBuffer(UINT64 size, D3D12_HEAP_TYPE heap, D3D12_RESOURCE_STATES state,
                                            D3D12_RESOURCE_FLAGS flags)
{
    D3D12_HEAP_PROPERTIES hp = {};
    hp.Type = heap;
    D3D12_RESOURCE_DESC d = {};
    d.Dimension = D3D12_RESOURCE_DIMENSION_BUFFER;
    d.Width = std::max<UINT64>(size, 1);
    d.Height = 1;
    d.DepthOrArraySize = 1;
    d.MipLevels = 1;
    d.SampleDesc.Count = 1;
    d.Layout = D3D12_TEXTURE_LAYOUT_ROW_MAJOR;
    d.Flags = flags;
    ComPtr<ID3D12Resource> r;
    CHECK(m_device->CreateCommittedResource(&hp, D3D12_HEAP_FLAG_NONE, &d, state, nullptr, IID_PPV_ARGS(&r)));
    return r;
}

ComPtr<ID3D12Resource> Renderer::MakeUpload(const void* data, UINT64 size)
{
    ComPtr<ID3D12Resource> r = MakeBuffer(size, D3D12_HEAP_TYPE_UPLOAD, D3D12_RESOURCE_STATE_GENERIC_READ);
    void* p;
    CHECK(r->Map(0, nullptr, &p));
    memcpy(p, data, size);
    r->Unmap(0, nullptr);
    return r;
}

void Renderer::Init(HWND hwnd, bool debug)
{
    m_hwnd = hwnd;
    RECT rc;
    GetClientRect(hwnd, &rc);
    m_width = std::max<LONG>(1, rc.right - rc.left);
    m_height = std::max<LONG>(1, rc.bottom - rc.top);

    UINT factoryFlags = 0;
    if (debug)
    {
        ComPtr<ID3D12Debug> dbg;
        if (SUCCEEDED(D3D12GetDebugInterface(IID_PPV_ARGS(&dbg))))
        {
            dbg->EnableDebugLayer();
            factoryFlags |= DXGI_CREATE_FACTORY_DEBUG;
        }
    }
    CHECK(CreateDXGIFactory2(factoryFlags, IID_PPV_ARGS(&m_factory)));

    // Pick the highest performance GPU that supports DXR.
    ComPtr<IDXGIAdapter1> adapter;
    for (UINT i = 0; m_factory->EnumAdapterByGpuPreference(i, DXGI_GPU_PREFERENCE_HIGH_PERFORMANCE,
                                                          IID_PPV_ARGS(&adapter)) != DXGI_ERROR_NOT_FOUND; ++i)
    {
        DXGI_ADAPTER_DESC1 desc;
        adapter->GetDesc1(&desc);
        if (desc.Flags & DXGI_ADAPTER_FLAG_SOFTWARE) continue;
        ComPtr<ID3D12Device5> dev;
        if (FAILED(D3D12CreateDevice(adapter.Get(), D3D_FEATURE_LEVEL_12_1, IID_PPV_ARGS(&dev)))) continue;
        D3D12_FEATURE_DATA_D3D12_OPTIONS5 o5 = {};
        if (SUCCEEDED(dev->CheckFeatureSupport(D3D12_FEATURE_D3D12_OPTIONS5, &o5, sizeof(o5))) &&
            o5.RaytracingTier >= D3D12_RAYTRACING_TIER_1_0)
        {
            m_device = dev;
            wcsncpy_s(m_adapterName, desc.Description, _TRUNCATE);
            break;
        }
    }
    if (!m_device) Fail("No GPU with DirectX Raytracing (DXR) support was found.", E_FAIL);

    D3D12_COMMAND_QUEUE_DESC qd = {};
    qd.Type = D3D12_COMMAND_LIST_TYPE_DIRECT;
    CHECK(m_device->CreateCommandQueue(&qd, IID_PPV_ARGS(&m_queue)));

    DXGI_SWAP_CHAIN_DESC1 sd = {};
    sd.Width = m_width;
    sd.Height = m_height;
    sd.Format = kFormat;
    sd.SampleDesc.Count = 1;
    sd.BufferUsage = DXGI_USAGE_RENDER_TARGET_OUTPUT;
    sd.BufferCount = kFrameCount;
    sd.SwapEffect = DXGI_SWAP_EFFECT_FLIP_DISCARD;
    ComPtr<IDXGISwapChain1> sc1;
    CHECK(m_factory->CreateSwapChainForHwnd(m_queue.Get(), hwnd, &sd, nullptr, nullptr, &sc1));
    m_factory->MakeWindowAssociation(hwnd, DXGI_MWA_NO_ALT_ENTER);
    CHECK(sc1.As(&m_swapChain));
    for (UINT i = 0; i < kFrameCount; i++)
        CHECK(m_swapChain->GetBuffer(i, IID_PPV_ARGS(&m_backBuffers[i])));

    CHECK(m_device->CreateCommandAllocator(D3D12_COMMAND_LIST_TYPE_DIRECT, IID_PPV_ARGS(&m_alloc)));
    CHECK(m_device->CreateCommandList(0, D3D12_COMMAND_LIST_TYPE_DIRECT, m_alloc.Get(), nullptr, IID_PPV_ARGS(&m_list)));
    CHECK(m_list->Close());
    CHECK(m_device->CreateFence(0, D3D12_FENCE_FLAG_NONE, IID_PPV_ARGS(&m_fence)));
    m_fenceEvent = CreateEventW(nullptr, FALSE, FALSE, nullptr);

    D3D12_DESCRIPTOR_HEAP_DESC hd = {};
    hd.Type = D3D12_DESCRIPTOR_HEAP_TYPE_CBV_SRV_UAV;
    hd.NumDescriptors = 1 + kMaxSceneTextures;
    hd.Flags = D3D12_DESCRIPTOR_HEAP_FLAG_SHADER_VISIBLE;
    CHECK(m_device->CreateDescriptorHeap(&hd, IID_PPV_ARGS(&m_heap)));
    m_descriptorSize = m_device->GetDescriptorHandleIncrementSize(D3D12_DESCRIPTOR_HEAP_TYPE_CBV_SRV_UAV);

    m_constantBuffer = MakeBuffer(kMaxSceneConstants, D3D12_HEAP_TYPE_UPLOAD, D3D12_RESOURCE_STATE_GENERIC_READ);
    CHECK(m_constantBuffer->Map(0, nullptr, reinterpret_cast<void**>(&m_cbData)));

    CreateOutput();
    CreateRootSignature();
    ClearTextures();
}

void Renderer::ClearTextures()
{
    // Null descriptors: sampling an unbound slot returns 0 instead of faulting.
    for (UINT i = 0; i < kMaxSceneTextures; i++)
    {
        m_textures[i].Reset();
        D3D12_SHADER_RESOURCE_VIEW_DESC srv = {};
        srv.Format = DXGI_FORMAT_R8G8B8A8_UNORM;
        srv.ViewDimension = D3D12_SRV_DIMENSION_TEXTURE2D;
        srv.Shader4ComponentMapping = D3D12_DEFAULT_SHADER_4_COMPONENT_MAPPING;
        srv.Texture2D.MipLevels = 1;
        m_device->CreateShaderResourceView(nullptr, &srv, CpuDescriptor(1 + i));
    }
}

void Renderer::UploadTexture(const TextureUpload& t)
{
    if (t.slot >= kMaxSceneTextures || t.mips.empty()) return;
    WaitGpu();

    const UINT mipCount = (UINT)t.mips.size();
    D3D12_RESOURCE_DESC td = {};
    td.Dimension = D3D12_RESOURCE_DIMENSION_TEXTURE2D;
    td.Width = t.mips[0].width;
    td.Height = t.mips[0].height;
    td.DepthOrArraySize = 1;
    td.MipLevels = (UINT16)mipCount;
    td.Format = t.format;
    td.SampleDesc.Count = 1;
    D3D12_HEAP_PROPERTIES hp = {};
    hp.Type = D3D12_HEAP_TYPE_DEFAULT;
    ComPtr<ID3D12Resource> tex;
    CHECK(m_device->CreateCommittedResource(&hp, D3D12_HEAP_FLAG_NONE, &td, D3D12_RESOURCE_STATE_COPY_DEST, nullptr,
                                            IID_PPV_ARGS(&tex)));

    std::vector<D3D12_PLACED_SUBRESOURCE_FOOTPRINT> fp(mipCount);
    std::vector<UINT> rows(mipCount);
    std::vector<UINT64> rowBytes(mipCount);
    UINT64 total = 0;
    m_device->GetCopyableFootprints(&td, 0, mipCount, 0, fp.data(), rows.data(), rowBytes.data(), &total);
    ComPtr<ID3D12Resource> upload = MakeBuffer(total, D3D12_HEAP_TYPE_UPLOAD, D3D12_RESOURCE_STATE_GENERIC_READ);
    uint8_t* dst = nullptr;
    CHECK(upload->Map(0, nullptr, reinterpret_cast<void**>(&dst)));
    for (UINT m = 0; m < mipCount; m++)
    {
        const TextureUpload::Mip& mip = t.mips[m];
        const size_t srcPitch = (size_t)mip.width * t.bytesPerPixel;
        for (UINT y = 0; y < rows[m]; y++)
            memcpy(dst + fp[m].Offset + (size_t)y * fp[m].Footprint.RowPitch, mip.data.data() + y * srcPitch, srcPitch);
    }
    upload->Unmap(0, nullptr);

    CHECK(m_alloc->Reset());
    CHECK(m_list->Reset(m_alloc.Get(), nullptr));
    for (UINT m = 0; m < mipCount; m++)
    {
        D3D12_TEXTURE_COPY_LOCATION from = {}, to = {};
        from.pResource = upload.Get();
        from.Type = D3D12_TEXTURE_COPY_TYPE_PLACED_FOOTPRINT;
        from.PlacedFootprint = fp[m];
        to.pResource = tex.Get();
        to.Type = D3D12_TEXTURE_COPY_TYPE_SUBRESOURCE_INDEX;
        to.SubresourceIndex = m;
        m_list->CopyTextureRegion(&to, 0, 0, 0, &from, nullptr);
    }
    D3D12_RESOURCE_BARRIER b = Transition(tex.Get(), D3D12_RESOURCE_STATE_COPY_DEST,
                                          D3D12_RESOURCE_STATE_NON_PIXEL_SHADER_RESOURCE);
    m_list->ResourceBarrier(1, &b);
    CHECK(m_list->Close());
    ID3D12CommandList* lists[] = { m_list.Get() };
    m_queue->ExecuteCommandLists(1, lists);
    WaitGpu();   // the upload buffer can go away after this

    D3D12_SHADER_RESOURCE_VIEW_DESC srv = {};
    srv.Format = t.format;
    srv.ViewDimension = D3D12_SRV_DIMENSION_TEXTURE2D;
    srv.Shader4ComponentMapping = D3D12_DEFAULT_SHADER_4_COMPONENT_MAPPING;
    srv.Texture2D.MipLevels = mipCount;
    m_device->CreateShaderResourceView(tex.Get(), &srv, CpuDescriptor(1 + t.slot));
    m_textures[t.slot] = tex;
}

void Renderer::CreateOutput()
{
    D3D12_HEAP_PROPERTIES hp = {};
    hp.Type = D3D12_HEAP_TYPE_DEFAULT;
    D3D12_RESOURCE_DESC td = {};
    td.Dimension = D3D12_RESOURCE_DIMENSION_TEXTURE2D;
    td.Width = m_width;
    td.Height = m_height;
    td.DepthOrArraySize = 1;
    td.MipLevels = 1;
    td.Format = kFormat;
    td.SampleDesc.Count = 1;
    td.Flags = D3D12_RESOURCE_FLAG_ALLOW_UNORDERED_ACCESS;
    m_output.Reset();
    CHECK(m_device->CreateCommittedResource(&hp, D3D12_HEAP_FLAG_NONE, &td, D3D12_RESOURCE_STATE_UNORDERED_ACCESS,
                                            nullptr, IID_PPV_ARGS(&m_output)));
    D3D12_UNORDERED_ACCESS_VIEW_DESC uav = {};
    uav.Format = kFormat;
    uav.ViewDimension = D3D12_UAV_DIMENSION_TEXTURE2D;
    m_device->CreateUnorderedAccessView(m_output.Get(), nullptr, &uav, m_heap->GetCPUDescriptorHandleForHeapStart());
}

void Renderer::CreateRootSignature()
{
    // Shared by all scenes: u0 (output, table), t0 (TLAS), b0 (scene constants),
    // t1..t4 (scene textures, table) and a static linear sampler s0.
    D3D12_DESCRIPTOR_RANGE range = {};
    range.RangeType = D3D12_DESCRIPTOR_RANGE_TYPE_UAV;
    range.NumDescriptors = 1;
    D3D12_DESCRIPTOR_RANGE texRange = {};
    texRange.RangeType = D3D12_DESCRIPTOR_RANGE_TYPE_SRV;
    texRange.NumDescriptors = kMaxSceneTextures;
    texRange.BaseShaderRegister = 1;
    D3D12_ROOT_PARAMETER params[4] = {};
    params[0].ParameterType = D3D12_ROOT_PARAMETER_TYPE_DESCRIPTOR_TABLE;
    params[0].DescriptorTable.NumDescriptorRanges = 1;
    params[0].DescriptorTable.pDescriptorRanges = &range;
    params[1].ParameterType = D3D12_ROOT_PARAMETER_TYPE_SRV;
    params[2].ParameterType = D3D12_ROOT_PARAMETER_TYPE_CBV;
    params[3].ParameterType = D3D12_ROOT_PARAMETER_TYPE_DESCRIPTOR_TABLE;
    params[3].DescriptorTable.NumDescriptorRanges = 1;
    params[3].DescriptorTable.pDescriptorRanges = &texRange;
    D3D12_STATIC_SAMPLER_DESC sampler = {};
    sampler.Filter = D3D12_FILTER_MIN_MAG_MIP_LINEAR;
    sampler.AddressU = D3D12_TEXTURE_ADDRESS_MODE_WRAP;    // longitude wraps
    sampler.AddressV = D3D12_TEXTURE_ADDRESS_MODE_CLAMP;   // latitude clamps at the poles
    sampler.AddressW = D3D12_TEXTURE_ADDRESS_MODE_CLAMP;
    sampler.MaxLOD = D3D12_FLOAT32_MAX;
    sampler.ShaderVisibility = D3D12_SHADER_VISIBILITY_ALL;
    D3D12_ROOT_SIGNATURE_DESC rsd = {};
    rsd.NumParameters = 4;
    rsd.pParameters = params;
    rsd.NumStaticSamplers = 1;
    rsd.pStaticSamplers = &sampler;
    ComPtr<ID3DBlob> blob, err;
    HRESULT hr = D3D12SerializeRootSignature(&rsd, D3D_ROOT_SIGNATURE_VERSION_1, &blob, &err);
    if (FAILED(hr)) Fail(err ? (const char*)err->GetBufferPointer() : "D3D12SerializeRootSignature", hr);
    CHECK(m_device->CreateRootSignature(0, blob->GetBufferPointer(), blob->GetBufferSize(), IID_PPV_ARGS(&m_rootSig)));
}

void Renderer::LoadScene(const Scene& scene)
{
    WaitGpu();
    m_pso.Reset();
    m_shaderTable.Reset();
    m_geometryBuffers.clear();
    m_blas.clear();
    m_tlas.Reset();
    m_tlasScratch.Reset();
    m_instanceBuffer.Reset();
    m_instances = nullptr;
    ClearTextures();
    CreatePipeline(scene);
    BuildGeometry(scene);
}

void Renderer::CreatePipeline(const Scene& scene)
{
    const std::vector<HitGroupDef> groups = scene.HitGroups();
    m_hitGroupCount = (UINT)groups.size();

    D3D12_DXIL_LIBRARY_DESC lib = {};
    lib.DXILLibrary = scene.Library();

    std::vector<D3D12_HIT_GROUP_DESC> hitDescs(groups.size());
    std::vector<D3D12_STATE_SUBOBJECT> subs;
    subs.reserve(groups.size() + 4);
    subs.push_back({ D3D12_STATE_SUBOBJECT_TYPE_DXIL_LIBRARY, &lib });
    for (size_t i = 0; i < groups.size(); i++)
    {
        hitDescs[i].HitGroupExport = groups[i].name;
        hitDescs[i].ClosestHitShaderImport = groups[i].closestHit;
        hitDescs[i].IntersectionShaderImport = groups[i].intersection;
        hitDescs[i].Type = groups[i].intersection ? D3D12_HIT_GROUP_TYPE_PROCEDURAL_PRIMITIVE
                                                  : D3D12_HIT_GROUP_TYPE_TRIANGLES;
        subs.push_back({ D3D12_STATE_SUBOBJECT_TYPE_HIT_GROUP, &hitDescs[i] });
    }
    D3D12_RAYTRACING_SHADER_CONFIG shaderCfg = { scene.PayloadSize(), scene.AttributeSize() };
    D3D12_GLOBAL_ROOT_SIGNATURE grs = { m_rootSig.Get() };
    D3D12_RAYTRACING_PIPELINE_CONFIG pipeCfg = { scene.MaxRecursion() };
    subs.push_back({ D3D12_STATE_SUBOBJECT_TYPE_RAYTRACING_SHADER_CONFIG, &shaderCfg });
    subs.push_back({ D3D12_STATE_SUBOBJECT_TYPE_GLOBAL_ROOT_SIGNATURE, &grs });
    subs.push_back({ D3D12_STATE_SUBOBJECT_TYPE_RAYTRACING_PIPELINE_CONFIG, &pipeCfg });

    D3D12_STATE_OBJECT_DESC sod = {};
    sod.Type = D3D12_STATE_OBJECT_TYPE_RAYTRACING_PIPELINE;
    sod.NumSubobjects = (UINT)subs.size();
    sod.pSubobjects = subs.data();
    CHECK(m_device->CreateStateObject(&sod, IID_PPV_ARGS(&m_pso)));

    // Shader table: [raygen @0] [Miss, ShadowMiss @64] [hit groups @128, stride 32]
    ComPtr<ID3D12StateObjectProperties> props;
    CHECK(m_pso.As(&props));
    m_shaderTable = MakeBuffer(128 + 32 * m_hitGroupCount, D3D12_HEAP_TYPE_UPLOAD, D3D12_RESOURCE_STATE_GENERIC_READ);
    uint8_t* p = nullptr;
    CHECK(m_shaderTable->Map(0, nullptr, reinterpret_cast<void**>(&p)));
    auto put = [&](const wchar_t* name, UINT offset) {
        void* id = props->GetShaderIdentifier(name);
        if (!id) Fail("GetShaderIdentifier returned null (missing shader export?)", E_FAIL);
        memcpy(p + offset, id, D3D12_SHADER_IDENTIFIER_SIZE_IN_BYTES);
    };
    put(L"RayGen", 0);
    put(L"Miss", 64);
    put(L"ShadowMiss", 96);
    for (UINT i = 0; i < m_hitGroupCount; i++) put(groups[i].name, 128 + 32 * i);
    m_shaderTable->Unmap(0, nullptr);
}

void Renderer::BuildGeometry(const Scene& scene)
{
    const std::vector<GeometryDef> geometry = scene.Geometry();

    CHECK(m_alloc->Reset());
    CHECK(m_list->Reset(m_alloc.Get(), nullptr));

    std::vector<ComPtr<ID3D12Resource>> scratch;
    for (const GeometryDef& g : geometry)
    {
        D3D12_RAYTRACING_GEOMETRY_DESC gd = {};
        gd.Flags = D3D12_RAYTRACING_GEOMETRY_FLAG_OPAQUE;
        if (g.procedural)
        {
            m_geometryBuffers.push_back(MakeUpload(&g.aabb, sizeof(g.aabb)));
            gd.Type = D3D12_RAYTRACING_GEOMETRY_TYPE_PROCEDURAL_PRIMITIVE_AABBS;
            gd.AABBs.AABBCount = 1;
            gd.AABBs.AABBs.StartAddress = m_geometryBuffers.back()->GetGPUVirtualAddress();
            gd.AABBs.AABBs.StrideInBytes = sizeof(D3D12_RAYTRACING_AABB);
        }
        else
        {
            m_geometryBuffers.push_back(MakeUpload(g.vertices.data(), g.vertices.size() * sizeof(float)));
            gd.Type = D3D12_RAYTRACING_GEOMETRY_TYPE_TRIANGLES;
            gd.Triangles.VertexBuffer.StartAddress = m_geometryBuffers.back()->GetGPUVirtualAddress();
            gd.Triangles.VertexBuffer.StrideInBytes = 12;
            gd.Triangles.VertexFormat = DXGI_FORMAT_R32G32B32_FLOAT;
            gd.Triangles.VertexCount = (UINT)(g.vertices.size() / 3);
            gd.Triangles.IndexFormat = DXGI_FORMAT_UNKNOWN;
        }

        D3D12_BUILD_RAYTRACING_ACCELERATION_STRUCTURE_INPUTS in = {};
        in.Type = D3D12_RAYTRACING_ACCELERATION_STRUCTURE_TYPE_BOTTOM_LEVEL;
        in.Flags = D3D12_RAYTRACING_ACCELERATION_STRUCTURE_BUILD_FLAG_PREFER_FAST_TRACE;
        in.DescsLayout = D3D12_ELEMENTS_LAYOUT_ARRAY;
        in.NumDescs = 1;
        in.pGeometryDescs = &gd;
        D3D12_RAYTRACING_ACCELERATION_STRUCTURE_PREBUILD_INFO info = {};
        m_device->GetRaytracingAccelerationStructurePrebuildInfo(&in, &info);
        scratch.push_back(MakeBuffer(AlignUp(info.ScratchDataSizeInBytes, 256), D3D12_HEAP_TYPE_DEFAULT,
                                     D3D12_RESOURCE_STATE_UNORDERED_ACCESS, D3D12_RESOURCE_FLAG_ALLOW_UNORDERED_ACCESS));
        m_blas.push_back(MakeBuffer(AlignUp(info.ResultDataMaxSizeInBytes, 256), D3D12_HEAP_TYPE_DEFAULT,
                                    D3D12_RESOURCE_STATE_RAYTRACING_ACCELERATION_STRUCTURE,
                                    D3D12_RESOURCE_FLAG_ALLOW_UNORDERED_ACCESS));
        D3D12_BUILD_RAYTRACING_ACCELERATION_STRUCTURE_DESC bd = {};
        bd.Inputs = in;
        bd.DestAccelerationStructureData = m_blas.back()->GetGPUVirtualAddress();
        bd.ScratchAccelerationStructureData = scratch.back()->GetGPUVirtualAddress();
        m_list->BuildRaytracingAccelerationStructure(&bd, 0, nullptr);
        D3D12_RESOURCE_BARRIER b = UavBarrier(m_blas.back().Get());
        m_list->ResourceBarrier(1, &b);
    }

    // TLAS, rebuilt every frame with the scene's instances.
    m_instanceCount = scene.InstanceCount();
    m_instanceBuffer = MakeBuffer(sizeof(D3D12_RAYTRACING_INSTANCE_DESC) * m_instanceCount, D3D12_HEAP_TYPE_UPLOAD,
                                  D3D12_RESOURCE_STATE_GENERIC_READ);
    CHECK(m_instanceBuffer->Map(0, nullptr, reinterpret_cast<void**>(&m_instances)));

    m_tlasInputs = {};
    m_tlasInputs.Type = D3D12_RAYTRACING_ACCELERATION_STRUCTURE_TYPE_TOP_LEVEL;
    m_tlasInputs.Flags = D3D12_RAYTRACING_ACCELERATION_STRUCTURE_BUILD_FLAG_PREFER_FAST_BUILD;
    m_tlasInputs.DescsLayout = D3D12_ELEMENTS_LAYOUT_ARRAY;
    m_tlasInputs.NumDescs = m_instanceCount;
    m_tlasInputs.InstanceDescs = m_instanceBuffer->GetGPUVirtualAddress();
    D3D12_RAYTRACING_ACCELERATION_STRUCTURE_PREBUILD_INFO info = {};
    m_device->GetRaytracingAccelerationStructurePrebuildInfo(&m_tlasInputs, &info);
    m_tlasScratch = MakeBuffer(AlignUp(info.ScratchDataSizeInBytes, 256), D3D12_HEAP_TYPE_DEFAULT,
                               D3D12_RESOURCE_STATE_UNORDERED_ACCESS, D3D12_RESOURCE_FLAG_ALLOW_UNORDERED_ACCESS);
    m_tlas = MakeBuffer(AlignUp(info.ResultDataMaxSizeInBytes, 256), D3D12_HEAP_TYPE_DEFAULT,
                        D3D12_RESOURCE_STATE_RAYTRACING_ACCELERATION_STRUCTURE,
                        D3D12_RESOURCE_FLAG_ALLOW_UNORDERED_ACCESS);

    CHECK(m_list->Close());
    ID3D12CommandList* lists[] = { m_list.Get() };
    m_queue->ExecuteCommandLists(1, lists);
    WaitGpu();   // keeps scratch buffers alive until the builds finish
}

void Renderer::WaitGpu()
{
    const UINT64 v = ++m_fenceValue;
    CHECK(m_queue->Signal(m_fence.Get(), v));
    if (m_fence->GetCompletedValue() < v)
    {
        CHECK(m_fence->SetEventOnCompletion(v, m_fenceEvent));
        WaitForSingleObject(m_fenceEvent, INFINITE);
    }
}

void Renderer::Resize(UINT w, UINT h)
{
    w = std::max(1u, w);
    h = std::max(1u, h);
    if (w == m_width && h == m_height) return;
    WaitGpu();
    for (auto& b : m_backBuffers) b.Reset();
    CHECK(m_swapChain->ResizeBuffers(kFrameCount, w, h, kFormat, 0));
    for (UINT i = 0; i < kFrameCount; i++)
        CHECK(m_swapChain->GetBuffer(i, IID_PPV_ARGS(&m_backBuffers[i])));
    m_width = w;
    m_height = h;
    CreateOutput();
}

void Renderer::Render(const void* constants, UINT constantsSize, const InstanceDef* instances, UINT count)
{
    // The previous frame is fully finished (WaitGpu at the end), so CPU-visible buffers are safe to overwrite.
    memcpy(m_cbData, constants, std::min(constantsSize, kMaxSceneConstants));
    count = std::min(count, m_instanceCount);
    for (UINT i = 0; i < count; i++)
    {
        D3D12_RAYTRACING_INSTANCE_DESC d = {};
        memcpy(d.Transform, instances[i].transform, sizeof(d.Transform));
        d.InstanceID = instances[i].id;
        d.InstanceMask = 0xFF;
        d.InstanceContributionToHitGroupIndex = std::min(instances[i].hitGroup, m_hitGroupCount - 1);
        d.AccelerationStructure = m_blas[std::min<size_t>(instances[i].geometry, m_blas.size() - 1)]->GetGPUVirtualAddress();
        m_instances[i] = d;
    }

    CHECK(m_alloc->Reset());
    CHECK(m_list->Reset(m_alloc.Get(), nullptr));

    D3D12_BUILD_RAYTRACING_ACCELERATION_STRUCTURE_DESC bd = {};
    bd.Inputs = m_tlasInputs;
    bd.Inputs.NumDescs = count;
    bd.DestAccelerationStructureData = m_tlas->GetGPUVirtualAddress();
    bd.ScratchAccelerationStructureData = m_tlasScratch->GetGPUVirtualAddress();
    m_list->BuildRaytracingAccelerationStructure(&bd, 0, nullptr);
    D3D12_RESOURCE_BARRIER b = UavBarrier(m_tlas.Get());
    m_list->ResourceBarrier(1, &b);

    ID3D12DescriptorHeap* heaps[] = { m_heap.Get() };
    m_list->SetDescriptorHeaps(1, heaps);
    m_list->SetComputeRootSignature(m_rootSig.Get());
    m_list->SetComputeRootDescriptorTable(0, m_heap->GetGPUDescriptorHandleForHeapStart());
    m_list->SetComputeRootShaderResourceView(1, m_tlas->GetGPUVirtualAddress());
    m_list->SetComputeRootConstantBufferView(2, m_constantBuffer->GetGPUVirtualAddress());
    D3D12_GPU_DESCRIPTOR_HANDLE texTable = m_heap->GetGPUDescriptorHandleForHeapStart();
    texTable.ptr += m_descriptorSize;
    m_list->SetComputeRootDescriptorTable(3, texTable);
    m_list->SetPipelineState1(m_pso.Get());

    const D3D12_GPU_VIRTUAL_ADDRESS st = m_shaderTable->GetGPUVirtualAddress();
    D3D12_DISPATCH_RAYS_DESC rays = {};
    rays.RayGenerationShaderRecord = { st, 32 };
    rays.MissShaderTable = { st + 64, 64, 32 };
    rays.HitGroupTable = { st + 128, 32ull * m_hitGroupCount, 32 };
    rays.Width = m_width;
    rays.Height = m_height;
    rays.Depth = 1;
    m_list->DispatchRays(&rays);

    ID3D12Resource* back = m_backBuffers[m_swapChain->GetCurrentBackBufferIndex()].Get();
    D3D12_RESOURCE_BARRIER pre[] = {
        Transition(m_output.Get(), D3D12_RESOURCE_STATE_UNORDERED_ACCESS, D3D12_RESOURCE_STATE_COPY_SOURCE),
        Transition(back, D3D12_RESOURCE_STATE_PRESENT, D3D12_RESOURCE_STATE_COPY_DEST),
    };
    m_list->ResourceBarrier(2, pre);
    m_list->CopyResource(back, m_output.Get());
    D3D12_RESOURCE_BARRIER post[] = {
        Transition(m_output.Get(), D3D12_RESOURCE_STATE_COPY_SOURCE, D3D12_RESOURCE_STATE_UNORDERED_ACCESS),
        Transition(back, D3D12_RESOURCE_STATE_COPY_DEST, D3D12_RESOURCE_STATE_PRESENT),
    };
    m_list->ResourceBarrier(2, post);

    CHECK(m_list->Close());
    ID3D12CommandList* lists[] = { m_list.Get() };
    m_queue->ExecuteCommandLists(1, lists);
    HRESULT hr = m_swapChain->Present(1, 0);
    if (hr == DXGI_ERROR_DEVICE_REMOVED || hr == DXGI_ERROR_DEVICE_RESET)
        Fail("GPU device removed", m_device->GetDeviceRemovedReason());
    WaitGpu();
}

// ---------------------------------------------------------------------------
// Desktop (behind icons) attachment
// ---------------------------------------------------------------------------
static BOOL CALLBACK FindLegacyWorkerW(HWND top, LPARAM out)
{
    if (FindWindowExW(top, nullptr, L"SHELLDLL_DefView", nullptr))
        *reinterpret_cast<HWND*>(out) = FindWindowExW(nullptr, top, L"WorkerW", nullptr);
    return TRUE;
}

// Returns the parent window and fills rc with the area to cover (parent client coords).
static HWND AttachToDesktop(HWND hwnd, RECT* rc)
{
    HWND progman = FindWindowW(L"Progman", nullptr);
    if (!progman) return nullptr;
    // Ask Explorer to create the WorkerW window that sits between the wallpaper and the icons.
    SendMessageTimeoutW(progman, 0x052C, 0xD, 0x1, SMTO_NORMAL, 1000, nullptr);
    SendMessageTimeoutW(progman, 0x052C, 0, 0, SMTO_NORMAL, 1000, nullptr);

    SetWindowLongPtrW(hwnd, GWL_STYLE, WS_CHILD | WS_VISIBLE | WS_CLIPSIBLINGS);
    SetWindowLongPtrW(hwnd, GWL_EXSTYLE, 0);

    HWND defView = FindWindowExW(progman, nullptr, L"SHELLDLL_DefView", nullptr);
    HWND workerw = FindWindowExW(progman, nullptr, L"WorkerW", nullptr);
    HWND parent = nullptr;
    HWND insertAfter = HWND_TOP;
    if (defView && workerw)
    {
        // Windows 11 24H2+: Progman -> { SHELLDLL_DefView (icons), WorkerW (wallpaper) }.
        parent = progman;
        insertAfter = defView;   // place us just below the icon layer
    }
    else
    {
        // Classic layout: a top-level WorkerW right after the one that hosts SHELLDLL_DefView.
        EnumWindows(FindLegacyWorkerW, reinterpret_cast<LPARAM>(&workerw));
        parent = workerw ? workerw : progman;
    }

    SetParent(hwnd, parent);
    GetClientRect(parent, rc);
    SetWindowPos(hwnd, insertAfter, 0, 0, rc->right - rc->left, rc->bottom - rc->top,
                 SWP_NOACTIVATE | SWP_SHOWWINDOW | SWP_FRAMECHANGED);
    return parent;
}

// ---------------------------------------------------------------------------
// App
// ---------------------------------------------------------------------------
struct App
{
    Renderer renderer;
    std::unique_ptr<Scene> scene;
    alignas(16) uint8_t constants[kMaxSceneConstants] = {};
    std::vector<InstanceDef> instances;
    Config config;
    std::wstring sceneSection;   // contents of the scene's own ini section (recreate scene if it changes)
    std::wstring configPath;
    FILETIME configTime = {};
    HWND hwnd = nullptr;
    HWND trayWnd = nullptr;
    HWND desktopParent = nullptr;
    bool wallpaper = false;
    bool userPaused = false;
    bool running = true;
    bool resizePending = false;
};
static App g_app;

static void UpdateTitle()
{
    if (g_app.wallpaper || !g_app.scene) return;
    wchar_t title[256];
    swprintf_s(title, L"RTWallpaper — %s — DXR — %s   (Tab: siguiente escena)", g_app.scene->Name(),
               g_app.renderer.AdapterName());
    SetWindowTextW(g_app.hwnd, title);
}

static std::wstring ReadSection(const std::wstring& name)
{
    wchar_t buf[4096] = {};
    DWORD n = GetPrivateProfileSectionW(name.c_str(), buf, _countof(buf), g_app.configPath.c_str());
    return std::wstring(buf, n);
}

static void SwitchScene(const std::wstring& name)
{
    g_app.scene.reset();   // stop the old scene's background work first
    g_app.scene = CreateScene(name, g_app.configPath);
    g_app.sceneSection = ReadSection(g_app.scene->Name());
    g_app.instances.assign(g_app.scene->InstanceCount(), InstanceDef{});
    memset(g_app.constants, 0, sizeof(g_app.constants));
    g_app.renderer.LoadScene(*g_app.scene);
    UpdateTitle();
}

// Saves the scene to the ini (the file watcher then applies it).
static void SelectScene(const wchar_t* name)
{
    WritePrivateProfileStringW(L"General", L"Scene", name, g_app.configPath.c_str());
}

static void ApplyConfig(const Config& c)
{
    bool sceneChanged = !g_app.scene || _wcsicmp(c.scene.c_str(), g_app.config.scene.c_str()) != 0 ||
                        ReadSection(g_app.scene->Name()) != g_app.sceneSection;
    g_app.config = c;
    if (sceneChanged) SwitchScene(c.scene);
}

static void RefitToDesktop()
{
    if (!g_app.desktopParent) return;
    RECT rc;
    GetClientRect(g_app.desktopParent, &rc);
    SetWindowPos(g_app.hwnd, nullptr, 0, 0, rc.right - rc.left, rc.bottom - rc.top, SWP_NOZORDER | SWP_NOACTIVATE);
}

static void ShowTrayMenu()
{
    HMENU menu = CreatePopupMenu();
    for (UINT i = 0; i < _countof(kSceneNames); i++)
    {
        bool current = g_app.scene && !_wcsicmp(g_app.scene->Name(), kSceneNames[i]);
        AppendMenuW(menu, MF_STRING | (current ? MF_CHECKED : 0), kCmdSceneBase + i, kSceneNames[i]);
    }
    AppendMenuW(menu, MF_SEPARATOR, 0, nullptr);
    AppendMenuW(menu, MF_STRING, kCmdEditConfig, L"Editar configuración…");
    AppendMenuW(menu, MF_STRING, kCmdPause, g_app.userPaused ? L"Reanudar" : L"Pausar");
    AppendMenuW(menu, MF_SEPARATOR, 0, nullptr);
    AppendMenuW(menu, MF_STRING, kCmdExit, L"Salir");
    POINT pt;
    GetCursorPos(&pt);
    SetForegroundWindow(g_app.trayWnd);
    UINT cmd = TrackPopupMenu(menu, TPM_RIGHTBUTTON | TPM_RETURNCMD | TPM_NONOTIFY, pt.x, pt.y, 0, g_app.trayWnd, nullptr);
    DestroyMenu(menu);
    if (cmd == kCmdPause) g_app.userPaused = !g_app.userPaused;
    else if (cmd == kCmdExit) g_app.running = false;
    else if (cmd == kCmdEditConfig) ShellExecuteW(nullptr, L"open", L"notepad.exe", g_app.configPath.c_str(), nullptr, SW_SHOW);
    else if (cmd >= kCmdSceneBase && cmd < kCmdSceneBase + _countof(kSceneNames)) SelectScene(kSceneNames[cmd - kCmdSceneBase]);
}

static LRESULT CALLBACK WndProc(HWND hwnd, UINT msg, WPARAM wp, LPARAM lp)
{
    switch (msg)
    {
    case WM_SIZE:
        if (hwnd == g_app.hwnd) g_app.resizePending = true;
        return 0;
    case WM_ERASEBKGND:
        return 1;
    case WM_KEYDOWN:
        if (wp == VK_ESCAPE && !g_app.wallpaper) g_app.running = false;
        if (wp == VK_TAB && g_app.scene)
        {
            UINT next = 0;
            for (UINT i = 0; i < _countof(kSceneNames); i++)
                if (!_wcsicmp(g_app.scene->Name(), kSceneNames[i])) next = (i + 1) % _countof(kSceneNames);
            g_app.config.scene = kSceneNames[next];
            SwitchScene(kSceneNames[next]);
        }
        return 0;
    case WM_DISPLAYCHANGE:
        RefitToDesktop();
        return 0;
    case WM_TRAY:
        if (LOWORD(lp) == WM_RBUTTONUP || LOWORD(lp) == WM_CONTEXTMENU || LOWORD(lp) == WM_LBUTTONUP)
            ShowTrayMenu();
        return 0;
    case WM_CLOSE:
        g_app.running = false;
        return 0;
    }
    return DefWindowProcW(hwnd, msg, wp, lp);
}

// True when a game/app covers its whole monitor. QUNS_BUSY is not used: some setups
// report it permanently, which would keep the wallpaper paused forever.
static bool FullscreenAppActive()
{
    QUERY_USER_NOTIFICATION_STATE s;
    if (SUCCEEDED(SHQueryUserNotificationState(&s)) &&
        (s == QUNS_RUNNING_D3D_FULL_SCREEN || s == QUNS_PRESENTATION_MODE))
        return true;

    HWND fg = GetForegroundWindow();
    if (!fg || fg == g_app.trayWnd || !IsWindowVisible(fg) || IsIconic(fg)) return false;
    wchar_t cls[64] = {};
    GetClassNameW(fg, cls, 64);
    if (!wcscmp(cls, L"Progman") || !wcscmp(cls, L"WorkerW") || !wcscmp(cls, L"Shell_TrayWnd")) return false;

    RECT wr;
    MONITORINFO mi = { sizeof(mi) };
    if (!GetWindowRect(fg, &wr) || !GetMonitorInfoW(MonitorFromWindow(fg, MONITOR_DEFAULTTONEAREST), &mi))
        return false;
    return wr.left <= mi.rcMonitor.left && wr.top <= mi.rcMonitor.top &&
           wr.right >= mi.rcMonitor.right && wr.bottom >= mi.rcMonitor.bottom;
}

int WINAPI wWinMain(HINSTANCE inst, HINSTANCE, PWSTR, int)
{
    int argc = 0;
    LPWSTR* argv = CommandLineToArgvW(GetCommandLineW(), &argc);
    bool debug = false, stop = false;
    std::wstring sceneOverride;
    int fpsOverride = 0;
    for (int i = 1; i < argc; i++)
    {
        if (!_wcsicmp(argv[i], L"--wallpaper") || !_wcsicmp(argv[i], L"/wallpaper")) g_app.wallpaper = true;
        else if (!_wcsicmp(argv[i], L"--stop")) stop = true;
        else if (!_wcsicmp(argv[i], L"--debug")) debug = true;
        else if (!_wcsicmp(argv[i], L"--fps") && i + 1 < argc) fpsOverride = std::max(1, _wtoi(argv[++i]));
        else if (!_wcsicmp(argv[i], L"--scene") && i + 1 < argc) sceneOverride = argv[++i];
    }
    LocalFree(argv);

    if (stop)
    {
        HANDLE ev = OpenEventW(EVENT_MODIFY_STATE, FALSE, kStopEvent);
        if (ev) { SetEvent(ev); CloseHandle(ev); }
        return 0;
    }

    HANDLE stopEvent = nullptr;
    if (g_app.wallpaper)
    {
        stopEvent = CreateEventW(nullptr, TRUE, FALSE, kStopEvent);
        if (GetLastError() == ERROR_ALREADY_EXISTS)
        {
            MessageBoxW(nullptr, L"RTWallpaper ya se está ejecutando como fondo de pantalla.\n"
                                 L"Usa el icono de la bandeja o 'RTWallpaper.exe --stop'.",
                        L"RTWallpaper", MB_ICONINFORMATION);
            return 0;
        }
        SetPriorityClass(GetCurrentProcess(), BELOW_NORMAL_PRIORITY_CLASS);
    }

    SetProcessDpiAwarenessContext(DPI_AWARENESS_CONTEXT_PER_MONITOR_AWARE_V2);

    g_app.configPath = ConfigPath();
    Config initial = LoadConfig(g_app.configPath);
    g_app.configTime = ConfigWriteTime(g_app.configPath);
    if (!sceneOverride.empty()) initial.scene = sceneOverride;
    if (fpsOverride) initial.fps = fpsOverride;

    WNDCLASSEXW wc = { sizeof(wc) };
    wc.style = CS_HREDRAW | CS_VREDRAW;
    wc.lpfnWndProc = WndProc;
    wc.hInstance = inst;
    wc.hCursor = LoadCursor(nullptr, IDC_ARROW);
    wc.hIcon = LoadIcon(nullptr, IDI_APPLICATION);
    wc.lpszClassName = kWindowClass;
    RegisterClassExW(&wc);

    if (g_app.wallpaper)
    {
        g_app.hwnd = CreateWindowExW(0, kWindowClass, L"RTWallpaper", WS_POPUP, 0, 0, 16, 16,
                                     nullptr, nullptr, inst, nullptr);
        RECT rc;
        g_app.desktopParent = AttachToDesktop(g_app.hwnd, &rc);
        if (!g_app.desktopParent) Fail("Could not find the desktop window (Progman).", E_FAIL);

        // Hidden top-level window that owns the tray icon and receives WM_DISPLAYCHANGE.
        g_app.trayWnd = CreateWindowExW(WS_EX_TOOLWINDOW, kWindowClass, L"RTWallpaper Tray", WS_POPUP,
                                        0, 0, 0, 0, nullptr, nullptr, inst, nullptr);
        NOTIFYICONDATAW nid = { sizeof(nid) };
        nid.hWnd = g_app.trayWnd;
        nid.uID = 1;
        nid.uFlags = NIF_ICON | NIF_MESSAGE | NIF_TIP;
        nid.uCallbackMessage = WM_TRAY;
        nid.hIcon = LoadIcon(nullptr, IDI_APPLICATION);
        wcscpy_s(nid.szTip, L"RTWallpaper (DXR)");
        Shell_NotifyIconW(NIM_ADD, &nid);
    }
    else
    {
        RECT work;
        SystemParametersInfoW(SPI_GETWORKAREA, 0, &work, 0);
        LONG ww = (work.right - work.left) * 3 / 4;
        RECT r = { 0, 0, ww, ww * 9 / 16 };
        AdjustWindowRect(&r, WS_OVERLAPPEDWINDOW, FALSE);
        g_app.hwnd = CreateWindowExW(0, kWindowClass, L"RTWallpaper", WS_OVERLAPPEDWINDOW,
                                     CW_USEDEFAULT, CW_USEDEFAULT, r.right - r.left, r.bottom - r.top,
                                     nullptr, nullptr, inst, nullptr);
        ShowWindow(g_app.hwnd, SW_SHOW);
    }

    g_app.renderer.Init(g_app.hwnd, debug);
    ApplyConfig(initial);

    HANDLE timer = CreateWaitableTimerExW(nullptr, nullptr, CREATE_WAITABLE_TIMER_HIGH_RESOLUTION, TIMER_ALL_ACCESS);
    LARGE_INTEGER freq, last, now;
    QueryPerformanceFrequency(&freq);
    QueryPerformanceCounter(&last);
    ULONGLONG lastPauseCheck = 0, lastConfigCheck = 0;
    bool autoPaused = false;
    UINT64 framesRendered = 0;   // always draw at least one frame so the wallpaper is never blank

    while (g_app.running)
    {
        MSG msg;
        while (PeekMessageW(&msg, nullptr, 0, 0, PM_REMOVE))
        {
            if (msg.message == WM_QUIT) g_app.running = false;
            TranslateMessage(&msg);
            DispatchMessageW(&msg);
        }
        if (!g_app.running) break;
        if (stopEvent && WaitForSingleObject(stopEvent, 0) == WAIT_OBJECT_0) break;

        const ULONGLONG tick = GetTickCount64();
        if (tick - lastConfigCheck > 500)   // hot-reload RTWallpaper.ini
        {
            lastConfigCheck = tick;
            FILETIME ft = ConfigWriteTime(g_app.configPath);
            if (CompareFileTime(&ft, &g_app.configTime) != 0)
            {
                g_app.configTime = ft;
                ApplyConfig(LoadConfig(g_app.configPath));
                framesRendered = 0;
            }
        }
        if (g_app.wallpaper && tick - lastPauseCheck > 500)
        {
            autoPaused = FullscreenAppActive();
            lastPauseCheck = tick;
        }
        if (framesRendered > 0 && (g_app.userPaused || autoPaused || IsIconic(g_app.hwnd)))
        {
            MsgWaitForMultipleObjects(0, nullptr, FALSE, 250, QS_ALLINPUT);
            QueryPerformanceCounter(&last);
            continue;
        }

        if (g_app.resizePending)
        {
            RECT rc;
            GetClientRect(g_app.hwnd, &rc);
            g_app.renderer.Resize(rc.right - rc.left, rc.bottom - rc.top);
            g_app.resizePending = false;
        }

        QueryPerformanceCounter(&now);
        float dt = (float)((now.QuadPart - last.QuadPart) / (double)freq.QuadPart);
        last = now;
        std::vector<TextureUpload> uploads;
        g_app.scene->PollTextures(uploads);
        for (const TextureUpload& t : uploads) g_app.renderer.UploadTexture(t);
        UINT cbSize = g_app.scene->Update(std::min(dt, 0.1f) * g_app.config.speed, g_app.renderer.Aspect(),
                                          g_app.constants, g_app.instances.data());
        g_app.renderer.Render(g_app.constants, cbSize, g_app.instances.data(), (UINT)g_app.instances.size());
        framesRendered++;

        // Frame cap (Present already waits for vsync; this caps high refresh displays).
        const double frameTime = 1.0 / g_app.config.fps;
        LARGE_INTEGER end;
        QueryPerformanceCounter(&end);
        double spent = (end.QuadPart - now.QuadPart) / (double)freq.QuadPart;
        if (timer && spent < frameTime)
        {
            LARGE_INTEGER due;
            due.QuadPart = -(LONGLONG)((frameTime - spent) * 1e7);
            SetWaitableTimer(timer, &due, 0, nullptr, nullptr, FALSE);
            WaitForSingleObject(timer, INFINITE);
        }
    }

    g_app.renderer.WaitGpu();
    if (g_app.trayWnd)
    {
        NOTIFYICONDATAW nid = { sizeof(nid) };
        nid.hWnd = g_app.trayWnd;
        nid.uID = 1;
        Shell_NotifyIconW(NIM_DELETE, &nid);
    }
    HWND parent = g_app.desktopParent;
    DestroyWindow(g_app.hwnd);
    if (parent) RedrawWindow(parent, nullptr, nullptr, RDW_INVALIDATE | RDW_ERASE | RDW_ALLCHILDREN | RDW_UPDATENOW);
    return 0;
}
