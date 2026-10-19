# Optional integration check: run with an environment containing registered AOS
# and HIL, plus this RTC checkout. No PipeWire daemon or GPU is required.
using Test
using FITSIO
using JSON3
using PipeWireAORTC
using AdaptiveOpticsSim
using AdaptiveOpticsSim.AlgorithmGraphs
using AdaptiveOpticsSimPipeWireHIL

const AOSPreparationOwner = PipeWireAORTC.AOSOwner

@testset "FITS-driven AOS graph preparation and deterministic reset" begin
    mktempdir() do directory
        graph_path = joinpath(directory, "simulation.toml")
        write(graph_path, """
            schema_version = 1
            name = "declared_modal_detector"
            [[nodes]]
            name = "modal"
            type = "modal_opd_expansion_f32"
            [nodes.config]
            pupil_rows = 2
            pupil_columns = 3
            mode_count = 3
            coefficients_schema = "test.aos.command/1"
            opd_schema = "test.aos.frame/1"
            basis_schema = "test.aos.basis/1"
            pupil_support_schema = "test.aos.pupil/1"
            [[inputs]]
            name = "command"
            destination = "modal.coefficients"
            binding = "command"
            [[outputs]]
            name = "frame"
            source = "modal.opd"
            [[parameters]]
            destination = "modal.basis"
            binding = "basis"
            [[parameters]]
            destination = "modal.pupil_support"
            binding = "pupil"
            """)
        basis = reshape(Float32.(1:18), 2, 3, 3)
        pupil = UInt8[1 1 0; 0 1 1]
        for (name, values) in (("basis", basis), ("pupil", pupil))
            FITS(joinpath(directory, name * ".fits"), "w") do fits
                write(fits, values)
            end
        end
        document = Dict{String,Any}(
            "version" => 1, "graph" => "simulation.toml", "command_input" => "command",
            "frame_output" => "frame", "command_count" => 3, "frame_shape" => [2, 3],
            "rate" => 500, "exposure_ns" => 1_896_000, "wall_rate" => 10,
            "backend" => "cpu", "device" => 0,
            "artifacts" => [
                Dict("binding" => "basis", "path" => "basis.fits", "axes" => [1,2,3], "type" => "Float32", "shape" => [2,3,3]),
                Dict("binding" => "pupil", "path" => "pupil.fits", "axes" => [1,2], "type" => "Bool", "shape" => [2,3])])
        config_path = joinpath(directory, "owner.conf")
        write(config_path, JSON3.write(document))
        options = AOSPreparationOwner.configuration(config_path)
        science = AOSPreparationOwner.prepare_science(options)
        @test length(science.artifacts) == 2
        @test science.artifacts[1].data == basis
        @test science.artifacts[2].data == (pupil .== 1)
        @test model_time_sequence(science.driver) == 0
        @test all(iszero, hil_command_buffer(science.boundary))
        @test size(hil_frame_buffer(science.boundary)) == (2, 3)
        first_frame = step_hil_frame_at!(science.boundary, science.driver)
        @test first_frame.sequence == 1
        @test all(iszero, hil_frame_buffer(science.boundary))
        copyto!(hil_command_buffer(science.boundary), Float32[1, 2, 3])
        adopt_hil_command!(science.boundary, first_frame.sequence)
        second_frame = step_hil_frame_at!(science.boundary, science.driver)
        expected = (basis[:,:,1] + 2basis[:,:,2] + 3basis[:,:,3]) .* pupil
        @test hil_frame_buffer(science.boundary) == expected
        adopt_hil_command!(science.boundary, second_frame.sequence)
        reset_hil_boundary!(science.boundary, science.driver)
        @test model_time_sequence(science.driver) == 0
        @test all(iszero, hil_command_buffer(science.boundary))
        replay = step_hil_frame_at!(science.boundary, science.driver)
        @test all(iszero, hil_frame_buffer(science.boundary))
        adopt_hil_command!(science.boundary, replay.sequence)
        @test_throws InterruptException AOSPreparationOwner.prepare_science(options;
            check=() -> throw(InterruptException()))
        # Binding declaration validation precedes opening artifacts.
        rm(joinpath(directory, "basis.fits"))
        mismatched = merge(options, (; command_input=:unknown_command))
        @test_throws ArgumentError AOSPreparationOwner.prepare_science(mismatched)
    end
end
