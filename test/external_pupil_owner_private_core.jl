# Optional CPU selector: julia --threads=2,0 --project=<science-env> ...
using Test, PipeWireAORTC, AdaptiveOpticsSim, AdaptiveOpticsSimPipeWireHIL, Proper, PipeWireAO
import PipeWireAO_jll
include(joinpath(@__DIR__,"external_pupil_owner_documents.jl"))
include(joinpath(pkgdir(AdaptiveOpticsSimPipeWireHIL),"test/private_core_helpers.jl"))
const Owner = PipeWireAORTC.AOSOwner
const Bootstrap = PipeWireAORTC.NativeOwnerBootstrapRuntime
const Client = PipeWireAORTC.NativeOwnerBootstrapClient
const Codec = PipeWireAORTC.NativeOwnerBootstrapCodec
const Source = PipeWireAORTC.NativeSourceControl
const External = Base.get_extension(PipeWireAORTC,:PipeWireAORTCAOSExt).ExternalPupilOwner
deadline() = time_ns()/1e9 + 30

function external_pupil_delivery(remote, options)
    science = External.prepare(options.plant.definition;settings=options.plant.settings)
    names = keys(science.sensors)
    formats = (science.pupil.shape,map(sensor->size(sensor.image),values(science.sensors))...)
    schemas = (science.pupil.schema,map(sensor->sensor.schema,values(science.sensors))...)
    peers = Tuple(PipeWireArrayStreamOptions(node_name="test.optical.peer.$index",media_name="test",
        schema=schemas[index],format=NdArrayFormat(NdArray.F32_LE,formats[index];layout=NdArray.ROW_MAJOR))
        for index in 1:3)
    with_array_streams(peers;remote,input=(false,true,true)) do owner
        registry = with_array_stream(owner,1) do _; Registry(owner.core); end
        links = Link[]
        try
            function connect(output_name,input_name)
                ports = nothing
                _wait_for_hil_condition() do
                    roundtrip(registry)
                    output = find_globals(registry;interface="PipeWire:Interface:Node",properties=("node.name"=>output_name,))
                    input = find_globals(registry;interface="PipeWire:Interface:Node",properties=("node.name"=>input_name,))
                    length(output)==length(input)==1 || return false
                    output_id,input_id = only(output).id,only(input).id
                    outputs=find_globals(registry;interface="PipeWire:Interface:Port",properties=("node.id"=>string(output_id),"port.direction"=>"out"))
                    inputs=find_globals(registry;interface="PipeWire:Interface:Port",properties=("node.id"=>string(input_id),"port.direction"=>"in"))
                    length(outputs)==length(inputs)==1 || return false
                    ports=(output_id,only(outputs).id,input_id,only(inputs).id)
                    true
                end
                push!(links,with_array_stream(owner,1) do _
                    create_object(owner.core,"link-factory",Link;properties=Dict(
                        "link.output.node"=>string(ports[1]),"link.output.port"=>string(ports[2]),
                        "link.input.node"=>string(ports[3]),"link.input.port"=>string(ports[4]),"object.linger"=>"false"))
                end)
            end
            connect("test.optical.peer.1",options.pupil_node)
            for (index,name) in enumerate(names)
                connect(getproperty(options.sensor_nodes,name),"test.optical.peer.$(index+1)")
            end
            packet=zeros(Float32,science.pupil.shape);packet[2,:,:].=1
            images=map(shape->zeros(Float32,shape),formats[2:end])
            domain=AcquisitionDomain(ntuple(i->UInt8(i),16))
            for sequence in UInt64(1):UInt64(2)
                @test stage_pipewire_array!(owner,1,packet;identity=AcquisitionIdentity(domain,UInt64(1),sequence),
                    pts=Int64((sequence-1)*2_000_000),duration=UInt64(2_000_000))
                _wait_for_hil_condition(;timeout=20) do
                    with_array_stream(trigger_process!,owner,1)
                    array_stream_status(owner,2).pending
                end
                receipt=drain_pipewire_array!(images[1],owner,2)
                @test receipt.identity.sequence==sequence && receipt.duration==2_000_000
                @test all(isfinite,images[1]) && sum(images[1])>0
                if sequence==1
                    @test !array_stream_status(owner,3).pending
                else
                    _wait_for_hil_condition(;timeout=20) do; array_stream_status(owner,3).pending; end
                    receipt=drain_pipewire_array!(images[2],owner,3)
                    @test receipt.identity.sequence==1 && receipt.duration==4_000_000
                    @test all(isfinite,images[2]) && sum(images[2])>0
                end
            end
        finally
            with_array_stream(owner,1) do _
                foreach(close,reverse(links));close(registry)
            end
        end
    end
end

@testset "managed external-pupil native bootstrap and source controls" begin
    Threads.nthreads(:default)>=2 || error("run with --threads=2,0")
    mktempdir() do directory
        (;config) = external_pupil_owner_documents(directory)
        _with_private_core() do remote
            remote = joinpath(ENV["PIPEWIREAO_RUNTIME_DIR"],remote)
            runtime = Bootstrap.Runtime(remote,"test.optical.bootstrap",Int64(51))
            options = merge(Owner.configuration(config),(;remote,control_node="test.optical.control",
                bootstrap_node="test.optical.bootstrap",bootstrap_instance=Int64(51),
                bootstrap_runtime=runtime,owner_check=()->Bootstrap.preparation_check!(runtime)))
            owner_task = @async try
                Owner.run_external_pupil_owner(options)
                Bootstrap.finish!(runtime)
                nothing
            catch error
                error
            end
            client = source = nothing
            try
                client = Client.connect(remote,options.bootstrap_node,getpid(),51;deadline=deadline())
                @test Client.connect_owner!(client;deadline=deadline()).lifecycle === Codec.Connected
                snapshot_codec = PropsBuffer(Source.SNAPSHOT_NAMES,Source.snapshot_values(Int64(1),
                    Source.INITIAL,Int64(0),Int32(0),Int64(1),Int64(0),false,false,Int64(1),Int64(0)))
                snapshot = Ref(snapshot_codec.prototype)
                # The public Node interface carries the same source PODs as a
                # camera Stream, with no invented detector or mirror port.
                source = with_thread_loop_lock(client.client.loop) do _
                    registry = something(client.client.registry)
                    object = only(find_globals(registry;interface="PipeWire:Interface:Node",
                        properties=("node.name"=>options.control_node,)))
                    node = bind(registry,object,Node;on_param=(node,seq,id,index,next,pod)->begin
                        id==SPA.PARAM_PROPS && pod!==nothing && parse_props!(snapshot,snapshot_codec,pod)
                        nothing
                    end)
                    subscribe_params!(node,(SPA.PARAM_PROPS,))
                    node
                end
                function control(pod,kind,token)
                    with_thread_loop_lock(client.client.loop) do _
                        set_param!(source,SPA.PARAM_PROPS,pod)
                    end
                    _wait_for_hil_condition(;timeout=10) do
                        istaskdone(owner_task) && error("owner exited: $(typeof(fetch(owner_task)))")
                        with_thread_loop_lock(client.client.loop) do _
                            snapshot[][3]==kind && snapshot[][4]==token
                        end
                    end
                    return with_thread_loop_lock(client.client.loop) do _; snapshot[]; end
                end
                running = control(run_control_request(1,:running),Source.RUN,1)
                @test running[5] == 0 && running[8]
                external_pupil_delivery(remote,options)
                refused = control(reset_control_request(2),Source.RESET,2)
                @test refused[5] < 0 && refused[6] == 1
                held = control(run_control_request(3,:stopped),Source.RUN,3)
                @test held[5] == 0 && !held[8]
                reset = control(reset_control_request(4),Source.RESET,4)
                @test reset[5] == 0 && reset[6] == 2 && reset[7] == 0 && !reset[8]
                with_thread_loop_lock(client.client.loop) do _; close(source); end
                source = nothing
                @test Client.quit!(client;deadline=deadline()).lifecycle === Codec.Stopped
                close(client); client=nothing
                @test fetch(owner_task) === nothing
            finally
                client === nothing || with_thread_loop_lock(client.client.loop) do _
                    source === nothing || close(source)
                end
                client === nothing || close(client)
                runtime.cancel[] = true
                timedwait(()->istaskdone(owner_task),10;pollint=0.01)
                close(runtime)
            end
        end
    end
end
