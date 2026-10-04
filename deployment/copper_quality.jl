#!/usr/bin/env julia
include(joinpath(@__DIR__, "julia", "PipeWireAODeployment.jl"))

if abspath(PROGRAM_FILE) == @__FILE__
    PipeWireAODeployment.CopperQuality.main(ARGS)
end
