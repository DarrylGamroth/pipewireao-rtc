# CPU-only numerical-extension test; no server or services needed.
using Test, PipeWireAORTC, PipeWireAO
using FilterGraphPipeWire, FilterGraphs, FilterGraphAlgorithms
const E = Base.get_extension(PipeWireAORTC, :PipeWireAORTCGraphExt)
const Clocks = E.Clocks

mutable struct UnpublishedAnalysisNode
    clock::Clocks.CachedNanoClock
    ticks::Vector{Int64}
    polls::Int
end

function PipeWireAO.isrunning(node::UnpublishedAnalysisNode)
    node.polls += 1
    Clocks.update!(node.clock, node.ticks[node.polls])
    return false
end

@testset "signed analysis setup deadlines without a core" begin
    clock = Clocks.CachedNanoClock(Int64(-100))
    previous, deadline = E.analysis_setup_deadline(clock, 3//1_000_000_000)
    @test (previous, deadline) === (Int64(-100), Int64(-97))
    Clocks.update!(clock, Int64(-98))
    @test E.analysis_setup_time(clock, previous, deadline, "expired") === Int64(-98)
    Clocks.update!(clock, deadline)
    @test_throws ErrorException("expired") E.analysis_setup_time(
        clock, -98, deadline, "expired"
    )
    Clocks.update!(clock, Int64(-99))
    @test_throws ErrorException("Analysis setup clock regressed") E.analysis_setup_time(
        clock, -98, deadline, "expired"
    )
    origin = Int64(2)^53 + 1
    Clocks.update!(clock, origin)
    @test E.analysis_setup_deadline(clock, 1//1_000_000_000) === (origin, origin + 1)
    for timeout in (0, -1, Inf, NaN)
        @test_throws ArgumentError E.analysis_setup_deadline(clock, timeout)
    end
    @test_throws InexactError E.analysis_setup_deadline(clock, typemax(Int))
    @test_throws InexactError E.analysis_setup_deadline(clock, floatmax(Float64))
    Clocks.update!(clock, typemax(Int64))
    @test_throws OverflowError E.analysis_setup_deadline(clock, 1//1_000_000_000)

    finished = Threads.Atomic{Bool}(false)
    for (ticks, message) in (
        (Int64[-99, -97], "Analysis node publication timed out"),
        (Int64[-101], "Analysis setup clock regressed"),
    )
        Clocks.update!(clock, Int64(-100))
        node = UnpublishedAnalysisNode(clock, ticks, 0)
        @test_throws ErrorException(message) E.analysis_connections(
            node, nothing, "unused", finished; timeout = 3//1_000_000_000, clock
        )
        @test node.polls == length(ticks)
    end
    # Cancellation leaves publication and native connection untouched.
    finished[] = true
    node = UnpublishedAnalysisNode(clock, Int64[], 0)
    @test E.analysis_connections(node, nothing, "unused", finished; clock) === nothing
    @test node.polls == 0
end

function prepared_analysis_flux_graph()
    mktempdir() do root
        path = joinpath(root, "flux.conf")
        write(
            path,
            """
    filter.graph = {
        nodes = [
            { type = ndarray name = flux label = pyramid-pupil-flux-u16-f64
              config = { image_size = [ 4 6 ] pupil_size = [ 2 3 ]
                pupil_origins = [ [ 0 0 ] [ 0 3 ] [ 2 0 ] [ 2 3 ] ] } }
        ]
        links = []
        inputs = [ "flux:raw" ]
        outputs = [ "flux:pupil-flux" ]
    }
    """,
        )
        options = FilterGraphPipeWire.parse_arguments(["--graph", path, "--check"])
        return FilterGraphPipeWire.prepare_service_graph(
            path; algorithms = (FilterGraphAlgorithms.PyramidPupilFluxU16F64,)
        )
    end
end

@testset "finite capture consumers inherit one declared source loop" begin
    endpoint(loop) = (
        properties = loop === nothing ? Dict{String,String}() :
                     Dict("node.loop.name" => loop),
    )
    @test E.analysis_source_loop(()) === nothing
    @test E.analysis_source_loop((endpoint(nothing), endpoint(""))) === nothing
    @test E.analysis_source_loop((endpoint("observation"), endpoint("observation"))) ==
        "observation"
    @test E.analysis_source_loop((endpoint(nothing), endpoint("observation"))) ==
        "observation"
    @test_throws ErrorException E.analysis_source_loop((
        endpoint("observation"), endpoint("control")
    ))
end

function analysis_native_buffer(data; header = nothing, output = false)
    native = PipeWireAO.LibPipeWire
    metadata = PipeWireAO.MetadataSnapshot((
        PipeWireAO.MetadataRequirement(PipeWireAO.SPA.META_HEADER),
    ))
    isnothing(header) || PipeWireAO.set_buffer_header!(
        PipeWireAO.writable_metadata_records(metadata), header
    )
    GC.@preserve data metadata begin
        records = PipeWireAO.metadata_records(metadata)
        buffers = [
            native.pw_ndarray_filter_buffer(
                UInt32(sizeof(native.pw_ndarray_filter_buffer)),
                output ? native.PW_NDARRAY_FILTER_BUFFER_FLAG_OUTPUT_UNAVAILABLE :
                UInt32(0),
                Ptr{Cvoid}(pointer(data)),
                UInt32(sizeof(data)),
                UInt32(sizeof(data)),
                records.count,
                UInt32(0),
                records.data,
            ),
        ]
        # Keep the canonical descriptor storage alive with its borrowed buffer.
        return (; buffers, metadata)
    end
end

@testset "single-input analysis keeps the ordinary graph boundary and Header" begin
    graph = prepared_analysis_flux_graph()
    try
        input_owner = E.analysis_input_owner(graph)
        @test input_owner === graph
        @test FilterGraphs.output_metadata_source_inputs(input_owner) == (1,)
        @test !(input_owner isa FilterGraphs.PreparedSynchronizedInputs)

        node = FilterGraphPipeWire.PipeWireNode(
            input_owner; name = "analysis-single-input-test", rate = 500//1, connect = false
        )
        try
            FilterGraphPipeWire._prepare_owner(node.owner)
            @test node.owner.output_metadata_source_inputs == (1,)
            @test node.owner.deferred_inputs === nothing

            raw = reshape(UInt16.(1:24), 4, 6)
            pupil_flux = zeros(Float64, 4)
            @test size(raw) == only(values(FilterGraphs.input_formats(graph))).shape
            @test size(pupil_flux) == only(values(FilterGraphs.output_formats(graph))).shape
            header = PipeWireAO.BufferHeader(
                PipeWireAO.SPA.META_HEADER_FLAG_DISCONT,
                UInt32(7),
                Int64(123456),
                Int64(0),
                UInt64(42),
            )
            input_storage = analysis_native_buffer(raw; header)
            output_storage = analysis_native_buffer(pupil_flux; output = true)
            GC.@preserve raw pupil_flux input_storage output_storage begin
                inputs = PipeWireAO.NdArrayFilterBuffers{false}(
                    Ptr{Cvoid}(pointer(input_storage.buffers)), UInt32(1)
                )
                outputs = PipeWireAO.NdArrayFilterBuffers{true}(
                    Ptr{Cvoid}(pointer(output_storage.buffers)), UInt32(1)
                )
                @test PipeWireAO.data_pointer(inputs[1]) == Ptr{UInt8}(pointer(raw))
                @test PipeWireAO.data_pointer(outputs[1]) == Ptr{UInt8}(pointer(pupil_flux))
                @test PipeWireAO.payload_size(inputs[1]) == sizeof(raw)
                @test PipeWireAO.payload_size(outputs[1]) == sizeof(pupil_flux)
                @test PipeWireAO.buffer_header(inputs[1]) == header
                FilterGraphPipeWire._process_graph_buffers!(
                    node.owner, nothing, inputs, outputs
                )
                @test pupil_flux == Float64[33, 105, 45, 117]
                @test PipeWireAO.buffer_header(inputs[1]) == header
                @test PipeWireAO.buffer_header(outputs[1]) == header
            end
        finally
            close(node)
        end
    finally
        FilterGraphPipeWire.close_execution(graph)
    end
end

@testset "independent optional link callbacks" begin
    states = [Threads.Atomic{Int}(Int(PipeWireAO.LINK_STATE_INIT)) for _ in 1:4]
    callbacks = map(1:4) do i
        E.analysis_link_observer(
            states[i],
            ((id = UInt32(i),), (id = UInt32(10 + i),)),
            ((id = UInt32(20 + i),), (id = UInt32(30 + i),)),
        )
    end
    info(i, state) = (
        output_node_id = UInt32(i),
        output_port_id = UInt32(10 + i),
        input_node_id = UInt32(20 + i),
        input_port_id = UInt32(30 + i),
        state = state,
    )
    for i in (3, 1, 4, 2)
        callbacks[i](nothing, info(i, PipeWireAO.LINK_STATE_PAUSED))
        @test states[i][] == Int(PipeWireAO.LINK_STATE_PAUSED)
        @test count(state -> state[] == Int(PipeWireAO.LINK_STATE_PAUSED), states) ==
            findfirst(==(i), (3, 1, 4, 2))
    end
    callbacks[2](nothing, info(1, PipeWireAO.LINK_STATE_ACTIVE))
    @test states[2][] == Int(PipeWireAO.LINK_STATE_ERROR)
    @test all(i -> states[i][] == Int(PipeWireAO.LINK_STATE_PAUSED), (1, 3, 4))
    @test !any(
        id -> id.name in ("CUDA", "AMDGPU", "GPUCompiler"), keys(Base.loaded_modules)
    )
end

@testset "readiness does not need the owner's Julia event loop" begin
    if Threads.nthreads(:default) < 2
        @test_skip Threads.nthreads(:default) >= 2
    else
        config = (name = "readiness-regression",)
        E.analysis_ready_notice(config, 4) # Compile before the native wait.
        pipe = Pipe()
        completed = Threads.Atomic{Bool}(false)
        before_return = false
        try
            redirect_stdout(pipe) do
                monitor = FilterGraphPipeWire.spawn_monitor() do
                    @ccall gc_safe = true usleep(100000::Cuint)::Cint
                    E.analysis_ready_notice(config, 4)
                    completed[] = true
                end
                @ccall gc_safe = true usleep(700000::Cuint)::Cint
                before_return = completed[]
                fetch(monitor)
            end
            close(pipe.in)
            message = read(pipe, String)
            @test before_return
            @test occursin(
                "PIPEWIREAO_ANALYSIS_READY name=readiness-regression links=4", message
            )
        finally
            close(pipe)
        end
    end
end

@testset "only finite capture supplies consumers for unlinked outputs" begin
    A = PipeWireAORTC.Analysis
    names = (
        :mean,
        :variance,
        :stddev,
        Symbol("sample-count"),
        :complete,
        Symbol("variance-valid"),
    )
    # An explicit mean link keeps its existing peer; unrelated input links must
    # not hide an unconnected statistics output with the same port name.
    links = [
        A.LinkSpec(A.Endpoint("capture", "mean"), A.Endpoint("selected-observation", "in")),
        A.LinkSpec(A.Endpoint("source", "variance"), A.Endpoint("capture", "sample")),
    ]
    config = (name = "capture", links = links, capture = true)
    @test E.analysis_discard_outputs(config, names) ==
        ("variance", "stddev", "sample-count", "complete", "variance-valid")
    @test E.analysis_discard_outputs(merge(config, (capture = nothing,)), names) == ()
    @test E.analysis_discard_outputs(merge(config, (links = A.LinkSpec[],)), names) ==
        String.(names)
end
