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
