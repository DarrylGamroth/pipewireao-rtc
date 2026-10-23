# Optional extension regression; the application test environment supplies AOS/HIL.
using Test, PipeWireAORTC, AdaptiveOpticsSim, AdaptiveOpticsSimPipeWireHIL
const TimingExt = Base.get_extension(PipeWireAORTC, :PipeWireAORTCAOSExt)
const TimingRecorder = PipeWireAORTC.PhaseTiming

@testset "AOS phase capture assembly and pacing" begin
    @test TimingExt.prepare_phase_timing((;)) === nothing
    @test TimingExt.exchange_timing(nothing) === nothing
    @test TimingExt.next_deadline(UInt64(100), UInt64(20), UInt64(119)) == 120
    @test TimingExt.next_deadline(UInt64(100), UInt64(20), UInt64(120)) == 140
    @test TimingExt.next_deadline(UInt64(100), UInt64(20), UInt64(161)) == 180
    mktempdir() do directory
        owner = TimingExt.prepare_phase_timing((; phase_timing_directory=directory,
            phase_timing_frames=4, phase_timing_warmup=0, pacing_period_ns=UInt64(20),
            bootstrap_instance=Int64(7)))
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
        TimingExt.record_phase_timing!(owner, timing, frame, UInt64(100), UInt64(110), UInt64(140))
        gc_after = Base.gc_time_ns()
        @test owner.capture.rows[1][1:15] == (1,3,100,101,102,103,104,105,106,107,108,109,110,140,1)
        @test gc_before <= owner.capture.rows[1][16] <= gc_after
        @test owner.capture.rows[1][17] > 0
        @test TimingExt.exchange_timing(owner) === timing
        # Compile and warm the exact record call before checking its allocation.
        TimingExt.record_phase_timing!(owner, timing, frame, UInt64(100), UInt64(110), UInt64(140))
        @test TimingExt.exchange_timing(owner) === timing
        @test @allocated(TimingExt.record_phase_timing!(owner, timing, frame,
            UInt64(100), UInt64(110), UInt64(140))) == 0
        @test owner.capture.used == 3
        TimingExt.record_phase_timing!(owner, timing, frame, UInt64(100), UInt64(110), UInt64(140))
        @test TimingExt.exchange_timing(owner) === nothing
        TimingExt.save_phase_timing!(owner)
        @test isfile(joinpath(directory, "phase-timing-1.json"))
        TimingExt.reset_phase_timing!(owner, 2)
        @test owner.capture.generation == 2
        @test owner.capture.used == 0
        @test TimingExt.exchange_timing(owner) === timing
        unpaced = TimingExt.prepare_phase_timing((; phase_timing_directory=directory,
            phase_timing_frames=1, phase_timing_warmup=0, pacing_period_ns=UInt64(0),
            bootstrap_instance=Int64(8)))
        TimingExt.record_phase_timing!(unpaced, timing, frame, UInt64(0), UInt64(110), UInt64(0))
        @test unpaced.capture.rows[1][15] == 0
    end
end
