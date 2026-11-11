// Sanity checks for src/space/Astro.hpp (built and run on Linux inside the toolchain container):
//   clang++-18 -std=c++17 -O2 -Isrc tests/astro_test.cpp -o /tmp/astro_test && /tmp/astro_test
#include <cstdio>
#include "space/Astro.hpp"

using namespace astro;

static int failures = 0;
static void Check(bool ok, const char* what, double value)
{
    printf("%-55s %14.4f  %s\n", what, value, ok ? "OK" : "FAIL");
    if (!ok) failures++;
}

int main()
{
    Orbit iss = Orbit::FromTle("ISS (ZARYA)",
        "1 25544U 98067A   26315.20707527  .00009235  00000+0  17362-3 0  9997",
        "2 25544  51.6322 292.5559 0007316  12.7435 347.3737 15.49310717594546");
    Orbit hst = Orbit::FromTle("HST",
        "1 20580U 90037B   26314.89250324  .00006442  00000+0  19351-3 0  9990",
        "2 20580  28.4707 156.7631 0002117 354.3305   5.7267 15.32255871811082");

    const double t = iss.epochUnix + 3600.0;
    Vec3 p = iss.PositionEci(t), p2 = iss.PositionEci(t + 1.0);
    double alt = p.Length() - EARTH_RADIUS, v = (p2 - p).Length();
    Check(iss.valid && hst.valid, "TLEs parsed", 1);
    Check(alt > 380 && alt < 450, "ISS altitude (km)", alt);
    Check(v > 7.60 && v < 7.72, "ISS speed (km/s)", v);
    Check(std::fabs(v - std::sqrt(MU_EARTH / p.Length())) < 0.02, "ISS speed vs circular sqrt(mu/r) (km/s)", std::sqrt(MU_EARTH / p.Length()));
    Check(iss.PeriodSeconds() / 60 > 91 && iss.PeriodSeconds() / 60 < 94, "ISS period (min)", iss.PeriodSeconds() / 60);
    Check(SIDEREAL_DAY / iss.PeriodSeconds() > 15.3 && SIDEREAL_DAY / iss.PeriodSeconds() < 15.7, "Orbits per Earth rotation (sidereal day / period)", SIDEREAL_DAY / iss.PeriodSeconds());
    double lat = std::asin(p.z / p.Length()) / DEG;
    Check(std::fabs(lat) <= 51.7, "ISS latitude within inclination (deg)", lat);

    Vec3 h = hst.PositionEci(t);
    Check(h.Length() - EARTH_RADIUS > 450 && h.Length() - EARTH_RADIUS < 560, "Hubble altitude (km)", h.Length() - EARTH_RADIUS);

    // Sun: distance ~1 AU, angular diameter ~0.53 deg, declination about -17.5 deg on 11 Nov.
    const double nov11 = (double)DaysFromCivil(2026, 11, 11) * 86400.0 + 12 * 3600.0;
    Vec3 s = SunPositionEci(nov11);
    double au = s.Length() / AU, dec = std::asin(s.z / s.Length()) / DEG;
    Check(au > 0.985 && au < 0.995, "Sun distance on 2026-11-11 (AU)", au);
    Check(s.Length() / EARTH_RADIUS > 23000, "Sun distance (Earth radii)", s.Length() / EARTH_RADIUS);
    Check(dec > -18.5 && dec < -16.5, "Sun declination on 2026-11-11 (deg)", dec);
    Check(std::fabs(2 * std::asin(SUN_RADIUS / s.Length()) / DEG - 0.54) < 0.02, "Sun angular diameter (deg)", 2 * std::asin(SUN_RADIUS / s.Length()) / DEG);

    // GMST at J2000.0 epoch is 280.46 deg.
    Check(std::fabs(Gmst((2451545.0 - 2440587.5) * 86400.0) / DEG - 280.4606) < 1e-3, "GMST at J2000 (deg)", Gmst((2451545.0 - 2440587.5) * 86400.0) / DEG);

    // Subsolar longitude at 12:00 UTC should be close to 0 (equation of time ~ +16 min in Nov => ~ -4 deg).
    double ra = std::atan2(s.y, s.x), lon = std::remainder(ra - Gmst(nov11), 2 * PI) / DEG;
    Check(std::fabs(lon) < 6, "Subsolar longitude at 12:00 UTC (deg)", lon);

    printf(failures ? "\n%d FAILED\n" : "\nall passed\n", failures);
    return failures;
}
