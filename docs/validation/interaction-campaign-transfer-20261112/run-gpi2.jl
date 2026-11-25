# Run in a fresh process with the baseline or candidate science environment.
# ARGS: measure|estimate LAUNCHER APPLICATION OUTPUT [BUNDLE]
using PipeWireAO

mode, launcher, application, output = ARGS[1:4]
mode in ("measure", "estimate") || error("expected measure or estimate")
ENV["PIPEWIREAO_PREFIX"] = String(PipeWireAO.LibPipeWire.PipeWireAO_jll.artifact_dir)
mode == "estimate" && include("fft-control.jl")
arguments = length(ARGS) == 5 ? [application, ARGS[5], output, "cpu"] :
    [application, output, "cpu"]
empty!(ARGS)
append!(ARGS, arguments)
include(launcher)
