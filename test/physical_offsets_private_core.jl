# CPU native return-path selector: julia --threads=4,0 --project=<science-env> ...
using Test, SHA, LinearAlgebra
using PipeWireAO, PipeWireAORTC, AdaptiveOpticsSimPipeWireHIL, FilterGraphAlgorithms, FilterGraphPipeWire, JuliaFilterGraph
import PipeWireAO_jll
include(joinpath(pkgdir(AdaptiveOpticsSimPipeWireHIL),"test/private_core_helpers.jl"))
const HIL=AdaptiveOpticsSimPipeWireHIL
const FGP=FilterGraphPipeWire
const JFG=JuliaFilterGraph
const Offsets=PipeWireAORTC.PhysicalOffsets
const Ext=Base.get_extension(PipeWireAORTC,:PipeWireAORTCOffsetsExt)
const Cal=PipeWireAORTC.InstrumentCalibration
const ThreadPinning=PipeWireAORTC.NativeOwnerBootstrapRuntime.ThreadPinning
const Common=PipeWireAORTC.Common
function wait_until(predicate;timeout=10)
    deadline=time_ns()/1e9+timeout
    while !predicate()
        time_ns()/1e9<deadline || error("private offset condition timed out")
        @ccall gc_safe=true usleep(Cuint(5000)::Cuint)::Cint
        yield()
    end
end
progress(message)=(println("offset private: ",message);flush(stdout))
const P=Float32[1 0;0 1;1 1;1 -1]
const Q=Float32.(pinv(Float64.(P)))
const C=Float32[1 .2;.3 1]

include("physical_offsets_documents.jl")

@testset "native physical offsets keep both outputs paired and GPI frames independent" begin
    Threads.nthreads(:default)>=4 || error("run with --threads=4,0")
    for scenario in (:silence,:disconnect,:pending_unrelated,:pending_mixed)
    mktempdir() do directory
        graph,config=physical_offset_fixture(directory;P,Q,C)
        declaration=Common.read_yaml(config)
        declaration["branches"]["scc"]["acquisition_version"]=3
        Common.write_yaml(config,declaration)
        wall=Threads.Atomic{UInt64}(100)
        prepared=Offsets.prepare(config,graph)
        observer=Offsets.frame_observer(config,nothing,JFG.output_formats(graph))
        _with_private_core() do remote
            remote=joinpath(ENV["PIPEWIREAO_RUNTIME_DIR"],remote)
            progress("private core ready")
            node=FGP.PipeWireNode(graph;name="test.gpi",remote,rate=2000//1,connect=false,
                boundary_layout=RowMajorLayout(),frame_observer=observer)
            FGP.prepare!(node;execution=:complete_frame,required_outputs=(:compensated,:physical))
            connect!(node)
            exchange=ThreadPinning.@spawnat 4 begin
                current_task().sticky=true
                try
                wait_until(()->PipeWireAO.isrunning(node))
                progress("exchange ready on thread $(Threads.threadid())")
                specs=(
                    ("send-residual",CONTROLLER_RESIDUAL_ERROR_V1,2,false,2),
                    ("send-llowfs",REQUESTED_PDM_COMMAND_V1,4,false,2),
                    ("send-scc",REQUESTED_PDM_COMMAND_V1,4,false,3),
                    ("read-compensated",CONTROLLER_RESIDUAL_ERROR_V1,2,true,2),
                    ("read-physical",REQUESTED_PDM_COMMAND_V1,4,true,2),
                    ("read-scc",REQUESTED_PDM_COMMAND_V1,4,true,3))
                options=map(specs) do (name,schema,count,input,version)
                    HIL.PipeWireArrayStreamOptions(;node_name=name,media_name=name,schema,
                        acquisition_version=version,
                        format=NdArrayFormat(NdArray.F32_LE,(count,);layout=NdArray.ROW_MAJOR,rate=SPA.Fraction(2000,1)))
                end
                HIL.with_array_streams(Tuple(options);remote,input=map(x->x[4],specs)) do wire
                    progress("test arrays opened")
                    registry=HIL.with_array_stream(wire,1) do _; Registry(wire.core); end
                    links=Any[]
                    function port(name,direction,portname=nothing)
                        nodes=find_globals(registry;interface="PipeWire:Interface:Node",properties=("node.name"=>name,))
                        length(nodes)==1 || return nothing
                        ports=find_globals(registry;interface="PipeWire:Interface:Port",
                            properties=("node.id"=>string(only(nodes).id),"port.direction"=>direction))
                        portname===nothing || (ports=filter(p->get(p.properties,"port.name",nothing)==portname,ports))
                        return length(ports)==1 ? only(ports) : nothing
                    end
                    try
                        for (source,sourceport,sink,sinkport) in (
                                ("send-residual",nothing,"test.gpi","residual"),
                                ("send-llowfs",nothing,"receive-llowfs",nothing),
                                ("send-scc",nothing,"receive-scc",nothing),
                                ("test.gpi","compensated","read-compensated",nothing),
                                ("test.gpi","physical","read-physical",nothing),
                                ("send-scc",nothing,"read-scc",nothing))
                            progress("link $source to $sink")
                            wait_until() do
                                roundtrip(registry)
                                port(source,"out",sourceport)!==nothing && port(sink,"in",sinkport)!==nothing
                            end
                            out,inlet=port(source,"out",sourceport),port(sink,"in",sinkport)
                            push!(links,HIL.with_array_stream(wire,1) do _
                                create_object(wire.core,"link-factory",Link;properties=Dict(
                                    "link.output.node"=>out.properties["node.id"],"link.output.port"=>string(out.id),
                                    "link.input.node"=>inlet.properties["node.id"],"link.input.port"=>string(inlet.id),"object.linger"=>"false"))
                            end)
                        end
                        for i in eachindex(specs)
                            wait_until() do
                                HIL.with_array_stream(wire,i) do stream
                                    stream_state(stream)==PipeWireAO.LibPipeWire.PW_STREAM_STATE_STREAMING
                                end
                            end
                        end
                        domains=map(k->AcquisitionDomain(ntuple(i->UInt8(i+k),16)),(1,2,3))
                        sequences=zeros(UInt64,3)
                        function emit(index,values;pts=0,duration=500000,generation=1)
                            sequences[index]+=1
                            @test HIL.stage_pipewire_array!(wire,index,values;
                                identity=AcquisitionIdentity(domains[index],UInt64(generation),sequences[index]),
                                pts=Int64(pts),duration=UInt64(duration),
                                trigger_state=index==3 ? ACQUISITION_TRIGGER_LOW : ACQUISITION_TRIGGER_ABSENT)
                            HIL.with_array_stream(wire,index) do stream; trigger_process!(stream); end
                        end
                        physical=zeros(Float32,4);compensated=zeros(Float32,2)
                        function frame(pts,expected)
                            progress("frame $pts")
                            emit(1,zeros(Float32,2);pts)
                            receipt=Ref{Any}(nothing)
                            try
                                wait_until() do
                                    receipt[]=HIL.drain_pipewire_array!(physical,wire,5)
                                    if receipt[]===nothing
                                        HIL.with_array_stream(wire,1) do stream;trigger_process!(stream);end
                                    end
                                    receipt[]!==nothing
                                end
                            catch error
                                progress("processed=$(node.owner.process_count) native_error=$(FGP.last_error(node)) clock=$(Ext.clock_sample(observer.clock))")
                                for i in eachindex(specs)
                                    progress("stream$i status=$(HIL.array_stream_status(wire,i))")
                                end
                                rethrow()
                            end
                            wait_until() do
                                HIL.drain_pipewire_array!(compensated,wire,4)!==nothing
                            end
                            @test physical≈expected atol=1e-15
                            @test compensated≈-C*(Q*expected) atol=1e-15
                            @test receipt[].identity.sequence==sequences[1]
                        end
                        frame(0,zeros(Float32,4)) # GPI operates before CAL2 is present
                        a,b=P*Float32[1e-9,0],P*Float32[0,2e-9]
                        for (source,value,expected,pts) in ((2,a,a,500000),(3,b,a+b,1000000))
                            before=FGP.parameter_status(node,:reference).requested_parameter_sequence
                            emit(source,value)
                            wait_until() do
                                FGP.parameter_status(node,:reference).requested_parameter_sequence>before
                            end
                            frame(pts,expected)
                            if source==3
                                observed=zeros(Float32,4)
                                receipt=Ref{Any}(nothing)
                                wait_until() do
                                    receipt[]=HIL.drain_pipewire_array!(observed,wire,6)
                                    receipt[]!==nothing
                                end
                                @test observed==value
                                @test receipt[].identity.sequence==sequences[3]
                                @test receipt[].trigger_state==ACQUISITION_TRIGGER_LOW
                                @test receipt[].pts==0 && receipt[].duration==500000
                                @test prepared.receiver.branches[:scc].last_sequence==receipt[].identity.sequence
                            end
                        end
                        # New source generation is never silently admitted;
                        # clearing LL leaves the independently held SCC intact.
                        before=FGP.parameter_status(node,:reference).requested_parameter_sequence
                        emit(2,2a;generation=2,pts=500000)
                        wait_until() do
                            FGP.parameter_status(node,:reference).requested_parameter_sequence>before
                        end
                        frame(1500000,b)
                        frame(2000000,b) # no new CAL2 packet required for a GPI frame
                        status=FGP.parameter_status(node,:reference)
                        @test status.active_parameter_sequence==status.requested_parameter_sequence
                        if scenario===:silence
                        # Withhold GPI frames: stage a nonzero SCC update,
                        # expire it, then inspect the FIRST resumed frame.
                        before=status.requested_parameter_sequence
                        emit(3,0.5f0*b;pts=2000000)
                        wait_until() do
                            FGP.parameter_status(node,:reference).requested_parameter_sequence>before
                        end
                        pending=FGP.parameter_status(node,:reference)
                        @test pending.requested_parameter_sequence>pending.active_parameter_sequence
                        wall[]=UInt64(10000000101)
                        wait_until() do
                            FGP.parameter_status(node,:reference).requested_parameter_sequence>pending.requested_parameter_sequence
                        end
                        frame(2500000,zeros(Float32,4))
                        @test !FGP.parameter_status(node,:reference).closure_inhibited
                        elseif scenario===:disconnect
                            before=FGP.parameter_status(node,:reference).requested_parameter_sequence
                            # Unlink only SCC. Its fault clears this contribution
                            # while GPI keeps receiving and publishing frames.
                            HIL.with_array_stream(wire,1) do _
                                close(popat!(links,3))
                            end
                            wait_until() do
                                FGP.parameter_status(node,:reference).requested_parameter_sequence>before
                            end
                            frame(2500000,zeros(Float32,4))
                        else
                            # Hold the primary source with SCC still active. Even
                            # equal-valued calibration replacement is a legal,
                            # incompatible transaction rather than offset-only
                            # supersession. A mixed transaction has the same rule.
                            processed=node.owner.process_count
                            if scenario===:pending_unrelated
                                FGP.replace_parameters!(node,:q=>copy(Q))
                            else
                                FGP.replace_parameters!(node,:offset=>copy(b),:q=>copy(Q))
                            end
                            pending=FGP.parameter_status(node,:reference)
                            @test pending.requested_parameter_sequence>pending.active_parameter_sequence
                            wall[]=UInt64(10000000101)
                            wait_until(()->!PipeWireAO.isrunning(node))
                            # No resumed primary frame can adopt the incompatible
                            # pending transaction: the receiver quits its owner.
                            @test node.owner.process_count==processed
                            @test FGP.parameter_status(node,:reference).active_parameter_sequence==pending.active_parameter_sequence
                            @test HIL.drain_pipewire_array!(physical,wire,5)===nothing
                            @test HIL.drain_pipewire_array!(compensated,wire,4)===nothing
                        end
                        # Hold/quit the graph before removing its transport peers.
                        quit!(node)
                        wait_until(()->!PipeWireAO.isrunning(node))
                    finally
                        HIL.with_array_stream(wire,1) do _
                            foreach(close,reverse(links));close(registry)
                        end
                    end
                end
                catch error
                    progress(sprint(showerror,error))
                    rethrow()
                finally
                    quit!(node)
                end
            end
            try
                failure=try
                    Offsets.with_receiver(prepared;node,remote,frame_clock=observer,clock=()->wall[]) do
                        progress("receiver connected; run graph")
                        FGP.run!(node)
                    end
                    nothing
                catch error
                    error
                end
                if scenario in (:pending_unrelated,:pending_mixed)
                    @test failure isa TaskFailedException
                    @test occursin("pending transaction is not the same physical offset without calibration changes",sprint(showerror,failure))
                    @test !PipeWireAO.isrunning(node)
                else
                    failure===nothing || throw(failure)
                end
            finally
                quit!(node)
                fetch(exchange)
                close(node)
            end
        end
    end
    end
end
