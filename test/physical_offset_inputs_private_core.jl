# HIL-only native source receiver: no graph/controller algorithm dependency.
using Test,LinearAlgebra,PipeWireAORTC,PipeWireAO,AdaptiveOpticsSimPipeWireHIL
import PipeWireAO_jll
const HIL=AdaptiveOpticsSimPipeWireHIL
const O=PipeWireAORTC.PhysicalOffsets
const C=PipeWireAORTC.Common
const A=PipeWireAORTC.InstrumentCalibration
Base.include(@__MODULE__,joinpath(@__DIR__,"physical_offset_inputs_documents.jl"))
Base.include(@__MODULE__,joinpath(pkgdir(HIL),"test/private_core_helpers.jl"))

function wait_until(f;timeout=10)
    deadline=time_ns()/1e9+timeout
    while !f()
        time_ns()/1e9<deadline || error("native physical input condition timed out")
        sleep(0.002)
    end
end

@testset "source-owned native P/Q receiver holds, withdraws and fences reset cohorts" begin
    mktempdir() do directory
        document=physical_inputs_document(directory)
        # Give this native scheduling selector a bounded model interval; its
        # wall silence is driven explicitly by poll!(now_ns), never sleep timing.
        for row in values(document["branches"])
            row["max_age_ns"]=1_000_000_000
        end
        path=joinpath(directory,"offsets.yaml");C.write_yaml(path,document)
        prepared=O.prepare(path;command_count=4,command_order="actual-physical-order",calibration_identity="accepted-calibration")
        _with_private_core() do remote
            remote=joinpath(ENV["PIPEWIREAO_RUNTIME_DIR"],remote)
            O.with_receiver(prepared;remote) do inputs
                options=Tuple(HIL.PipeWireArrayStreamOptions(;node_name="send-"*string(name),media_name=string(name),
                    acquisition_version=i==1 ? 2 : 3,schema="test.physical/1",
                    format=NdArrayFormat(NdArray.F32_LE,(4,);layout=NdArray.ROW_MAJOR)) for (i,name) in enumerate(prepared.inputs.names))
                HIL.with_array_streams(options;remote,input=(false,false)) do wire
                    registry=HIL.with_array_stream(wire,1) do _;Registry(wire.core);end
                    links=Any[]
                    function port(name,direction)
                        nodes=find_globals(registry;interface="PipeWire:Interface:Node",properties=("node.name"=>name,))
                        length(nodes)==1 || return nothing
                        ports=find_globals(registry;interface="PipeWire:Interface:Port",
                            properties=("node.id"=>string(only(nodes).id),"port.direction"=>direction))
                        return length(ports)==1 ? only(ports) : nothing
                    end
                    try
                        for name in prepared.inputs.names
                            wait_until() do
                                roundtrip(registry)
                                port("send-"*string(name),"out")!==nothing && port("receive-"*string(name),"in")!==nothing
                            end
                            source,sink=port("send-"*string(name),"out"),port("receive-"*string(name),"in")
                            push!(links,HIL.with_array_stream(wire,1) do _
                                create_object(wire.core,"link-factory",Link;properties=Dict("link.output.node"=>source.properties["node.id"],
                                    "link.output.port"=>string(source.id),"link.input.node"=>sink.properties["node.id"],
                                    "link.input.port"=>string(sink.id),"object.linger"=>"false"))
                            end)
                        end
                        for i in 1:2
                            wait_until() do
                                HIL.with_array_stream(wire,i) do stream
                                    stream_state(stream)==PipeWireAO.LibPipeWire.PW_STREAM_STATE_STREAMING
                                end
                            end
                        end
                        r=prepared.inputs.receiver
                        source_domain=AcquisitionDomain(ntuple(i->UInt8(i),16))
                        domains=map(k->AcquisitionDomain(ntuple(i->UInt8(i+k),16)),(2,3))
                        function source_clock(sequence;generation=1,pts=(sequence-1)*10)
                            O.observe_clock!(r,AcquisitionIdentity(source_domain,UInt64(generation),UInt64(sequence)),Int64(pts),UInt64(10))
                        end
                        function emit(i,values,sequence;generation=1,pts=0)
                            @test HIL.stage_pipewire_array!(wire,i,values;identity=AcquisitionIdentity(domains[i],UInt64(generation),UInt64(sequence)),
                                pts=Int64(pts),duration=UInt64(10),trigger_state=i==2 ? ACQUISITION_TRIGGER_LOW : ACQUISITION_TRIGGER_ABSENT)
                            HIL.with_array_stream(trigger_process!,wire,i)
                        end
                        function adopted(predicate;now=100)
                            wait_until() do
                                for i in 1:2;HIL.with_array_stream(trigger_process!,wire,i);end
                                O.poll!(inputs;now_ns=UInt64(now))
                                predicate()
                            end
                        end
                        source_clock(1)
                        @test all(iszero,O.poll!(inputs;now_ns=UInt64(1))) # Controller priming/no output.
                        source_clock(2)
                        @test all(iszero,O.poll!(inputs;now_ns=UInt64(2)))
                        a=Float32[1e-9,0,1e-9,1e-9]
                        b=Float32[0,2e-9,2e-9,-2e-9]
                        emit(1,a,1)
                        adopted(()->r.branches[:llowfs].present)
                        @test prepared.inputs.total≈a
                        emit(2,b,1)
                        adopted(()->r.branches[:scc].present)
                        @test prepared.inputs.total≈a+b
                        @test r.branches[:scc].identity.generation==1
                        source_clock(3)
                        @test O.poll!(inputs;now_ns=UInt64(1000))≈a+b # held absolute, no new output needed
                        @test all(iszero,O.poll!(inputs;now_ns=UInt64(1101)))
                        @test all(c.reason===:silence for c in values(r.branches))
                        O.reset_inputs!(inputs)
                        @test r.clock_identity===nothing && r.clock_end_ns==0
                        @test all(iszero,prepared.inputs.total)
                        source_clock(1;generation=2)
                        emit(2,b,2) # Old branch generation cannot cross reset.
                        wait_until() do
                            HIL.with_array_stream(trigger_process!,wire,2)
                            HIL.array_stream_status(inputs.transport,2).pending
                        end
                        O.poll!(inputs;now_ns=UInt64(100))
                        @test !r.branches[:scc].present
                        emit(2,b,1;generation=2)
                        adopted(()->r.branches[:scc].present)
                        @test prepared.inputs.total≈b
                        # Invalid physical payload withdraws only its contribution.
                        emit(2,Float32[NaN,0,0,0],2;generation=2)
                        adopted(()->!r.branches[:scc].armed)
                        @test all(iszero,prepared.inputs.total)
                        @test r.branches[:scc].reason===:payload
                    finally
                        HIL.with_array_stream(wire,1) do _
                            foreach(close,reverse(links))
                            close(registry)
                        end
                    end
                end
            end
        end
        @test all(!c.armed for c in values(prepared.inputs.receiver.branches))
        @test all(iszero,prepared.inputs.total)
    end
    @test !any(id->id.name in ("FilterGraphAlgorithms","FilterGraphPipeWire","JuliaFilterGraph","CUDA","AMDGPU"),keys(Base.loaded_modules))
end
