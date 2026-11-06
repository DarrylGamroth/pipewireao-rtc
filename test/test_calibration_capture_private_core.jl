include("test_calibration_capture.jl")
include("control_private_core.jl")

function capture_link(core, registry, source, sink)
    wait_proof(10, "capture ports") do
        roundtrip(registry)
        !isempty(
            find_globals(
                registry;
                interface = "PipeWire:Interface:Port",
                properties = (
                    "node.id" => string(node_id(source)), "port.direction" => "out"
                ),
            ),
        ) &&
            !isempty(
                find_globals(
                    registry;
                    interface = "PipeWire:Interface:Port",
                    properties = (
                        "node.id" => string(node_id(sink)), "port.direction" => "in"
                    ),
                ),
            )
    end
    output = only(
        find_globals(
            registry;
            interface = "PipeWire:Interface:Port",
            properties = ("node.id" => string(node_id(source)), "port.direction" => "out"),
        ),
    )
    input = only(
        find_globals(
            registry;
            interface = "PipeWire:Interface:Port",
            properties = ("node.id" => string(node_id(sink)), "port.direction" => "in"),
        ),
    )
    with_thread_loop_lock(main_loop(core)) do _
        create_object(
            core,
            "link-factory",
            Link;
            properties = Dict(
                "link.output.node" => string(node_id(source)),
                "link.output.port" => string(output.id),
                "link.input.node" => string(node_id(sink)),
                "link.input.port" => string(input.id),
                "object.linger" => "false",
            ),
        )
    end
end

@testset "private-core correlated four-stream capture and shared wakeup ownership" begin
    with_control_private_core() do remote, directory, daemon
        loop = ThreadLoop("test.capture.private")
        context, core, registry = with_thread_loop_lock(loop) do _
            context = Context(loop)
            core = CoreConnection(context; properties = Dict("remote.name" => remote))
            context, core, Registry(core)
        end
        start!(loop)
        capture = nothing
        sources = Any[]
        links = Any[]
        wakeup = Base.AsyncCondition()
        try
            original = capture_declarations("private.capture")
            declarations = (
                flux = original.flux,
                raw = original.raw,
                slopes = original.slopes,
                validity = original.validity,
            )
            capture = CC.Capture(core, declarations; wakeup)
            for name in keys(declarations)
                spec = getproperty(declarations, name)
                slot = getproperty(capture.slots, name)
                source = NdArraySource(
                    core,
                    "private.source.$name",
                    zeros(eltype(slot.wire), length(slot.wire)),
                    spec.format;
                    schema = spec.schema,
                )
                push!(sources, source)
                push!(
                    links,
                    capture_link(
                        core, registry, source.stream, getproperty(capture.streams, name)
                    ),
                )
            end
            roundtrip(core)
            start!(capture)
            foreach(start!, sources)
            files = PipeWireAORTC.CaptureFiles
            actions = PipeWireAORTC.CalibrationActionCodec
            selection_path = joinpath(directory, "capture.yaml")
            PipeWireAORTC.Common.write_yaml(
                selection_path,
                Dict(
                    "capture" =>
                        Dict("channels" => ["validity", "flux"], "maximum_bytes" => 20),
                ),
            )
            configuration = PipeWireAORTC.InstrumentCalibration._capture_configuration(
                PipeWireAORTC.Common.read_yaml(selection_path)
            )
            selected = NamedTuple{configuration.channels}(
                map(configuration.channels) do name
                    declaration = getproperty(declarations, name)
                    files.Channel(declaration.format, declaration.schema)
                end,
            )
            contract = files.Contract(selected)
            store = files.CaptureStore(
                joinpath(directory, "evidence"),
                contract;
                stage = "native-transport",
                illumination = "synthetic",
                settings = Dict("source" => "private-core"),
                maximum_bytes = configuration.maximum_bytes,
            )
            sequence_counter = Ref(0)
            function acquire()
                sequence = sequence_counter[] += 1
                arm_exposure!(capture, exposure(sequence))
                publisher = @async begin
                    sleep(0.01)
                    for (index, source) in enumerate(sources)
                        slot = values(capture.slots)[index]
                        T = eltype(slot.wire)
                        payload = T === Bool ? Bool[false, true] : T.(1:length(slot.wire))
                        token = submit_array!(
                            source,
                            payload,
                            BufferHeader(
                                UInt32(0),
                                UInt32(0),
                                Int64(9000),
                                Int64(0),
                                UInt64(sequence),
                            );
                            identity = identity(sequence),
                            exposure_duration_ns = 10,
                            reference_timestamp = reference_timestamp_now(
                                METADATA_CLOCK_REALTIME
                            ),
                        )
                        wait_array_source!(source, token; timeout_ns = 10_000_000_000)
                    end
                end
                result = CC.await!(
                    capture; deadline = PipeWireAORTC.ControlClient.monotonic() + 15
                )
                fetch(publisher)
                @test result.arrays.raw == UInt16[1 2 3; 4 5 6]
                @test result.arrays.slopes == Float32[1 2; 3 4]
                @test result.arrays.validity == [false, true]
                @test all(
                    receipt -> receipt.identity == identity(sequence),
                    values(result.metadata),
                )
                @test all(slot -> slot.buffer.handle == C_NULL, values(capture.slots))
                return result,
                actions.Exposure(
                    UInt64(1),
                    UInt64(1),
                    UInt64(sequence),
                    exposure(sequence).start_model_ns,
                    UInt64(10),
                )
            end
            descriptor = files.capture!(
                store,
                acquire;
                run = UInt64(1),
                serial = UInt64(1),
                probe = UInt32(0),
                cursor = actions.AcquisitionCursor(
                    UInt64(1), UInt64(1), UInt64(0), Int64(100)
                ),
                frames = UInt32(2),
                deadline = PipeWireAORTC.ControlClient.monotonic() + 15,
            )
            recorded = files.read_capture(
                store.directory,
                descriptor;
                expected_contract = contract,
                expected_stage = store.stage,
                expected_illumination = store.illumination,
                expected_settings = store.settings,
            )
            @test descriptor.bytes == 2contract.bytes == configuration.maximum_bytes
            @test length(recorded.samples) == 2
            @test keys(recorded.samples[1].arrays) == (:validity, :flux)
            @test recorded.samples[1].arrays.flux == Float32[1, 2]
            @test recorded.samples[2].exposure.start_model_ns == 110
            # A full identity mismatch over a real link faults the armed capture.
            arm_exposure!(capture, exposure(3))
            source = sources[findfirst(==(:raw), keys(declarations))]
            token = submit_array!(
                source,
                UInt16[1, 2, 3, 4, 5, 6],
                BufferHeader(UInt32(0), UInt32(0), Int64(9000), Int64(0), UInt64(3));
                identity = identity(3, 2),
                exposure_duration_ns = 10,
                reference_timestamp = reference_timestamp_now(METADATA_CLOCK_REALTIME),
            )
            wait_array_source!(source, token; timeout_ns = 10_000_000_000)
            @test_throws InvalidStateException CC.await!(
                capture; deadline = PipeWireAORTC.ControlClient.monotonic() + 5
            )
            @test capture.failure === :identity
            @test_throws InvalidStateException CC.snapshot(capture)
            close(capture)
            @test isopen(wakeup)
            @test isopen(core)
        finally
            capture === nothing || close(capture)
            with_thread_loop_lock(loop) do _
                foreach(close, reverse(links))
            end
            foreach(close, reverse(sources))
            close(wakeup)
            with_thread_loop_lock(loop) do _
                close(registry)
                close(core)
                close(context)
            end
            close(loop)
        end
    end
end

@test !any(id -> id.name in ("CUDA", "AMDGPU"), keys(Base.loaded_modules))
