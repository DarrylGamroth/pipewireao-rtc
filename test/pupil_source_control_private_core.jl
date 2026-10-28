# Native source control boundary; a committed snapshot survives Pause/Run.
using Test,LinearAlgebra,PipeWireAORTC,PipeWireAO,AdaptiveOpticsSim,AdaptiveOpticsSimPipeWireHIL
using AdaptiveOpticsSim.AlgorithmGraphs
using AdaptiveOpticsSim.AlgorithmGraphs: poll_graph_output_snapshot!,snapshot_metadata,release_graph_output_snapshot!
import PipeWireAO_jll
const HIL=AdaptiveOpticsSimPipeWireHIL
const Ext=Base.get_extension(PipeWireAORTC,:PipeWireAORTCAOSExt)
const Source=Ext.PupilSourceOwner
const SC=PipeWireAORTC.NativeSourceControl
const O=PipeWireAORTC.PhysicalOffsets
Base.include(@__MODULE__,joinpath(@__DIR__,"pupil_source_documents.jl"))
Base.include(@__MODULE__,joinpath(pkgdir(HIL),"test/private_core_helpers.jl"))

@testset "Pause/Run retains the committed pupil cursor without reset or snapshot loss" begin
    mktempdir() do directory
        (;config)=pupil_source_documents(directory)
        options=PipeWireAORTC.AOSOwner.configuration(config)
        science=PipeWireAORTC.AOSOwner.prepare_pupil_source_science(options)
        publisher=science.publisher
        state=Ext.OwnerState()
        calibration=O.Calibration(;identity=options.calibration_identity,schema="test.physical/1",command_order=options.command_order,
            projection=Matrix{Float32}(I,2,2),inverse=Matrix{Float32}(I,2,2),modes=[1,2],
            command_limit_m=1e-6,coefficient_limit_m=1e-7,max_age_ns=100,silence_ns=1000)
        receiver=O.Receiver((scc=calibration,);command_limit_m=1e-6)
        try
            _with_private_core() do remote
                remote=joinpath(ENV["PIPEWIREAO_RUNTIME_DIR"],remote)
                option=HIL.PipeWireArrayStreamOptions(;node_name="control-boundary",media_name="control-boundary",
                    schema="test.physical/1",format=NdArrayFormat(NdArray.F32_LE,(2,);layout=NdArray.ROW_MAJOR))
                HIL.with_array_streams((option,);remote,input=(false,)) do transport
                    mailbox=SC.Mailbox(Int64(1))
                    control=nothing
                    try
                        with_thread_loop_lock(transport.loop) do _
                            control=Filter(transport.core,"pupil-control";properties=SC.source_properties(mailbox),
                                on_param_changed=SC.ParameterChanged(mailbox))
                            connect!(control;flags=FILTER_ASYNC|FILTER_INACTIVE,params=mailbox.parameters.params)
                        end
                        runtime=(;transport)
                        admitted=merge(options,(;bootstrap_runtime=runtime,owner_check=()->nothing))
                        command=zeros(Float32,2)
                        function run_control(token,running)
                            with_thread_loop_lock(transport.loop) do _
                                SC.stage!(mailbox,SC.RUN,Int64(token),running)
                            end
                            Source.consume_control!(admitted,mailbox,control,state,()->error("unexpected reset"))
                        end
                        run_control(1,true)
                        @test state.running
                        state.sequence=Source.step!(science,publisher,receiver,command;generation=UInt64(state.generation))
                        # Leave the actual committed snapshot pending through the
                        # native Pause ACK; only the source cursor is frozen.
                        run_control(2,false)
                        @test !state.running && state.sequence==1 && state.generation==1
                        @test mailbox.snapshot_destination[][6:7]==(Int64(1),Int64(1))
                        _wait_for_hil_condition(()->poll_graph_output_snapshot!(publisher.snapshot))
                        metadata=snapshot_metadata(publisher.snapshot)
                        @test metadata.sequence==1 && metadata.model_time_ns==0
                        release_graph_output_snapshot!(publisher.snapshot)
                        @test publisher.dropped[]==0 && !publisher.paused[]
                        run_control(3,true)
                        @test state.running && state.sequence==1 && state.generation==1
                        state.sequence=Source.step!(science,publisher,receiver,command;generation=UInt64(state.generation))
                        _wait_for_hil_condition(()->poll_graph_output_snapshot!(publisher.snapshot))
                        metadata=snapshot_metadata(publisher.snapshot)
                        @test metadata.sequence==2 && metadata.model_time_ns==2_000_000 && metadata.generation==1
                        release_graph_output_snapshot!(publisher.snapshot)
                        @test publisher.dropped[]==0
                        @test graph_step_sequence(science.graph)==model_time_sequence(science.driver)==2
                    finally
                        with_thread_loop_lock(transport.loop) do _
                            control===nothing || close(control)
                        end
                    end
                end
            end
        finally
            Ext.PupilOutput.close!(publisher)
        end
    end
    @test !any(id->id.name in ("FilterGraphAlgorithms","FilterGraphPipeWire","JuliaFilterGraph","CUDA","AMDGPU"),keys(Base.loaded_modules))
end
