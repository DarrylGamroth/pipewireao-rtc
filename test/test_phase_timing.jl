using Test
using PipeWireAORTC

module PhaseTimingTestHost
const Common = Main.PipeWireAORTC.Common
include("../src/owners/phase_timing.jl")
end

const PhaseTiming = PhaseTimingTestHost.PhaseTiming

phase_row(generation, sequence) =
    (UInt64(generation), UInt64(sequence), ntuple(UInt64, 15)...)

@testset "phase timing capture declarations and bounds" begin
    mktempdir() do directory
        @test_throws ArgumentError PhaseTiming.Capture("relative", 0, 1, 1, 1)
        @test_throws ArgumentError PhaseTiming.Capture(directory, -1, 1, 1, 1)
        @test_throws ArgumentError PhaseTiming.Capture(directory, 0, 0, 1, 1)
        @test_throws ArgumentError PhaseTiming.Capture(directory, 0, 65_537, 1, 1)
        @test_throws ArgumentError PhaseTiming.Capture(directory, 0, 1, 1, 0)
        unpaced = PhaseTiming.Capture(directory, 0, 1, 0, 1)
        @test unpaced.period_ns == 0

        capture = PhaseTiming.Capture(directory, 2, 2, 2_000_000, 9)
        @test length(capture.rows) == 2
        @test !PhaseTiming.wants_sample(nothing)
        @test PhaseTiming.wants_sample(capture)
        @test PhaseTiming.record!(nothing, phase_row(1, 1)) === nothing
        @test PhaseTiming.reset!(nothing, 1) === nothing
        @test PhaseTiming.save!(nothing) === nothing

        PhaseTiming.record!(capture, phase_row(1, 1))
        PhaseTiming.record!(capture, phase_row(1, 2))
        @test capture.used == 0
        PhaseTiming.record!(capture, phase_row(1, 3))
        PhaseTiming.record!(capture, phase_row(1, 4))
        @test capture.used == 2
        @test !PhaseTiming.wants_sample(capture)
        PhaseTiming.record!(capture, phase_row(1, 5))
        @test capture.used == 2
        @test_throws ArgumentError PhaseTiming.record!(capture, phase_row(2, 6))
        @test_throws ArgumentError PhaseTiming.reset!(capture, 2)

        @test PhaseTiming.save!(capture) === nothing
        path = joinpath(directory, "phase-timing-1.json")
        report = PipeWireAORTC.Common.read_json(path)
        @test report["version"] == 1
        @test report["owner_pid"] == getpid()
        @test report["bootstrap_instance"] == 9
        @test report["generation"] == 1
        @test report["period_ns"] == 2_000_000
        @test report["warmup_frames"] == 2
        @test report["capacity"] == 2
        @test report["record_count"] == 2
        @test report["capture_complete"]
        @test report["columns"] == collect(String.(PhaseTiming.COLUMNS))
        @test report["rows"] == [collect(phase_row(1, 3)), collect(phase_row(1, 4))]
        @test PhaseTiming.save!(capture) === nothing
        @test sort(readdir(directory)) == ["phase-timing-1.json"]

        PhaseTiming.reset!(capture, 2)
        @test capture.seen == 0 && capture.used == 0 && capture.saved_count == -1
        PhaseTiming.record!(capture, phase_row(2, 1))
        PhaseTiming.record!(capture, phase_row(2, 2))
        PhaseTiming.record!(capture, phase_row(2, 3))
        PhaseTiming.save!(capture)
        conflict = joinpath(directory, "phase-timing-3.json")
        PhaseTiming.reset!(capture, 3)
        mkdir(conflict)
        write(joinpath(conflict, "retained"), "keep")
        PhaseTiming.record!(capture, phase_row(3, 1))
        PhaseTiming.record!(capture, phase_row(3, 2))
        PhaseTiming.record!(capture, phase_row(3, 3))
        @test_throws ArgumentError PhaseTiming.save!(capture)
        @test read(joinpath(conflict, "retained"), String) == "keep"
        @test isfile(joinpath(directory, "phase-timing-2.json"))
        @test length(readdir(directory)) == 3

        symlink_capture = PhaseTiming.Capture(directory, 0, 4, 2_000_000, 9)
        PhaseTiming.reset!(symlink_capture, 4)
        target = joinpath(directory, "symlink-target")
        write(target, "keep target")
        symlink(target, joinpath(directory, "phase-timing-4.json"))
        PhaseTiming.record!(symlink_capture, phase_row(4, 1))
        PhaseTiming.record!(symlink_capture, phase_row(4, 2))
        PhaseTiming.record!(symlink_capture, phase_row(4, 3))
        @test_throws ArgumentError PhaseTiming.save!(symlink_capture)
        @test islink(joinpath(directory, "phase-timing-4.json"))
        @test read(target, String) == "keep target"
    end
end

@testset "phase timing same-generation save replaces only the report file" begin
    mktempdir() do directory
        capture = PhaseTiming.Capture(directory, 0, 4, 2_000_000, 12)
        PhaseTiming.reset!(capture, 7)
        PhaseTiming.record!(capture, phase_row(7, 1))
        PhaseTiming.save!(capture)
        path = joinpath(directory, "phase-timing-7.json")
        open(path, "r") do prior
            PhaseTiming.record!(capture, phase_row(7, 2))
            PhaseTiming.save!(capture)
            old_document = PipeWireAORTC.Common.parse_json(String(read(prior)))
            new_document = PipeWireAORTC.Common.read_json(path)
            @test old_document["record_count"] == 1
            @test new_document["record_count"] == 2
            @test new_document["rows"][2] == collect(phase_row(7, 2))
        end
        @test PhaseTiming.save!(capture) === nothing
        @test sort(readdir(directory)) == ["phase-timing-7.json"]
    end
end

@testset "phase timing warmed recording allocation" begin
    mktempdir() do directory
        capture = PhaseTiming.Capture(directory, 0, 4, 2_000_000, 11)
        PhaseTiming.reset!(capture, 1)
        row = phase_row(1, 1)
        PhaseTiming.record!(capture, row)
        allocated = @allocated PhaseTiming.record!(capture, row)
        @test allocated == 0
    end
end
