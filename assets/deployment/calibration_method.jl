#!/usr/bin/env julia
using PipeWireAODeployment

if abspath(PROGRAM_FILE) == @__FILE__
    PipeWireAODeployment.CalibrationMethod.main(ARGS)
end
