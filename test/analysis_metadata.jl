# Actual native callback buffers and RTC Node policy; no server or service.
using Test, PipeWireAORTC, PipeWireAO
using FilterGraphAlgorithms, JuliaFilterGraph, FilterGraphIsland, FilterGraphPipeWire
const E = Base.get_extension(PipeWireAORTC, :PipeWireAORTCGraphExt)
const C = PipeWireAORTC.Common

function analysis_callback_buffer(
    data,
    requirements;
    header = nothing,
    identity = nothing,
    output = false,
)
    native = PipeWireAO.LibPipeWire
    metadata = MetadataSnapshot((MetadataRequirement(SPA.META_HEADER), requirements...))
    records = writable_metadata_records(metadata)
    header === nothing || set_buffer_header!(records, header)
    if identity !== nothing
        set_acquisition_identity!(records, identity)
        set_exposure_timing!(
            records,
            ExposureTiming(100; clock = METADATA_CLOCK_MODEL, duration_nanoseconds = 2000),
        )
        set_reference_timestamp!(records, ReferenceTimestamp(1_700_000_000_000_000_123))
    end
    extent = UInt32(sizeof(data))
    storage = [
        native.pw_ndarray_filter_buffer(
            UInt32(sizeof(native.pw_ndarray_filter_buffer)),
            output ? native.PW_NDARRAY_FILTER_BUFFER_FLAG_OUTPUT_UNAVAILABLE : UInt32(0),
            Ptr{Cvoid}(pointer(data)),
            extent,
            extent,
            metadata.count,
            0,
            pointer(metadata.descriptors),
        ),
    ]
    return (; data, metadata, storage)
end

@testset "RTC WFS summary preserves declared source facts through native callbacks" begin
    mktempdir() do directory
        path = joinpath(directory, "graph.conf")
        write(
            path,
            """
    filter.graph = {
        nodes = [ { type = ndarray name = wfs label = shack-hartmann-summary-f32
                    config = { subaperture_count = 2 } } ]
        inputs = [ "wfs:slopes" "wfs:flux" "wfs:validity" ]
        outputs = [ "wfs:summary" ]
    }
    """,
        )
        options = FilterGraphIsland.parse_arguments([
            "--graph",
            path,
            "--check",
            "--boundary-layout",
            "row-major",
        ])
        graph = FilterGraphIsland.prepare_service_graph(
            options;
            declarations = FilterGraphIsland.algorithm_declarations(options),
        )
        config =
            (; name = "analysis-metadata-test", rate = 500//1, channel_units = NamedTuple())
        node = E.prepare_analysis_node(
            config,
            joinpath(directory, "absent.sock"),
            graph,
            options.boundary_layout,
            nothing,
        )
        try
            FilterGraphPipeWire._prepare_owner(node.owner)
            @test node.owner.join isa JuliaFilterGraph.PreparedSynchronizedInputs
            requirements = node.owner.output_records.summary.requirements
            @test Set(r.type for r in requirements) ==
                  Set(r.type for r in C.TELEMETRY_METADATA)
            identity = AcquisitionIdentity(AcquisitionDomain(ntuple(UInt8, 16)), 7, 42)
            header = BufferHeader(SPA.META_HEADER_FLAG_MARKER, 0, 123456, 0, 42)
            # Values use row-major layout: (x,y) pairs for two subapertures.
            source_values = (Float32[1, 2, 3, 4], Float32[10, 20], Bool[true, true])
            sources = map(
                values -> analysis_callback_buffer(
                    values,
                    C.TELEMETRY_METADATA;
                    header,
                    identity,
                ),
                source_values,
            )
            result = fill(NaN32, 8)
            destination =
                analysis_callback_buffer(result, Tuple(requirements); output = true)
            input_storage = vcat(map(source -> source.storage, sources)...)
            GC.@preserve sources destination input_storage begin
                inputs = NdArrayFilterBuffers{false}(
                    Ptr{Cvoid}(pointer(input_storage)),
                    UInt32(3),
                )
                outputs = NdArrayFilterBuffers{true}(
                    Ptr{Cvoid}(pointer(destination.storage)),
                    UInt32(1),
                )
                @test all(source -> metadata_records_valid(source.metadata), sources)
                @test metadata_fits(outputs[1], sources[1].metadata)
                # Exercise the actual callback, including preflight, acquisition
                # matching, scientific summary and publication of retained facts.
                node.filter.callbacks.on_process(node.filter, inputs, outputs)
                @test iszero(
                    unsafe_load(pointer(destination.storage)).flags &
                    PipeWireAO.LibPipeWire.PW_NDARRAY_FILTER_BUFFER_FLAG_OUTPUT_UNAVAILABLE,
                )
                @test result ≈ Float32[2, 2, 15, sqrt(5), sqrt(10), sqrt(15), 2, 3]
                @test buffer_header(destination.metadata) == header
                @test acquisition_identity(destination.metadata) == identity
                @test exposure_timing(destination.metadata) ==
                      exposure_timing(sources[1].metadata)
                @test reference_timestamp(destination.metadata) ==
                      reference_timestamp(sources[1].metadata)
                @test optical_classification(destination.metadata) === nothing
                @test trigger_classification(destination.metadata) === nothing
            end
        finally
            close(node)
            FilterGraphIsland.close_execution(graph)
        end
    end
end

@testset "classification profiles follow each declared source port" begin
    required=(
        camera = (MetadataRequirement(SPA.META_OPTICAL_CHOPPING; required = true),),
        ordinary = (),
    )
    inputs=C.telemetry_metadata_ports((:camera, :ordinary); required)
    outputs=C.telemetry_metadata_ports(
        (:camera_product, :ordinary_product, :shared),
        (:camera, :ordinary),
        (1, 2, 0);
        required,
    )
    @test length(inputs.camera.metadata)==5
    @test length(inputs.ordinary.metadata)==3
    @test any(r -> r.type==SPA.META_OPTICAL_CHOPPING && r.required, inputs.camera.metadata)
    @test any(
        r -> r.type==SPA.META_ELECTRICAL_TRIGGER && !r.required,
        inputs.camera.metadata,
    )
    @test length(outputs.camera_product.metadata)==5
    @test all(!r.required for r in outputs.camera_product.metadata)
    @test length(outputs.ordinary_product.metadata)==3
    @test length(outputs.shared.metadata)==3
end
