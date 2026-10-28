# Actual adopted-command staging through the ordinary capacity-one copy queue.
using Test,LinearAlgebra,PipeWireAORTC,PipeWireAO,AdaptiveOpticsSim,AdaptiveOpticsSimPipeWireHIL
using AdaptiveOpticsSim.AlgorithmGraphs
using AdaptiveOpticsSim.AlgorithmGraphs: poll_graph_output_snapshot!,release_graph_output_snapshot!
const HIL=AdaptiveOpticsSimPipeWireHIL
const E=PipeWireAORTC.InstrumentExport
const C=PipeWireAORTC.Common
const A=PipeWireAORTC.InstrumentCalibration
const O=PipeWireAORTC.PhysicalOffsets
const Ext=Base.get_extension(PipeWireAORTC,:PipeWireAORTCAOSExt)
const Source=Ext.PupilSourceOwner
Base.include(@__MODULE__,joinpath(@__DIR__,"pupil_source_documents.jl"))
Base.include(@__MODULE__,joinpath(@__DIR__,"physical_offset_inputs_documents.jl"))
Base.include(@__MODULE__,joinpath(@__DIR__,"native_control_private_core.jl"))

mutable struct CommandCapture
    buffer::StreamBuffer
    values::Vector{Float32}
    receipt::Any
end
function (capture::CommandCapture)(stream)
    dequeue_buffer!(capture.buffer,stream) || return nothing
    try
        header=buffer_header(capture.buffer)
        metadata=buffer_acquisition(capture.buffer)
        data=buffer_data(capture.buffer)
        chunk=chunk_info(data)
        header!==nothing && metadata!==nothing && chunk.size==sizeof(capture.values) || return nothing
        copyto!(capture.values,reinterpret(Float32,bytes(data)))
        capture.receipt=(;identity=acquisition_identity(metadata),pts=header.pts,duration=acquisition_exposure_duration(metadata))
    finally
        queue_buffer!(capture.buffer,stream)
    end
    return nothing
end

@testset "adopted physical telemetry is optional, micrometre OPD and model-clock bound" begin
    mktempdir() do directory
        (;config)=pupil_source_documents(directory)
        options=merge(PipeWireAORTC.AOSOwner.configuration(config),(;applied_command_observation=true))
        science=PipeWireAORTC.AOSOwner.prepare_pupil_source_science(options)
        publisher=science.publisher
        document=physical_inputs_document(directory;P=Matrix{Float32}(I,2,2))
        document["calibration_identity"]=options.calibration_identity
        document["command_order"]=options.command_order
        path=joinpath(directory,"offsets.yaml");C.write_yaml(path,document)
        prepared=O.prepare(path;options.command_count,options.command_order,options.calibration_identity)
        state=Ext.OwnerState()
        output=Source.applied_command_option(options)
        try
            # The daemon owns the queue. Its lifetime therefore encloses both
            # client endpoints and their outstanding data-loop work.
            modules="""
                { name = libpipewire-module-queue args = {
                    queue.media = application/ndarray node.name = applied-queue
                    queue.max-buffers = 1 queue.storage = copy queue.overflow = drop-oldest
                    capture.props = { node.name = applied-queue-input }
                    playback.props = { node.name = applied-queue-output node.loop.name = telemetry-loop }
                } }
                """
            with_control_private_core(;telemetry_loop=true,modules,prefix=ENV["PIPEWIREAO_PREFIX"]) do remote,_,_
                O.with_receiver(prepared;remote,applied_command=output) do inputs
                    scratch=zeros(Float32,2)
                    command=Float32[1e-9,-2e-9]
                    function frame()
                        state.sequence=Source.step!(science,publisher,prepared.inputs.receiver,command;generation=UInt64(state.generation))
                        Source.observe_command!(inputs,scratch,command,publisher,state)
                        wait_proof(()->poll_graph_output_snapshot!(publisher.snapshot),10,"committed pupil snapshot")
                        release_graph_output_snapshot!(publisher.snapshot)
                    end
                    # No consumer: physical model progression does not wait.
                    frame();frame()
                    @test state.sequence==2 && model_time_sequence(science.driver)==2
                    println("ADOPTED_QUEUE_UNOBSERVED_TICKS_PASS");flush(stdout)
                    capture=CommandCapture(StreamBuffer(),zeros(Float32,2),nothing)
                    observer=nothing
                    try
                        with_thread_loop_lock(inputs.transport.loop) do _
                            observer=Stream(inputs.transport.core,"adopted-reader";
                                properties=Dict("node.name"=>"adopted-reader","node.virtual"=>"true",
                                    "node.want-driver"=>"true","node.pause-on-idle"=>"false"),on_process=capture,
                                on_state_changed=(_,old,state,detail)->begin
                                    println("ADOPTED_OBSERVER_STATE ",old," -> ",state," ",detail);flush(stdout)
                                end)
                            connect!(observer,:input;flags=STREAM_DRIVER|STREAM_MAP_BUFFERS|STREAM_NO_CONVERT|STREAM_DONT_RECONNECT,
                                params=(ndarray_format(output.format;schema=output.schema),Pod(buffers_param(size=8,buffers=3)),
                                    Pod(header_metadata_param()),Pod(acquisition_metadata_param())))
                        end
                        registry=with_thread_loop_lock(inputs.transport.loop) do _;Registry(inputs.transport.core);end
                            links=Any[]
                            function port(name,direction)
                                nodes=find_globals(registry;interface="PipeWire:Interface:Node",properties=("node.name"=>name,))
                                length(nodes)==1 || return nothing
                                ports=find_globals(registry;interface="PipeWire:Interface:Port",properties=("node.id"=>string(only(nodes).id),"port.direction"=>direction))
                                return length(ports)==1 ? only(ports) : nothing
                            end
                            try
                                for (producer,consumer) in ((output.node_name,"applied-queue-input"),("applied-queue-output","adopted-reader"))
                                    wait_proof(10,"adopted queue endpoints") do
                                        roundtrip(registry)
                                        port(producer,"out")!==nothing && port(consumer,"in")!==nothing
                                    end
                                    a,b=port(producer,"out"),port(consumer,"in")
                                    push!(links,with_thread_loop_lock(inputs.transport.loop) do _
                                        create_object(inputs.transport.core,"link-factory",Link;properties=Dict("link.output.node"=>a.properties["node.id"],
                                            "link.output.port"=>string(a.id),"link.input.node"=>b.properties["node.id"],"link.input.port"=>string(b.id),"object.linger"=>"false"))
                                    end)
                                end
                                wait_proof(10,"adopted queue negotiated three producer buffers") do
                                    HIL.with_array_stream(inputs.transport,inputs.applied_command) do stream
                                        stream_state(stream)==PipeWireAO.LibPipeWire.PW_STREAM_STATE_STREAMING
                                    end
                                end
                                wait_proof(10,"independently driven telemetry observer") do
                                    with_thread_loop_lock(inputs.transport.loop) do _
                                        stream_state(observer)==PipeWireAO.LibPipeWire.PW_STREAM_STATE_STREAMING
                                    end
                                end
                                frame()
                                println("ADOPTED_QUEUE_LINKED_TICK");flush(stdout)
                                receipt=Ref{Any}(nothing)
                                wait_proof(10,"adopted command after model tick") do
                                    HIL.with_array_stream(trigger_process!,inputs.transport,inputs.applied_command)
                                    with_thread_loop_lock(inputs.transport.loop) do _
                                        trigger_process!(observer)
                                        receipt[]=capture.receipt
                                    end
                                    receipt[]!==nothing && receipt[].identity.sequence==3
                                end
                                @test capture.values==command./1f-6
                                @test receipt[].pts==4_000_000 && receipt[].duration==2_000_000
                                @test receipt[].identity.domain==publisher.domain && receipt[].identity.generation==1
                                @test science.command==command
                                println("ADOPTED_QUEUE_PAYLOAD_PASS");flush(stdout)
                                # Held reset flushes old telemetry and starts a
                                # new source cohort at the true first model tick.
                                Source.reset_science!(science)
                                O.reset_inputs!(inputs)
                                state.generation=2;state.sequence=0
                                HIL.reset_pipewire_array!(inputs.transport,inputs.applied_command;
                                    identity=AcquisitionIdentity(publisher.domain,UInt64(2),UInt64(0)))
                                with_thread_loop_lock(inputs.transport.loop) do _;capture.receipt=nothing;end
                                fill!(command,0)
                                frame()
                                wait_proof(10,"new adopted command cohort") do
                                    HIL.with_array_stream(trigger_process!,inputs.transport,inputs.applied_command)
                                    with_thread_loop_lock(inputs.transport.loop) do _
                                        trigger_process!(observer)
                                        receipt[]=capture.receipt
                                    end
                                    receipt[]!==nothing && receipt[].identity.generation==2
                                end
                                @test all(iszero,capture.values) && all(iszero,science.command)
                                @test receipt[].identity.sequence==1 && receipt[].pts==0 && receipt[].duration==2_000_000
                                println("ADOPTED_QUEUE_RESET_PASS");flush(stdout)
                            finally
                                with_thread_loop_lock(inputs.transport.loop) do _
                                    foreach(close,reverse(links));close(registry)
                                end
                            end
                    finally
                        with_thread_loop_lock(inputs.transport.loop) do _
                            observer===nothing || close(observer)
                        end
                        println("ADOPTED_QUEUE_CLIENT_CLOSED");flush(stdout)
                    end
                end
            end
        finally
            Ext.PupilOutput.close!(publisher)
        end
    end
    @test !any(id->id.name in ("CUDA","AMDGPU","FilterGraphAlgorithms","FilterGraphPipeWire","JuliaFilterGraph"),keys(Base.loaded_modules))
end
