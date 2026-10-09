#!/usr/bin/env julia
using PipeWireAODeployment

if abspath(PROGRAM_FILE) == @__FILE__
    PipeWireAODeployment.HILExport.main(ARGS)
end
