module OpticalStartup
using PrecompileTools: @setup_workload, @compile_workload
using Proper
include("../workload.jl")
@setup_workload begin
    config = joinpath(chomp(read(joinpath(@__DIR__, "..", "application"), String)), "simulation.conf")
    @compile_workload begin
        optical_workload(config)
    end
end
end
