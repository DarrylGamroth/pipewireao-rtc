using PipeWireAORTC
using SHA
using TOML

root, output = ARGS
C = PipeWireAORTC.Common
sky = "optics/generated/fitted/sky.yaml"
definition = "generated/held-out/definition.yaml"
instrument = "instrument.yaml"
sources = (sky, definition, instrument)
model, plant, detector = map(name -> C.read_yaml(joinpath(root, name)), sources)
camera = plant["components"]["scc_camera"]["config"]
records = Dict(
    "unocculted_star_peak" => model["star_peak"],
    "photons_per_second_per_unit_intensity" => plant["observations"]["scc"]["normalized_to_photon_rate"],
    "quantum_efficiency" => camera["quantum_efficiency"],
    "exposure_seconds" => detector["wavefront_sensors"]["scc"]["acquisition"]["exposure_duration_s"],
    "photon_noise" => camera["photon_noise"],
    "input_sha256" => Dict(name => bytes2hex(open(sha256, joinpath(root, name))) for name in sources),
)
open(output, "w") do io
    println(io, "# Generated from the fitted sky model, held-out camera settings, and instrument exposure.")
    TOML.print(io, records; sorted=true)
end
