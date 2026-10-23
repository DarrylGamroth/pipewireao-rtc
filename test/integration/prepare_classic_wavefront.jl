# Create a fresh test application with a cold FFT witness; never modify the base.
using PipeWireAORTC
const C = PipeWireAORTC.Common
length(ARGS) == 2 || error("usage: prepare_classic_wavefront.jl CPU_APPLICATION DESTINATION")
source, destination = abspath.(ARGS)
options = PipeWireAORTC.AOSOwner.configuration(joinpath(source, "simulation.conf"))
options.backend === :cpu && options.total_exchanges == 32 &&
    options.pacing_rate_hz == 2 && options.optical_observation ||
    error("base must select CPU, 32 exchanges, 2 Hz wall rate and optical observation")
spec = C.read_json(joinpath(source, "deployment.conf"))
all(C.sha256_file(joinpath(source, path)) == hash for (path, hash) in spec["artifacts"]) ||
    error("base application has changed sealed artifacts")
cp(source, destination)
cp(joinpath(@__DIR__, "classic_fft_oracle.jl"), joinpath(destination, "classic_fft_oracle.jl"))
owner = only(filter(owner -> any(arg -> occursin("AOSOwner.main", arg), owner["argv"]), spec["owners"]))
index = something(findfirst(==("-e"), owner["argv"])) + 1
owner["argv"][index] = "using PipeWireAORTC; include(\"@PACKAGE@/classic_fft_oracle.jl\"); " *
    "Main.ClassicFFTOracle.record_native!(joinpath(ENV[\"PIPEWIREAO_RUNTIME_DIR\"],\"fft-oracle\")); " *
    "PipeWireAORTC.AOSOwner.main(ARGS)"
spec["artifacts"]["classic_fft_oracle.jl"] = C.sha256_file(joinpath(destination, "classic_fft_oracle.jl"))
C.write_json(joinpath(destination, "deployment.conf"), spec)
