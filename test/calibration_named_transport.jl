# Optional native selector: two independent conditioner owners on one private
# core. No optical model, deployed session, device or accelerator is used.
module CalibrationNamedTransportTests
using Test, PipeWireAO, PipeWireAORTC, FilterGraphIsland, FilterGraphPipeWire, JuliaFilterGraph
using AdaptiveOpticsSim, AdaptiveOpticsSimPipeWireHIL, AdaptiveOpticsCalibration
include("native_control_private_core.jl")
include("calibration_named_commands.jl")
const Ext=Base.get_extension(PipeWireAORTC,:PipeWireAORTCCalibrationExt)
const Native=PipeWireAORTC.NativeCalibrationEndpoint
const Control=PipeWireAORTC.NativeControlClient

function named_transport(remote,directory,daemon)
    condition,guard=Base.AsyncCondition(),ReentrantLock()
    notify()=Native.wake!(condition,guard)
    await(predicate;seconds=15)=Native.await(predicate,condition,guard,Control.monotonic()+seconds)
    loop=ThreadLoop("test.named-calibration-transport")
    context=core=registry=listener=probes=nothing
    workers=Ext.CalibrationGraphWorker[]
    links=PipeWireAO.Link[]
    sinks=Stream[]
    commands=(woofer=CalibrationNamedCommandTests.prepare_command(2,"test.woofer/1"),
        tiptilt=CalibrationNamedCommandTests.prepare_command(3,"test.tiptilt/1"))
    actual=map(descriptor->zeros(Float32,only(JuliaFilterGraph.input_formats(descriptor.graph).requested.shape)),commands)
    sequences=map(_->Ref(UInt64(0)),commands)
    buffers=map(_->StreamBuffer(),commands)
    try
        with_thread_loop_lock(loop) do _
            context=Context(loop)
            core=CoreConnection(context;properties=Dict("remote.name"=>remote))
            registry=Registry(core)
            listener=add_listener!(registry;on_global_added=(_...)->notify(),on_global_removed=(_...)->notify())
        end
        start!(loop)
        probes=Ext.prepare_calibration_probes(core,commands,500//1;notify,prefix="test.named-command")
        with_thread_loop_lock(loop) do _
            @test length(unique(stream_properties(probe.source)["node.name"] for probe in values(probes.probes)))==2
        end
        for (key,descriptor) in pairs(commands)
            push!(workers,Ext.start_calibration_graph(descriptor,remote,"test.named.$key",500//1;notify))
        end
        with_thread_loop_lock(loop) do _
            for (key,descriptor) in pairs(commands)
                buffer=getproperty(buffers,key)
                demand=getproperty(actual,key)
                sequence=getproperty(sequences,key)
                sink=Stream(core,"test.named-demand.$key";
                    properties=Dict("node.name"=>"test.named-demand.$key","node.reliable"=>"true"),
                    on_process=stream->begin
                        dequeue_buffer!(buffer,stream) || return nothing
                        try
                            copyto!(demand,reinterpret(Float32,buffer_memory(buffer_data(buffer),sizeof(demand))))
                            sequence[]=something(buffer_header(buffer)).sequence
                        finally
                            queue_buffer!(buffer,stream)
                        end
                        notify()
                        nothing
                    end)
                push!(sinks,sink)
                format=Ext.calibration_probe_format(JuliaFilterGraph.output_formats(descriptor.graph).demanded,500//1)
                connect!(sink,:input;flags=STREAM_MAP_BUFFERS|STREAM_INACTIVE|STREAM_DONT_RECONNECT|STREAM_NO_CONVERT,
                    params=Ext.calibration_probe_parameters(format,"test.$key/1"))
            end
        end
        connections=Tuple(connection for (index,key) in enumerate(keys(commands)) for connection in (
            (getproperty(probes.probes,key).source,nothing,"test.named.$key",:requested),
            ("test.named.$key",Symbol("constraint-feedback"),getproperty(probes.probes,key).feedback,nothing),
            ("test.named.$key",:demanded,sinks[index],nothing)))
        function check()
            for worker in workers
                istaskdone(worker.task) && error("named graph stopped: $(worker.error[])")
            end
            snapshot=Ext.calibration_probe_snapshot(probes)
            snapshot.error===nothing || throw(snapshot.error)
        end
        endpoints=Native.await(condition,guard,Control.monotonic()+30) do
            check()
            all(worker->worker.ready[],workers) || return nothing
            with_thread_loop_lock(loop) do _
                candidates=map(connections) do (output,outname,input,inname)
                    (Ext.calibration_endpoint(registry,output,"out",outname),
                        Ext.calibration_endpoint(registry,input,"in",inname))
                end
                all(pair->all(!isnothing,pair),candidates) ? candidates : nothing
            end
        end
        for (output,input) in endpoints
            push!(links,Ext.calibration_link(core,registry,output,input;on_info=(_...)->notify()))
        end
        with_thread_loop_lock(loop) do _
            foreach(sink->set_active!(sink,true),sinks)
            for probe in values(probes.probes)
                set_active!(probe.feedback,true)
                set_active!(probe.source,true)
            end
        end
        roundtrip(core)
        await() do
            check()
            with_thread_loop_lock(loop) do _
                all(probe -> stream_state(probe.source)==PipeWireAO.LibPipeWire.PW_STREAM_STATE_STREAMING &&
                    stream_state(probe.feedback)==PipeWireAO.LibPipeWire.PW_STREAM_STATE_STREAMING, values(probes.probes)) &&
                    all(sink -> stream_state(sink)==PipeWireAO.LibPipeWire.PW_STREAM_STATE_STREAMING, sinks)
            end
        end
        references=(woofer=Float32[0,0],tiptilt=Float32[.1,.2,.3])
        requested=merge(references,(woofer=Float32[.5,-2],))
        for (token,figures) in ((UInt64(1),references),(UInt64(2),requested),(UInt64(3),references))
            Ext.stage!(probes,token,figures)
            try
                await() do
                    check()
                    Ext.calibration_probe_snapshot(probes).received==token &&
                        all(sequence->sequence[]==token,values(sequences))
                end
            catch
                @show token Ext.calibration_probe_snapshot(probes) map(sequence->sequence[],sequences)
                with_thread_loop_lock(loop) do _
                    @show map(probe->(stream_state(probe.source),stream_state(probe.feedback)),probes.probes)
                    @show map(stream_state,sinks)
                end
                rethrow()
            end
            snapshot=Ext.calibration_probe_snapshot(probes)
            @test snapshot.received==snapshot.published==snapshot.sequence==token
            @test actual.tiptilt==references.tiptilt
            @test Ext.calibration_feedback(figures,actual,snapshot.values)==(token==2)
        end
        @test actual==references
        # With one feedback Link absent the aggregate cannot report completion.
        # Test its absolute deadline directly; the public owner additionally
        # fences any graph worker that stops when the Link disappears.
        with_thread_loop_lock(loop) do _
            close(links[5])
            deleteat!(links,5)
        end
        roundtrip(core)
        Ext.stage!(probes,UInt64(4),references)
        @test_throws Control.UnknownOutcome await(;seconds=.1) do
            Ext.calibration_probe_snapshot(probes).received==4
        end
        @test Ext.calibration_probe_snapshot(probes).received!=4
        @test Ext.calibration_probe_snapshot(probes).error===nothing
    finally
        for worker in workers
            Ext.quit_calibration_graph!(worker)
        end
        for worker in workers
            await(()->istaskdone(worker.task))
        end
        probes===nothing || close(probes)
        with_thread_loop_lock(loop) do _
            foreach(close,reverse(links))
            foreach(close,reverse(sinks))
            for resource in (listener,registry,core,context)
                resource===nothing || close(resource)
            end
        end
        close(loop)
        foreach(descriptor->FilterGraphIsland.close_execution(descriptor.graph),values(commands))
        close(condition)
    end
end

@testset "named command transport verifies all Ports and restores the complete reference" begin
    Threads.nthreads(:default)>=3 || error("run with at least three Julia default threads")
    with_control_private_core(named_transport)
    @test !any(id.name in ("CUDA","AMDGPU") for id in keys(Base.loaded_modules))
end
end
