#!/usr/bin/env julia
using PipeWireAODeployment

if abspath(PROGRAM_FILE) == @__FILE__
    PipeWireAODeployment.CopperReference.main(ARGS)
end
