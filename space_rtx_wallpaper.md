# Ray Tracing Space Wallpaper (Earth & Satellites RTX)

Este documento contiene la lógica C++ y los shaders HLSL para un fondo de pantalla RTX de temática espacial. La Tierra rota sobre su eje, los satélites la orbitan a velocidades relativas reales (LEO), y la cámara tiene un modo de "deriva cinemática" constante.

## 1. Shader en HLSL (`SpaceRaytracing.hlsl`)

Este shader incluye el cálculo para el material de la Tierra (con un efecto de atmósfera usando Fresnel) y el metal ultrarreflectante de los satélites (paneles solares y chasis). El Sol actúa como una luz direccional de altísima intensidad.

```hlsl
#define MAX_DEPTH 3

struct RayPayload {
    float4 color : SV_Target;
    uint depth   : RayDepth;
};

struct SceneConstantBuffer {
    matrix viewProjectionInv;
    float4 cameraPosition;
    float4 sunDirection;       // Dirección de la luz solar
    float4 earthTransform;     // Rotación y posición de la Tierra
    float4 satellitePos[2];    // Posición de los 2 satélites principales
};

RaytracingAccelerationStructure g_accelStruct : register(t0);
ConstantBuffer<SceneConstantBuffer> g_sceneCB  : register(b0);

// Texturas (Asumiendo que se cargan externamente en el motor)
Texture2D<float4> g_EarthDayMap : register(t1);
Texture2D<float4> g_EarthNightMap : register(t2);
SamplerState g_sampler : register(s0);

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

    // Fondo espacial por defecto (estrellas leves o negro absoluto)
    RayPayload payload = { float4(0.01f, 0.01f, 0.02f, 1.0f), 0 };
    TraceRay(g_accelStruct, RAY_FLAG_NONE, 0xFF, 0, 1, 0, ray, payload);
}

// --- Closest Hit: La Tierra (Atmósfera + Ciclo Día/Noche) ---
[shader("closesthit")]
void EarthClosestHit(inout RayPayload payload, in BuiltInTriangleIntersectionAttributes attribs) {
    if (payload.depth >= MAX_DEPTH) return;

    float3 hitPos = HitWorldPosition();
    float3 N = normalize(HitWorldNormal());
    float3 V = -WorldRayDirection();
    float3 L = normalize(g_sceneCB.sunDirection.xyz);

    // Mapeo UV esférico con rotación aplicada
    float u = 0.5f + atan2(N.z, N.x) / (2.0f * 3.14159f);
    float v = 0.5f - asin(N.y) / 3.14159f;
    
    // Desplazamiento UV basado en la rotación de la Tierra
    u = frac(u + g_sceneCB.earthTransform.w); 

    // Iluminación solar (N dot L)
    float NdotL = dot(N, L);
    float sunIntensity = max(0.0f, NdotL);
    
    // Transición suave entre día y noche (Terminador)
    float dayFactor = smoothstep(-0.2f, 0.2f, NdotL);

    // Color base (Simulando lectura de textura)
    float3 dayColor = float3(0.1f, 0.3f, 0.6f); // Azul terrestre genérico
    float3 nightColor = float3(0.8f, 0.7f, 0.3f) * 2.0f; // Luces de ciudades
    
    float3 finalColor = lerp(nightColor * (1.0f - dayFactor), dayColor * sunIntensity, dayFactor);

    // Efecto de Atmósfera (Rayleigh Scattering simplificado via Fresnel)
    float fresnel = pow(1.0f - max(0.0f, dot(N, V)), 4.0f);
    float3 atmosphereGlow = float3(0.3f, 0.6f, 1.0f) * fresnel * max(0.0f, NdotL + 0.2f) * 1.5f;

    payload.color.rgb = finalColor + atmosphereGlow;
}

// --- Closest Hit: Satélites (Metal y Paneles Solares) ---
[shader("closesthit")]
void SatelliteClosestHit(inout RayPayload payload, in BuiltInTriangleIntersectionAttributes attribs) {
    if (payload.depth >= MAX_DEPTH) return;

    float3 hitPos = HitWorldPosition();
    float3 N = HitWorldNormal();
    float3 V = -WorldRayDirection();

    // Material metálico reflectante
    float R0 = 0.8f; 
    float fresnel = R0 + (1.0f - R0) * pow(1.0f - max(0.0f, dot(N, V)), 5.0f);

    float3 reflectDir = reflect(-V, N);
    RayDesc reflectRay = { hitPos + N * 0.001f, 0.001f, reflectDir, 10000.0f };
    
    RayPayload subPayload = { float4(0, 0, 0, 1), payload.depth + 1 };
    TraceRay(g_accelStruct, RAY_FLAG_NONE, 0xFF, 0, 1, 0, reflectRay, subPayload);

    // El reflejo del sol sobre el satélite y el rebote de luz terrestre
    payload.color.rgb = subPayload.color.rgb * fresnel + float3(0.05f, 0.05f, 0.05f);
}
```

## 2. Lógica Orbital C++ (`SpaceAnimator.cpp`)

Este módulo se encarga de las matemáticas físicas relativas. Los satélites LEO (Low Earth Orbit) completan una vuelta cada ~90 minutos, mientras que la Tierra rota cada 24 horas. Esta relación $16:1$ se mantiene en el escalado del tiempo.

```cpp
#include <directxmath.h>
#include <cmath>

using namespace DirectX;

class SpaceAnimator {
private:
    float m_timeAcc = 0.0f;

    // Escalas de tiempo realistas
    // La cámara se mueve muy lento (deriva cinemática)
    const float CAMERA_SPEED = 0.05f; 
    // La Tierra rota sobre su eje
    const float EARTH_ROT_SPEED = 0.1f; 
    // LEO = 16 órbitas por 1 rotación terrestre
    const float SATELLITE_SPEED = EARTH_ROT_SPEED * 16.0f; 

public:
    void Update(float deltaTime, SceneConstantBuffer& cb) {
        m_timeAcc += deltaTime;

        // 1. Movimiento del Observador (Cámara Cinemática)
        // La cámara orbita lentamente la Tierra subiendo y bajando en el eje Y
        float camX = sinf(m_timeAcc * CAMERA_SPEED) * 20.0f;
        float camY = cosf(m_timeAcc * CAMERA_SPEED * 0.5f) * 5.0f;
        float camZ = cosf(m_timeAcc * CAMERA_SPEED) * 20.0f;
        cb.cameraPosition = XMFLOAT4(camX, camY, camZ, 1.0f);

        // (La matriz viewProjectionInv se calculará con cb.cameraPosition mirando al origen 0,0,0)

        // 2. Rotación de la Tierra (Enviada en el componente W)
        float currentEarthRotation = m_timeAcc * EARTH_ROT_SPEED;
        cb.earthTransform = XMFLOAT4(0.0f, 0.0f, 0.0f, currentEarthRotation);

        // 3. Posiciones de los Satélites (Órbitas elípticas cruzadas)
        // Satélite 1: Órbita ecuatorial/inclinada
        float sat1Radius = 12.0f; // Ligeramente despegado de la Tierra (Radio = 10.0f)
        float sat1Angle = m_timeAcc * SATELLITE_SPEED;
        cb.satellitePos[0] = XMFLOAT4(
            sinf(sat1Angle) * sat1Radius,
            sinf(sat1Angle * 0.5f) * 2.0f, // Ligera inclinación
            cosf(sat1Angle) * sat1Radius,
            1.0f
        );

        // Satélite 2: Órbita polar
        float sat2Radius = 13.5f;
        float sat2Angle = (m_timeAcc * SATELLITE_SPEED) * 0.8f + 3.1415f; // Desfasado y ligeramente más lento
        cb.satellitePos[1] = XMFLOAT4(
            sinf(sat2Angle) * 3.0f, // Poca variación en X
            cosf(sat2Angle) * sat2Radius, // Órbita principalmente en Y (Polar)
            sinf(sat2Angle) * sat2Radius,
            1.0f
        );

        // 4. Luz Solar (Sol lejano y estático en la escena)
        cb.sunDirection = XMFLOAT4(1.0f, 0.2f, -0.5f, 0.0f); // Luz direccional
    }
};
```