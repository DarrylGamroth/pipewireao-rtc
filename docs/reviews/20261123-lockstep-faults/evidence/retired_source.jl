# Exercise released MediaSession policy with injected effect completions.
# The native endpoint is never contacted. Its data control has just retired.
using Test, Clocks, PipeWireAORTC
const S = PipeWireAORTC.MediaSession
const R = PipeWireAORTC.RunnerCodec
const launcher = S.Identity(11, 12, 13, 14)

function advance!(m, effects)
    for effect in effects
        @test m.effect.effect isa effect
        S.submitted!(m, m.effect)
        S.complete!(m, m.effect)
    end
end

function trial(faulted, failing_effect, reason)
    m = S.Machine(101; clock=Clocks.CachedNanoClock(Int64(0)))
    advance!(m, (S.CaptureOwners, S.ConnectOwners, S.CaptureParameters, S.CaptureSources,
        S.PrepareSources, S.DiscoverGraphs, S.HoldSources, S.ConnectLinks, S.HoldGraphs))
    for command in (S.InspectWarmup(), S.Admit())
        S.submit!(m, S.Request(command; controller=launcher))
        S.take_replies!(m)
    end
    S.submit!(m, S.Request(S.Start(); token=1))
    advance!(m, (S.RunGraphs, S.RunSources))
    @test m.lifecycle == R.Running
    S.take_replies!(m)
    if faulted
        S.required_lost!(m, "Required Link removed")
        advance!(m, (S.HoldSources, S.HoldGraphs, S.WithdrawLinks))
        @test S.Hsm.current(m) == :HeldFault
    end

    S.submit!(m, S.Request(S.Quit(); token=2, controller=launcher))
    advance!(m, (S.HoldSources, S.HoldGraphs, S.ShutdownGraphOwners, S.WithdrawLinks, S.ShutdownSources))

    source = S.SourceControlBinding(UInt64(9), UInt32(22), Int64(33), nothing)
    id = UInt32(source.handle)
    # Model the owner's data-node retirement while its bootstrap can still be pending.
    # Use the production retirement and identity-check operations on minimal object storage.
    runtime = (; objects=Dict(id => (; serial=UInt64(275))), captured=Dict(id => true),
        retired=Dict{UInt32,UInt64}(), sources=[source])
    S.retire_object!(runtime, id)
    @test runtime.retired[id] == 275 && !haskey(runtime.captured, id)
    failing_effect === S.RemoveControls && advance!(m, (S.ShutdownOwners,))
    @test m.effect.effect isa failing_effect
    S.fail!(m, m.effect, reason; submitted=true)
    @test m.effect.effect isa S.HoldSources
    failure = try
        S.perform!(runtime, S.Job(m.effect, false), m.effect.effect)
        error("expected a missing data-control capture")
    catch e
        e
    end
    @test failure == ArgumentError("object is not captured")
    S.fail!(m, m.effect, sprint(showerror, failure); submitted=false)
    @test m.effect.effect isa S.Disconnect
    @test m.cleanup_failure == "ArgumentError: object is not captured"
    @test m.failure == (faulted ? "Required Link removed" : reason)
    println("prior_fault=",faulted," injected_effect=",failing_effect," injected_reason=",repr(reason),
        " next_effect=",typeof(m.effect.effect)," retained_failure=",repr(m.failure),
        " retained_cleanup=",repr(m.cleanup_failure))
end
@testset "first failed Quit effect and post-retirement compensation" begin
    trial(true, S.ShutdownOwners, "injected bootstrap timeout")
    trial(true, S.RemoveControls, "injected final inventory failure")
    trial(false, S.ShutdownOwners, "injected bootstrap timeout")
end
