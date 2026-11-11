# Ray Tracing Windows Desktop Wallpaper (DXR + C++ Native)

Este documento contiene la arquitectura completa, el shader HLSL y el código en C++ optimizado con ruido Simplex (**FastNoiseLite**) para crear un fondo de pantalla con **Ray Tracing nativo en tiempo real** incrustado a través de **Lively Wallpaper**.

---

## 1. Shader en HLSL (`ProceduralRaytracing.hlsl`)

Este shader implementa el suelo de mármol negro reflectante (con reflexión Fresnel y deconstrucción de albedo) y 3 esferas de cuarzo refractivo que flotan interactivamente impulsadas por las coordenadas calculadas en CPU.

```hlsl
#define MAX_DEPTH 3

struct RayPayload {
    float4 color : SV_Target;
    uint depth   : RayDepth;
};

struct SceneConstantBuffer {
    matrix viewProjectionInv;
    float4 cameraPosition;
    float4 spherePositions[3];
    float4 lightPositions[2];
    float4 lightColors[2];
};

RaytracingAccelerationStructure g_accelStruct : register(t0);
ConstantBuffer<SceneConstantBuffer> g_sceneCB  : register(b0);

// --- Ray Generation Shader ---
[shader("raygeneration")]
void RayGen() {
    uint2 dispatchIdx = DispatchRaysIndex().xy;
    uint2 dispatchDim = DispatchRaysDimensions().xy;

    float2 d = (((dispatchIdx.xy + 0.5f) / dispatchDim.xy) * 2.0f - 1.0f);
    d.y = -d.y;

    RayDesc ray;
    ray.Origin = g_sceneCB.cameraPosition.xyz;
    float4 target = mul(g_sceneCB.viewProjectionInv, float4(d, 1.0f, 1.0f));
    ray.Direction = normalize(target.xyz / target.w - ray.Origin);
    ray.TMin = 0.001f;
    ray.TMax = 10000.0f;

    RayPayload payload = { float4(0, 0, 0, 1), 0 };
    TraceRay(g_accelStruct, RAY_FLAG_NONE, 0xFF, 0, 1, 0, ray, payload);

    // Salida de renderizado
}

// --- Closest Hit: Piso de Mármol Negro (Reflexión Fresnel + Roughness) ---
[shader("closesthit")]
void FloorClosestHit(inout RayPayload payload, in BuiltInTriangleIntersectionAttributes attribs) {
    if (payload.depth >= MAX_DEPTH) return;

    float3 hitPos = HitWorldPosition();
    float3 N = float3(0, 1, 0); // Normal del plano horizontal
    float3 V = -WorldRayDirection();

    // Patrón procedimental para veteado de mármol
    float marblePattern = sin(hitPos.x * 2.0f + sin(hitPos.z * 2.0f)) * 0.5f + 0.5f;
    float3 albedo = lerp(float3(0.01f, 0.01f, 0.01f), float3(0.12f, 0.12f, 0.14f), marblePattern);

    // Reflexión Fresnel (Espejado)
    float R0 = 0.05f; 
    float fresnel = R0 + (1.0f - R0) * pow(1.0f - max(0.0f, dot(N, V)), 5.0f);

    float3 reflectDir = reflect(-V, N);
    RayDesc reflectRay = { hitPos + N * 0.001f, 0.001f, reflectDir, 10000.0f };
    
    RayPayload subPayload = { float4(0, 0, 0, 1), payload.depth + 1 };
    TraceRay(g_accelStruct, RAY_FLAG_NONE, 0xFF, 0, 1, 0, reflectRay, subPayload);

    // Cálculo de Iluminación Directa desde neón
    float3 directLight = float3(0, 0, 0);
    for (int i = 0; i < 2; i++) {
        float3 L = normalize(g_sceneCB.lightPositions[i].xyz - hitPos);
        float dist = length(g_sceneCB.lightPositions[i].xyz - hitPos);
        float atten = 1.0f / (1.0f + 0.1f * dist + 0.05f * dist * dist);
        directLight += albedo * g_sceneCB.lightColors[i].rgb * max(0.0f, dot(N, L)) * atten;
    }

    payload.color.rgb = directLight + subPayload.color.rgb * fresnel;
}

// --- Closest Hit: Esferas de Cuarzo/Vidrio (Refracción Ley de Snell) ---
[shader("closesthit")]
void QuartzClosestHit(inout RayPayload payload, in BuiltInTriangleIntersectionAttributes attribs) {
    if (payload.depth >= MAX_DEPTH) return;

    float3 hitPos = HitWorldPosition();
    float3 N = HitWorldNormal();
    float3 V = WorldRayDirection();

    float ior = 1.52f; // Índice de Refracción (Cuarzo)
    float eta = (dot(V, N) < 0) ? (1.0f / ior) : ior;
    float3 refrNormal = (dot(V, N) < 0) ? N : -N;

    float3 refractDir = refract(V, refrNormal, eta);

    RayDesc refractRay = { hitPos + refractDir * 0.001f, 0.001f, refractDir, 10000.0f };
    RayPayload subPayload = { float4(0, 0, 0, 1), payload.depth + 1 };
    TraceRay(g_accelStruct, RAY_FLAG_NONE, 0xFF, 0, 1, 0, refractRay, subPayload);

    payload.color.rgb = subPayload.color.rgb;
}
```

---

## 2. Lógica de Movimiento Aleatorio C++ (`SceneAnimator.cpp`)

Utilizando la librería ligera header-only **FastNoiseLite**, este módulo calcula trayectorias orgánicas e impredecibles sin patrones repetitivos a 60 FPS:

```cpp
#include "FastNoiseLite.h"
#include <directxmath.h>

using namespace DirectX;

class SceneAnimator {
private:
    FastNoiseLite m_noiseX;
    FastNoiseLite m_noiseY;
    FastNoiseLite m_noiseZ;
    float m_timeAcc = 0.0f;

public:
    SceneAnimator() {
        m_noiseX.SetNoiseType(FastNoiseLite::NoiseType_OpenSimplex2);
        m_noiseY.SetNoiseType(FastNoiseLite::NoiseType_OpenSimplex2);
        m_noiseZ.SetNoiseType(FastNoiseLite::NoiseType_OpenSimplex2);

        m_noiseX.SetSeed(1337);
        m_noiseY.SetSeed(4242);
        m_noiseZ.SetSeed(9999);

        m_noiseX.SetFrequency(0.15f);
        m_noiseY.SetFrequency(0.15f);
        m_noiseZ.SetFrequency(0.15f);
    }

    void Update(float deltaTime, SceneConstantBuffer& cb) {
        m_timeAcc += deltaTime;

        // Movimiento procedural independiente para cada una de las 3 esferas
        for (int i = 0; i < 3; i++) {
            float offset = i * 100.0f;
            
            float x = m_noiseX.GetNoise(m_timeAcc + offset, 0.0f) * 4.0f;
            float y = 1.2f + fabsf(m_noiseY.GetNoise(m_timeAcc + offset, 50.0f)) * 2.0f; // Flotación sobre el piso
            float z = m_noiseZ.GetNoise(m_timeAcc + offset, 100.0f) * 3.0f;

            cb.spherePositions[i] = XMFLOAT4(x, y, z, 1.0f); // Radio = 1.0
        }

        // Posiciones de las fuentes de luz de neón (Azul Cobalto y Ámbar Warm)
        cb.lightPositions[0] = XMFLOAT4(-5.0f, 4.0f, sinf(m_timeAcc * 0.5f) * 3.0f, 1.0f);
        cb.lightPositions[1] = XMFLOAT4(5.0f, 4.0f, cosf(m_timeAcc * 0.5f) * 3.0f, 1.0f);

        cb.lightColors[0] = XMFLOAT4(0.0f, 0.4f, 1.0f, 10.0f); // Azul Cobalto
        cb.lightColors[1] = XMFLOAT4(1.0f, 0.5f, 0.0f, 10.0f); // Ámbar Warm
    }
};
```

---

## 3. Instrucciones de Compilación y Despliegue

1. **Clonar repositorio base:** Descarga el repositorio de ejemplos oficiales [DirectX-Graphics-Samples en GitHub](https://github.com/microsoft/DirectX-Graphics-Samples).
2. **Reemplazar Shaders y Código:** Abre el proyecto `D3D12RaytracingProceduralGeometry` en Visual Studio e integra el shader HLSL y la clase C++ anteriores.
3. **Compilar en Release:** Selecciona la configuración **Release / x64** en Visual Studio para construir la versión final optimizada. Se generará un ejecutable nativo (`.exe`).
4. **Incrustar con Lively Wallpaper:** 
   * Descarga e instala **Lively Wallpaper**.
   * Haz clic en **Add Wallpaper** $\rightarrow$ **Browse** y selecciona el ejecutable `.exe` compilado.
   * Ajusta la regla de reproducción a **Pause** cuando ejecutes aplicaciones o juegos en pantalla completa para mantener el uso de GPU en 0%.