#pragma once
// Astronomy and orbital mechanics for the "space" scene (double precision, km, seconds).
//
// Frames:
//   ECI   - Earth-centred inertial (equatorial, x = vernal equinox, z = north pole). TLEs give TEME,
//           which we treat as ECI (difference < 1 arcmin, irrelevant at wallpaper scale).
//   ECEF  - Earth-fixed: ECI rotated by GMST around z.
//   World - renderer frame (right-handed, +Y up): world = (eci.x, eci.z, -eci.y).
#include <cmath>
#include <cstdlib>
#include <cstring>
#include <string>

namespace astro
{
constexpr double PI = 3.14159265358979323846;
constexpr double DEG = PI / 180.0;
constexpr double MU_EARTH = 398600.4418;      // km^3/s^2
constexpr double EARTH_RADIUS = 6371.0;       // km (mean, used for drawing)
constexpr double EARTH_EQ_RADIUS = 6378.137;  // km (WGS-84, used for J2)
constexpr double J2 = 1.08262668e-3;
constexpr double AU = 149597870.7;            // km
constexpr double SUN_RADIUS = 695700.0;       // km
constexpr double SIDEREAL_DAY = 86164.0905;   // s

struct Vec3
{
    double x = 0, y = 0, z = 0;
    Vec3 operator+(const Vec3& o) const { return { x + o.x, y + o.y, z + o.z }; }
    Vec3 operator-(const Vec3& o) const { return { x - o.x, y - o.y, z - o.z }; }
    Vec3 operator*(double s) const { return { x * s, y * s, z * s }; }
    double Length() const { return std::sqrt(x * x + y * y + z * z); }
    Vec3 Normalized() const { double l = Length(); return l > 0 ? *this * (1.0 / l) : *this; }
};
inline double Dot(const Vec3& a, const Vec3& b) { return a.x * b.x + a.y * b.y + a.z * b.z; }
inline Vec3 Cross(const Vec3& a, const Vec3& b)
{
    return { a.y * b.z - a.z * b.y, a.z * b.x - a.x * b.z, a.x * b.y - a.y * b.x };
}
inline Vec3 EciToWorld(const Vec3& e) { return { e.x, e.z, -e.y }; }

// Days since 1970-01-01 for a civil date (Howard Hinnant's algorithm).
inline long long DaysFromCivil(int y, unsigned m, unsigned d)
{
    y -= m <= 2;
    const long long era = (y >= 0 ? y : y - 399) / 400;
    const unsigned yoe = (unsigned)(y - era * 400);
    const unsigned doy = (153 * (m + (m > 2 ? -3 : 9)) + 2) / 5 + d - 1;
    const unsigned doe = yoe * 365 + yoe / 4 - yoe / 100 + doy;
    return era * 146097 + (long long)doe - 719468;
}

inline double JulianDate(double unixSeconds) { return unixSeconds / 86400.0 + 2440587.5; }

// Greenwich Mean Sidereal Time (radians).
inline double Gmst(double unixSeconds)
{
    const double d = JulianDate(unixSeconds) - 2451545.0;
    double g = std::fmod(280.46061837 + 360.98564736629 * d, 360.0);
    if (g < 0) g += 360.0;
    return g * DEG;
}

// Sun position in ECI (km). Low-precision solar ephemeris (Astronomical Almanac), ~0.01 deg.
inline Vec3 SunPositionEci(double unixSeconds)
{
    const double n = JulianDate(unixSeconds) - 2451545.0;
    const double L = (280.460 + 0.9856474 * n) * DEG;
    const double g = (357.528 + 0.9856003 * n) * DEG;
    const double lambda = L + (1.915 * std::sin(g) + 0.020 * std::sin(2 * g)) * DEG;
    const double eps = (23.439 - 0.0000004 * n) * DEG;
    const double r = (1.00014 - 0.01671 * std::cos(g) - 0.00014 * std::cos(2 * g)) * AU;
    return { r * std::cos(lambda), r * std::cos(eps) * std::sin(lambda), r * std::sin(eps) * std::sin(lambda) };
}

// ---------------------------------------------------------------------------
// Two-line elements + Kepler propagation with J2 secular perturbations.
// ---------------------------------------------------------------------------
struct Orbit
{
    std::string name;
    double epochUnix = 0;
    double inclination = 0, raan = 0, eccentricity = 0, argPerigee = 0, meanAnomaly = 0;  // rad
    double meanMotion = 0;   // rad/s
    double semiMajorAxis = 0; // km
    bool valid = false;

    double PeriodSeconds() const { return 2 * PI / meanMotion; }

    // Circular-orbit fallback (used when no TLE is available).
    static Orbit Circular(const char* name, double altitudeKm, double inclinationDeg, double raanDeg, double epochUnix)
    {
        Orbit o;
        o.name = name;
        o.semiMajorAxis = EARTH_RADIUS + altitudeKm;
        o.meanMotion = std::sqrt(MU_EARTH / (o.semiMajorAxis * o.semiMajorAxis * o.semiMajorAxis));
        o.inclination = inclinationDeg * DEG;
        o.raan = raanDeg * DEG;
        o.epochUnix = epochUnix;
        o.valid = true;
        return o;
    }

    static double Field(const std::string& line, size_t start, size_t len)
    {
        return std::atof(line.substr(start, len).c_str());
    }

    // Parses the two element lines (columns per the NORAD TLE format).
    static Orbit FromTle(const std::string& name, const std::string& l1, const std::string& l2)
    {
        Orbit o;
        o.name = name;
        if (l1.size() < 63 || l2.size() < 63 || l1[0] != '1' || l2[0] != '2') return o;
        int yy = (int)Field(l1, 18, 2);
        double day = Field(l1, 20, 12);
        int year = yy < 57 ? 2000 + yy : 1900 + yy;
        o.epochUnix = (double)DaysFromCivil(year, 1, 1) * 86400.0 + (day - 1.0) * 86400.0;
        o.inclination = Field(l2, 8, 8) * DEG;
        o.raan = Field(l2, 17, 8) * DEG;
        o.eccentricity = std::atof(("0." + l2.substr(26, 7)).c_str());
        o.argPerigee = Field(l2, 34, 8) * DEG;
        o.meanAnomaly = Field(l2, 43, 8) * DEG;
        const double revPerDay = Field(l2, 52, 11);
        o.meanMotion = revPerDay * 2 * PI / 86400.0;
        o.semiMajorAxis = std::cbrt(MU_EARTH / (o.meanMotion * o.meanMotion));
        o.valid = revPerDay > 0;
        return o;
    }

    // Position in ECI (km) at a unix time.
    Vec3 PositionEci(double unixSeconds) const
    {
        const double dt = unixSeconds - epochUnix;
        const double e = eccentricity;
        const double p = semiMajorAxis * (1 - e * e);
        const double k = 1.5 * meanMotion * J2 * (EARTH_EQ_RADIUS / p) * (EARTH_EQ_RADIUS / p);
        const double cosI = std::cos(inclination);
        const double raanNow = raan - k * cosI * dt;                                 // nodal regression
        const double argpNow = argPerigee + 0.5 * k * (5 * cosI * cosI - 1) * dt;    // apsidal precession

        double M = std::fmod(meanAnomaly + meanMotion * dt, 2 * PI);
        double E = M;
        for (int i = 0; i < 8; i++) E -= (E - e * std::sin(E) - M) / (1 - e * std::cos(E));   // Kepler's equation
        const double nu = std::atan2(std::sqrt(1 - e * e) * std::sin(E), std::cos(E) - e);
        const double r = semiMajorAxis * (1 - e * std::cos(E));

        // Perifocal -> ECI: R3(-raan) R1(-i) R3(-argp)
        const double u = argpNow + nu;
        const double cO = std::cos(raanNow), sO = std::sin(raanNow);
        const double cu = std::cos(u), su = std::sin(u);
        const double sI = std::sin(inclination);
        return { r * (cO * cu - sO * su * cosI), r * (sO * cu + cO * su * cosI), r * (su * sI) };
    }
};

// Splits a Celestrak "FORMAT=TLE" response (3 lines per object) into orbits.
inline bool ParseTle(const std::string& text, Orbit& out)
{
    std::string lines[3];
    int n = 0;
    size_t pos = 0;
    while (pos < text.size() && n < 3)
    {
        size_t end = text.find('\n', pos);
        if (end == std::string::npos) end = text.size();
        std::string line = text.substr(pos, end - pos);
        while (!line.empty() && (line.back() == '\r' || line.back() == ' ')) line.pop_back();
        if (!line.empty()) lines[n++] = line;
        pos = end + 1;
    }
    if (n < 3) return false;
    out = Orbit::FromTle(lines[0], lines[1], lines[2]);
    return out.valid;
}
} // namespace astro
