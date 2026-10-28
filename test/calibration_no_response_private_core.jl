# Optional public-owner CPU selector. No raw files, GPU, deployed core or device.
# Set PIPEWIREAORTC_CALIBRATION_APPLICATION to a built CPU Classic application.
module CalibrationNoResponsePrivateCoreTests
using Test, PipeWireAO, PipeWireAORTC, FilterGraphIsland, FilterGraphPipeWire, JuliaFilterGraph
using AdaptiveOpticsSim, AdaptiveOpticsSimPipeWireHIL, AdaptiveOpticsCalibration
include("native_control_private_core.jl")
const C=PipeWireAORTC.InstrumentCalibration
const E=PipeWireAORTC.NativeCalibrationEndpoint
const A=PipeWireAORTC.NativeCalibrationActionCodec
const Client=PipeWireAORTC.NativeCalibrationActionClient
const Control=PipeWireAORTC.NativeControlClient
const Ext=Base.get_extension(PipeWireAORTC,:PipeWireAORTCCalibrationExt)

@testset "consumer-only native Collect keeps full ADC samples and exact bounded receipts" begin
    Threads.nthreads(:default)>=4 || error("run with at least four Julia default threads")
    application=ENV["PIPEWIREAORTC_CALIBRATION_APPLICATION"]
    before=Ext.reference_application_hashes(application)
    with_control_private_core() do remote,directory,daemon
        chmod(dirname(remote),0o700)
        frontend=command=server=client=serving=nothing
        seen=Any[]
        fail=Ref(false)
        consume=function (sample,exposure)
            push!(seen,(;identity=sample.metadata.raw.identity,
                output_identity=sample.metadata.calibrated.identity,
                shape=size(sample.arrays.raw),type=eltype(sample.arrays.raw)))
            fail[] && error("bounded online consumer failed")
            nothing
        end
        try
            frontend=C.calibration_graph(application;inputs=(raw="pixel-calibration:raw",),
                outputs=(calibrated="pixel-calibration:calibrated",))
            command=C.calibration_graph(application;inputs=(requested="pdm-command:requested",),
                outputs=(:demanded,Symbol("constraint-feedback")))
            count=only(JuliaFilterGraph.input_formats(command.graph).requested.shape)
            shape=JuliaFilterGraph.input_formats(frontend.graph).raw.shape
            reference=zeros(Float32,count)
            name="test.consumer-only.$(getpid())"
            instance=Int64(501)
            deadline=Control.monotonic()+600
            @test_throws ArgumentError C.prepare_initial_calibration(application,remote,frontend,command;
                reference,name,instance,deadline,measurements=nothing,simulation_graph="dark")
            server=C.prepare_initial_calibration(application,remote,frontend,command;
                reference,name,instance,deadline,measurements=nothing,consume,simulation_graph="dark")
            frontend=command=nothing
            owner=server.effects
            @test owner.measurements===nothing && owner.capture_store===nothing
            serving=@async try E.serve!(server;deadline=deadline+600);nothing catch error;error end
            client=Client.connect(Client.Binding(remote,name,getpid(),instance),UInt64(1),
                Int64(600_000_000_000);command_count=count,deadline)
            action(value)=Client.complete!(client,value;deadline,record=false)
            @test action(A.Hold()) isa A.Held
            adopted=action(A.Adopt(UInt32(0),reference))
            @test adopted isa A.Adopted && !adopted.clipped
            settled=action(A.Settle(UInt32(0),adopted.cursor,A.DiscardExposures(UInt32(1))))
            @test settled isa A.Settled && settled.cursor.sequence==1
            @test isempty(seen) # Settling is never delivered to the consumer.
            for (measurements,frames) in ((UInt32(1),UInt32(1)),(UInt32(0),UInt32(4096)))
                rejected=action(A.Collect(UInt32(0),settled.cursor,measurements,frames))
                @test rejected isa A.Failed && rejected.reason===A.InvalidEvidence
                @test owner.cursor==settled.cursor && isempty(seen)
            end
            result=action(A.Collect(UInt32(0),settled.cursor,UInt32(0),UInt32(2)))
            @test result isa A.Responses && result.values isa Vector{Float32} && isempty(result.values)
            @test result.valid && length(result.exposures)==length(seen)==2
            @test all(sample->sample.type===UInt16 && sample.shape==shape,seen)
            @test all(sample->sample.identity==sample.output_identity,seen)
            @test all(sample->sample.identity.domain==owner.acquisition_domain,seen)
            @test [sample.identity.sequence for sample in seen]==[value.sequence for value in result.exposures]==[2,3]
            @test all(sample.identity.generation==value.generation for (sample,value) in zip(seen,result.exposures))
            fail[]=true
            adopted=action(A.Adopt(UInt32(1),reference))
            settled=action(A.Settle(UInt32(1),adopted.cursor,A.Immediate()))
            result=action(A.Collect(UInt32(1),settled.cursor,UInt32(0),UInt32(2)))
            @test result isa A.Responses && isempty(result.values) && !result.valid
            @test length(result.exposures)==2 && [value.sequence for value in result.exposures]==[4,5]
            @test length(seen)==3 && owner.cursor.sequence==5 && owner.consumer_failed
            adopted=action(A.Adopt(UInt32(2),reference))
            settled=action(A.Settle(UInt32(2),adopted.cursor,A.Immediate()))
            rejected=action(A.Collect(UInt32(2),settled.cursor,UInt32(0),UInt32(1)))
            @test rejected isa A.Failed && rejected.reason===A.InvalidEvidence
            @test owner.cursor==settled.cursor && length(seen)==3
            restored=action(A.Restore(reference,A.Immediate()))
            @test restored isa A.Restored && restored.figure==reference && !restored.clipped
            @test action(A.Release()) isa A.Released
            close(client);client=nothing
            @test fetch(serving)===nothing
            @test !Base.process_exited(daemon)
        finally
            client===nothing || close(client)
            if server!==nothing
                close(server)
                serving===nothing || fetch(serving)
            end
            for descriptor in (frontend,command)
                descriptor===nothing || FilterGraphIsland.close_execution(descriptor.graph)
            end
        end
    end
    @test Ext.reference_application_hashes(application)==before
    @test !any(id.name in ("CUDA","AMDGPU") for id in keys(Base.loaded_modules))
end
end
