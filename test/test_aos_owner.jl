using Test
using FITSIO
using JSON
using PipeWireAORTC

const Owner = PipeWireAORTC.AOSOwner

function owner_configuration(directory; backend = "cpu")
    write(
        joinpath(directory, "simulation.yaml"), "schema_version: 1\nname: declared_test\n"
    )
    return Dict{String,Any}(
        "version" => 1,
        "graph" => "simulation.yaml",
        "command_input" => "pdm_command",
        "frame_output" => "detector_frame",
        "command_count" => 3,
        "frame_shape" => [2, 3],
        "rate" => 500,
        "exposure_ns" => 1_896_000,
        "pacing_rate_hz" => 10,
        "backend" => backend,
        "device" => 0,
        "artifacts" => [
            Dict{String,Any}(
                "binding" => "grid",
                "path" => "grid.fits",
                "hdu" => 1,
                "axes" => [2, 1],
                "type" => "UInt32",
                "shape" => [3, 2],
            ),
        ],
    )
end

@testset "AOS FITS binding ownership, order and cancellation" begin
    mktempdir() do directory
        path = joinpath(directory, "owner.conf")
        document = owner_configuration(directory)
        write(path, JSON.json(document))
        values = UInt32[1 2 3; 4 5 6]
        FITS(joinpath(directory, "grid.fits"), "w") do fits
            write(fits, values)
        end
        options = Owner.configuration(path)
        prepared = Owner.prepare_bindings(options.artifacts)
        @test only(prepared).data == permutedims(values)
        @test only(prepared).data isa Matrix{UInt32}
        @test only(prepared).provenance["axes"] == [2, 1]
        @test only(prepared).provenance["target_shape"] == [3, 2]
        @test_throws InterruptException Owner.prepare_bindings(
            options.artifacts; check = () -> throw(InterruptException())
        )
        @test sort(readdir(directory)) == ["grid.fits", "owner.conf", "simulation.yaml"]
        # Selection is exact, and the square case still requires explicit axes.
        document["artifacts"][1]["shape"] = [2, 3]
        write(path, JSON.json(document))
        @test_throws DimensionMismatch Owner.prepare_bindings(
            Owner.configuration(path).artifacts
        )
    end
end

mutable struct SourcePacingState
    running::Bool
    completed::Bool
    sequence::UInt64
    last_request_id::Int64
    deadline_ns::Int64
    host_ns::Union{Nothing,Int64}
end
SourcePacingState() = SourcePacingState(false, false, 0, 0, 0, nothing)

@testset "signed source pacing preserves Pause Run Reset and fences invalid clocks" begin
    control = PipeWireAORTC.SourceControl
    for origin in (typemin(Int64), -Int64(2)^60, Int64(2)^53 + 1)
        state = SourcePacingState()
        resets = Ref(0)
        reset = () -> (resets[] += 1)
        @test control.apply!(state, control.RUN, Int64(1), true, origin, Int64(1), reset) ==
            0
        @test state.running && state.deadline_ns === origin + 1
        state.sequence = 17
        @test control.apply!(
            state, control.RUN, Int64(2), false, origin + 1, Int64(1), reset
        ) == 0
        @test !state.running && state.sequence === UInt64(17)
        @test control.apply!(
            state, control.RUN, Int64(3), true, origin + 2, Int64(1), reset
        ) == 0
        @test state.running &&
            state.sequence === UInt64(17) &&
            state.deadline_ns === origin + 3
        @test control.apply!(
            state, control.RESET, Int64(4), false, origin + 3, Int64(1), reset
        ) == -Base.Libc.EBUSY
        @test resets[] == 0 && state.sequence == 17
        @test control.apply!(
            state, control.RUN, Int64(5), false, origin + 4, Int64(1), reset
        ) == 0
        @test control.apply!(
            state, control.RESET, Int64(6), false, origin + 5, Int64(1), reset
        ) == 0
        @test resets[] == 1 && state.sequence === UInt64(0) && state.host_ns === origin + 5
        @test_throws ArgumentError control.apply!(
            state, control.RUN, Int64(7), true, origin + 4, Int64(1), reset
        )
        @test !state.running && state.last_request_id == 6 && state.host_ns === origin + 5
    end
    state = SourcePacingState()
    @test_throws OverflowError control.apply!(
        state, control.RUN, Int64(1), true, typemax(Int64), Int64(1), () -> nothing
    )
    @test !state.running && state.deadline_ns === Int64(0)
    state = SourcePacingState()
    @test_throws ArgumentError control.apply!(
        state, control.RUN, Int64(1), true, Int64(0), Int64(-1), () -> nothing
    )
    @test state.last_request_id == 0 && state.host_ns === nothing
    @test Owner.pacing_period(0, 500) === Int64(0)
    @test_throws ArgumentError Owner.pacing_period(1e-10, 500)
end
