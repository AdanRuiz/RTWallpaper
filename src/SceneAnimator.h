#pragma once
// Organic, non-repeating motion for the 3 quartz spheres using OpenSimplex2 noise
// (FastNoiseLite), plus the two orbiting neon lights and a slow camera sway.
#include <cmath>
#include <DirectXMath.h>
#include "FastNoiseLite.h"

// Must match SceneConstantBuffer in Raytracing.hlsl (all float4 => no padding issues).
struct SceneConstantBuffer
{
    DirectX::XMFLOAT4 cameraPosition;   // xyz, w = tan(fovY / 2)
    DirectX::XMFLOAT4 cameraForward;
    DirectX::XMFLOAT4 cameraRight;
    DirectX::XMFLOAT4 cameraUp;
    DirectX::XMFLOAT4 spherePositions[3]; // xyz, w = radius
    DirectX::XMFLOAT4 lightPositions[2];
    DirectX::XMFLOAT4 lightColors[2];     // rgb, w = intensity
    DirectX::XMFLOAT4 params;             // x = time
};

class SceneAnimator
{
    FastNoiseLite m_noiseX, m_noiseY, m_noiseZ;
    float m_timeAcc = 0.0f;

public:
    SceneAnimator()
    {
        FastNoiseLite* n[3] = { &m_noiseX, &m_noiseY, &m_noiseZ };
        const int seeds[3] = { 1337, 4242, 9999 };
        for (int i = 0; i < 3; i++)
        {
            n[i]->SetNoiseType(FastNoiseLite::NoiseType_OpenSimplex2);
            n[i]->SetSeed(seeds[i]);
            n[i]->SetFrequency(0.15f);
        }
    }

    void Update(float deltaTime, SceneConstantBuffer& cb)
    {
        using namespace DirectX;
        m_timeAcc += deltaTime;
        const float t = m_timeAcc;

        // Independent procedural motion for each sphere (radius = 1).
        for (int i = 0; i < 3; i++)
        {
            float offset = i * 100.0f;
            float x = m_noiseX.GetNoise(t + offset, 0.0f) * 4.0f;
            float y = 1.2f + fabsf(m_noiseY.GetNoise(t + offset, 50.0f)) * 2.0f; // float above the floor
            float z = m_noiseZ.GetNoise(t + offset, 100.0f) * 3.0f;
            cb.spherePositions[i] = XMFLOAT4(x, y, z, 1.0f);
        }

        // Neon lights: cobalt blue and warm amber.
        cb.lightPositions[0] = XMFLOAT4(-5.0f, 4.0f, sinf(t * 0.5f) * 3.0f, 1.0f);
        cb.lightPositions[1] = XMFLOAT4( 5.0f, 4.0f, cosf(t * 0.5f) * 3.0f, 1.0f);
        cb.lightColors[0]    = XMFLOAT4(0.0f, 0.4f, 1.0f, 10.0f);
        cb.lightColors[1]    = XMFLOAT4(1.0f, 0.5f, 0.0f, 10.0f);

        // Slow camera sway around the scene.
        float a = sinf(t * 0.05f) * 0.45f;
        XMVECTOR eye    = XMVectorSet(sinf(a) * 10.5f, 3.4f + sinf(t * 0.11f) * 0.3f, cosf(a) * 10.5f, 0.0f);
        XMVECTOR target = XMVectorSet(0.0f, 1.4f, 0.0f, 0.0f);
        XMVECTOR fwd    = XMVector3Normalize(XMVectorSubtract(target, eye));
        XMVECTOR right  = XMVector3Normalize(XMVector3Cross(fwd, XMVectorSet(0, 1, 0, 0)));
        XMVECTOR up     = XMVector3Cross(right, fwd);

        XMStoreFloat4(&cb.cameraPosition, eye);
        cb.cameraPosition.w = tanf(XMConvertToRadians(48.0f) * 0.5f);
        XMStoreFloat4(&cb.cameraForward, fwd);
        XMStoreFloat4(&cb.cameraRight, right);
        XMStoreFloat4(&cb.cameraUp, up);
        cb.params = XMFLOAT4(t, 0.0f, 0.0f, 0.0f);
    }
};
