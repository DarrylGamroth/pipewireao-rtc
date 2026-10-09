#!/usr/bin/env julia
using PipeWireAODeployment

if abspath(PROGRAM_FILE) == @__FILE__
    PipeWireAODeployment.CopperQuality.main(ARGS)
end
