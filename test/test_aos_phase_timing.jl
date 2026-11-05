# Optional extension regression; the application test environment supplies AOS/HIL.
using Test, PipeWireAORTC, AdaptiveOpticsSim, AdaptiveOpticsSimPipeWireHIL
const TimingExt = Base.get_extension(PipeWireAORTC, :PipeWireAORTCAOSExt)
const TimingRecorder = PipeWireAORTC.PhaseTiming

@testset "AOS phase capture assembly and pacing" begin
    @test TimingExt.prepare_phase_timing((;)) === nothing
    @test TimingExt.exchange_timing(nothing) === nothing
    @test TimingExt.next_deadline(Int64(100), Int64(20), Int64(119)) == 120
    @test TimingExt.next_deadline(Int64(100), Int64(20), Int64(120)) == 140
    @test TimingExt.next_deadline(Int64(100), Int64(20), Int64(161)) == 180
    mktempdir() do directory
        owner = TimingExt.prepare_phase_timing((;
            phase_timing_directory = directory,
            phase_timing_frames = 4,
            phase_timing_warmup = 0,
            pacing_period_ns = UInt64(20),
            bootstrap_instance = Int64(7),
        ))
        @test isempty(readdir(directory))
        @test owner.capture.seen == 0 &&
            owner.capture.used == 0 &&
            owner.capture.saved_count == -1
        @test owner.capture.generation == 0 &&
            all(iszero, Iterators.flatten(owner.capture.rows))
        timing = owner.exchange
        timing.generation = 1
        timing.sequence = 3
        timing.started_ns = 101
        timing.ready_ns = 102
        timing.step_started_ns = 103
        timing.step_finished_ns = 104
        timing.staged_ns = 105
        timing.adoption_started_ns = 108
        timing.finished_ns = 109
        frame = PipeWireFrameCommandTiming(UInt64(3), Int64(106), Int64(107))
        gc_before = Base.gc_time_ns()
        TimingExt.record_phase_timing!(
            owner, timing, frame, Int64(100), Int64(110), Int64(140)
        )
        gc_after = Base.gc_time_ns()
        @test owner.capture.rows[1][1:15] ==
            (1, 3, 100, 101, 102, 103, 104, 105, 106, 107, 108, 109, 110, 140, 1)
        @test gc_before <= owner.capture.rows[1][16] <= gc_after
        @test owner.capture.rows[1][17] > 0
        @test TimingExt.exchange_timing(owner) === timing
        # Compile and warm the exact record call before checking its allocation.
        TimingExt.record_phase_timing!(
            owner, timing, frame, Int64(100), Int64(110), Int64(140)
        )
        @test TimingExt.exchange_timing(owner) === timing
        @test @allocated(
            TimingExt.record_phase_timing!(
                owner, timing, frame, Int64(100), Int64(110), Int64(140)
            )
        ) == 0
        @test owner.capture.used == 3
        TimingExt.record_phase_timing!(
            owner, timing, frame, Int64(100), Int64(110), Int64(140)
        )
        @test TimingExt.exchange_timing(owner) === nothing
        TimingExt.save_phase_timing!(owner)
        @test isfile(joinpath(directory, "phase-timing-1.json"))
        TimingExt.reset_phase_timing!(owner, 2)
        @test owner.capture.generation == 2
        @test owner.capture.used == 0
        @test TimingExt.exchange_timing(owner) === timing
        unpaced = TimingExt.prepare_phase_timing((;
            phase_timing_directory = directory,
            phase_timing_frames = 1,
            phase_timing_warmup = 0,
            pacing_period_ns = UInt64(0),
            bootstrap_instance = Int64(8),
        ))
        TimingExt.record_phase_timing!(
            unpaced, timing, frame, Int64(0), Int64(110), Int64(0)
        )
        @test unpaced.capture.rows[1][15] == 0
    end
end

function pacing_cycles(deadline::Int64, period::Int64, count::Int)
    for _ in 1:count
        deadline = TimingExt.next_deadline(deadline, period, deadline + 1)
    end
    return deadline
end

@testset "signed pacing retains exact phase and checked diagnostic boundaries" begin
    for origin in (typemin(Int64), -Int64(2)^60, Int64(2)^53 + 1)
        @test TimingExt.next_deadline(origin, Int64(20), origin + 19) === origin + 20
        @test TimingExt.next_deadline(origin, Int64(20), origin + 20) === origin + 40
        @test TimingExt.next_deadline(origin, Int64(20), origin + 61) === origin + 80
    end
    pacing_cycles(Int64(-1_000_000), Int64(20), 1000)
    @test @allocated(pacing_cycles(Int64(-1_000_000), Int64(20), 1000)) == 0
    # Full signed elapsed arithmetic must not wrap the missed-period count.
    @test TimingExt.next_deadline(typemin(Int64), Int64(1), typemax(Int64) - 1) ===
        typemax(Int64)
    @test_throws OverflowError TimingExt.next_deadline(
        typemax(Int64), Int64(1), typemax(Int64)
    )
    @test_throws ArgumentError TimingExt.next_deadline(Int64(0), Int64(0), Int64(0))
    state = TimingExt.OwnerState()
    @test TimingExt.SourceControl.observe_clock!(state, Int64(-2)) === Int64(-2)
    @test TimingExt.SourceControl.observe_clock!(state, Int64(-1)) === Int64(-1)
    @test_throws ArgumentError TimingExt.SourceControl.observe_clock!(state, Int64(-2))
    @test state.host_ns === Int64(-1) &&
        state.sequence === UInt64(0) &&
        state.generation === Int64(1)
    mktempdir() do directory
        owner = TimingExt.prepare_phase_timing((;
            phase_timing_directory = directory,
            phase_timing_frames = 1,
            phase_timing_warmup = 0,
            pacing_period_ns = Int64(20),
            bootstrap_instance = Int64(7),
        ))
        timing = owner.exchange
        timing.sequence = 3
        frame = PipeWireFrameCommandTiming(UInt64(3), Int64(106), Int64(107))
        @test_throws InexactError TimingExt.record_phase_timing!(
            owner, timing, frame, Int64(-1), Int64(110), Int64(140)
        )
        @test owner.capture.used == 0 && owner.capture.seen == 0
    end
end

# Controlled producer and worker I/O: exercise the real host throttle without
# running an optical graph, changing scientific model chronology, or opening a core.
const ClockObservation = TimingExt.OpticalObservation
const ClockPupil = TimingExt.PupilOutput
const ClockHIL = AdaptiveOpticsSimPipeWireHIL
const ClockGraphs = AdaptiveOpticsSim.AlgorithmGraphs
const ClockAPI = TimingExt.Clocks
mutable struct ClockSnapshot
    count::Int
    pts::Int64
    model_ns::Int64
end
function ClockGraphs.try_snapshot_graph_output!(
    snapshot::ClockSnapshot; generation, pts, model_time_ns
)
    snapshot.count += 1
    snapshot.pts = pts
    snapshot.model_ns = model_time_ns
    return true
end
ClockGraphs.release_graph_output_snapshot!(::ClockSnapshot) = nothing
function clock_observation()
    snapshot = ClockSnapshot(0, 0, 0)
    values = zeros(Float32, 1, 1)
    return ClockObservation.Observation(
        snapshot,
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
        UInt64(1),
        nothing,
        nothing,
        nothing,
    )
end
@testset "optical host throttle preserves model stamps and rejects regression/overflow" begin
    frame = PipeWireFrameCommandTiming(UInt64(7), Int64(11), Int64(12))
    for origin in (-Int64(2)^60, Int64(2)^53 + 1)
        observation = clock_observation()
        @test ClockObservation.sample!(observation, frame, Int64(81), origin)
        @test observation.snapshot.count == 1 &&
            observation.snapshot.pts == 11 &&
            observation.snapshot.model_ns == 81
        ClockObservation.release!(observation)
        limit = origin + ClockObservation.PERIOD_NS
        @test !ClockObservation.sample!(observation, frame, Int64(82), limit - 1)
        @test ClockObservation.sample!(observation, frame, Int64(83), limit)
        ClockObservation.release!(observation)
        @test !ClockObservation.sample!(observation, frame, Int64(84), limit - 1)
        @test observation.failed[] &&
            observation.snapshot.count == 2 &&
            observation.host_ns === limit
    end
    observation = clock_observation()
    @test !ClockObservation.sample!(observation, frame, Int64(81), typemax(Int64))
    @test observation.failed[] && observation.snapshot.count == 0 && !observation.busy[]
end

mutable struct OutputClock <: ClockAPI.AbstractNanoClock
    values::Vector{Int64}
    reads::Int
    stop::Base.RefValue{Bool}
    advanced_ns::Int64
end
function ClockAPI.time_nanos(clock::OutputClock)
    clock.reads += 1
    clock.reads == length(clock.values) && (clock.stop[] = true)
    return clock.values[clock.reads] + clock.advanced_ns
end
mutable struct ClockOutputStream
    clock::OutputClock
    triggers::Vector{Int64}
    trigger_work_ns::Int64
    status_work_ns::Int64
end
struct ClockOutputOptions
    stream::ClockOutputStream
end
mutable struct ClockPublisher
    options::ClockOutputOptions
    period_ns::UInt64
    stop::Base.RefValue{Bool}
    paused::Base.RefValue{Bool}
    failed::Base.RefValue{Bool}
    registered::Base.RefValue{Bool}
    drain_request::Base.RefValue{UInt64}
    drained::Base.RefValue{UInt64}
    flushed::Base.RefValue{UInt64}
    generation::Base.RefValue{UInt64}
    clock::OutputClock
    status::Vector{Tuple{Int64,Bool}}
end
ClockHIL.with_array_streams(f, options::Tuple{ClockOutputOptions}; remote, input) =
    f(only(options).stream)
ClockHIL.array_stream_status(::ClockOutputStream, ::Int) = (; pending = true)
ClockHIL.with_array_stream(f, stream::ClockOutputStream, ::Int) = f(stream)
ClockPupil.process_sample!(::ClockPublisher, ::ClockOutputStream) = false
const ClockPW = TimingExt.PipeWireAO
ClockPW.node_id(::ClockOutputStream) = UInt32(9)
ClockPW.stream_state(::ClockOutputStream) = ClockPW.LibPipeWire.PW_STREAM_STATE_STREAMING
ClockPW.is_driving(::ClockOutputStream) = true
function ClockPW.trigger_process!(stream::ClockOutputStream)
    push!(
        stream.triggers, stream.clock.values[stream.clock.reads] + stream.clock.advanced_ns
    )
    stream.clock.advanced_ns += stream.trigger_work_ns
    return nothing
end
function ClockPupil.publish_status!(
    p::ClockPublisher, ::ClockOutputStream; failure = nothing
)
    push!(
        p.status, (p.clock.values[p.clock.reads] + p.clock.advanced_ns, failure !== nothing)
    )
    p.clock.advanced_ns += p.options.stream.status_work_ns
    return nothing
end
function run_output_clock(
    values;
    paused = true,
    trigger_work_ns = Int64(0),
    status_work_ns = Int64(0),
    worker = ClockPupil.worker!,
)
    stop = Ref(false)
    clock = OutputClock(values, 0, stop, 0)
    publisher = ClockPublisher(
        ClockOutputOptions(
            ClockOutputStream(clock, Int64[], trigger_work_ns, status_work_ns)
        ),
        UInt64(2_000_000),
        stop,
        Ref(paused),
        Ref(false),
        Ref(false),
        Ref(UInt64(0)),
        Ref(UInt64(0)),
        Ref(UInt64(1)),
        Ref(UInt64(1)),
        clock,
        Tuple{Int64,Bool}[],
    )
    worker(publisher, "unused", nothing; clock)
    return publisher
end
@testset "pupil worker status uses one signed decision sample per loop" begin
    for origin in (-Int64(2)^60, Int64(2)^53 + 1)
        p = run_output_clock([
            origin, origin, origin + 99_999_999, origin + 100_000_000, origin + 100_000_000
        ])
        @test p.clock.reads == 5
        @test p.status == [(origin, false), (origin + 100_000_000, false)]
        @test !p.failed[] && p.period_ns === UInt64(2_000_000)
    end
    p = run_output_clock(Int64[2, 2, 1, 1, 2])
    @test p.failed[] && p.status == [(Int64(2), false), (Int64(1), true)]
    p = run_output_clock(Int64[typemax(Int64), typemax(Int64)])
    @test p.failed[] && p.status == [(typemax(Int64), false), (typemax(Int64), true)]
    for origin in (-Int64(2)^60, Int64(2)^53 + 1)
        p = run_output_clock(
            [
                origin,
                origin,
                origin,
                origin + 1_999_999,
                origin + 2_000_000,
                origin + 2_000_000,
            ];
            paused = false,
        )
        @test p.clock.reads == 6 && p.registered[]
        @test p.options.stream.triggers == [origin, origin + 2_000_000]
        @test p.status == [(origin, false)] && !p.failed[]
    end
end

@testset "pupil worker relative periods begin after slow native I/O completion" begin
    origin = Int64(2)^53 + 1
    trigger = run_output_clock(
        fill(origin, 4); paused = false, trigger_work_ns = Int64(3_000_000)
    )
    @test trigger.options.stream.triggers == [origin]
    @test trigger.clock.reads == 4 && !trigger.failed[]
    status = run_output_clock(fill(origin, 3); status_work_ns = Int64(150_000_000))
    @test status.status == [(origin, false)]
    @test status.clock.reads == 3 && !status.failed[]
end
