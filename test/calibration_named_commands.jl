# Cold CPU contracts and locked named-slot state; no daemon, devices or GPU.
module CalibrationNamedCommandTests
using Test, PipeWireAO, PipeWireAORTC, FilterGraphIsland, FilterGraphPipeWire, JuliaFilterGraph
using AdaptiveOpticsSim, AdaptiveOpticsSimPipeWireHIL, AdaptiveOpticsCalibration
const Ext = Base.get_extension(PipeWireAORTC, :PipeWireAORTCCalibrationExt)

function prepare_command(count, schema)
    declaration = Dict("filter.graph"=>Dict(
        "nodes"=>[Dict("name"=>"command", "type"=>"ndarray", "label"=>"vector-conditioning-f32",
            "config"=>Dict("count"=>count, "requested_schema"=>"test.requested/1",
                "demanded_schema"=>schema, "feedback_schema"=>"test.feedback/1",
                "command_limits"=>[-1,1], "slew_limit"=>nothing, "initial_current"=>nothing,
                "quantization_origin"=>nothing, "quantization_step"=>nothing, "dither_seed"=>nothing))],
        "inputs"=>["command:requested"], "outputs"=>["command:demanded","command:constraint-feedback"]))
    graph = mktempdir() do directory
        path=joinpath(directory,"graph.conf")
        PipeWireAORTC.ScienceExport.write_spa_config(path,declaration)
        FilterGraphIsland.prepare_service_graph(FilterGraphIsland.parse_arguments([
            "--graph",path,"--check","--execution","complete-frame"]))
    end
    return (;graph, source_graph_sha256="test")
end

@testset "sensor measurements select existing typed outputs without an invented validity mask" begin
    declaration=Dict("filter.graph"=>Dict(
        "nodes"=>[
            Dict("name"=>"pixels","type"=>"ndarray","label"=>"pixel-calibration-u16-f32",
                "config"=>Dict("image_size"=>[8,12],"initial_flat"=>nothing,"initial_background"=>nothing)),
            Dict("name"=>"pyramid","type"=>"ndarray","label"=>"pyramid-pupil-image-f32",
                "config"=>Dict("image_size"=>[8,12],"pupil_size"=>[2,3],
                    "pupil_origins"=>[[1,1],[5,1],[1,8],[5,8]],"pupil_mask"=>fill(true,6)))],
        "inputs"=>["pixels:raw"],
        "outputs"=>["pyramid:reconstruction-pixels","pyramid:mean-pupil-intensity"],
        "links"=>[Dict("output"=>"pixels:calibrated","input"=>"pyramid:image")]))
    graph=mktempdir() do directory
        path=joinpath(directory,"graph.conf")
        PipeWireAORTC.ScienceExport.write_spa_config(path,declaration)
        FilterGraphIsland.prepare_service_graph(FilterGraphIsland.parse_arguments([
            "--graph",path,"--check","--execution","complete-frame"]))
    end
    try
        frontend=(;graph,parameters=Dict{Symbol,Array}())
        outputs=JuliaFilterGraph.output_formats(graph)
        @test outputs[Symbol("reconstruction-pixels")].shape==(4,6)
        @test Ext.calibration_measurements(frontend,outputs,Symbol("reconstruction-pixels"),nothing)===nothing
        @test Ext.calibration_measurements(frontend,outputs,Symbol("mean-pupil-intensity"),nothing)===nothing
        @test_throws ArgumentError Ext.calibration_measurements(frontend,outputs,:slopes,nothing)
        @test_throws ArgumentError Ext.calibration_measurements(frontend,outputs,Symbol("reconstruction-pixels"),trues(6))
    finally
        FilterGraphIsland.close_execution(graph)
    end
end

@testset "named commands bind exact names, dimensions, schemas and selected probe" begin
    woofer=prepare_command(2,"test.woofer/1")
    tiptilt=prepare_command(3,"test.tiptilt/1")
    try
        commands=(;woofer,tiptilt)
        options=(command_input=(:tiptilt,:woofer), command_count=(tiptilt=3,woofer=2),
            command_schema=(woofer="test.woofer/1",tiptilt="test.tiptilt/1"))
        reference=(tiptilt=Float32[.1,.2,.3],woofer=Float32[0,0])
        held=Ext.calibration_commands(commands,reference,:woofer,options)
        @test held == (woofer=Float32[0,0],tiptilt=Float32[.1,.2,.3])
        reference.tiptilt[1]=.8
        @test held.tiptilt[1]==.1f0
        @test Ext.calibration_named_commands(commands)
        @test !Ext.calibration_named_commands(woofer)
        @test Ext.calibration_descriptors(woofer,commands)==(woofer,woofer,tiptilt)
        for (supplied,figures,selected) in ((commands,reference,nothing), (commands,reference,:missing),
                ((;woofer),reference,:woofer), (commands,(woofer=reference.woofer,),:woofer),
                (commands,(woofer=Float32[0],tiptilt=reference.tiptilt),:woofer),
                (commands,(woofer=[0.,0.],tiptilt=reference.tiptilt),:woofer),
                (commands,(woofer=Float32[Inf,0],tiptilt=reference.tiptilt),:woofer))
            @test_throws ArgumentError Ext.calibration_commands(supplied,figures,selected,options)
        end
        @test_throws ArgumentError Ext.calibration_commands(commands,reference,:woofer,
            merge(options,(command_schema=(woofer="wrong/1",tiptilt="test.tiptilt/1"),)))
        scalar=(command_input=:woofer,command_count=2,command_schema="test.woofer/1")
        @test Ext.calibration_commands(woofer,Float32[0,0],nothing,scalar)===nothing
        @test_throws ArgumentError Ext.calibration_commands(woofer,Float32[0,0],:woofer,scalar)
        @test_throws ArgumentError Ext.calibration_commands(woofer,Float32[0,0],nothing,options)
        figures=(woofer=Float32[.5,.2],tiptilt=Float32[.1,.2,.3])
        @test !Ext.calibration_feedback(figures,figures,map(x->zero(x),figures))
        actual=(woofer=figures.woofer,tiptilt=Float32[0,.2,.3])
        feedback=(woofer=Float32[0,0],tiptilt=Float32[.1,0,0])
        @test Ext.calibration_feedback(figures,actual,feedback) # clipping in a held Port counts
        @test_throws ErrorException Ext.calibration_feedback(figures,actual,map(x->zero(x),figures))
        @test_throws ErrorException Ext.calibration_feedback(figures,actual,(woofer=feedback.woofer,))
        @test Ext.calibration_feedback(Float32[2],Float32[1],Float32[1])
    finally
        FilterGraphIsland.close_execution(woofer.graph)
        FilterGraphIsland.close_execution(tiptilt.graph)
    end
end

function empty_probe(loop,count,failure)
    Ext.CalibrationProbe(loop,nothing,nothing,zeros(Float32,count),zeros(Float32,count),
        UInt64(0),UInt64(0),UInt64(0),false,failure,false,StreamBuffer(),StreamBuffer(),()->nothing)
end

@testset "named slots prevalidate every figure and state before changing any token" begin
    loop=ThreadLoop("test.named-calibration-slots")
    failure=Ref{Any}(nothing)
    first=empty_probe(loop,2,failure)
    held=empty_probe(loop,3,failure)
    probes=Ext.CalibrationProbes(loop,(woofer=first,tiptilt=held))
    figures=(woofer=Float32[.4,.2],tiptilt=Float32[.1,.2,.3])
    try
        @test_throws ArgumentError Ext.stage!(probes,UInt64(1),(woofer=figures.woofer,))
        @test_throws ArgumentError Ext.stage!(probes,UInt64(1),merge(figures,(tiptilt=Float32[0,Inf,0],)))
        @test_throws DimensionMismatch Ext.stage!(probes,UInt64(1),merge(figures,(tiptilt=Float32[0],)))
        held.sequence=1
        @test_throws InvalidStateException Ext.stage!(probes,UInt64(2),figures)
        @test first.sequence==0 && first.figure==zeros(Float32,2)
        held.sequence=0
        @test first.sequence==held.sequence==0 && all(iszero,held.figure)
        # Snapshot completion requires all Ports at exactly the shared token.
        first.sequence=held.sequence=UInt64(1)
        first.published=held.published=first.received=UInt64(1)
        @test Ext.calibration_probe_snapshot(probes).received==0
        held.received=UInt64(1)
        snapshot=Ext.calibration_probe_snapshot(probes)
        @test snapshot.received==snapshot.published==snapshot.sequence==1
        snapshot.values.woofer[1]=99
        @test first.values[1]==0
        Ext.calibration_probe_failure!(held,ErrorException("held Port disconnected"))
        @test Ext.calibration_probe_snapshot(probes).error===failure[]
        @test_throws ErrorException Ext.stage!(probes,UInt64(2),figures)
        @test first.sequence==held.sequence==1
        close(probes)
        @test first.closed && held.closed && Ext.calibration_probe_snapshot(probes).closed
        @test_throws InvalidStateException Ext.stage!(probes,UInt64(2),figures)
    finally
        close(probes)
        close(loop)
    end
end
@test !any(id.name in ("CUDA","AMDGPU") for id in keys(Base.loaded_modules))
end
