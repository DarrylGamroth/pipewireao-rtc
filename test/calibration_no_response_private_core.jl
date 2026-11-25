# CPU/native selector. Run with --threads=4,1.
module CalibrationNoResponsePrivateCoreTests
using Test, PipeWireAO, PipeWireAORTC, FilterGraphAlgorithms, FilterGraphPipeWire, FilterGraphs
using AdaptiveOpticsSim, AdaptiveOpticsSimPipeWireHIL, AdaptiveOpticsCalibration
include("control_private_core.jl")
include("aos_graph_documents.jl")
include("helpers/calibration_application.jl")
const C = PipeWireAORTC.InstrumentCalibration
const E = PipeWireAORTC.CalibrationEndpoint
const A = PipeWireAORTC.CalibrationActionCodec
const Client = PipeWireAORTC.CalibrationActionClient
const Control = PipeWireAORTC.ControlClient
const Ext = Base.get_extension(PipeWireAORTC, :PipeWireAORTCCalibrationExt)

function write_calibration_plant(application)
    wire_contract = Dict(
        "frame_encoding" => "uint16",
        "frame_schema" => FilterGraphAlgorithms.RAW_DETECTOR_PIXELS_V1,
        "command_schema" => FilterGraphAlgorithms.DEMANDED_PDM_COMMAND_V1,
        "command_scale" => 1,
    )
    (; path, document) = modal_simulation_source(application; wire_contract)
    configuration = PipeWireAORTC.InstrumentConfiguration
    declaration = configuration.load_simulation(path)
    merge!(
        document,
        wire_contract,
        Dict(
            "command_input" => "command",
            "frame_output" => "frame",
            "frame_shape" => [2, 2],
            "prescription_identity" => configuration.prescription_identity(
                declaration, configuration.settings(declaration),
            ),
        ),
    )
    PipeWireAORTC.ScienceExport.write_spa_config(joinpath(application, "simulation.conf"), document)
end

application_hashes(application) = Dict(
    relpath(joinpath(dir, filename), application) => C.digest(joinpath(dir, filename)) for
    (dir, _, files) in walkdir(application) for filename in files
)

@testset "consumer-only native Collect keeps full ADC samples and exact bounded receipts" begin
    Threads.nthreads(:default) >= 4 || error("run with at least four Julia default threads")
    mktempdir() do application
        background = Float32[1 3; 2 4]
        write_calibration_controller(application, background)
        write_calibration_plant(application)
        before = application_hashes(application)
        with_control_private_core() do remote, directory, daemon
            chmod(dirname(remote), 0o700)
            frontend = command = server = client = serving = nothing
            seen = Any[]
            fail = Ref(false)
            consume = function (sample, exposure)
                push!(
                    seen,
                    (;
                        identity = sample.metadata.raw.identity,
                        output_identity = sample.metadata.calibrated.identity,
                        raw = copy(sample.arrays.raw),
                        calibrated = copy(sample.arrays.calibrated),
                    ),
                )
                fail[] && error("bounded online consumer failed")
                nothing
            end
            try
                frontend = C.calibration_graph(
                    application;
                    inputs = (raw = "pixels:raw",),
                    outputs = (calibrated = "pixels:calibrated",),
                )
                command = C.calibration_graph(
                    application;
                    inputs = (requested = "conditioner:requested",),
                    outputs = (:demanded, Symbol("constraint-feedback")),
                )
                count = only(FilterGraphs.input_formats(command.graph).requested.shape)
                shape = FilterGraphs.input_formats(frontend.graph).raw.shape
                reference = zeros(Float32, count)
                name = "test.consumer-only.$(getpid())"
                instance = Int64(501)
                deadline = Control.monotonic() + 120
                @test_throws ArgumentError C.prepare_initial_calibration(
                    application,
                    remote,
                    frontend,
                    command;
                    reference,
                    name,
                    instance,
                    deadline,
                    measurements = nothing,
                )
                server = C.prepare_initial_calibration(
                    application,
                    remote,
                    frontend,
                    command;
                    reference,
                    name,
                    instance,
                    deadline,
                    measurements = nothing,
                    consume,
                )
                frontend = command = nothing
                owner = server.effects
                @test owner.measurements === nothing
                serving = @async try
                    E.serve!(server; deadline = deadline)
                    nothing
                catch error
                    error
                end
                client = Client.connect(
                    Client.Binding(remote, name, getpid(), instance),
                    UInt64(1),
                    Int64(600_000_000_000);
                    command_count = count,
                    deadline,
                )
                action(value) = Client.complete!(client, value; deadline, record = false)
                @test action(A.Hold()) isa A.Held
                figure = Float32[0.5, 0.5]
                adopted = action(A.Adopt(UInt32(0), figure))
                @test adopted isa A.Adopted && !adopted.clipped && adopted.figure == figure
                settled = action(
                    A.Settle(UInt32(0), adopted.cursor, A.DiscardExposures(UInt32(1)))
                )
                @test settled isa A.Settled && settled.cursor.sequence == 1
                @test isempty(seen) # Settling is never delivered to the consumer.
                for (measurements, frames) in
                    ((UInt32(1), UInt32(1)), (UInt32(0), UInt32(4096)))
                    rejected = action(
                        A.Collect(UInt32(0), settled.cursor, measurements, frames)
                    )
                    @test rejected isa A.Failed && rejected.reason === A.InvalidEvidence
                    @test owner.cursor == settled.cursor && isempty(seen)
                end
                result = action(A.Collect(UInt32(0), settled.cursor, UInt32(0), UInt32(2)))
                @test result isa A.Responses &&
                    result.values isa Vector{Float32} &&
                    isempty(result.values)
                @test result.valid && length(result.exposures) == length(seen) == 2
                expected = UInt16[3 0; 4 6]
                @test all(sample -> sample.raw isa Matrix{UInt16} && size(sample.raw) == shape, seen)
                @test all(sample -> sample.raw == expected, seen)
                @test all(sample -> sample.calibrated == Float32.(expected) .- background, seen)
                @test all(sample -> sample.identity == sample.output_identity, seen)
                @test all(sample -> sample.identity.domain == owner.acquisition_domain, seen)
                @test [sample.identity.sequence for sample in seen] ==
                    [value.sequence for value in result.exposures] ==
                    [2, 3]
                @test all(
                    sample.identity.generation == value.generation for
                    (sample, value) in zip(seen, result.exposures)
                )
                fail[] = true
                adopted = action(A.Adopt(UInt32(1), reference))
                settled = action(A.Settle(UInt32(1), adopted.cursor, A.Immediate()))
                result = action(A.Collect(UInt32(1), settled.cursor, UInt32(0), UInt32(2)))
                @test result isa A.Responses && isempty(result.values) && !result.valid
                @test length(result.exposures) == 2 &&
                    [value.sequence for value in result.exposures] == [4, 5]
                @test length(seen) == 3 && owner.cursor.sequence == 5 && owner.consumer_failed
                adopted = action(A.Adopt(UInt32(2), reference))
                settled = action(A.Settle(UInt32(2), adopted.cursor, A.Immediate()))
                rejected = action(A.Collect(UInt32(2), settled.cursor, UInt32(0), UInt32(1)))
                @test rejected isa A.Failed && rejected.reason === A.InvalidEvidence
                @test owner.cursor == settled.cursor && length(seen) == 3
                restored = action(A.Restore(reference, A.Immediate()))
                @test restored isa A.Restored &&
                    restored.figure == reference &&
                    !restored.clipped
                @test action(A.Release()) isa A.Released
                close(client)
                client = nothing
                @test fetch(serving) === nothing
                close(server)
                server = nothing
                @test owner.closed
                @test all(Ext.calibration_graph_released, owner.workers)
                @test !Base.process_exited(daemon)
            finally
                client === nothing || close(client)
                if server !== nothing
                    close(server)
                    serving === nothing || fetch(serving)
                end
                for descriptor in (frontend, command)
                    descriptor === nothing ||
                        FilterGraphPipeWire.close_execution(descriptor.graph)
                end
            end
        end
        @test application_hashes(application) == before
    end
    @test !any(id.name in ("CUDA", "AMDGPU") for id in keys(Base.loaded_modules))
end
end
