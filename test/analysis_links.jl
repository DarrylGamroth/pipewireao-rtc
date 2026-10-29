# CPU-only numerical-extension test; no server or services needed.
using Test, PipeWireAORTC, PipeWireAO
using FilterGraphIsland, FilterGraphPipeWire, JuliaFilterGraph, FilterGraphAlgorithms
const E=Base.get_extension(PipeWireAORTC,:PipeWireAORTCGraphExt)

function prepared_analysis_flux_graph()
    mktempdir() do root
        path = joinpath(root, "flux.conf")
        write(path, """
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
            """)
        options = FilterGraphIsland.parse_arguments(["--graph", path, "--check"])
        return FilterGraphIsland.prepare_service_graph(options;
            declarations=(FilterGraphAlgorithms.PyramidPupilFluxU16F64,))
    end
end

function analysis_native_buffer(data; header=nothing, output=false)
    native = PipeWireAO.LibPipeWire
    storage = [native.pw_ndarray_filter_buffer(
        ntuple(_ -> UInt8(0), sizeof(native.pw_ndarray_filter_buffer)),)]
    header_metadata = native.PW_NDARRAY_FILTER_METADATA_HEADER
    GC.@preserve storage data begin
        buffer = pointer(storage)
        unsafe_store!(buffer.struct_size, UInt32(sizeof(native.pw_ndarray_filter_buffer)))
        unsafe_store!(buffer.flags, output ?
            native.PW_NDARRAY_FILTER_BUFFER_FLAG_OUTPUT_UNAVAILABLE : UInt32(0))
        unsafe_store!(buffer.data, Ptr{Cvoid}(pointer(data)))
        unsafe_store!(buffer.size, UInt32(sizeof(eltype(data)) * length(data)))
        unsafe_store!(buffer.capacity, UInt32(sizeof(eltype(data)) * length(data)))
        unsafe_store!(buffer.metadata_available, header_metadata)
        unsafe_store!(buffer.metadata_valid, isnothing(header) ? UInt32(0) : header_metadata)
        if !isnothing(header)
            unsafe_store!(buffer.header, native.spa_meta_header(
                header.flags, header.offset, header.pts, header.dts_offset, header.sequence))
        end
    end
    return storage
end

@testset "single-input analysis keeps the ordinary graph boundary and Header" begin
    graph = prepared_analysis_flux_graph()
    try
        input_owner = E.analysis_input_owner(graph)
        @test input_owner === graph
        @test JuliaFilterGraph.output_metadata_source_inputs(input_owner) == (1,)
        @test !(input_owner isa JuliaFilterGraph.PreparedSynchronizedInputs)

        node = FilterGraphPipeWire.PipeWireNode(input_owner;
            name="analysis-single-input-test", rate=500//1, connect=false)
        try
            FilterGraphPipeWire._prepare_owner(node.owner)
            @test node.owner.output_metadata_source_inputs == (1,)
            @test node.owner.deferred_inputs === nothing

            raw = reshape(UInt16.(1:24), 4, 6)
            pupil_flux = zeros(Float64, 4)
            header = PipeWireAO.BufferHeader(PipeWireAO.SPA.META_HEADER_FLAG_DISCONT,
                UInt32(7), Int64(123456), Int64(0), UInt64(42))
            input_storage = analysis_native_buffer(raw; header)
            output_storage = analysis_native_buffer(pupil_flux; output=true)
            GC.@preserve raw pupil_flux input_storage output_storage begin
                inputs = PipeWireAO.NdArrayFilterBuffers{false}(
                    Ptr{Cvoid}(pointer(input_storage)), UInt32(1))
                outputs = PipeWireAO.NdArrayFilterBuffers{true}(
                    Ptr{Cvoid}(pointer(output_storage)), UInt32(1))
                FilterGraphPipeWire._process_graph_buffers!(node.owner, nothing, inputs, outputs)
                @test pupil_flux == Float64[33, 105, 45, 117]
                @test PipeWireAO.buffer_header(outputs[1]) == header
            end
        finally
            close(node)
        end
    finally
        FilterGraphIsland.close_execution(graph)
    end
end

@testset "independent optional link callbacks" begin
    states=[Threads.Atomic{Int}(Int(PipeWireAO.LINK_STATE_INIT)) for _ in 1:4]
    callbacks=map(1:4) do i
        E.analysis_link_observer(states[i],((id=UInt32(i),),(id=UInt32(10+i),)),
            ((id=UInt32(20+i),),(id=UInt32(30+i),)))
    end
    info(i,state)=(output_node_id=UInt32(i),output_port_id=UInt32(10+i),
        input_node_id=UInt32(20+i),input_port_id=UInt32(30+i),state=state)
    for i in (3,1,4,2)
        callbacks[i](nothing,info(i,PipeWireAO.LINK_STATE_PAUSED))
        @test states[i][]==Int(PipeWireAO.LINK_STATE_PAUSED)
        @test count(state->state[]==Int(PipeWireAO.LINK_STATE_PAUSED),states)==findfirst(==(i),(3,1,4,2))
    end
    callbacks[2](nothing,info(1,PipeWireAO.LINK_STATE_ACTIVE))
    @test states[2][]==Int(PipeWireAO.LINK_STATE_ERROR)
    @test all(i->states[i][]==Int(PipeWireAO.LINK_STATE_PAUSED),(1,3,4))
    @test !any(id->id.name in ("CUDA","AMDGPU","GPUCompiler"),keys(Base.loaded_modules))
end

@testset "readiness does not need the owner's Julia event loop" begin
    if Threads.nthreads(:default)<2
        @test_skip Threads.nthreads(:default)>=2
    else
        config=(name="readiness-regression",)
        E.analysis_ready_notice(config,4) # Compile before the native wait.
        pipe=Pipe()
        completed=Threads.Atomic{Bool}(false)
        before_return=false
        try
            redirect_stdout(pipe) do
                monitor=FilterGraphIsland.spawn_monitor() do
                    @ccall gc_safe=true usleep(100000::Cuint)::Cint
                    E.analysis_ready_notice(config,4)
                    completed[]=true
                end
                @ccall gc_safe=true usleep(700000::Cuint)::Cint
                before_return=completed[]
                fetch(monitor)
            end
            close(pipe.in)
            message=read(pipe,String)
            @test before_return
            @test occursin("PIPEWIREAO_ANALYSIS_READY name=readiness-regression links=4",message)
        finally
            close(pipe)
        end
    end
end

@testset "only finite capture supplies consumers for unlinked outputs" begin
    A=PipeWireAORTC.Analysis
    names=(:mean,:variance,:stddev,Symbol("sample-count"),:complete,Symbol("variance-valid"))
    # An explicit mean link keeps its existing peer; unrelated input links must
    # not hide an unconnected statistics output with the same port name.
    links=[A.LinkSpec(A.Endpoint("capture","mean"),A.Endpoint("selected-observation","in")),
        A.LinkSpec(A.Endpoint("source","variance"),A.Endpoint("capture","sample"))]
    config=(name="capture",links=links,capture=true)
    @test E.analysis_discard_outputs(config,names)==("variance","stddev","sample-count","complete","variance-valid")
    @test E.analysis_discard_outputs(merge(config,(capture=nothing,)),names)==()
    @test E.analysis_discard_outputs(merge(config,(links=A.LinkSpec[],)),names)==String.(names)
end
