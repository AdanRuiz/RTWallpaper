# ISS-TLE-Predictor ⚡🛰️

**Open-source pipeline to forecast and calculate the probability of Transient Luminous Events (TLEs) — Sprites & Giant Jets — visible from the International Space Station (ISS).**

---

## 📌 Overview

**ISS-TLE-Predictor** is an open-source Python tool designed to compute real-time probability maps of Upper Atmospheric Lightning (Sprites, Elves, and Giant Jets) over targeted regions (e.g., Mexico, Central America, and the US) and intersect them with the **Line of Sight (LoS)** of the **International Space Station (ISS)**.

By leveraging public satellite feeds, space tracking APIs, and open lightning networks, this project aims to assist astrophotographers, space enthusiasts, and researchers in identifying optimal windows to observe atmospheric electrical phenomena from orbit.

---

## 🔬 How It Works

The prediction algorithm relies on a 3-stage physics-based pipeline:

```
┌─────────────────────────┐     ┌────────────────────────┐     ┌────────────────────────┐
│   GOES-16 / GOES-19 S3  │     │   ISS Orbital TLEs     │     │ Open Lightning Feeds   │
│ (Cloud Tops < -70°C &   │     │  (CelesTrak / SGP4)    │     │  (WWLLN / GLM Optical) │
│ Stratiform Radar Cloud) │     └───────────┬────────────┘     └───────────┬────────────┘
└────────────┬────────────┘                 │                              │
             │                              │                              │
             └───────────────────┐          │          ┌───────────────────┘
                                 ▼          ▼          ▼
                             ┌────────────────────────────┐
                             │    ISS-TLE Core Engine     │
                             │  (Spatial-Temporal Match)  │
                             └──────────────┬─────────────┘
                                            │
                                            ▼
                             ┌────────────────────────────┐
                             │   Probability & Visibility │
                             │        Heatmap Output      │
                             └────────────────────────────┘
```

1. **Mesoscale Convective System (MCS) Isolation:** Pulls real-time Band 13 Infrared ($10.3\,\mu\text{m}$) data from **GOES-16/19** via AWS Open Data. It filters for cloud tops colder than $-70^\circ\text{C}$ to locate mature storm shields.
2. **Charge Discharge Validation:** Cross-references lightning flashes ($+CG$ peak current and optical flash density) within the stratiform region of the storm.
3. **ISS Line of Sight (LoS) Geometry:** Propagates ISS orbits using `SGP4` and TLE vectors to compute whether the station has an unobstructed oblique angle (typically 300–1500 km range) over the storm cell during dark-sky conditions.

---

## 🌐 Public Data Sources Used

This project relies **100% on free, open-access public data**:

| Data Source | Provider | Purpose | API / Protocol |
| :--- | :--- | :--- | :--- |
| **GOES-16 / GOES-19** | NOAA / AWS S3 | IR Cloud Top Temperatures & GLM Lightning Flashes | S3 Protocol (`noaa-goes16`) |
| **NORAD TLEs** | CelesTrak / Space-Track | Real-time ISS orbital parameters | REST API / Plaintext TLE |
| **WWLLN / Open Lightning** | UW / Open Feeds | High-peak positive Cloud-to-Ground ($+CG$) strikes | HTTP / CSV Feed |
| **NEXRAD MRMS** | NOAA Open Data | Stratiform vs Convective region separation | Google Cloud / AWS S3 |

---

## 🛠️ Installation & Setup

### Prerequisites
* Python 3.9+
* GDAL / GEOS libraries (for spatial operations)

### Installation

1. **Clone the repository:**
   ```bash
   git clone https://github.com/your-username/ISS-TLE-Predictor.git
   cd ISS-TLE-Predictor
   ```

2. **Create a virtual environment:**
   ```bash
   python -m venv venv
   source venv/bin/activate  # On Windows: venv\Scripts\activate
   ```

3. **Install dependencies:**
   ```bash
   pip install -r requirements.txt
   ```

---

## 📁 Repository Structure

```text
ISS-TLE-Predictor/
├── config/
│   └── settings.yaml          # Target bounding boxes (e.g., Mexico), thresholds
├── data/                      # Local cache for S3 downloads and TLE files
├── src/
│   ├── data_ingestion/        # AWS S3 GOES-16 & CelesTrak TLE fetchers
│   │   ├── goes_fetcher.py
│   │   └── iss_tracker.py
│   ├── physics/               # Atmospheric & charge moment calculations
│   │   ├── mcs_detector.py
│   │   └── tle_probability.py
│   └── visualization/         # Map generation and heatmaps
│       └── mapper.py
├── notebooks/                 # Jupyter Notebooks for experimentation
│   └── exploratory_analysis.ipynb
├── main.py                    # Pipeline execution entry point
├── requirements.txt
└── README.md
```

---

## 🚀 Quick Start Example

Run the primary script to check for upcoming visible TLE events over Mexico in the next 3 hours:

```python
from src.data_ingestion.iss_tracker import ISSTracker
from src.data_ingestion.goes_fetcher import GOESFetcher
from src.physics.tle_probability import TLEEvaluator

# 1. Fetch current ISS orbit trajectory
iss = ISSTracker()
iss_position = iss.get_current_position()

# 2. Query GOES-16 Cloud Top Temperatures over Lat/Lon bounding box
goes = GOESFetcher(bbox=[-118.0, 14.0, -86.0, 33.0])  # Mexico bounding box
cold_tops = goes.get_cold_cloud_shields(threshold_temp_c=-70)

# 3. Evaluate TLE Probability and ISS visibility
evaluator = TLEEvaluator()
results = evaluator.calculate_visibility(iss_pos=iss_position, storm_cells=cold_tops)

print(f"Active TLE Targets Visible from ISS: {len(results)}")
```

---

## 📋 Roadmap

- [ ] **Phase 1:** Automated AWS S3 ingestion of GOES-16 IR & GLM data.
- [ ] **Phase 2:** SGP4 orbital propagator integration for ISS visibility cone generation.
- [ ] **Phase 3:** Probability scoring engine based on stratiform flash rate and charge moment changes.
- [ ] **Phase 4:** Live Web Dashboard (FastAPI + Leaflet.js) showing real-time ISS position relative to TLE hot zones.

---

## 🤝 Contributing

Contributions are warmly welcome! Whether you are an astrophysicist, a meteorologist, a Python developer, or a space optics hobbyist, feel free to open an **Issue** or submit a **Pull Request**.

1. Fork the Project
2. Create your Feature Branch (`git checkout -b feature/AmazingFeature`)
3. Commit your Changes (`git commit -m 'Add some AmazingFeature'`)
4. Push to the Branch (`git push origin feature/AmazingFeature`)
5. Open a Pull Request

---

## 📜 License

Distributed under the MIT License. See `LICENSE` for more information.

---

## ⚡ Acknowledgments

* **NOAA / NASA** for providing open access to GOES satellite datasets via AWS Open Data.
* **CelesTrak** for maintaining up-to-date TLE orbital data.
* The **Atmosphere-Space Interactions Monitor (ASIM)** team for pioneering TLE research aboard the ISS.