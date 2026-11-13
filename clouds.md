# Nubes con volumen: versión híbrida (escena `space`)

> **Estado:** fase **C1 implementada** (`Clouds=layered`, por defecto); C2–C4 pendientes. `Clouds=volumetric` se comporta como `layered` hasta que exista C3.
>
> Especificación. Versión viable en tiempo real de [`2d_to_3d_volumetric_cloud_pipeline.md`](2d_to_3d_volumetric_cloud_pipeline.md): el mismo objetivo, nubes reales con volumen a partir de datos de satélite, pero con el volumen calculado solo donde se ve. Sustituye a la fase 3 de [`relief.md`](relief.md) (nubes con altura), que pasa a ser la capa 2.5D de este documento.

## 1. Por qué híbrida

Desde la órbita, un píxel cubre 5–10 km de suelo y la capa de nubes mide 1–16 km de espesor. Lo que decide si el volumen se ve es el **espesor proyectado en pantalla** de una columna de nubes:

```
espesor_px = H_top · sin(θ) / f
θ = ángulo entre el rayo y la vertical local;  f = huella del píxel en km (distancia · ángulo del píxel)
```

| Zona | θ | Espesor proyectado (H = 10 km, f = 6 km) | ¿Se ve el volumen? |
|---|---|---|---|
| Centro del disco | 0–40° | < 1 px | No: una capa 2D con altura basta |
| Media | 40–65° | 1–1.5 px | Apenas: relieve y sombras sí, volumen no |
| **Limbo** | > 65° | 1.5–3 px, y los rayos recorren cientos de km dentro de la capa | **Sí** |
| **Terminador** (Sol < 8°) | cualquiera | sombras de 70–700 km | **Sí, por las sombras y las cimas iluminadas** |

El pipeline original hace 64 pasos de volumen más 4×64 hacia el Sol en todos los píxeles: ~750 M evaluaciones de densidad por frame, 30–50 ms en la RTX 4060. La versión híbrida usa:

* **capa 2.5D** en todo el planeta: altura, relieve, sombras largas y luz de nube con dispersión múltiple, sin marchar el volumen;
* **volumen real** solo donde el espesor proyectado lo justifica (limbo) y en la silueta sobre el horizonte.

**Presupuesto:** 2–4 ms por frame en total (§9).

## 2. Modos

| `Clouds=` | Qué hace | Coste |
|---|---|---|
| `flat` | **Desactivado**: comportamiento actual, capa plana a 8 km con sombra simple | ~0 |
| `layered` | Capa 2.5D (§5) en todo el planeta | 0.5–1 ms |
| `volumetric` (por defecto tras validar) | `layered` + volumen en el limbo y en la silueta (§6) | 2–4 ms |

## 3. Datos

### 3.1 Mapa del tiempo (*weather map*)

Una textura equirectangular (misma convención de UV que `LatLonUV`) con **`R8G8_UNORM`**, en el slot actual de nubes (t3).

> **Implementación de C1:** la textura sigue siendo `R8` (solo opacidad). La altura se estima **en el shader** (`CloudTopKm`) leyendo la opacidad en un mip 1.5 niveles más grueso, que suaviza las cimas y afila los bordes sin preprocesado en la CPU: `h = 2 + 10·k²` km con `k = smoothstep(0.6, 1, a)`, así que solo los núcleos más densos llegan a 12 km. El canal G se añade con C2. El relieve de las cimas se controla con `CloudRelief` (exageración, 2 por defecto). Las **masas grandes, altas y densas** (cumulonimbos, cúmulos congestus) reciben **cimas de coliflor**: ruido *billow* (|2n − 1| de un ruido suave, 3 octavas de 70, 34 y 16 km, con el dominio deformado) fijo al suelo. Da bultos redondeados de tamaños muy irregulares con pliegues entre ellos. Los bultos **conservan el color de la capa**: solo escalan su brillo (lado al Sol más claro, lado opuesto y pliegues más oscuros) y se mezclan al ~55 % sobre la capa lisa, como textura de la misma nube. Las sombras entre nubes son suaves (±1.5 km) y parciales (45 %, la luz atraviesa la nube), y la luz del cielo sobre las nubes está desaturada para que las partes en sombra se vean grises y no azules. Solo se aplica donde la cima estimada es alta, la nube es opaca y la zona opaca es amplia (un mip 8 veces más grueso); las nubes pequeñas o finas siguen lisas. Cada octava se apaga cuando sus bultos miden menos de ~2 píxeles, así que de lejos no hay parpadeo. Un primer intento con ruido celular (Voronoi) se descartó: dibujaba polígonos, como un caparazón. Coste medido en la RTX 4060 Laptop: de ~34 % a ~37 % de GPU (≈1 ms por frame).

| Canal | Contenido | Origen |
|---|---|---|
| R | Opacidad de nube 0–1 | `clouds-alpha.png` (clouds.matteason.co.uk), cada hora, como hoy |
| G | Altura de la cima, 0–18 km → 0–1 | Fase C1: estimada desde la opacidad. Fase C2: satélite real (§3.2) |

La **base** de la nube no se mide desde arriba: se deduce del tipo, que a su vez se estima a partir de la cima.

| Cima | Tipo | Base | Perfil vertical |
|---|---|---|---|
| < 3 km | estratos / estratocúmulos | 0.5 km | plano, denso abajo |
| 3–7 km | cúmulos / altocúmulos | 1.0 km | redondeado |
| > 7 km | cumulonimbos | 1.5 km | columna densa, yunque ancho arriba |
| cirros (opacidad < 0.4 y cima > 8 km) | cirros | cima − 1.5 km | lámina fina, sin erosión fuerte |

### 3.2 Alturas reales de satélite (fase C2, opcional)

El pipeline original propone sacar la altura del infrarrojo de GOES-16. Hay que corregirlo:

* **GOES-16 se retiró en 2025.** Las fuentes vigentes son GOES-19 (Este) y GOES-18 (Oeste), que solo cubren América y el Pacífico. Para una cobertura global hacen falta además Himawari-9 (Asia–Pacífico) y Meteosat (Europa, África y el océano Índico).
* **No hay que calcular la altura a partir de la temperatura:** GOES publica directamente la **altura de la cima** (producto L2 *ACHA*, `ABI-L2-ACHAF`, disco completo). Himawari tiene un producto equivalente.
* **La normalización min–max del script original no es física:** cambia de una imagen a otra. Si se usa infrarrojo, debe ser temperatura de brillo calibrada.

**Propuesta:** un workflow programado de GitHub Actions (`cloudtop.yml`, cada hora) en este repositorio:

1. descarga el último ACHA de GOES-19 y GOES-18 y la altura de Himawari-9 de los buckets públicos de NOAA en AWS (sin credenciales);
2. reproyecta a equirectangular 4096×2048 y combina las zonas solapadas prefiriendo el satélite con menor ángulo cenital; descarta los píxeles con ángulo cenital > 70°;
3. marca como "sin dato" el hueco de Meteosat, que requiere una cuenta de EUMETSAT y se añade después como mejora;
4. publica `cloudtop/latest.png` (R8; 255 = sin dato) y `cloudtop/latest.json` (hora de las imágenes) en GitHub Pages.

La app lo descarga cada hora con ETag. Donde no hay dato usa la estimación de C1.

**Desfase horario:** el mapa de opacidad y el de alturas pueden diferir hasta 1 h, y las nubes se mueven 30–50 km/h. Por eso la altura solo se aplica donde R indica nube, y se dilata y suaviza 2 texels.

Los nombres de producto, los buckets y la licencia de cada fuente se verifican al implementar. Uso de Actions: gratuito en repos públicos.

### 3.3 Ruido 3D para el detalle

* Textura **3D de 64³ `R8G8_UNORM`**, con Perlin-Worley en R (forma) y Worley de alta frecuencia en G (bordes deshilachados).
* Se **genera en la CPU al arrancar** (< 100 ms, sin descarga) y es periódica en las tres dimensiones.
* Se muestrea en coordenadas **fijas a la Tierra (ECEF)** para que el detalle gire con el mapa y no "nade". Periodo de la forma ≈ 40 km; del detalle ≈ 6 km.
* El renderer solo sube texturas 2D: hace falta soporte de `Texture3D` en `TextureUpload` / `UploadTexture` (§8).

### 3.4 Slots

Con `relief.md` y este documento, las texturas de la escena son:

| Slot | Registro | Contenido |
|---|---|---|
| 0 | t1 | día |
| 1 | t2 | noche |
| 2 | t3 | weather map R8G8 (antes R8) |
| 3 | t4 | relieve (`relief.md`) |
| 4 | t5 | ruido 3D |

Por tanto, `kMaxSceneTextures` pasa a 5 y el root signature declara la tabla t1..t5.

## 4. Luz en las nubes (común a 2.5D y volumen)

El modelo original de dispersión simple con Beer-Lambert produce nubes grises. Desde el espacio las nubes son blancas brillantes por la **dispersión múltiple**. Se usa:

* **Fase:** mezcla de dos Henyey-Greenstein, `0.7·HG(g = 0.8) + 0.3·HG(g = −0.3)`: borde plateado hacia el Sol y retrodispersión suave.
* **Dispersión múltiple por octavas** (aproximación de Hillaire, *Physically Based Sky, Atmosphere and Cloud Rendering in Frostbite*, 2016). Se suman 3 octavas; en la octava *i* la extinción se multiplica por `0.5^i`, la energía por `0.5^i` y la excentricidad de la fase por `0.5^i`.
* **Capa 2.5D (sin marcha):** reflectancia de una lámina con dos flujos, `R = (1−g)·τ / (1 + (1−g)·τ)` con g = 0.85. El espesor óptico sale de la opacidad, `τ = −ln(1 − 0.98·a) · 8`. Con τ = 10, R ≈ 0.6 (cúmulo denso) y con τ = 1, R ≈ 0.13 (velo).
* **Luz del Sol en el punto:**
  * transmitancia de la atmósfera a esa altura (`SunTransmittance`, ya existe), que da el enrojecimiento al atardecer;
  * sombra de la Tierra: test analítico rayo–esfera hacia el Sol. Así las cimas altas siguen iluminadas cuando el suelo ya está de noche: una cima a 12 km ve el Sol hasta 3.5° por debajo del horizonte;
  * sombra del relieve (`relief.md`, fase 2) y de otras nubes (§5.2).
* **Luz ambiente:** cielo azul desde arriba (el `skylight` actual) más rebote del suelo desde abajo (albedo del mapa de día, × 0.3).
* **Noche:** sin Sol, las nubes reciben solo el resplandor de las ciudades de abajo (mapa nocturno × 0.05). Así se ve cómo las nubes tapan y difuminan las luces.

## 5. Capa 2.5D (modo `layered`)

En `EarthClosestHit`, sustituyendo la capa plana actual:

### 5.1 Forma
* Altura de la cima `h(uv)` del canal G y opacidad `a(uv)` del canal R.
* **Normal de la cima** a partir del gradiente de `h` (diferencias centrales, como el relieve), exagerada ×3: los cúmulos y yunques se ven redondeados con su lado iluminado y su lado en sombra.
* **Paralaje:** el punto de la cima visto desde la cámara está desplazado `h·tan(θ)` respecto al suelo. Se corrige la UV de la nube con 2 iteraciones de *parallax mapping*. Así las nubes altas cerca del borde se separan de su sombra.

### 5.2 Sombras largas
* Marcha de 9 muestras hacia el Sol sobre el weather map (`CloudOcclusion`), más una lectura justo encima del punto. Van en dos tramos: 5 repartidas por igual hasta donde llega la sombra de las nubes bajas (2 km, casi todas) y 4 con paso cuadrático hasta el alcance de las torres de 12 km, con tope de 700 km. Cada muestra lee un mip tan grueso como la separación con sus vecinas: no se salta ninguna nube y las sombras lejanas salen con penumbra.
* Una nube a distancia `s` hace sombra si su cima es mayor que `s·tan(e) + s²/(2·RE)`.
* **Estiramiento (`CloudShadowLength`, por defecto 4):** el mapa de nubes tiene texeles de ~5 km. La sombra física de una nube de 2 km mide `2 km / tan(e)`: menos de un texel con el Sol a más de 22°, así que queda escondida bajo la propia nube y solo asoma a pocos grados del terminador. Para que se vea a esta escala, la altura de las nubes sobre el punto sombreado se multiplica por este factor solo al calcular la sombra (la forma y el paralaje de la nube no cambian). `1` = físico; `0` = solo la sombra justo debajo de la nube.
* Se aplica a tres cosas, con distinta fuerza:
  * **suelo:** la luz directa baja hasta un 75 % (la luz del cielo queda);
  * **reflejo del Sol en el mar:** es una imagen especular del Sol, muchas veces más brillante que el blanco, así que una nube en medio lo apaga casi del todo, `(1 − 0.98·occ)³`. Con el 75 % de la sombra difusa seguiría saturado y la sombra no se vería;
  * **bruma del aire (`AIR_SHADOW = 0.5`):** el aire que queda en sombra bajo la nube tampoco dispersa luz del Sol. Aproximadamente la mitad de la luz del aire viene de debajo de las cimas (`1 − exp(−z/HR)` de la columna de Rayleigh y casi toda la calima). Sobre el mar oscuro, casi todo el color es esa bruma: sin esto la sombra sobre el océano no se ve.
* **Opacidad para la sombra (`ShadowOpacity`):** el mapa viene del infrarrojo: el suelo frío se lee como un velo tenue y las nubes bajas y cálidas como medio transparentes. Para la sombra se usa `smoothstep(0.08, 0.6, opacidad)`: el velo casi no oscurece y cualquier nube claramente visible tapa casi toda la luz directa.
* También da sombra sobre las cimas de otras nubes (una torre sobre la capa baja de al lado), hasta un 45 %, **sin estirar** y con transición ancha (3 km): las alturas son estimadas, y estiradas o con transición estrecha dibujan manchas grises de bordes duros sobre las capas.

### 5.3 Composición
`color = mezcla(suelo · sombra_nubes, luz_nube, a)`. La luz de la nube es la de §4 con la normal de la cima. Las luces nocturnas se atenúan con `exp(−τ)`, como hoy.

## 6. Volumen (modo `volumetric`)

### 6.1 Dónde
En `RayGen`, para el rayo primario:

1. intersección analítica con la cáscara de nubes `[RE + 0.5 km, RE + 16 km]`, que da el segmento `[t0, t1]`. Si el rayo da en la Tierra, `t1 = min(t1, hitT)`, con `hitT` nuevo en `RayPayload`;
2. peso del volumen `w = smoothstep(1.5, 3.0, 16 km · sin(θ) / f)`;
3. los rayos que **no** tocan la Tierra pero cruzan la cáscara sobre el horizonte siempre usan volumen (`w = 1`): es la silueta de las nubes en el limbo;
4. si `w = 0`, nada que hacer: la capa 2.5D ya pintó las nubes. Si `w > 0`, se pasa `w` en el payload para que `EarthClosestHit` atenúe su capa 2.5D por `1 − w` y no se pinten dos veces.

### 6.2 Densidad
```
ρ(P) = cobertura(uv) · perfil(h_rel, tipo) − erosión
erosión = ruido3D.R(P/40 km) · 0.6 · (1 − h_rel)  +  ruido3D.G(P/6 km) · 0.25 · h_rel
```
* `h_rel` es la altura relativa entre la base y la cima de esa columna (§3.1), y `perfil` es la curva del tipo de nube.
* **Saltar el vacío:** se lee primero la opacidad en un mip grueso. Si es < 0.02, se avanza el doble de paso sin evaluar ruido.

### 6.3 Marcha
* **Pasos:** `N = clamp(ceil(4 · espesor_px), 6, 32)`, distribuidos uniformemente en el segmento.
* **Desfase por píxel:** ruido de gradiente intercalado fijo, no animado, para cambiar bandas por grano fino. No hay historial temporal; una TAA sería una mejora posterior, fuera de alcance.
* **Luz por paso:**
  * 3 pasos cortos hacia el Sol, a 0.5, 2 y 6 km (autosombra cercana);
  * más allá, la sombra de largo alcance de la capa 2.5D (§5.2) evaluada a la altura del punto (1 consulta);
  * dispersión múltiple por octavas (§4).
* **Salida temprana** con transmitancia < 0.02.

### 6.4 Composición con la atmósfera
```
color_final = inscatter(cámara → nube) + T_atm(cámara → nube) · (luz_nube + T_nube · color_detrás)
```
`color_detrás` es lo que devolvió `TraceRadiance`: el suelo (con su 2.5D atenuada por `1 − w`) o el cielo. La dispersión de la atmósfera entre la cámara y la nube se calcula con la función `Atmosphere` hasta `t_nube`, la distancia ponderada por densidad.

## 7. Configuración (`[Space]`)

```ini
Clouds=volumetric         ; flat | layered | volumetric
CloudTopSource=estimate   ; estimate (desde la opacidad) | satellite (fase C2, §3.2)
CloudSteps=32             ; máximo de pasos del volumen (6–64)
CloudDetail=1             ; erosión con ruido 3D (0 = formas suaves, más barato)
CloudRelief=2             ; exageración del relieve de las cimas en layered (0 = sin relieve)
CloudDebug=0              ; 1 = colorea el peso del volumen w (rojo) sobre la imagen
```

**Desactivar:** con `Clouds=flat` la escena queda **exactamente como hoy**: no se genera el ruido 3D, no se descarga `cloudtop/latest.png`, el weather map vuelve a ser solo la opacidad y el shader se salta la capa 2.5D y el volumen con una sola comprobación de `cloudInfo`. `Clouds=layered` apaga solo el volumen y `CloudTopSource=estimate` evita las descargas de la fase C2. Si el mapa de nubes no está disponible (`Offline=1` o falla de red), las nubes se desactivan como hoy, en cualquier modo.

## 8. Cambios por archivo

| Archivo | Cambio |
|---|---|
| `src/main.cpp` | `UploadTexture` con `Texture3D`; tabla t1..t5; claves nuevas en el .ini por defecto |
| `src/scenes/Scene.hpp` | `TextureUpload` con `depth` y dimensión; `kMaxSceneTextures = 5` |
| `src/scenes/SpaceScene.hpp` | Weather map R8G8 (opacidad + altura estimada o de satélite); generación del ruido 3D; `cloudInfo` en `Constants`; descarga horaria de `cloudtop/latest.png` (C2); carga del .ini |
| `src/space/Noise3D.hpp` | Nuevo: Perlin-Worley periódico 64³ en CPU |
| `src/shaders/Space.hlsl` | `g_noise3d : register(t5)`; capa 2.5D (§5); volumen en `RayGen` (§6); `hitT` y `cloudWeight` en `RayPayload` |
| `src/shaders/Common.hlsli` | Intersección rayo–cáscara esférica y Henyey-Greenstein (reutilizables) |
| `scripts/cloudtop.py`, `.github/workflows/cloudtop.yml` | Fase C2: mosaico global horario de altura de cimas |
| `tests/astro_test.cpp` | Pruebas numéricas (§10) |
| `README.md`, `docs/space_rtx_wallpaper.template.md`, `config/RTWallpaper.ini` | Documentación, configuración y créditos (NOAA GOES, JMA Himawari) |

El tamaño de `RayPayload` crece 8 bytes; hay que actualizar el `MaxPayloadSize` de la escena.

## 9. Coste estimado

RTX 4060 Laptop, 2560×1440 + 1920×1080 a 30 FPS. Hoy la escena usa ~35 % de GPU (~11 ms de GPU por frame).

| Parte | Píxeles afectados | Coste |
|---|---|---|
| Capa 2.5D: forma, paralaje, sombras de 9 muestras | Tierra visible (~3.5 M) | 0.5–1 ms |
| Volumen en el limbo y la silueta | ~10–20 % (0.4–0.7 M) × ~20 pasos × (1 + 3 de luz en los que tienen nube) | 1.5–3 ms |
| **Total** | | **2–4 ms** |
| Con `relief.md` (fases 1–2) | | +1–2 ms |

**Criterio de aceptación:** con relieve y nubes `volumetric`, ≤ 50 % de GPU y 30 FPS estables en los dos monitores.

**Si no se cumple, en orden:**
1. `CloudSteps=16`;
2. `CloudDetail=0`;
3. volumen a media resolución con composición bilineal sensible a la profundidad: requiere una segunda pasada y una textura intermedia;
4. bajar a `layered`.

Opcional: medir el tiempo de GPU con *timestamp queries* y reducir `CloudSteps` automáticamente si el frame se pasa del presupuesto.

## 10. Verificación

**Pruebas numéricas** (CPU):

* cuerda de la cáscara de 0.5–16 km para un rayo tangente al suelo: `≈ √(2·RE·16) = 451 km` hasta el borde exterior;
* espesor proyectado: H = 10 km, f = 6 km, θ = 70° → 1.57 px (umbral del volumen);
* reflectancia de dos flujos: τ = 10 → 0.60; τ = 1 → 0.13 (g = 0.85);
* una cima a 12 km ve el Sol hasta −3.5°; una a 2 km, hasta −1.4°;
* el ruido 3D es periódico: las caras opuestas coinciden.

**Pruebas visuales** (con `TimeOffsetHours` y comparando con fotos de la ISS):

* limbo: silueta irregular de cúmulos y yunques sobre la línea azul de la atmósfera, sin un borde liso;
* terminador: cimas de cumulonimbos rosadas y anaranjadas sobre suelo ya oscuro, y sombras de cientos de km;
* noche: nubes difuminando las luces de las ciudades;
* `CloudDebug=1`: el volumen solo se activa en el limbo, sin costuras visibles entre 2.5D y volumen;
* nada "nada" ni parpadea con la cámara en movimiento (ruido en ECEF y desfase fijo).

## 11. Fases de implementación

| Fase | Contenido | Depende de |
|---|---|---|
| C1 | Weather map R8G8 con altura estimada + capa 2.5D completa (§5) | `relief.md` fase 2 (opcional, para sombras del terreno) |
| C2 | Alturas reales: workflow horario + descarga | C1 |
| C3 | Volumen en el limbo y la silueta (§6) + ruido 3D + `Texture3D` en el renderer | C1 |
| C4 (opcional) | Relámpagos: densidad de destellos de GOES GLM (últimos 10 min) iluminando el interior de las nubes de noche. Solo América | C2, C3 |

## 12. Riesgos

* **Estimar la altura desde la opacidad:** una niebla densa parece un cumulonimbo. Se mitiga con la fase C2 y una curva conservadora.
* **Costura entre 2.5D y volumen:** ambos usan la misma forma y la misma luz (§4), y `w` mezcla suavemente. Se valida con `CloudDebug`.
* **Grano sin TAA:** con N ≥ 8 y el desfase fijo es un grano fino estable. Si molesta, se añade TAA, que requiere historial y reproyección.
* **Datos de terceros:** cambios de formato o de URL en NOAA o JMA. Si fallan, el workflow publica el último mapa válido y la app vuelve a la estimación.
* **Coste en GPUs menores:** la degradación automática (§9) y `Clouds=layered` como alternativa.
