using Test
include("check_graph_replay.jl")
const GR = GraphReplayCheck

function replay_report(profile="classic"; n=3)
    shape = profile == "classic" ? [352,352] : [64,64]
    Dict{String,Any}("version"=>1,"profile"=>profile,"backend"=>"cuda",
        "completed"=>true,"failure"=>nothing,"completed_frames"=>n,
        "requested_frames"=>n,"completed_commands"=>n,"sequence"=>n,
        "sequences"=>collect(1:n),"model_period_ns"=>2_000_000,"exposure_ns"=>1_896_000,
        "model_timestamps_ns"=>[(i-1)*2_000_000 for i in 1:n],
        "source_published_ns"=>[100*i for i in 1:n],
        "command_received_ns"=>[100*i+30 for i in 1:n],
        "source_to_command_latency_ns"=>fill(30,n),
        "frame"=>Dict("element_type"=>"U16_LE","layout"=>"ROW_MAJOR","shape"=>shape,
            "units"=>"raw detector ADC code","encoding"=>"nearest ties to even",
            "schema"=>"org.calculon.ao.raw-detector-pixels/1"),
        "command"=>Dict("recorded_element_type"=>"F32_LE","shape"=>[277],
            "recorded_units"=>"metre OPD","plant_units"=>"metre OPD",
            "layout"=>"frame followed by 277 actuator values","transport_units"=>"micrometre OPD",
            "transport_element_type"=>"F32_LE","transport_to_plant_scale"=>1e-6,
            "schema"=>"org.calculon.ao.demanded-pdm-command/1"))
end

@testset "completed prefix contract and chronology" begin
    for profile in ("classic","copper"), backend in ("cpu","cuda","amdgpu")
        report = replay_report(profile)
        report["backend"] = backend
        @test GR.validate_report(report,profile) == (3,profile == "classic" ? (352,352) : (64,64))
    end
    for (key,value) in (("version",true),("completed",false),("failure","failed"),
        ("completed_frames",true),("completed_frames",0),("completed_frames",257),
        ("completed_commands",2),("sequence",3.0),("sequences",[1,3,2]),
        ("model_timestamps_ns",[0,2_000_000,4_000_001]),("model_period_ns",0),
        ("exposure_ns",2_000_001),("backend","automatic"),
        ("source_to_command_latency_ns",[30,31,30]),
        ("source_published_ns",[100,100,300]),("command_received_ns",[201,230,330]))
        report = replay_report()
        report[key] = value
        @test_throws ArgumentError GR.validate_report(report,"classic")
    end
    report = replay_report()
    report["sequences"] = Any[true,2,3]
    @test_throws ArgumentError GR.validate_report(report,"classic")
    for (descriptor,key,value) in (("frame","layout","COLUMN_MAJOR"),
        ("frame","shape",[64,64]),("frame","encoding","truncate"),
        ("frame","shape",[352.0,352.0]),("command","shape",[277.0]),
        ("command","transport_to_plant_scale",Float64(GR.SCALE)),
        ("command","recorded_units","micrometre OPD"))
        report = replay_report()
        report[descriptor][key] = value
        @test_throws ArgumentError GR.validate_report(report,"classic")
    end
    # JSON integer identities stay exact through the SDK parser.
    report = replay_report()
    report["source_published_ns"] = [UInt64(2)^54+100*i for i in 1:3]
    report["command_received_ns"] = [x+30 for x in report["source_published_ns"]]
    mktempdir() do root
        path = joinpath(root,"report.json")
        GR.Common.write_json(path,report)
        decoded = GR.Common.read_json(path)
        @test decoded["source_published_ns"] == report["source_published_ns"]
        @test first(GR.validate_report(decoded,"classic")) == 3
    end
end

function little_endian(path, values::Vector{T}) where T
    bytes = T === Float32 ? reinterpret(UInt8,htol.(reinterpret(UInt32,values))) : reinterpret(UInt8,htol.(values))
    write(path,bytes)
end

@testset "file admission and row-major parameter arrays" begin
    mktempdir() do root
        package = joinpath(root,"package")
        mkdir(package)
        report = joinpath(root,"report.json")
        write(report,"{}")
        @test GR.fresh_output(joinpath(root,"new"),(package,)) == joinpath(root,"new")
        @test_throws ArgumentError GR.fresh_output(package,(package,))
        @test_throws ArgumentError GR.fresh_output(joinpath(package,"new"),(package,))
        symlink(package,joinpath(root,"alias"))
        @test_throws ArgumentError GR.fresh_output(joinpath(root,"alias/new"),(package,))
        path = joinpath(root,"array.f32")
        little_endian(path,Float32[1,2,3,4,5,6])
        desc = Dict("file"=>basename(path),"sha256"=>GR.digest(path))
        @test GR.payload(desc,report,24) == path
        @test_throws ArgumentError GR.payload(desc,report,20)
        desc["sha256"] = repeat("0",64)
        @test_throws ArgumentError GR.payload(desc,report,24)
        record = Dict("path"=>path,"element_type"=>"F32_LE","shape"=>[2,3])
        @test GR.parameter_array(record) == Float32[1 2 3; 4 5 6]
        little_endian(path,UInt32[1,2,3,4,5,6])
        record["element_type"] = "U32_LE"
        @test GR.parameter_array(record) == UInt32[1 2 3; 4 5 6]
        write(path,UInt8[1,0,1,0,0,1])
        record["element_type"] = "Bool"
        array = GR.parameter_array(record)
        @test array isa Matrix{Bool}
        @test array == Bool[1 0 1; 0 0 1]
        write(path,UInt8[1,0,2,0,0,1])
        @test_throws ArgumentError GR.parameter_array(record)
        record["element_type"] = "F32_LE"
        little_endian(path,Float32[1,2,NaN,4,5,6])
        @test_throws ArgumentError GR.parameter_array(record)
        # JSON descriptors use SDK decoding without invoking a native parser.
        for name in ("provenance.json","graphs/graph.conf.in","hil/plant.toml")
            mkpath(dirname(joinpath(package,name)))
            write(joinpath(package,name),"{}")
        end
        artifacts = Dict(name=>GR.digest(joinpath(package,name)) for name in
            ("provenance.json","graphs/graph.conf.in","hil/plant.toml"))
        deployment = Dict("version"=>1,"artifacts"=>artifacts)
        GR.Common.write_json(joinpath(package,"deployment.conf"),deployment)
        @test GR.manifest(package,"/unused") == deployment
        write(joinpath(package,"hil/plant.toml"),"modified")
        @test_throws ArgumentError GR.manifest(package,"/unused")
    end
end

function diagnostic_fixture(profile)
    projection, command, controller = profile == "classic" ?
        ("vdm-to-pdm","pdm-command","vdm-feedback-to-controller") :
        ("physical","command","feedback-to-controller")
    graph = Dict("filter.graph"=>Dict("nodes"=>[
        Dict("name"=>projection,"label"=>"vdm-to-pdm-f32"),
        Dict("name"=>command,"label"=>"pdm-command-f32"),
        Dict("name"=>controller,"label"=>"vdm-feedback-to-controller-f32")],
        "outputs"=>[command*":demanded",controller*":controller-constraint-feedback"]))
    text = "{ \"unchanged\" = \"é\" \"outputs\" = [ \"$command:demanded\" \"$controller:controller-constraint-feedback\" ] }"
    return graph,text,projection,command
end

@testset "diagnostic declarations and startup parsing" begin
    for profile in ("classic","copper")
        graph,text,projection,command = diagnostic_fixture(profile)
        expected = replace(text," ] }"=>"  \"$projection:requested-pdm-command\" \"$command:constraint-feedback\" ] }")
        @test GR.diagnostic_graph(text,graph,profile) == expected
        json_style = replace(text,"\"outputs\" ="=>"\"outputs\":")
        @test GR.diagnostic_graph(json_style,graph,profile) == replace(expected,"\"outputs\" ="=>"\"outputs\":")
        @test_throws ArgumentError GR.diagnostic_graph(text*text,graph,profile)
        graph["filter.graph"]["outputs"] = [command*":demanded"]
        @test_throws ArgumentError GR.diagnostic_graph(text,graph,profile)
    end
    argv = ["--execution","complete-frame","--feedback","constraint-feedback","controller-constraint-feedback",
        "--parameter","background","Float32","2,3","/tmp/background","--algorithm","FilterGraphAlgorithms.Example"]
    startup, algorithms = GR.startup_parameters(Dict("argv"=>argv))
    @test startup["background"] == ("Float32",(2,3),"/tmp/background")
    @test algorithms == ["FilterGraphAlgorithms.Example"]
    @test_throws ArgumentError GR.startup_parameters(Dict("argv"=>[argv;argv[end-6:end-2]]))
    @test length(GR.expected_parameters("classic")) == 15
    @test length(GR.expected_parameters("copper")) == 11
end

@testset "explicit reconstructor difference only" begin
    mktempdir() do root
        mkdir(joinpath(root,"calibration"))
        source_path = joinpath(root,"calibration/source.f32")
        jfg_path = joinpath(root,"jfg.f32")
        little_endian(source_path,Float32[1,2,3,4])
        little_endian(jfg_path,Float32[1,2,3,5])
        record = Dict("name"=>"reconstructor","path"=>jfg_path,"element_type"=>"F32_LE", "shape"=>[2,2],"sha256"=>GR.digest(jfg_path))
        p = Dict("name"=>"reconstructor","file"=>"source.f32","element_type"=>"F32_LE","shape"=>[2,2])
        provenance = Dict("parameters"=>[p])
        @test_throws ArgumentError GR.matching_parameters([record],root,provenance,Dict())
        differences = GR.matching_parameters([record],root,provenance,Dict();allow_reconstructor_difference=true)
        @test only(differences)["max_abs_difference"] == 1
        @test only(differences)["rms_difference"] == 0.5
        @test only(differences)["relative_frobenius_difference"] ≈ 1/sqrt(30)
        @test only(differences)["nonidentical_components"] == 1
        p["name"] = record["name"] = "background"
        @test_throws ArgumentError GR.matching_parameters([record],root,provenance,Dict();allow_reconstructor_difference=true)
    end
end

@testset "controller coefficients and limiter remain fixed" begin
    nodes = [Dict("label"=>label,"config"=>Dict{String,Any}("count"=>2),"props"=>Dict("gain"=>0.3)) for label in
        ("closed-loop-correction-f32","controller-to-vdm-f32","vdm-to-pdm-f32",
         "pdm-feedback-to-vdm-f32","vdm-feedback-to-controller-f32","pdm-command-f32")]
    current = Dict("filter.graph"=>Dict("nodes"=>nodes))
    source = deepcopy(current)
    for node in source["filter.graph"]["nodes"]
        node["config"]["rate"] = [500,1]
    end
    @test GR.matching_controller(current,source) === nothing
    last(nodes)["config"]["slew_limit"] = nothing
    @test GR.matching_controller(current,source) === nothing
    last(nodes)["config"]["slew_limit"] = 0.01
    @test_throws ArgumentError GR.matching_controller(current,source)
    last(nodes)["config"]["slew_limit"] = nothing
    first(nodes)["props"]["gain"] = 0.31
    @test_throws ArgumentError GR.matching_controller(current,source)
end

@testset "native Classic construction parameters are embedded" begin
    mktempdir() do root
        origins_path = joinpath(root,"origins.u32le")
        active_path = joinpath(root,"active.u8")
        little_endian(origins_path,UInt32[0,22,44,66])
        write(active_path,UInt8[1,0])
        records = [Dict("name"=>"subaperture-origins","path"=>origins_path,
            "element_type"=>"U32_LE","shape"=>[2,2],"sha256"=>GR.digest(origins_path)),
            Dict("name"=>"active","path"=>active_path,"element_type"=>"Bool",
                "shape"=>[2],"sha256"=>GR.digest(active_path))]
        construction = [Dict("name"=>p["name"],"element_type"=>p["element_type"],
            "shape"=>p["shape"],"sha256"=>p["sha256"],"file"=>basename(p["path"])) for p in records]
        provenance = Dict("engine"=>"fgn","parameters"=>Any[],"construction_parameters"=>construction)
        config = Dict("initial_subaperture_origins"=>[[0,22],[44,66]],"active"=>Any[true,false])
        graph = Dict("filter.graph"=>Dict("nodes"=>[
            Dict("label"=>"shack-hartmann-image-f32","config"=>config)]))
        # No calibration directory or files exist in the native source. The
        # construction descriptor binds arrays embedded in its exact graph.
        @test isempty(GR.matching_parameters(records,root,provenance,graph;source_artifacts=Dict()))
        config["initial_subaperture_origins"] = [[0,22],[44,67]]
        @test_throws ArgumentError GR.matching_parameters(records,root,provenance,graph)
        config["initial_subaperture_origins"] = [[0,22],[44,66]]
        config["active"] = Any[true,true]
        @test_throws ArgumentError GR.matching_parameters(records,root,provenance,graph)
        config["active"] = Any[true,false]
        construction[1]["shape"] = [4]
        @test_throws ArgumentError GR.matching_parameters(records,root,provenance,graph)
        construction[1]["shape"] = [2,2]
        construction[1]["sha256"] = repeat("0",64)
        @test_throws ArgumentError GR.matching_parameters(records,root,provenance,graph)
        construction[1]["sha256"] = records[1]["sha256"]
        nodes = graph["filter.graph"]["nodes"]
        push!(nodes,deepcopy(only(nodes)))
        @test_throws ArgumentError GR.matching_parameters(records,root,provenance,graph)
        pop!(nodes)
        # An ordinary live parameter descriptor must still bind a file.
        provenance["parameters"] = construction
        provenance["construction_parameters"] = Any[]
        @test_throws Base.IOError GR.matching_parameters(records,root,provenance,graph)
    end
end

module MockReplay
const FORMATS = NamedTuple{(:demanded,Symbol("requested-pdm-command"),Symbol("constraint-feedback"),Symbol("controller-constraint-feedback"))}(
    ((element_type=Float32,shape=(277,)),(element_type=Float32,shape=(277,)),
     (element_type=Float32,shape=(277,)),(element_type=Float32,shape=(2,))))
mutable struct Graph
    step::Int
    fail_at::Int
    closed::Bool
    output_formats::typeof(FORMATS)
end
Graph(step,fail_at) = Graph(step,fail_at,false,FORMATS)
const graphs = Graph[]
prepare_graph(path; algorithms) = (graph=Graph(0,path == "failure" ? 2 : 0); push!(graphs,graph); graph)
replace_parameters!(graph,bindings...) = graph
Base.close(graph::Graph) = (graph.closed=true; nothing)
algorithms() = ()
reset!(graph) = (graph.step=0; graph)
function process!(outputs,graph,inputs)
    graph.step += 1
    graph.step == graph.fail_at && return (; demanded=false)
    # Distinguishes row-major layout and requires previous-frame feedback.
    value = Float32(inputs.raw[1,2]) + getproperty(inputs,Symbol("constraint-feedback"))[1]
    fill!(outputs.demanded,value)
    fill!(getproperty(outputs,Symbol("requested-pdm-command")),value+2)
    fill!(getproperty(outputs,Symbol("constraint-feedback")),2)
    fill!(getproperty(outputs,Symbol("controller-constraint-feedback")),Float32(graph.step))
    return (; demanded=true, requested=true, physical=true, controller=true)
end
function process_clipped!(outputs,graph,inputs)
    graph.step += 1
    # All demanded values remain on the same rail, even though requested
    # commands and clipping feedback depend on the previous-frame feedback.
    requested = Float32(inputs.raw[1,2]) + getproperty(inputs,Symbol("constraint-feedback"))[1]
    fill!(outputs.demanded,0.01f0)
    fill!(getproperty(outputs,Symbol("requested-pdm-command")),requested)
    fill!(getproperty(outputs,Symbol("constraint-feedback")),requested-0.01f0)
    fill!(getproperty(outputs,Symbol("controller-constraint-feedback")),requested-0.01f0)
    return (; demanded=true, requested=true, physical=true, controller=true)
end
end

@testset "warm/reset chronology and ordinary allocation replay" begin
    values = UInt16[1,2,3,4,5,6, 7,8,9,10,11,12, 13,14,15,16,17,18]
    raw = zeros(UInt16,2,3)
    GR.load_frame!(raw,values,2)
    @test raw == UInt16[7 8 9;10 11 12]
    inputs = NamedTuple{(:raw,GR.FEEDBACK_IN)}((raw,zeros(Float32,2)))
    outputs = NamedTuple{(:demanded,GR.REQUESTED,GR.PHYSICAL,GR.FEEDBACK_OUT)}(
        (zeros(Float32,277),zeros(Float32,277),zeros(Float32,277),zeros(Float32,2)))
    actual = repeat(reshape(Float32[2,9,16].*GR.SCALE,1,3),277,1)
    graph = MockReplay.Graph(0,0)
    result = GR.replay_frames!(MockReplay.process!,MockReplay.reset!,graph,inputs,outputs,values,actual,[0,2,4])
    @test result.predicted == actual
    @test graph.step == 3
    @test isempty(result.allocation_bytes)
    @test all(r -> r.max_abs_difference_m == 0,result.records)
    @test result.records[1].requested_minus_demanded.max_abs_um == 2
    @test result.records[1].physical_constraint_feedback.nonzero_components == 277
    @test result.records[3].controller_constraint_feedback.max_abs_um == 3
    @test GR.aggregate_statistics(result.records,:controller_constraint_feedback).max_abs_um == 3
    @test GR.aggregate_statistics(result.records,:physical_constraint_feedback).nonzero_components == 831
    measured = GR.replay_frames!(MockReplay.process!,MockReplay.reset!,MockReplay.Graph(0,0),
        inputs,outputs,values,actual,[0,2,4];measure=true)
    @test measured.predicted == actual
    @test length(measured.allocation_bytes) == 3
    @test all(>=(0),measured.allocation_bytes)
    @test GR.difference_statistics(actual,actual).nonidentical_components == 0
    @test !GR.complete((; demanded=1))
    @test_throws ArgumentError GR.replay_frames!(MockReplay.process!,MockReplay.reset!,MockReplay.Graph(0,2),
        inputs,outputs,values,actual,[0,2,4])
    metadata = Dict("parameters"=>Any[],"diagnostic_graph"=>"mock","algorithms"=>String[],
        "frame_shape"=>[2,3],"controller_count"=>2,"model_timestamps_ns"=>[0,2,4])
    replay, cleanup = GR.prepared_replay(metadata,MockReplay,MockReplay,values,actual;measure=true)
    @test replay.predicted == actual
    @test cleanup && last(MockReplay.graphs).closed
    metadata["diagnostic_graph"] = "failure"
    @test_throws ArgumentError GR.prepared_replay(metadata,MockReplay,MockReplay,values,actual)
    @test last(MockReplay.graphs).closed
end

@testset "fixed-input controller feedback negative control" begin
    values = UInt16[1,2,3,4,5,6, 7,8,9,10,11,12, 13,14,15,16,17,18]
    inputs = NamedTuple{(:raw,GR.FEEDBACK_IN)}((zeros(UInt16,2,3),zeros(Float32,2)))
    outputs = NamedTuple{(:demanded,GR.REQUESTED,GR.PHYSICAL,GR.FEEDBACK_OUT)}(
        (zeros(Float32,277),zeros(Float32,277),zeros(Float32,277),zeros(Float32,2)))
    actual = repeat(reshape(Float32[2,9,16].*GR.SCALE,1,3),277,1)
    normal = GR.replay_frames!(MockReplay.process!,MockReplay.reset!,MockReplay.Graph(0,0),
        inputs,outputs,values,actual,[0,2,4])
    no_carry = GR.replay_frames!(MockReplay.process!,MockReplay.reset!,MockReplay.Graph(0,0),
        inputs,outputs,values,actual,[0,2,4];carry_feedback=false)
    expected_no_carry = repeat(reshape(Float32[2,8,14].*GR.SCALE,1,3),277,1)
    @test normal.predicted == actual
    @test no_carry.predicted == expected_no_carry
    @test all(iszero,getproperty(inputs,GR.FEEDBACK_IN))
    @test normal.predicted[:,1] == no_carry.predicted[:,1]
    @test normal.predicted[:,2] != no_carry.predicted[:,2]
    control = GR.feedback_control_report(normal,no_carry,actual)
    @test control["informative"]
    @test control["flag_gate_passed"]
    @test control["normal_controller_nonzero_components"] == 6
    @test control["no_carry_vs_normal"].nonidentical_components == 554
    @test control["no_carry_vs_recorded"].nonidentical_components == 554
    @test GR.require_informative_feedback_control(control) === nothing
    metadata = Dict("parameters"=>Any[],"diagnostic_graph"=>"mock","algorithms"=>String[],
        "frame_shape"=>[2,3],"controller_count"=>2,"model_timestamps_ns"=>[0,2,4])
    prepared_control, cleanup = GR.prepared_replay(metadata,MockReplay,MockReplay,values,actual;carry_feedback=false)
    @test prepared_control.predicted == expected_no_carry
    @test cleanup && last(MockReplay.graphs).closed
    @test isempty(prepared_control.allocation_bytes)

    clipped_actual = fill(0.01f0*GR.SCALE,277,3)
    clipped = GR.replay_frames!(MockReplay.process_clipped!,MockReplay.reset!,MockReplay.Graph(0,0),
        inputs,outputs,values,clipped_actual,[0,2,4])
    clipped_no_carry = GR.replay_frames!(MockReplay.process_clipped!,MockReplay.reset!,MockReplay.Graph(0,0),
        inputs,outputs,values,clipped_actual,[0,2,4];carry_feedback=false)
    uninformative = GR.feedback_control_report(clipped,clipped_no_carry,clipped_actual)
    @test clipped.predicted == clipped_no_carry.predicted == clipped_actual
    @test uninformative["normal_controller_nonzero_components"] == 6
    @test uninformative["no_carry_vs_normal"].nonidentical_components == 0
    @test !uninformative["informative"]
    @test !uninformative["flag_gate_passed"]
    @test_throws ArgumentError GR.require_informative_feedback_control(uninformative)

    # A command difference alone cannot demonstrate a clipping-feedback path.
    zero_statistics = GR.vector_statistics(zeros(Float32,2))
    records = [merge(r,(; controller_constraint_feedback=zero_statistics)) for r in normal.records]
    no_feedback = GR.feedback_control_report((; predicted=normal.predicted,records),no_carry,actual)
    @test no_feedback["no_carry_vs_normal"].nonidentical_components > 0
    @test no_feedback["normal_controller_nonzero_components"] == 0
    @test !no_feedback["informative"]
    @test_throws ArgumentError GR.require_informative_feedback_control(no_feedback)
end

@testset "script identity guard" begin
    mktempdir() do directory
        path = joinpath(directory,"script.jl")
        write(path,"before\n")
        identity = GR.digest(path)
        @test GR.verify_script_identity(path,identity) === nothing
        write(path,"after\n")
        @test_throws ArgumentError GR.verify_script_identity(path,identity)
    end
end
