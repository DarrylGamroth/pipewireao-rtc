include("test_calibration_capture.jl")
include("native_control_private_core.jl")

function capture_link(core,registry,source,sink)
    wait_proof(10,"capture ports") do
        roundtrip(registry)
        !isempty(find_globals(registry;interface="PipeWire:Interface:Port",
            properties=("node.id"=>string(node_id(source)),"port.direction"=>"out"))) &&
        !isempty(find_globals(registry;interface="PipeWire:Interface:Port",
            properties=("node.id"=>string(node_id(sink)),"port.direction"=>"in")))
    end
    output=only(find_globals(registry;interface="PipeWire:Interface:Port",
        properties=("node.id"=>string(node_id(source)),"port.direction"=>"out")))
    input=only(find_globals(registry;interface="PipeWire:Interface:Port",
        properties=("node.id"=>string(node_id(sink)),"port.direction"=>"in")))
    with_thread_loop_lock(main_loop(core)) do _
        create_object(core,"link-factory",Link;properties=Dict(
            "link.output.node"=>string(node_id(source)),"link.output.port"=>string(output.id),
            "link.input.node"=>string(node_id(sink)),"link.input.port"=>string(input.id),"object.linger"=>"false"))
    end
end

@testset "private-core correlated four-stream capture and shared wakeup ownership" begin
    with_control_private_core() do remote,directory,daemon
        loop=ThreadLoop("test.capture.private")
        context,core,registry=with_thread_loop_lock(loop) do _
            context=Context(loop)
            core=CoreConnection(context;properties=Dict("remote.name"=>remote))
            context,core,Registry(core)
        end
        start!(loop)
        capture=nothing
        sources=Any[];links=Any[]
        wakeup=Base.AsyncCondition()
        try
            declarations=capture_declarations("private.capture")
            capture=CC.Capture(core,declarations;wakeup)
            for name in keys(declarations)
                spec=getproperty(declarations,name);slot=getproperty(capture.slots,name)
                source=NdArraySource(core,"private.source.$name",zeros(eltype(slot.wire),length(slot.wire)),spec.format;schema=spec.schema)
                push!(sources,source)
                push!(links,capture_link(core,registry,source.stream,getproperty(capture.streams,name)))
            end
            roundtrip(core)
            start!(capture);foreach(start!,sources)
            for sequence in 1:2
                CC.arm!(capture,exposure(sequence))
                publisher=@async begin
                    sleep(0.01)
                    for (index,source) in enumerate(sources)
                        slot=values(capture.slots)[index]
                        T=eltype(slot.wire)
                        payload=T===Bool ? Bool[false,true] : T.(1:length(slot.wire))
                        token=submit_array!(source,payload,BufferHeader(UInt32(0),UInt32(0),Int64(9000),Int64(0),UInt64(sequence));
                            identity=identity(sequence),exposure_duration_ns=10)
                        wait_array_source!(source,token;timeout_ns=10_000_000_000)
                    end
                end
                result=CC.await!(capture;deadline=PipeWireAORTC.NativeControlClient.monotonic()+15)
                fetch(publisher)
                @test result.arrays.raw==UInt16[1 2 3;4 5 6]
                @test result.arrays.slopes==Float32[1 2;3 4]
                @test result.arrays.validity==[false,true]
                @test all(receipt->receipt.identity==identity(sequence),values(result.metadata))
                @test all(slot->slot.buffer.handle==C_NULL,values(capture.slots))
            end
            # A full identity mismatch over a real link faults the armed capture.
            CC.arm!(capture,exposure(3))
            source=first(sources)
            token=submit_array!(source,UInt16[1,2,3,4,5,6],
                BufferHeader(UInt32(0),UInt32(0),Int64(9000),Int64(0),UInt64(3));
                identity=identity(3,2),exposure_duration_ns=10)
            wait_array_source!(source,token;timeout_ns=10_000_000_000)
            @test_throws InvalidStateException CC.await!(capture;deadline=PipeWireAORTC.NativeControlClient.monotonic()+5)
            @test capture.failure===:identity
            @test_throws InvalidStateException CC.snapshot(capture)
            close(capture)
            @test isopen(wakeup)
            @test isopen(core)
        finally
            capture===nothing || close(capture)
            with_thread_loop_lock(loop) do _
                foreach(close,reverse(links))
            end
            foreach(close,reverse(sources))
            close(wakeup)
            with_thread_loop_lock(loop) do _
                close(registry);close(core);close(context)
            end
            close(loop)
        end
    end
end

@test !any(id->id.name in ("CUDA","AMDGPU"),keys(Base.loaded_modules))
