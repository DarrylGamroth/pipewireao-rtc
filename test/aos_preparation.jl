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
const AOSReportExtension = Base.get_extension(PipeWireAORTC, :PipeWireAORTCAOSExt)
const AOSReportControl = PipeWireAORTC.NativeSourceControl
const AOSReportBootstrap = PipeWireAORTC.NativeOwnerBootstrapRuntime

mutable struct ReportPreparationRuntime
    failure::Union{Nothing,Exception}
    prepared::Bool
    finishing::Bool
end
AOSReportBootstrap.fault!(runtime::ReportPreparationRuntime, error::Exception) = (runtime.failure = error; nothing)
AOSReportBootstrap.prepared!(runtime::ReportPreparationRuntime) = (runtime.prepared = true; nothing)
AOSReportBootstrap.finishing!(runtime::ReportPreparationRuntime) = (runtime.finishing = true; nothing)

mutable struct ReportControlTransport
    generation::Int64
end
AdaptiveOpticsSimPipeWireHIL.with_frame_stream(f, ::ReportControlTransport) = f(nothing)
AdaptiveOpticsSimPipeWireHIL.frame_acquisition_generation(transport::ReportControlTransport) = transport.generation

@testset "AOS report save precedes native report readiness and reset ACK" begin
    mktempdir() do directory
        graph = joinpath(directory, "simulation.toml")
        write(graph, "schema_version = 1\nname = \"report_order\"\n")
        options = (; remote=joinpath(directory, "native"), control_node="simulator-wfs",
            bootstrap_instance=Int64(7), backend=:cpu, graph)
        state = AOSReportExtension.OwnerState()
        mailbox = AOSReportExtension.prepare_source_control(options, state, Int64(9))
        initial = PipeWireAORTC.Common.read_json(AOSPreparationOwner.report_path(options))
        @test initial["generation"] == mailbox.report_generation == 1
        @test initial["sequence"] == mailbox.report_sequence == 0
        @test initial["source_instance"] == mailbox.instance == 9
        state.sequence = 4
        AOSReportExtension.save_report!(options, mailbox, state, Int64(1))
        @test mailbox.report_generation == 1 && mailbox.report_sequence == 4
        blocked = merge(options, (; remote=joinpath(directory, "blocked", "native")))
        path = AOSPreparationOwner.report_path(blocked)
        mkpath(path)
        write(joinpath(path, "retained"), "do not replace this directory")
        @test_throws Base.IOError AOSReportExtension.save_report!(blocked, mailbox, state, Int64(2))
        @test mailbox.report_generation == 1 && mailbox.report_sequence == 4
        @test_throws Base.IOError AOSReportExtension.prepare_source_control(blocked, state, Int64(10))
        # The actual control consumer reaches a real failed filesystem save
        # after applying reset, before any Stream publication can occur.
        AOSReportControl.stage!(mailbox, AOSReportControl.RESET, Int64(1))
        transport = ReportControlTransport(1)
        @test_throws Base.IOError AOSReportExtension.consume_control!(blocked, mailbox, transport,
            state, UInt64(0), () -> (transport.generation = 2))
        @test state.sequence == 0
        @test mailbox.kind == AOSReportControl.RESET && mailbox.token == 1
        @test mailbox.last_token == 0
        @test mailbox.report_generation == 1 && mailbox.report_sequence == 4
        @test read(joinpath(path, "retained"), String) == "do not replace this directory"
    end
end

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
        @testset "initial report failure prevents native preparation" begin
            runtime = ReportPreparationRuntime(nothing, false, false)
            invocation = merge(options, (; remote=joinpath(directory, "private", "native"),
                control_node="simulator-wfs", bootstrap_instance=Int64(7),
                bootstrap_runtime=runtime, owner_check=() -> nothing))
            blocked = AOSPreparationOwner.report_path(invocation)
            mkpath(blocked)
            write(joinpath(blocked, "retained"), "preserve")
            failure = try
                AOSPreparationOwner.run_owner(invocation)
                nothing
            catch error
                error
            end
            @test failure isa CompositeException
            @test runtime.failure isa Base.IOError
            @test failure.exceptions[1] === runtime.failure
            @test length(failure.exceptions) == 2
            @test failure.exceptions[2] isa Base.IOError
            @test !runtime.prepared && runtime.finishing
            @test read(joinpath(blocked, "retained"), String) == "preserve"
        end
        # Binding declaration validation precedes opening artifacts.
        rm(joinpath(directory, "basis.fits"))
        mismatched = merge(options, (; command_input=:unknown_command))
        @test_throws ArgumentError AOSPreparationOwner.prepare_science(mismatched)
    end
end
