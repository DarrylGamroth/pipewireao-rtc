using Test, PipeWireAORTC
const Runtime = PipeWireAORTC.SessionRuntime

source_endpoint(profile, instance) = Dict{String,Any}(
    "control-protocol" => profile,
    "control-node" => "simulator-wfs",
    "control-instance" => instance,
)

@testset "readiness accepts the declared native source profile" begin
    for profile in (
        "pipewireao.rtc.calibration-lifecycle/1",
        "pipewireao.rtc.correction-lifecycle/1",
        "pipewireao.source-control/1",
    )
        source = source_endpoint(profile, "19")
        @test Runtime._source_endpoint(source) ==
            Dict("node" => "simulator-wfs", "instance" => Int64(19), "profile" => profile)
        if PipeWireAORTC.DeploymentConfiguration.uses_source_control_protocol(source)
            # Native source owners publish their live mailbox incarnation;
            # SessionLaunch does not reserve an acquisition control-instance.
            source["control-instance"] = nothing
            @test Runtime._source_endpoint(source) == Dict(
                "node" => "simulator-wfs", "instance" => nothing, "profile" => profile
            )
        else
            source["control-instance"] = nothing
            @test_throws ArgumentError Runtime._source_endpoint(source)
        end
        for invalid in
            (0, -1, "", "not-an-instance", "1.0", string(big(typemax(Int64)) + 1))
            source["control-instance"] = invalid
            @test_throws ArgumentError Runtime._source_endpoint(source)
        end
        for node in (nothing, "", "source with spaces", "a"^129)
            source["control-instance"] = "19"
            source["control-node"] = node
            @test_throws ArgumentError Runtime._source_endpoint(source)
        end
    end
    for profile in (nothing, "", "pipewireao.source-control/2", "pipewireao.rtc.heart/1")
        @test_throws ArgumentError Runtime._source_endpoint(source_endpoint(profile, "19"))
    end
end

@testset "source Status remains calibration-specific" begin
    # Invalid profiles must fail before any connection or process lookup.
    for profile in
        ("pipewireao.source-control/1", "pipewireao.rtc.correction-lifecycle/1", "unknown")
        record = Dict("source_endpoint" => Dict("profile" => profile))
        @test_throws ArgumentError Runtime.source_status(record, "classic"; deadline = 0)
    end
    @test_throws ArgumentError Runtime.source_status(Dict(), "unsupported"; deadline = 0)
end

import Clocks
module SessionClockBoundary
import Clocks
import PipeWireAORTC
const S = PipeWireAORTC.SystemdOwners
const calls = Ref(0)
const closed = Ref(0)
const lifecycle = Ref(:ready)
struct Connection
    selected::NamedTuple
end
Base.close(connection::Connection) = (closed[] += 1; nothing)
function _selected(record, deadline; clock)
    calls[] += 1
    return Connection((;
        status = (;
            lifecycle = lifecycle[],
            owner_pid = UInt32(17),
            incarnation = 9,
            remote = "unused",
        )
    ))
end
source = read(joinpath(pkgdir(PipeWireAORTC), "src/deployment/session_runtime.jl"), String)
position = first(findfirst("function _analysis_ready(", source))
expression, _ = Meta.parse(source, position)
Core.eval(@__MODULE__, expression)
end

mutable struct SessionWaitClock <: Clocks.AbstractNanoClock
    ticks::Vector{Int64}
    reads::Int
end
SessionWaitClock(ticks::Int64...) = SessionWaitClock(collect(ticks), 0)
function Clocks.time_nanos(clock::SessionWaitClock)
    clock.reads += 1
    return clock.ticks[min(clock.reads, length(clock.ticks))]
end

@testset "Signed runtime readiness waits preserve source samples and cleanup" begin
    B = SessionClockBoundary
    handle = (; main_pid = 17)
    record = Dict("session_control_instance" => 9, "remote" => "unused")
    for origin in (Int64(-10), Int64(0), Int64(2)^53 + 1)
        B.calls[] = B.closed[] = 0
        B.lifecycle[] = :ready
        clock = SessionWaitClock(origin)
        @test B._analysis_ready(handle, record, origin + 1; clock) === nothing
        @test clock.reads == 1 && B.calls[] == B.closed[] == 1
        B.calls[] = B.closed[] = 0
        B.lifecycle[] = :prepared
        clock = SessionWaitClock(origin, origin + 1)
        @test_throws ArgumentError B._analysis_ready(handle, record, origin + 1; clock)
        @test clock.reads == 2 && B.calls[] == B.closed[] == 1
        @test Runtime.remaining(origin + 1, 1, origin) === 1.0e-9
        @test_throws ArgumentError Runtime.remaining(origin, 1, origin)
    end
    B.calls[] = B.closed[] = 0
    B.lifecycle[] = :prepared
    clock = SessionWaitClock(Int64(-10), Int64(-11))
    @test_throws ArgumentError B._analysis_ready(handle, record, Int64(-9); clock)
    @test B.calls[] == B.closed[] == 1
    @test_throws OverflowError Runtime.remaining(typemax(Int64), 1, typemin(Int64))
    for limit in (0, -1, NaN, Inf, 1.0e-10)
        @test_throws ArgumentError Runtime.remaining(Int64(1), limit, Int64(0))
    end
    @test_throws OverflowError PipeWireAORTC.SessionCLI.control_session(
        "unused", ["status"]; timeout = 1, clock = Clocks.CachedNanoClock(typemax(Int64))
    )
end

module CoreClockBoundary
import Clocks
import PipeWireAORTC
const fail = PipeWireAORTC.SessionLaunch.fail
module S
import PipeWireAORTC.SystemdOwners: duration_ns
const calls = Ref(0)
alive(service) = (calls[] += 1; false)
end
source = read(joinpath(pkgdir(PipeWireAORTC), "src/deployment/session_launch.jl"), String)
position = first(findfirst("function wait_core!(", source))
expression, _ = Meta.parse(source, position)
Core.eval(@__MODULE__, expression)
end

@testset "Private core setup rejects signed expiry, regression and overflow" begin
    B = CoreClockBoundary
    for origin in (Int64(-10), Int64(0), Int64(2)^53 + 1)
        B.S.calls[] = 0
        clock = SessionWaitClock(origin)
        @test_throws PipeWireAORTC.SessionLaunch.LaunchError B.wait_core!(
            nothing, "unused"; clock
        )
        @test clock.reads == 2 && B.S.calls[] == 1
        B.S.calls[] = 0
        clock = SessionWaitClock(origin, origin + 1)
        @test_throws PipeWireAORTC.SessionLaunch.LaunchError B.wait_core!(
            nothing, "unused"; seconds = 1.0e-9, clock
        )
        @test clock.reads == 2 && B.S.calls[] == 0
    end
    B.S.calls[] = 0
    clock = SessionWaitClock(Int64(-10), Int64(-11))
    @test_throws PipeWireAORTC.SessionLaunch.LaunchError B.wait_core!(
        nothing, "unused"; clock
    )
    @test clock.reads == 2 && B.S.calls[] == 0
    @test_throws OverflowError B.wait_core!(
        nothing, "unused"; clock = Clocks.CachedNanoClock(typemax(Int64))
    )
    @test B.S.calls[] == 0
end
