#!/usr/bin/env julia
using PipeWireAODeployment

if abspath(PROGRAM_FILE) == @__FILE__
    exit(PipeWireAODeployment.Deployment.main(ARGS))
end
