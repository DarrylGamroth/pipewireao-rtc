using Test, PipeWireAORTC, PipeWireAO
const CSO = PipeWireAORTC.CorrectionSupervision
const OBS_SCHEMA = "pipewireao/pdm-constraint-feedback-f32/1"

# Public format/metadata shape without loading optional scientific packages.
# The extension integration selector separately exercises actual public types.
mutable struct ObserverClock
    now::UInt64
end
(clock::ObserverClock)() = clock.now
const OBS_FORMATS = (feedback=(element_type=Float32, shape=(4,),
    layout=:row_major, schema=OBS_SCHEMA),)
function observer_inputs(; tolerance=0.1, action=:monitor_only)
    clock = ObserverClock(1000)
    configuration = CSO.Configuration(; trip_fraction=0.5, clear_fraction=0.0,
        persistence_ns=100, max_gap_ns=60, action)
    policy = (; configuration, tolerance, schema=OBS_SCHEMA, shape=(4,), layout=:row_major)
    observer = CSO.Observer(OBS_FORMATS, (; feedback=policy); owner_instance=701, clock)
    return observer, clock, policy
end
header(sequence; offset=0, corrupted=false, discontinuity=false) =
    (; sequence=UInt64(sequence), offset, corrupted, discontinuity,
        timestamp_nanoseconds=Int64(-10)) # Model PTS is deliberately unusable.
function frame!(observer, clock, sequence, now, feedback; metadata=header(sequence))
    clock.now = now
    observer(Val(:frame), (; feedback), (; feedback=metadata))
    return only(CSO.snapshot(observer))
end

@testset "Cold feedback boundary validation" begin
    observer, clock, policy = observer_inputs()
    @test only(CSO.snapshot(observer)).state === :Unknown
    for tolerance in (-1, NaN, Inf, true, "1")
        @test_throws ArgumentError observer_inputs(; tolerance)
    end
    for replacement in ((schema="pipewireao/vdm-command-f32/1",), (shape=(2,),),
            (layout=:column_major,), (element_type=Float64,))
        formats = (feedback=merge(OBS_FORMATS.feedback, replacement),)
        @test_throws ArgumentError CSO.Observer(formats, (; feedback=policy); owner_instance=701, clock)
    end
    @test_throws ArgumentError CSO.Observer((;), (; feedback=policy); owner_instance=701, clock)
    @test_throws ArgumentError CSO.Observer(OBS_FORMATS, (;); owner_instance=701, clock)
    @test_throws ArgumentError CSO.Observer(OBS_FORMATS, (; feedback=policy); owner_instance=0, clock)
    for shape in ((true,), (0,), (-1,), ("4",), (typemax(Int),), (2, 2))
        formats = (feedback=merge(OBS_FORMATS.feedback, (;shape)),)
        bad = merge(policy, (;shape))
        @test_throws ArgumentError CSO.Observer(formats, (;feedback=bad); owner_instance=701, clock)
    end
    large_shape = (PipeWireAORTC.Artifacts.MAX_IMAGE_BYTES ÷ sizeof(Float32),)
    large_format = merge(OBS_FORMATS.feedback, (;shape=large_shape))
    large_policy = merge(policy, (;shape=large_shape))
    @test_throws ArgumentError CSO.Observer((;left=large_format, right=large_format),
        (;left=large_policy, right=large_policy); owner_instance=701, clock)

end

@testset "Actual source sequence and owner time determine persistence" begin
    observer, clock, _ = observer_inputs(; tolerance=0.125)
    # Includes negative feedback (slew/quantization); exactly tolerance is clear.
    first = frame!(observer, clock, 41, 1000, Float32[0.2, -0.2, 0.0, 0.125])
    @test first.state === :Pending && first.fraction == 0.5
    @test first.sequence == 41 && first.observed_ns == 1000
    frame!(observer, clock, 42, 1050, fill(0.2f0, 4))
    trip = frame!(observer, clock, 43, 1100, fill(0.2f0, 4))
    @test trip.state === :Tripped && trip.action === :monitor_only
    @test trip.trip_sequence == 43 && trip.trip_ns == 1100
    # A reader may miss the trip frame and many later frames without losing intent.
    frame!(observer, clock, 44, 1150, zeros(Float32, 4))
    frame!(observer, clock, 45, 1200, fill(NaN32, 4))
    observer(Val(:reset)); observer(Val(:invalidated))
    retained = only(CSO.snapshot(observer))
    @test retained.state === :Tripped && retained.trip_sequence == 43
    @test retained.action === :monitor_only && retained.trip_ns == 1100
    @test isnan(retained.fraction)
end

@testset "Missing, corrupt, repeated and discontinuous data break continuity" begin
    cases = ((; metadata=nothing), (; metadata=header(2; corrupted=true)),
        (; metadata=header(2; discontinuity=true)), (; metadata=header(2; offset=1)),
        (; metadata=header(1)))
    for kwargs in cases
        observer, clock, _ = observer_inputs()
        frame!(observer, clock, 1, 1000, fill(0.2f0, 4))
        value = frame!(observer, clock, 2, 1050, fill(0.2f0, 4); kwargs...)
        @test value.state === :Unknown
        value = frame!(observer, clock, 3, 1100, fill(0.2f0, 4))
        @test value.state === :Pending
        @test frame!(observer, clock, 4, 1150, fill(0.2f0, 4)).state === :Pending
    end
    for values in (Float32[NaN, 0, 0, 0], Float32[Inf, 0, 0, 0], zeros(Float32, 3), zeros(Float64, 4))
        observer, clock, _ = observer_inputs()
        @test frame!(observer, clock, 1, 1000, values).state === :Unknown
    end
    for event in (Val(:reset), Val(:invalidated))
        observer, clock, _ = observer_inputs()
        frame!(observer, clock, 1, 1000, fill(0.2f0, 4)); observer(event)
        @test frame!(observer, clock, 2, 1050, fill(0.2f0, 4)).state === :Pending
        @test frame!(observer, clock, 3, 1100, fill(0.2f0, 4)).state === :Pending
    end
    for (sequence, now) in ((3, 1050), (2, 1061), (2, 999))
        observer, clock, _ = observer_inputs()
        frame!(observer, clock, 1, 1000, fill(0.2f0, 4))
        value = frame!(observer, clock, sequence, now, fill(0.2f0, 4))
        @test value.state !== :Tripped
    end
end

@testset "Bounded atomic snapshot and read-only properties" begin
    observer, clock, _ = observer_inputs()
    binding = only(observer.bindings)
    @atomic binding.published.version = UInt64(1)
    @test only(CSO.snapshot(observer)) === nothing
    @atomic binding.published.version = UInt64(2)
    @test !isempty(CSO.property_info(observer))
    @test observer(PipeWireAO.SPA.Props(Pair{String,PipeWireAO.Pod}[]), true) isa PipeWireAO.SPA.Props
    frame!(observer, clock, 1, 1000, zeros(Float32, 4))
    # The control getter must never mutate the single-writer Supervisor.
    clock.now = 1061
    observer(PipeWireAO.SPA.Props(Pair{String,PipeWireAO.Pod}[]), true)
    @test CSO.state(binding.supervisor) === :Clear
end

function observer_allocation(observer, clock, outputs, metadata)
    clock.now += 1
    return @allocated observer(Val(:frame), outputs, metadata)
end
@testset "Warm callback allocation budget" begin
    observer, clock, _ = observer_inputs()
    outputs, metadata = (feedback=zeros(Float32, 4),), (feedback=header(1),)
    observer_allocation(observer, clock, outputs, metadata)
    @test observer_allocation(observer, clock, outputs, metadata) == 0
    observer(Val(:reset))
    @test @allocated(observer(Val(:invalidated))) == 0
end

function trip_observer!()
    observer, clock, policy = observer_inputs()
    frame!(observer, clock, 1, 1000, fill(0.2f0, 4))
    frame!(observer, clock, 2, 1050, fill(0.2f0, 4))
    frame!(observer, clock, 3, 1100, fill(0.2f0, 4))
    return observer, clock, policy
end

@testset "Explicit rearm intent is frame-owned, fenced and one-shot" begin
    observer, clock, _ = trip_observer!()
    @test CSO.request_rearm!(observer, 702) == 0
    token = CSO.request_rearm!(observer, 701)
    @test token > 0 && CSO.request_rearm!(observer, 701) == 0
    @test only(CSO.snapshot(observer)).state === :Tripped
    @test CSO.rearm_status(observer).acknowledged_token == 0
    # Replayed clear data is not a NEW successful sample.
    frame!(observer, clock, 3, 1150, zeros(Float32, 4))
    @test CSO.rearm_status(observer) == (requested_token=0,
        acknowledged_token=token, result=:refused)
    @test only(CSO.snapshot(observer)).state === :Tripped
    frame!(observer, clock, 4, 1200, zeros(Float32, 4))
    @test only(CSO.snapshot(observer)).state === :Tripped # No automatic retry.
    token2 = CSO.request_rearm!(observer, 701)
    @test token2 > token
    frame!(observer, clock, 5, 1250, zeros(Float32, 4))
    @test CSO.rearm_status(observer).result === :rearmed
    clear = only(CSO.snapshot(observer))
    @test clear.state === :Clear && clear.action === :none && clear.trip_sequence == 0
    @test clear.rearm_sequence == 5 && clear.rearm_ns == 1250
    # Rearm does not weaken sequence fencing.
    @test frame!(observer, clock, 5, 1300, fill(0.2f0, 4)).state === :Unknown
    @test frame!(observer, clock, 6, 1350, fill(0.2f0, 4)).state === :Pending

    # An intent staged after the callback captures its mailbox token waits
    # for the NEXT frame; exercise this exact capture/adopt boundary.
    observer, clock, _ = trip_observer!()
    captured = @atomic observer.rearm.request_token
    frame!(observer, clock, 4, 1150, zeros(Float32, 4))
    token = CSO.request_rearm!(observer, 701)
    CSO.adopt_rearm!(observer, captured, UInt64(1150))
    @test CSO.rearm_status(observer).requested_token == token
    @test only(CSO.snapshot(observer)).state === :Tripped
    frame!(observer, clock, 5, 1200, zeros(Float32, 4))
    @test CSO.rearm_status(observer).result === :rearmed
end

@testset "Multiple-output rearm refuses atomically on any uncleared latch" begin
    _, clock, policy = observer_inputs()
    formats = (; left=OBS_FORMATS.feedback, right=OBS_FORMATS.feedback)
    observer = CSO.Observer(formats, (; left=policy, right=policy); owner_instance=701, clock)
    high = fill(0.2f0, 4); clear = zeros(Float32, 4)
    for (sequence, now) in ((1, 1000), (2, 1050), (3, 1100))
        clock.now = now
        observer(Val(:frame), (;left=high, right=high), (;left=header(sequence), right=header(sequence)))
    end
    @test all(s -> s.state === :Tripped, CSO.snapshot(observer))
    token = CSO.request_rearm!(observer, 701)
    clock.now = 1150
    observer(Val(:frame), (;left=clear, right=high), (;left=header(4), right=header(4)))
    @test CSO.rearm_status(observer).result === :refused
    @test all(s -> s.state === :Tripped, CSO.snapshot(observer))
    @test CSO.request_rearm!(observer, 701) > token
    clock.now = 1200
    observer(Val(:frame), (;left=clear, right=clear), (;left=header(5), right=header(5)))
    @test CSO.rearm_status(observer).result === :rearmed
    @test all(s -> s.state === :Clear, CSO.snapshot(observer))
end

function successful_frame_allocation(observer, clock, outputs)
    clock.now += 1
    metadata = (feedback=header(clock.now),)
    return @allocated observer(Val(:frame), outputs, metadata)
end
@testset "Successful and rearm callback allocation budgets" begin
    observer, clock, _ = observer_inputs()
    outputs = (feedback=zeros(Float32, 4),)
    successful_frame_allocation(observer, clock, outputs)
    @test successful_frame_allocation(observer, clock, outputs) == 0
    observer, clock, _ = trip_observer!()
    CSO.request_rearm!(observer, 701)
    successful_frame_allocation(observer, clock, outputs) # Warm specialization/rearm branch.
    observer, clock, _ = trip_observer!()
    CSO.request_rearm!(observer, 701)
    @test successful_frame_allocation(observer, clock, outputs) == 0
end

@testset "Concurrent snapshots never expose mixed frame records" begin
    observer, clock, _ = observer_inputs()
    values = zeros(Float32, 4)
    seen_first = Threads.Atomic{Bool}(false)
    writer = Threads.@spawn begin
        for sequence in UInt64(1):UInt64(20000)
            clock.now = sequence + 1000
            observer(Val(:frame), (feedback=values,), (feedback=header(sequence),))
            if sequence == 1
                while !seen_first[]
                    yield()
                end
            end
            sequence % 100 == 0 && yield()
        end
    end
    reads = 0
    while !istaskdone(writer)
        value = only(CSO.snapshot(observer))
        if value !== nothing && value.sequence > 0
            @test value.observed_ns == value.sequence + 1000
            reads += 1
            seen_first[] = true
        end
        yield()
    end
    fetch(writer)
    @test reads > 0
end

struct ShiftedFeedback <: AbstractVector{Float32}
    values::Vector{Float32}
end
Base.size(values::ShiftedFeedback) = size(values.values)
Base.axes(values::ShiftedFeedback) = (Base.IdentityUnitRange(-2:(length(values.values)-3)),)
Base.getindex(values::ShiftedFeedback, index::Int) = (checkbounds(values, index); values.values[index+3])

function scalar_feedback_oracle(values, tolerance)
    clipped = 0
    for value in values
        isfinite(value) || return nothing
        clipped += abs(Float64(value)) > tolerance
    end
    return clipped / length(values)
end
@testset "Finite/count reductions preserve IEEE comparisons and arbitrary axes" begin
    cases = (Float32[0, -0.0, nextfloat(0f0), -nextfloat(0f0)],
        Float32[prevfloat(0.125f0), 0.125, nextfloat(0.125f0), -0.125],
        Float32[floatmax(Float32), -floatmax(Float32), floatmin(Float32), -floatmin(Float32)],
        Float32[NaN, 0, 1, -1], Float32[Inf, 0, 1, -1], Float32[-Inf, 0, 1, -1])
    for values in cases, tolerance in (0.0, Float64(nextfloat(0f0)), 0.125, floatmax(Float64))
        expected = scalar_feedback_oracle(values, tolerance)
        @test isequal(CSO.feedback_fraction(values, Val((4,)), tolerance), expected)
        @test isequal(CSO.feedback_fraction(ShiftedFeedback(values), Val((4,)), tolerance), expected)
        storage = repeat(values, inner=2)
        @test isequal(CSO.feedback_fraction(view(storage, 1:2:length(storage)), Val((4,)), tolerance), expected)
    end
end
