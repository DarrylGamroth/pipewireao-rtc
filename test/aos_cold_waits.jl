# Controlled cold owner waits: no native core, affinity, device, or scientific run.
using Test, PipeWireAORTC, AdaptiveOpticsSim, AdaptiveOpticsSimPipeWireHIL
const ColdExt = Base.get_extension(PipeWireAORTC, :PipeWireAORTCAOSExt)
const ColdPupil = ColdExt.PupilOutput
const ColdObservation = ColdExt.OpticalObservation
const ColdSource = ColdExt.PupilSourceOwner
const ColdClocks = ColdExt.Clocks
const ColdGraphs = AdaptiveOpticsSim.AlgorithmGraphs
const ColdHIL = AdaptiveOpticsSimPipeWireHIL
const COLD_BUDGET_NS = Int64(30_000_000_000)

@testset "pupil acknowledgement wait preserves readiness before temporal refusal" begin
    p = (; task = nothing)
    for origin in (-Int64(2)^60, Int64(2)^53 + 1),
        advance in (Int64(-1), COLD_BUDGET_NS),
        ready in (false, true)

        clock = ColdClocks.CachedNanoClock(origin)
        queries = Ref(0)
        checks = Ref(0)
        predicate = () -> (queries[] += 1; ready && queries[] == 2)
        check = () -> (checks[] += 1; ColdClocks.update!(clock, origin + advance))
        if ready
            @test ColdPupil.await!(predicate, p; clock, check) === nothing
            @test queries[] == 2 && checks[] == 1
        else
            error = try
                ColdPupil.await!(predicate, p; clock, check)
            catch error
                error
            end
            @test typeof(error) === ErrorException
            @test occursin(advance < 0 ? "regressed" : "did not acknowledge", error.msg)
            @test queries[] == checks[] == 2
        end
    end
    origin = Int64(2)^53 + 1
    clock = ColdClocks.CachedNanoClock(origin)
    checks = Ref(0)
    check =
        () -> begin
            checks[] += 1
            ColdClocks.update!(clock, origin + COLD_BUDGET_NS - (checks[] == 1 ? 1 : 0))
        end
    @test_throws ErrorException ColdPupil.await!(() -> false, p; clock, check)
    @test checks[] == 3 # One nanosecond before expiry is still pending.
    queries = Ref(0)
    @test_throws OverflowError ColdPupil.await!(
        () -> (queries[] += 1; true), p; clock = ColdClocks.CachedNanoClock(typemax(Int64))
    )
    @test queries[] == 0
    @test ColdPupil.await!(
        () -> true,
        p;
        clock = ColdClocks.CachedNanoClock(Int64(-1)),
        check = () -> error("ready needs no cancellation check"),
    ) === nothing
    @test_throws InterruptException ColdPupil.await!(
        () -> false,
        p;
        clock = ColdClocks.CachedNanoClock(Int64(-1)),
        check = () -> throw(InterruptException()),
    )
    completed = @async nothing
    wait(completed)
    @test_throws ErrorException ColdPupil.await!(
        () -> false, (; task = completed); clock = ColdClocks.CachedNanoClock(Int64(-1))
    )
end

mutable struct ColdSnapshot
    events::Vector{Symbol}
    values::Matrix{Float32}
    ready::Bool
end
function ColdGraphs.try_snapshot_graph_output!(snapshot::ColdSnapshot; kwargs...)
    push!(snapshot.events, :submit)
    return true
end
ColdGraphs.poll_graph_output_snapshot!(snapshot::ColdSnapshot) =
    (push!(snapshot.events, :poll); snapshot.ready)
ColdGraphs.snapshot_values(snapshot::ColdSnapshot) = snapshot.values
ColdGraphs.release_graph_output_snapshot!(snapshot::ColdSnapshot) =
    (push!(snapshot.events, :release); nothing)
ColdGraphs.reset_graph_output_snapshot!(snapshot::ColdSnapshot) =
    (push!(snapshot.events, :reset_snapshot); nothing)
struct ColdCPU end
Base.:(>)(::ColdCPU, ::Integer) = true
ColdObservation.pin_image_thread!(::ColdCPU) = nothing
struct ColdTransport
    events::Vector{Symbol}
end
ColdHIL.frame_acquisition_generation(::ColdTransport) = UInt64(3)
ColdHIL.reset_pipewire_image_sources!(transport::ColdTransport) =
    (push!(transport.events, :reset_sources); nothing)
function ColdObservation.start!(
    observation::ColdObservation.Observation, transport::ColdTransport, ::ColdCPU
)
    push!(transport.events, :start)
    return nothing
end
function cold_observation(events)
    values = zeros(Float32, 1, 1)
    return ColdObservation.Observation(
        ColdSnapshot(events, values, false),
        nothing,
        Threads.Atomic{Bool}(false),
        nothing,
        values,
        copy(values),
        copy(values),
        trues(1, 1),
        Threads.Atomic{Bool}(false),
        Threads.Atomic{Bool}(false),
        Threads.Atomic{UInt64}(0),
        Threads.Atomic{UInt64}(0),
        UInt64(0),
        nothing,
        nothing,
        nothing,
    )
end

@testset "optical warmup uses completion proof before expiry and keeps exact generation" begin
    for origin in (-Int64(2)^60, Int64(2)^53 + 1),
        advance in (Int64(-1), COLD_BUDGET_NS),
        ready in (false, true)

        clock = ColdClocks.CachedNanoClock(origin)
        events = Symbol[]
        observation = cold_observation(events)
        transport = ColdTransport(events)
        checks = Ref(0)
        check = () -> begin
            checks[] += 1
            if checks[] >= 2
                ColdClocks.update!(clock, origin + advance)
                ready && (observation.completed[] = 1)
            end
        end
        if ready
            @test ColdObservation.warm!(
                observation, transport; cpu = ColdCPU(), clock, check
            ) === nothing
            @test events == [:start, :submit, :reset_sources] && checks[] == 2
        else
            @test_throws ArgumentError ColdObservation.warm!(
                observation, transport; cpu = ColdCPU(), clock, check
            )
            @test events == [:start, :submit] && checks[] == 3
        end
        @test observation.generation === UInt64(3)
    end
    events = Symbol[]
    observation = cold_observation(events)
    @test_throws OverflowError ColdObservation.warm!(
        observation,
        ColdTransport(events);
        cpu = ColdCPU(),
        clock = ColdClocks.CachedNanoClock(typemax(Int64)),
    )
    @test events == [:start, :submit] # Budget validation precedes wait polling/reset.
    @test observation.completed[] == 0
    events = Symbol[]
    observation = cold_observation(events)
    observation.failed[] = true
    @test_throws ArgumentError ColdObservation.warm!(
        observation,
        ColdTransport(events);
        cpu = ColdCPU(),
        clock = ColdClocks.CachedNanoClock(Int64(-1)),
    )
    @test observation.completed[] == 0 && :reset_sources ∉ events
    # Reset must forward the injected clock while retaining the existing facts reset.
    events = Symbol[]
    observation = cold_observation(events)
    observation.failed[] = true
    observation.next_sample_ns = 7
    checks = Ref(0)
    @test_throws OverflowError ColdObservation.reset!(
        observation,
        ColdTransport(events);
        cpu = ColdCPU(),
        clock = ColdClocks.CachedNanoClock(typemax(Int64)),
        check = () -> (checks[] += 1; checks[] > 2 && error("clock was not forwarded")),
    )
    @test observation.next_sample_ns === nothing && !observation.failed[]
end

mutable struct ColdGraph
    events::Vector{Symbol}
end
mutable struct ColdDriver
    model_ns::Int64
end
function ColdSource.step_graph_at!(graph::ColdGraph, driver::ColdDriver)
    push!(graph.events, :step)
    driver.model_ns += 2_000_000
    return nothing
end
ColdGraphs.reset_graph!(graph::ColdGraph) = (push!(graph.events, :reset_graph); nothing)
ColdSource.reset_model_time!(driver::ColdDriver) = (driver.model_ns = 0; nothing)
struct ColdPublisher
    snapshot::ColdSnapshot
    packet::Array{Float32,3}
    amplitude::Matrix{Float32}
end
function ColdPupil.sample!(publisher::ColdPublisher; generation, model_ns)
    generation === UInt64(1) && model_ns === Int64(0) ||
        error("warmup changed scientific identity")
    push!(publisher.snapshot.events, :sample)
    return true
end
function cold_source(events)
    science = (; graph = ColdGraph(events), driver = ColdDriver(0), command = Float32[1])
    publisher = ColdPublisher(
        ColdSnapshot(events, fill(2.0f-9, 1, 1), false),
        zeros(Float32, 2, 1, 1),
        ones(Float32, 1, 1),
    )
    return science, publisher
end
@testset "pupil warmup always resets the first model phase after pending clock failure" begin
    for origin in (-Int64(2)^60, Int64(2)^53 + 1),
        advance in (Int64(-1), COLD_BUDGET_NS),
        ready in (false, true)

        clock = ColdClocks.CachedNanoClock(origin)
        events = Symbol[]
        science, publisher = cold_source(events)
        checks = Ref(0)
        check = () -> begin
            checks[] += 1
            if checks[] >= 3
                ColdClocks.update!(clock, origin + advance)
                publisher.snapshot.ready = ready
            end
        end
        if ready
            @test ColdSource.warmup!(science, publisher; clock, check) === nothing
            @test events ==
                [:step, :sample, :poll, :poll, :release, :reset_snapshot, :reset_graph]
            @test publisher.packet[:, 1, 1] == Float32[2.0f-9, 1]
        else
            @test_throws ErrorException ColdSource.warmup!(science, publisher; clock, check)
            @test events == [:step, :sample, :poll, :poll, :reset_snapshot, :reset_graph]
        end
        @test science.driver.model_ns === Int64(0) && science.command == Float32[0]
    end
    events = Symbol[]
    science, publisher = cold_source(events)
    @test_throws OverflowError ColdSource.warmup!(
        science, publisher; clock = ColdClocks.CachedNanoClock(typemax(Int64))
    )
    @test events == [:step, :sample, :reset_snapshot, :reset_graph]
    @test science.driver.model_ns === Int64(0) && science.command == Float32[0]
end

@testset "pending warmups retain the final nanosecond before exact expiry" begin
    origin = Int64(2)^53 + 1
    clock = ColdClocks.CachedNanoClock(origin)
    events = Symbol[]
    observation = cold_observation(events)
    checks = Ref(0)
    check =
        () -> begin
            checks[] += 1
            if checks[] >= 2
                ColdClocks.update!(clock, origin + COLD_BUDGET_NS - (checks[] == 2 ? 1 : 0))
            end
        end
    @test_throws ArgumentError ColdObservation.warm!(
        observation, ColdTransport(events); cpu = ColdCPU(), clock, check
    )
    @test checks[] == 4 && events == [:start, :submit]
    clock = ColdClocks.CachedNanoClock(origin)
    events = Symbol[]
    science, publisher = cold_source(events)
    checks = Ref(0)
    check =
        () -> begin
            checks[] += 1
            if checks[] >= 3
                ColdClocks.update!(clock, origin + COLD_BUDGET_NS - (checks[] == 3 ? 1 : 0))
            end
        end
    @test_throws ErrorException ColdSource.warmup!(science, publisher; clock, check)
    @test checks[] == 5 && count(==(:poll), events) == 3
    @test events[(end-1):end] == [:reset_snapshot, :reset_graph]
end
