# Read the native Core on a private socket before starting any RTC-owned graph.
using Test, PipeWireAORTC, PipeWireAO

include(joinpath(@__DIR__, "..", "control_private_core.jl"))

@testset "independent core socket belongs to the declared service" begin
    prefix = String(PipeWireAO.LibPipeWire.PipeWireAO_jll.artifact_dir)
    with_control_private_core(; prefix) do socket, _, daemon
        launch = PipeWireAORTC.SessionLaunch
        @test launch.verify_external_core(prefix, socket, getpid(daemon), Dict(ENV)) === nothing
        @test_throws launch.LaunchError launch.verify_external_core(prefix, socket, getpid(), Dict(ENV))
    end
end
