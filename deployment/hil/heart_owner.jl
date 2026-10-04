#!/usr/bin/env julia
include(joinpath(@__DIR__, "..", "julia", "PipeWireAODeployment.jl"))
exit(PipeWireAODeployment.HeartOwner.main(ARGS))
