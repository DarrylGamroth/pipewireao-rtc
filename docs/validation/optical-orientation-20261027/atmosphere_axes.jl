# Disconnected coordinate probe of registered AOS; no RTC controls or plant changes.
using Test, AdaptiveOpticsSim
const A = AdaptiveOpticsSim.Atmospheres
screen = zeros(Float32, 16, 16)
screen[8, 9] = 1
out = zeros(Float32, 8, 8)
extract(x, y) = (A.extract_shifted_screen!(out, screen, Float32(x), Float32(y), 1f0); Tuple(argmax(out)))
base = extract(0, 0)
wind_x = extract(1, 0)
wind_y = extract(0, 1)
@test base == (4, 5)
@test wind_x == (4, 6)
@test wind_y == (5, 5)
println("AOS ", pkgversion(AdaptiveOpticsSim), " ", pathof(AdaptiveOpticsSim))
println("Asymmetric phase marker: baseline=", base, "; +offset_x=", wind_x, "; +offset_y=", wind_y)
println("Atmosphere +x moves array axis 2; atmosphere +y moves array axis 1.")
