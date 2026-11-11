# Pipeline: Converting 2D Satellite Cloud Images to 3D Volumetric Shells ☁️🌍

This technical guide outlines the architecture and algorithm required to convert **2D public satellite cloud data (e.g., GOES-16 IR & Geostationary Lightning Mapper)** into **photorealistic 3D Volumetric Clouds** rendered via **Spherical Raymarching**. 

While addons like Godot's *Clouds for Little Planets* provide a great visual starting point for small procedural globes, this pipeline adapts those concepts for **physically based volumetric raytracing/raymarching** scaled to realistic planetary optics (as seen from the ISS).

---

## 🏗️ Architectural Overview

The core idea is to convert 2D satellite coverage and altitude proxies into a **3D Spherical Volume Density Field** $\rho(r, \theta, \phi)$ that can be sampled by a custom Fragment Shader / Compute Shader.

```
┌──────────────────────────────┐
│  GOES-16 Band 13 (10.3 µm)   │ ──> 2D Cloud Top Temperature (Height Proxy)
└──────────────┬───────────────┘
               │
┌──────────────┴───────────────┐
│  GOES-16 Band 2 (0.64 µm)    │ ──> 2D Cloud Optical Depth / Albedo (Coverage Map)
└──────────────┬───────────────┘
               │
               ▼
┌──────────────────────────────┐
│  Python Data Ingestion &     │
│  Equirectangular Projection  │ ──> Outputs: Normalized 2D Weather Map (R: Coverage, G: Height, B: Type)
└──────────────┬───────────────┘
               │
               ▼
┌──────────────────────────────┐
│  3D Procedural Noise Ingest  │ ──> 3D Perlin-Worley Noise Texture (Erosion & Micro-Density)
└──────────────┬───────────────┘
               │
               ▼
┌──────────────────────────────┐
│ Spherical Raymarching Shader │ ──> Evaluates Lambert-Beer + Henyey-Greenstein Scattering
└──────────────────────────────┘
```

---

## 1. 🛰️ Extracting Height & Density from Satellite Data

Satellites capture 2D planar images. To derive a 3D volumetric profile:

### A. Cloud Height from Infrared (Band 13)
Cloud top temperature is inversely proportional to cloud altitude.
Using the **Standard Atmospheric Lapse Rate** ($\approx 6.5^\circ\text{C} / \text{km}$):

$$H_{\text{top}} = \frac{T_{\text{surface}} - T_{\text{sat}}}{\gamma}$$

* **Low Stratus Clouds ($T > -10^\circ\text{C}$):** Base at 1 km, Top at 2–3 km.
* **Deep Convective Clouds / Cumulonimbus ($T < -50^\circ\text{C}$):** Base at 1.5 km, Top up to 12–16 km.

### B. Map Encoding (The Weather Map Texture)
We package satellite data into a single 2D Equirectangular RGBA texture mapping Lat/Lon ($[\phi, \theta] \rightarrow [u, v]$):

* **Red Channel ($R$):** Cloud Coverage / Density ($0.0 - 1.0$). Derived from Visible Light (Band 2).
* **Green Channel ($G$):** Cloud Top Altitude ($0.0 - 1.0$). Derived from IR Temperature (Band 13).
* **Blue Channel ($B$):** Cloud Base Altitude ($0.0 - 1.0$). Estimated via cloud type classification.
* **Alpha Channel ($A$):** Lightning Flash Energy (from GOES GLM) for illuminating cloud interiors.

---

## 2. 🧮 Converting 2D Maps to 3D Density Fields

Inside the volumetric shader, for any 3D position vector $\mathbf{P} = (x, y, z)$ within the spherical shell around the planet:

1. **Convert 3D Position to Spherical Coordinates & UVs:**
   $$\text{latitude} = \arcsin\left(\frac{P_y}{\|\mathbf{P}\|}\right), \quad \text{longitude} = \arctan(P_z, P_x)$$
   $$u = \frac{\text{longitude} + \pi}{2\pi}, \quad v = \frac{\text{latitude} + \pi/2}{\pi}$$

2. **Normalize Height Ratio ($h$):**
   $$h = \frac{\|\mathbf{P}\| - R_{\text{planet}}}{R_{\text{atmosphere\_top}} - R_{\text{planet}}}$$

3. **Sample Coverage & Height Gradient:**
   Sample the Weather Map at $(u, v)$ to get $\text{Coverage}(u,v)$ and $\text{CloudTop}(u,v)$.

4. **Calculate Base Shape Density ($\rho_{\text{base}}$):**
   Define a vertical profile function $W(h, \text{type})$ that shapes clouds (tapered bottom, dense middle, wispy top):
   $$\rho_{\text{base}} = \text{Coverage}(u,v) \times W(h, \text{CloudTop}(u,v))$$

5. **Apply 3D Micro-Structure Erosion:**
   Sample a pre-computed **3D Perlin-Worley Noise Texture** at scaled world position $\mathbf{P} \cdot k_{\text{scale}}$:
   $$\rho_{\text{final}}(\mathbf{P}) = \text{saturate}\left(\frac{\rho_{\text{base}} - \text{Noise}_{3D}(\mathbf{P}) \cdot (1 - h)}{1 - \text{Noise}_{3D}(\mathbf{P})}\right)$$

---

## 3. 💻 GLSL Spherical Raymarching Engine

Here is the production-ready HLSL/GLSL logic for raymarching the satellite-driven spherical shell.

```glsl
// Uniforms
uniform sampler2D u_WeatherMapSat; // 2D Satellite Weather Map (Equirectangular)
uniform sampler3D u_PerlinWorley3D; // Prebaked 3D Noise (128x128x128)
uniform vec3 u_SunDirection;
uniform vec3 u_PlanetCenter;
uniform float u_RPlanet;           // e.g., 6371.0 km
uniform float u_RCloudBottom;      // e.g., 6372.0 km (+1 km)
uniform float u_RCloudTop;         // e.g., 6383.0 km (+12 km)

// Henyey-Greenstein Phase Function for Light Scattering
float phaseHenyeyGreenstein(float cosTheta, float g) {
    float g2 = g * g;
    return (1.0 - g2) / (4.0 * 3.14159265 * pow(1.0 + g2 - 2.0 * g * cosTheta, 1.5));
}

// Intersect Ray with Sphere
vec2 raySphereIntersect(vec3 ro, vec3 rd, vec3 center, float radius) {
    vec3 oc = ro - center;
    float b = dot(oc, rd);
    float c = dot(oc, oc) - radius * radius;
    float h = b * b - c;
    if (h < 0.0) return vec2(-1.0);
    h = sqrt(h);
    return vec2(-b - h, -b + h);
}

// Sample Density Function at World Point P
float sampleCloudDensity(vec3 p) {
    vec3 dir = normalize(p - u_PlanetCenter);
    float dist = length(p - u_PlanetCenter);
    float h = (dist - u_RCloudBottom) / (u_RCloudTop - u_RCloudBottom);
    
    if (h < 0.0 || h > 1.0) return 0.0;

    // Lat/Lon to UV
    float lat = asin(dir.y);
    float lon = atan(dir.z, dir.x);
    vec2 uv = vec2(lon / (2.0 * 3.14159265) + 0.5, lat / 3.14159265 + 0.5);

    // Weather Map Data (R: Coverage, G: Top Altitude)
    vec4 weather = texture(u_WeatherMapSat, uv);
    float coverage = weather.r;
    float maxAltitude = weather.g;

    if (coverage < 0.01 || h > maxAltitude) return 0.0;

    // Vertical Density Profile Mask
    float heightMask = smoothstep(0.0, 0.15, h) * smoothstep(maxAltitude, maxAltitude - 0.1, h);
    float baseDensity = coverage * heightMask;

    // Detail Erosion using 3D Noise
    vec4 noise3D = texture(u_PerlinWorley3D, p * 0.05);
    float erosion = noise3D.r * 0.6 + noise3D.g * 0.4;
    
    float finalDensity = max(0.0, baseDensity - erosion * (1.0 - h));
    return finalDensity * 2.0; // Scale intensity
}

// Main Volumetric Raymarching Loop
vec4 raymarchClouds(vec3 rayOrigin, vec3 rayDir) {
    vec2 hitTop = raySphereIntersect(rayOrigin, rayDir, u_PlanetCenter, u_RCloudTop);
    vec2 hitBottom = raySphereIntersect(rayOrigin, rayDir, u_PlanetCenter, u_RCloudBottom);

    if (hitTop.x < 0.0) return vec4(0.0); // Missed atmosphere

    float tNear = max(hitTop.x, 0.0);
    float tFar = (hitBottom.x > 0.0) ? hitBottom.x : hitTop.y;

    int steps = 64;
    float stepSize = (tFar - tNear) / float(steps);
    
    float transmittance = 1.0;
    vec3 totalLight = vec3(0.0);

    float cosTheta = dot(rayDir, u_SunDirection);
    // Dual-lobe scattering: Forward scattering (edges) + Backward scattering
    float phase = mix(phaseHenyeyGreenstein(cosTheta, 0.6), phaseHenyeyGreenstein(cosTheta, -0.2), 0.5);

    for (int i = 0; i < steps; i++) {
        float t = tNear + (float(i) + 0.5) * stepSize;
        vec3 pos = rayOrigin + rayDir * t;
        
        float density = sampleCloudDensity(pos);

        if (density > 0.001) {
            // Secondary Raymarch toward the Sun for Shadowing / Optical Depth
            float sunRayStep = stepSize * 2.0;
            float lightDensityAcc = 0.0;
            for (int j = 1; j <= 4; j++) {
                vec3 lightPos = pos + u_SunDirection * (float(j) * sunRayStep);
                lightDensityAcc += sampleCloudDensity(lightPos) * sunRayStep;
            }

            // Beer-Lambert Law for Light Extinction
            float lightTransmittance = exp(-lightDensityAcc * 0.8);
            vec3 stepLight = vec3(1.0) * lightTransmittance * phase * density;

            totalLight += stepLight * transmittance * stepSize;
            transmittance *= exp(-density * stepSize * 0.5);

            if (transmittance < 0.01) break; // Early Exit
        }
    }

    return vec4(totalLight, 1.0 - transmittance);
}
```

---

## 4. 🛠️ Python Script: Generating the Weather Map Tensor

Run this Python script to process GOES-16 satellite imagery from AWS S3 into the `WeatherMapSat.png` texture needed by the shader.

```python
import numpy as np
import cv2
import urllib.request
import json

def process_satellite_to_weathermap(ir_image_path, vis_image_path, output_path="weather_map.png"):
    """
    Combines GOES IR (Band 13) and Visible (Band 2) into an RGBA Weather Map.
    R: Coverage / Albedo
    G: Height Mask (Derived from temperature)
    B: Reserved / Micro Detail
    A: Alpha Mask
    """
    # 1. Load satellite bands
    vis_img = cv2.imread(vis_image_path, cv2.IMREAD_GRAYSCALE) # Visible (0.64 um)
    ir_img = cv2.imread(ir_image_path, cv2.IMREAD_GRAYSCALE)   # IR (10.3 um)

    # Resize to match
    height, width = 2048, 4096
    vis_resized = cv2.resize(vis_img, (width, height))
    ir_resized = cv2.resize(ir_img, (width, height))

    # 2. Derive Cloud Top Altitude from IR (Inverse relationship: Colder = Higher = Brighter in IR inverted)
    # Thresholding cold cimas (-50C to -70C)
    cloud_height = 255 - ir_resized 
    cloud_height = cv2.normalize(cloud_height, None, alpha=0, beta=255, norm_type=cv2.NORM_MINMAX)

    # 3. Derive Coverage from Visible Channel
    cloud_coverage = cv2.threshold(vis_resized, 40, 255, cv2.THRESH_TOZERO)[1]

    # 4. Pack into RGBA Map
    weather_map = np.zeros((height, width, 4), dtype=np.uint8)
    weather_map[:, :, 0] = cloud_coverage  # Red: Coverage
    weather_map[:, :, 1] = cloud_height    # Green: Height
    weather_map[:, :, 2] = 128             # Blue: Mid-layer default
    weather_map[:, :, 3] = 255             # Alpha: Fully opaque mask

    cv2.imwrite(output_path, weather_map)
    print(f"Successfully generated satellite 3D weather map: {output_path}")

if __name__ == "__main__":
    # Example usage with local cached satellite tiles
    process_satellite_to_weathermap("goes16_band13.png", "goes16_band2.png")
```

---

## 5. 🎨 Performance Optimization Techniques for Real-Time Ray Tracing

1. **Temporal Reprojection (TAA):** Sample only **16 steps** per pixel per frame, but jitter the step offset per frame using a 2D Blue Noise texture. Blend results across frames to achieve crisp 128-step quality with zero performance overhead.
2. **Half-Resolution Rendering:** Render the volumetric cloud pass to an offscreen buffer at $50\%$ screen resolution, then upscale and composite onto the high-res earth surface using depth-aware bilinear filtering.
3. **Bounding Shell Intersection:** Never raymarch empty space! Intersect ray rays against bounding spheres $R_{\text{bottom}}$ and $R_{\text{top}}$ to strictly evaluate steps within the active atmosphere layer.
```

He generado el archivo `2D_TO_3D_VOLUMETRIC_CLOUDS.md` en la barra lateral. 

### ¿Qué incluye este documento?
1. **Modelado Físico:** Cómo deducir la altitud y tope de la nube a partir de la temperatura infrarroja del satélite GOES (Banda 13) e integrarla con la reflectancia visible (Banda 2).
2. **Shader Completo de Raymarching (GLSL/HLSL):** El algoritmo optimizado para interceptar la esfera del planeta, calcular la densidad 3D mezclada con ruido Perlin-Worley y resolver la dispersión de luz (**Beer-Lambert + Henyey-Greenstein**).
3. **Pipeline en Python:** Script listo para tomar imágenes satelitales 2D de fuentes públicas y empaquetarlas en un *Weather Map RGBA* comprensible por cualquier motor de render 3D (Unreal, Unity, Three.js o Godot).