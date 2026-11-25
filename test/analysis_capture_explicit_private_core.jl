using Test, PipeWireAORTC, PipeWireAO
using FilterGraphPipeWire, FilterGraphs

include("control_private_core.jl")
include("helpers/analysis_capture_fixture.jl")

const Common = PipeWireAORTC.Common
const Store = PipeWireAORTC.ConfigurationStore
const DOMAIN = AcquisitionDomain(ntuple(UInt8, 16))
const PERIOD_NS = UInt64(1_000_000)

wire_type(::Type{Float32}) = NdArray.F32_LE
wire_type(::Type{UInt64}) = NdArray.U64_LE
wire_type(::Type{Bool}) = NdArray.BOOL8

function connect_analysis_sink!(sinks, core, port, descriptor, seen)
    format = NdArrayFormat(
        wire_type(descriptor.element_type), descriptor.shape;
        layout = NdArray.ROW_MAJOR, rate = SPA.Fraction(1000, 1),
    )
    buffer = StreamBuffer()
    name = "analysis-explicit-$port"
    sink = Stream(
        core, name;
        properties = Dict("node.name" => name, "node.reliable" => "true"),
        on_process = stream -> begin
            dequeue_buffer!(buffer, stream) || return nothing
            try
                if seen !== nothing
                    header = buffer_header(buffer)
                    identity = acquisition_identity(metadata_records(buffer))
                    timestamp = reference_timestamp(buffer)
                    if header !== nothing && identity !== nothing && timestamp !== nothing
                        sequence = header.sequence
                        seen[] |= identity == AcquisitionIdentity(DOMAIN, UInt64(1), sequence) &&
                            timestamp.timestamp_nanoseconds == sequence * PERIOD_NS &&
                            timestamp.duration_nanoseconds == PERIOD_NS
                    end
                end
            finally
                queue_buffer!(buffer, stream)
            end
            return nothing
        end,
    )
    push!(sinks, sink)
    connect!(
        sink, :input;
        flags = STREAM_MAP_BUFFERS | STREAM_DONT_RECONNECT | STREAM_NO_CONVERT,
        params = (
            ndarray_format(format; schema = descriptor.schema),
            Pod(buffers_param(size = payload_size(format), buffers = 2)),
            Pod(header_metadata_param()),
            (
                Pod(metadata_param(MetadataRequirement(kind))) for
                kind in (SPA.META_ACQUISITION_IDENTITY, SPA.META_EXPOSURE_TIMING, SPA.META_REFERENCE_TIMESTAMP)
            )...,
        ),
    )
end

@testset "Finite native analysis registers FITS products with explicitly linked outputs" begin
    with_control_private_core(; telemetry_loop = true) do remote, directory, _
        name = "capture-explicit"
        output_links = [
            Dict("output" => "$name:$port", "input" => "analysis-explicit-$port:input_1")
            for port in OUTPUTS
        ]
        path = analysis_capture_configuration(directory, name; output_links)
        graph = FilterGraphPipeWire.prepare_service_graph(joinpath(directory, "graph.conf"))
        formats = try
            FilterGraphs.output_formats(graph)
        finally
            FilterGraphPipeWire.close_execution(graph)
        end

        log_path = joinpath(directory, "analysis.log")
        receipt_path = joinpath(ENV["PIPEWIREAO_RUNTIME_DIR"], "$name-capture.json")
        state = joinpath(directory, "state")
        expected_mean = Float32[1 2; 2 4]
        frame = vec(expected_mean)
        metadata_seen = Threads.Atomic{Bool}(false)
        loop = ThreadLoop("analysis.capture.explicit")
        context, core, registry = with_thread_loop_lock(loop) do _
            context = Context(loop)
            core = CoreConnection(context; properties = Dict("remote.name" => remote))
            context, core, Registry(core)
        end
        start!(loop)
        source = child = nothing
        sinks = Stream[]
        open(log_path, "w+") do log
            try
                with_thread_loop_lock(loop) do _
                    for (port, descriptor) in pairs(formats)
                        seen = port === Symbol("sample-count") ? metadata_seen : nothing
                        connect_analysis_sink!(sinks, core, port, descriptor, seen)
                    end
                end
                format = NdArrayFormat(
                    NdArray.F32_LE, (2, 2);
                    layout = NdArray.ROW_MAJOR, rate = SPA.Fraction(1000, 1),
                )
                source = NdArraySource(
                    core, "analysis-test-source", zeros(Float32, 4), format;
                    schema = "test/analysis-samples-f32/1",
                    properties = Dict("node.loop.name" => "telemetry-loop"),
                )
                start!(source)
                child = start_analysis_capture(path, remote, state, log)
                wait_proof(180, "finite analysis readiness"; check = () -> begin
                    process_exited(child) && error("analysis exited before input")
                end) do
                    occursin("PIPEWIREAO_ANALYSIS_READY name=$name links=7", read(log_path, String))
                end

                for sequence in UInt64(1):UInt64(80)
                    (isfile(receipt_path) || process_exited(child)) && break
                    stamp = sequence * PERIOD_NS
                    header = BufferHeader(UInt32(0), UInt32(0), Int64(stamp), Int64(0), sequence)
                    try
                        token = submit_array!(
                            source, frame, header;
                            identity = AcquisitionIdentity(DOMAIN, UInt64(1), sequence),
                            exposure_duration_ns = PERIOD_NS,
                            reference_timestamp = ReferenceTimestamp(stamp; duration_nanoseconds = PERIOD_NS),
                        )
                        wait_array_source!(source, token; timeout_ns = 2_000_000_000)
                    catch
                        # A submit racing the completed capture can lose its Link.
                        wait_proof(() -> process_exited(child), 10, "analysis exit after input withdrawal")
                        break
                    end
                    sleep(0.02)
                end
                wait_proof(() -> process_exited(child), 30, "finite analysis completion")
                @test success(child)
                receipt = Common.read_json(receipt_path)
                @test receipt["state"] == "registered"
                roundtrip(registry)
                @test isempty(nodes(registry, name))
                @test isempty(nodes(registry, "$name.discard."; prefix = true))
                @test metadata_seen[]
                store = Store.Store(joinpath(state, "pipewireao/configuration"))
                for (port, expected, units) in (
                    ("mean", expected_mean, "adu"),
                    ("variance", zeros(Float32, 2, 2), "adu^2"),
                    ("stddev", zeros(Float32, 2, 2), "adu"),
                )
                    artifact = receipt["artifacts"][port]
                    @test artifact["manifest"]["metadata"]["sample_count"] == 8
                    @test artifact["manifest"]["preparation"]["BUNIT"] == units
                    PipeWireAORTC.Artifacts.FITS(Store.read_artifact(store, artifact["id"])) do fits
                        @test read(fits[1]) == expected
                    end
                end
            catch
                flush(log)
                for line in last(split(read(log_path, String), '\n'), 30)
                    println(stderr, first(line, min(length(line), 400)))
                end
                rethrow()
            finally
                child === nothing || stop_proof_child!(child, "finite analysis child")
                source === nothing || close(source)
                with_thread_loop_lock(loop) do _
                    foreach(close, sinks)
                    close(registry)
                    close(core)
                    close(context)
                end
                close(loop)
            end
        end
    end
end

@testset "Finite capture records an incomplete outcome if its discard factory is absent" begin
    check_missing_discard_factory()
end
