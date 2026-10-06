using Test, Sockets, PipeWireAODeployment

const D = PipeWireAODeployment.Deployment

struct InterruptedBroker end
Sockets.accept(::InterruptedBroker) = throw(InterruptException())
struct FailedBroker end
Sockets.accept(::FailedBroker) = error("fixture accept failure")

function control_accept_fixture(broker)
    D.DeploymentRunner((;), "", Dict{String,Any}(), Dict{String,String}(), Set{Int}(),
        Tuple{String,Base.Process}[], IdDict{Base.Process,Int}(), nothing, nothing, nothing,
        broker, nothing, nothing, nothing, nothing, 0, nothing, false, false, false,
        nothing, Dict{String,Any}(), nothing, nothing)
end

@testset "owned control accept interruption" begin
    interrupted = control_accept_fixture(InterruptedBroker())
    @test_throws InterruptException D.fixture_serve_control(interrupted)
    @test interrupted.broker_accept === nothing
    failed = control_accept_fixture(FailedBroker())
    error = try
        D.fixture_serve_control(failed)
        nothing
    catch caught
        caught
    end
    @test error isa TaskFailedException
    @test occursin("fixture accept failure", sprint(showerror, error))
end
