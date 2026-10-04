#!/usr/bin/env julia
include(joinpath(@__DIR__, "PipeWireAODeployment.jl"))
exit(PipeWireAODeployment.Deployment.main(ARGS))
