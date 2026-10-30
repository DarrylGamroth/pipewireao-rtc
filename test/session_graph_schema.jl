# Optional no-core check of actual JFG port schemas against session declarations.
using Test, PipeWireAORTC, FilterGraphIsland, FilterGraphPipeWire, JuliaFilterGraph, FilterGraphAlgorithms
const E=PipeWireAORTC.InstrumentExport
const C=PipeWireAORTC.Common
const D=PipeWireAORTC.DeploymentConfiguration
const PREFIX=get(ENV,"PIPEWIREAO_PREFIX","/opt/pipewireao")
const NATIVE_COMMAND="pipewireao/demanded-pdm-command-f32/1"
const OPD_COMMAND="pipewireao/dm-command-opd-um-f32/1"

@testset "session graph schemas agree with the actual prepared boundary" begin
    mktempdir() do directory
        config=Dict{String,Any}("actuator_count"=>2,"command_limits"=>[-0.5,0.5],
            "slew_limit"=>nothing,"initial_current"=>nothing,"quantization_origin"=>nothing,
            "quantization_step"=>nothing,"dither_seed"=>nothing)
        node=Dict("name"=>"command","type"=>"ndarray","label"=>"pdm-command-f32","config"=>config)
        graph=Dict("node.name"=>"scc-controller","filter.graph"=>Dict("nodes"=>[node],
            "inputs"=>["command:requested"],"outputs"=>["command:demanded"]))
        graphpath=joinpath(directory,"graph.conf")
        PipeWireAORTC.ScienceExport.write_spa_config(graphpath,graph)
        port=Dict("name"=>"demanded","direction"=>"output","shape"=>[2],
            "element-type"=>"F32_LE","schema"=>NATIVE_COMMAND)
        session=Dict("graphs"=>[Dict("node.name"=>"scc-controller","ports"=>[port])])
        path=joinpath(directory,"session.conf")
        C.write_json(path,session)
        C.write_json(joinpath(directory,"core.conf"),Dict())
        C.write_json(joinpath(directory,"instrument.json"),Dict("deformable_mirrors"=>Dict(),"wavefront_sensors"=>Dict()))
        spec=Dict("session"=>"session.conf","core"=>"core.conf")
        declarations=[Dict("path"=>"graph.conf")]
        before=read(path)
        # Same shape and element type cannot excuse a native-command/OPD schema mismatch.
        @test_throws ArgumentError E.prepare_session_configuration!(directory,spec,declarations,"instrument.json",PREFIX)
        @test read(path)==before
        contracts=E.graph_port_contracts(graphpath)
        @test contracts["outputs"]["demanded"]["schema"]==OPD_COMMAND
        port["schema"]=Dict("\$ref"=>"/graphs/scc-controller/outputs/demanded/schema")
        C.write_json(path,session)
        E.prepare_session_configuration!(directory,spec,declarations,"instrument.json",PREFIX)
        @test only(only(D.decode(path,PREFIX)["graphs"])["ports"])["schema"]==OPD_COMMAND
        # The existing generic conditioner uses the same numerical kernel with explicit units.
        node["label"]="vector-conditioning-f32"
        delete!(config,"actuator_count")
        merge!(config,Dict("count"=>2,"requested_schema"=>"pipewireao/requested-pdm-command-f32/1",
            "demanded_schema"=>NATIVE_COMMAND,"feedback_schema"=>"pipewireao/pdm-constraint-feedback-f32/1"))
        PipeWireAORTC.ScienceExport.write_spa_config(graphpath,graph)
        port["schema"]=NATIVE_COMMAND
        C.write_json(path,session)
        E.prepare_session_configuration!(directory,spec,declarations,"instrument.json",PREFIX)
        @test E.graph_port_contracts(graphpath)["outputs"]["demanded"]["schema"]==NATIVE_COMMAND
        for (field,value) in (("shape",[3]),("element-type","U16_LE"))
            bad=deepcopy(session);only(only(bad["graphs"])["ports"])[field]=value
            C.write_json(path,bad);before=read(path)
            @test_throws ArgumentError E.prepare_session_configuration!(directory,spec,declarations,"instrument.json",PREFIX)
            @test read(path)==before
        end
    end
end

@testset "native conditioner retains the physical limiter numerics" begin
    common=(;command_limits=(-0.5f0,0.5f0),slew_limit=nothing,initial_current=nothing,
        quantization_origin=nothing,quantization_step=nothing,dither_seed=nothing)
    legacy=prepare_algorithm(PdmCommandF32,PdmCommandF32Configuration(;actuator_count=2,common...))
    native=prepare_algorithm(VectorConditioningF32,VectorConditioningF32Configuration(;
        count=2,requested_schema=REQUESTED_PDM_COMMAND_V1,demanded_schema=NATIVE_COMMAND,
        feedback_schema=PDM_CONSTRAINT_FEEDBACK_V1,common...))
    @test typeof(native.plan)===typeof(legacy.plan)
    @test typeof(native.workspace)===typeof(legacy.workspace)
    demanded=zeros(Float32,2);feedback=similar(demanded)
    expected=similar(demanded);expected_feedback=similar(demanded)
    for requested in (Float32[0.1,0.2],Float32[0.8,-0.9],Float32[0,0])
        @test FilterGraphAlgorithms.process!(demanded,feedback,native,requested)===nothing
        @test FilterGraphAlgorithms.process!(expected,expected_feedback,legacy,requested)===nothing
        @test demanded==expected==clamp.(requested,-0.5f0,0.5f0)
        @test feedback==expected_feedback==requested-demanded
        FilterGraphAlgorithms.commit!(native.workspace);FilterGraphAlgorithms.commit!(legacy.workspace)
    end
end
