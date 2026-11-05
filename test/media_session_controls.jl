using Test
using PipeWireAORTC
using PipeWireAO

module MediaSessionControlsTests
using Test, PipeWireAO
import PipeWireAORTC: Common, ControlCodec, ControlClient, OwnerBootstrapCodec,
    AcquisitionLifecycleCodec, RunnerCodec, SourceControl, ParameterSource
include(joinpath(@__DIR__,"..","src","media_session","controls.jl"))
include(joinpath(@__DIR__,"..","src","media_session","correction.jl"))
const SPA = PipeWireAO.SPA
const CC = ControlCodec
const BC = OwnerBootstrapCodec
const AC = AcquisitionLifecycleCodec
const IDENTITY = CC.ControllerIdentity(UInt32(7),UInt64(11),Int64(13))
struct Group
    nodes::Vector{String}
    members::Vector{String}
    running::Bool
end
mutable struct Runtime{C,P}
    configuration::C
    parameters::P
    controller::CC.ControllerIdentity
    token::Int64
    graphs::Dict{String,UInt64}
    groups::Dict{String,Group}
    machine::NamedTuple{(:lifecycle,),Tuple{UInt32}}
    properties::Dict{String,String}
    records::Vector{Vector{Pod}}
    index::Int
    submitted::Vector{Pod}
    time::Float64
    identity_valid::Bool
    send_failure::Bool
end
function Runtime(records;configuration=Dict{String,String}(),parameters=nothing,lifecycle=UInt32(4),properties=Dict(
        "pipewireao.rtc-control.protocol"=>ControlClient.PROTOCOL,
        "pipewireao.rtc-control.profile"=>ControlClient.profile_name(BC.PROFILE),
        "pipewireao.rtc-control.instance"=>"17","pipewireao.rtc-control.owner-pid"=>"19"))
    Runtime(configuration,parameters,IDENTITY,Int64(0),Dict("graph"=>UInt64(1)),
        Dict("loop"=>Group(["graph"],String[],true)),(lifecycle=lifecycle,),properties,
        records,0,Pod[],Common.monotonic_seconds(),true,false)
end
now(runtime::Runtime) = runtime.time
capture!(runtime::Runtime,handle) = nothing
assert_identity!(runtime::Runtime,handle) = runtime.identity_valid ? nothing : throw(ArgumentError("incarnation changed"))
property(runtime::Runtime,handle,key) = get(runtime.properties,key,nothing)
function enumerate!(runtime::Runtime,job,handle,param)
    runtime.index += 1
    return runtime.records[min(runtime.index,length(runtime.records))]
end
function setparam!(runtime::Runtime,job,handle,param,pod)
    push!(runtime.submitted,pod)
    runtime.send_failure && throw(ErrorException("native send failed"))
end
synchronize!(runtime::Runtime,job) = nothing
function await_condition!(f,runtime::Runtime,job)
    for _ in 1:20
        runtime.time < job.ticket.deadline || throw(ControlClient.UnknownOutcome("absolute deadline expired"))
        value = f()
        value === nothing || value === false || return value
        runtime.time += 0.001
    end
    throw(ErrorException("test operation failed to finish"))
end
job(runtime) = (ticket=(deadline=runtime.time+5.0,),)
function capability(profile=BC.PROFILE;state=UInt32(2),token=Int64(0),registered=true)
    names = ControlClient.capability_names(profile)
    rows = registered ? Pod[Pod(policy_struct(Pod(SPA.Id(IDENTITY.global_id)),Pod(reinterpret(Int64,IDENTITY.serial)),Pod(IDENTITY.instance)))] : Pod[]
    values = Pod[Pod(Int32(1)),Pod(Int64(17)),Pod(SPA.Id(UInt32(19))),Pod(SPA.Id(state)),Pod(token),Pod(SPA.Struct(rows))]
    Pod(PipeWireAO.props_param(SPA.Props([names[i]=>values[i] for i in eachindex(names)])))
end
bootstrap_reply(token=Int64(1)) = ControlClient.encode_completion(BC.PROFILE,CC.ReplyHeader(IDENTITY,Int64(17),token,UInt32(2),Int32(0)),BC.Connected,"")
function legacy(;kind=SourceControl.INITIAL,token=Int64(0),generation=Int64(1),sequence=Int64(0),running=false,completed=false,report_generation=generation,report_sequence=sequence)
    values = SourceControl.snapshot_values(Int64(17),kind,token,Int32(0),generation,sequence,running,completed,report_generation,report_sequence)
    Pod(PipeWireAO.props_param(SPA.Props([SourceControl.SNAPSHOT_NAMES[i]=>Pod(values[i]) for i in eachindex(values)])))
end
function run_status(token,state;result=Int32(0))
    prefix = "pipewireao.run-control."
    Pod(PipeWireAO.props_param(SPA.Props([prefix*"version"=>Pod(Int32(1)),prefix*"completed-token"=>Pod(Int64(token)),prefix*"result"=>Pod(result),prefix*"actual-state"=>Pod(state)])))
end
@testset "session native owner correlation and one-shot effects" begin
    runtime = Runtime([[capability(;token=Int64(50))],[capability(;token=Int64(51)),bootstrap_reply(Int64(51))]])
    owner = capture_owner(runtime,UInt64(1),BC.PROFILE,17,19)
    reply = request_owner!(runtime,job(runtime),owner,BC.Command(:connect))
    @test reply.lifecycle == BC.Connected
    @test length(runtime.submitted) == 1
    header,_ = CC.decode_request(only(runtime.submitted))
    @test header.token == 51
    @test 0 < header.budget_ns <= 5_000_000_000
    @test owner.observation.pending === nothing
    @test runtime.token == 51
    runtime = Runtime([[capability()]])
    runtime.send_failure = true
    owner = capture_owner(runtime,UInt64(1),BC.PROFILE,17,19)
    @test_throws ErrorException request_owner!(runtime,job(runtime),owner,BC.Command(:connect))
    @test length(runtime.submitted) == 1
    @test owner.observation.pending === nothing
    runtime = Runtime([[capability(;registered=false)]])
    owner = capture_owner(runtime,UInt64(1),BC.PROFILE,17,19)
    @test_throws ControlClient.UnknownOutcome request_owner!(runtime,(ticket=(deadline=runtime.time+0.002,),),owner,BC.Command(:connect))
    @test isempty(runtime.submitted)
    runtime.identity_valid = false
    @test_throws ArgumentError check_owner!(runtime,owner)
    runtime = Runtime([[capability(;state=UInt32(3))]])
    owner = capture_owner(runtime,UInt64(1),BC.PROFILE,17,19)
    @test_throws ArgumentError wait_prepared!(runtime,job(runtime),owner)
    runtime = Runtime([[capability(),capability()]])
    owner = capture_owner(runtime,UInt64(1),BC.PROFILE,17,19)
    @test_throws ArgumentError observe_owner!(runtime,job(runtime),owner)
    runtime.token = typemax(Int64)
    @test_throws ArgumentError next_control_token!(runtime)
end
@testset "finite source ACK and report publication" begin
    previous = legacy_snapshot(named_values(legacy()),Int64(17))
    records = node_records([legacy(;kind=SourceControl.RUN,token=Int64(1),running=true),run_status(1,"running")],Int64(17))
    @test matching_source_record(records,:run,Int64(1),"running",previous).running
    mismatch = node_records([legacy(;kind=SourceControl.RUN,token=Int64(1),running=true),run_status(1,"stopped")],Int64(17))
    @test_throws ArgumentError matching_source_record(mismatch,:run,Int64(1),"running",previous)
    incomplete = node_records([legacy(;kind=SourceControl.QUERY,token=Int64(1),sequence=Int64(4),completed=true,report_sequence=Int64(3))],Int64(17))
    @test_throws ArgumentError matching_source_record(incomplete,:query,Int64(1),"",previous)
    @test_throws ArgumentError legacy_snapshot(named_values(legacy(;running=true,completed=true)),Int64(17))
    @test_throws ArgumentError legacy_snapshot(named_values(legacy()),Int64(18))
    @test native_state(true) == "running"
    @test native_state(1) == "stopped"
    runtime = Runtime([[legacy()],[legacy(;kind=SourceControl.QUERY,token=Int64(1))]];properties=Dict("pipewireao.source-control.instance"=>"17","pipewireao.source-control.owner-pid"=>"19"))
    source = LegacySource(UInt64(1),UInt32(19),Int64(17),nothing)
    @test source_operation!(runtime,job(runtime),source,:query).generation == 1
    @test length(runtime.submitted) == 1
end
@testset "correction and protective recovery admission" begin
    config = Dict("node.pids"=>Dict("graph"=>19),"owners"=>[Dict("pid"=>19,"bootstrap-node"=>"bootstrap","bootstrap-instance"=>"17")])
    runtime = Runtime(Vector{Pod}[];configuration=config)
    prefix = CORRECTION_PREFIX*"controller:closed"
    values = Dict("pipewireao.correction-control.version"=>Pod(Int32(1)),"pipewireao.correction-control.owner-instance"=>Pod(Int64(17)),
        "pipewireao.run-control.actual-state"=>Pod("running"),prefix*".state"=>Pod("Open"),prefix*".fault"=>Pod(""),prefix*".requested"=>Pod(false),
        "controller:closed"=>Pod(false),"controller:requested-generation"=>Pod(Int64(2)),"controller:active-generation"=>Pod(Int64(2)))
    updates = Dict("controller:closed"=>Pod(true)); declarations = Dict{String,PropertyDeclaration}()
    @test check_correction!(runtime,"graph",values,updates,declarations) === nothing
    values[prefix*".fault"] = Pod("latched")
    @test_throws ArgumentError check_correction!(runtime,"graph",values,updates,declarations)
    values[prefix*".fault"] = Pod("")
    runtime.machine = (lifecycle=UInt32(3),)
    @test_throws ArgumentError check_correction!(runtime,"graph",values,updates,declarations)
    runtime.machine = (lifecycle=UInt32(4),)
    values[RECOVERY_PREFIX*"version"] = Pod(Int32(1)); values[RECOVERY_PREFIX*"closure-inhibited"] = Pod(true)
    @test_throws ArgumentError check_parameter_correction(values)
    @test_throws ArgumentError check_correction!(runtime,"graph",values,updates,declarations)
    values[RECOVERY_PREFIX*"observation-monotonic-nanoseconds"] = Pod(Int64(1_000_000_000))
    values[RECOVERY_PREFIX*"reference-timeout-ms"] = Pod(Int32(100))
    @test recovery_reference_fresh(values,1.099999)
    @test !recovery_reference_fresh(values,1.1)
    @test !recovery_reference_fresh(values,0.99)
    @test correction_status_field(prefix*".state")
    @test !correction_status_field(prefix*".unsupported")
end
@testset "typed scalar admission and bitwise adoption" begin
    info = Pod(PipeWireAO.prop_info_param(SPA.PropInfo("controller:gain",Pod(SPA.Choice(SPA.CHOICE_RANGE,Float32[1,0,2])))))
    @test property_declarations([info])["controller:gain"].kind == SPA.POD_FLOAT
    readonly = Pod(PipeWireAO.prop_info_param(SPA.PropInfo("controller:gain",Pod(Float32(1));flags=1)))
    @test !property_declarations([readonly])["controller:gain"].writable
    @test_throws ArgumentError property_declarations([info,info])
    before = Dict("controller"=>Int64(2))
    after = Dict("controller:requested-generation"=>Pod(Int64(3)),"controller:active-generation"=>Pod(Int64(3)),"controller:gain"=>Pod(-0.0f0))
    @test !properties_adopted(after,before,Dict("controller:gain"=>Pod(0.0f0)))
    @test properties_adopted(after,before,Dict("controller:gain"=>Pod(-0.0f0)))
    @test_throws ArgumentError RunnerCodec._scalar_pod(RunnerCodec.RunnerScalar(:float,reinterpret(UInt32,NaN32));finite=true)
end
@testset "property transactions submit once and prove active generations" begin
    info = Pod(PipeWireAO.prop_info_param(SPA.PropInfo("controller:gain",Pod(Float32(1)))))
    props(generation,gain) = Pod(PipeWireAO.props_param(SPA.Props([
        "controller:requested-generation"=>Pod(Int64(generation)),
        "controller:active-generation"=>Pod(Int64(generation)),"controller:gain"=>Pod(Float32(gain))])))
    command = RunnerCodec.RunnerCommand(:properties_set,"graph",
        Dict("controller:gain"=>RunnerCodec.RunnerScalar(:float,reinterpret(UInt32,2.0f0))))
    runtime = Runtime([[info],[props(2,1)],[props(2,1)],[props(3,2)]])
    result = update_properties!(runtime,job(runtime),command)
    @test policy_text(result.values[1]) == "graph"
    @test policy_bool(result.values[3])
    @test length(runtime.submitted) == 1
    @test PipeWireAO.pod_value(Float32,named_values(only(runtime.submitted))["controller:gain"]) == 2.0f0
    runtime = Runtime([[info],[props(2,1)]];lifecycle=UInt32(3))
    result = update_properties!(runtime,job(runtime),command)
    @test !policy_bool(result.values[3])
    @test length(runtime.submitted) == 1
    readonly = Pod(PipeWireAO.prop_info_param(SPA.PropInfo("controller:gain",Pod(Float32(1));flags=1)))
    runtime = Runtime([[readonly],[props(2,1)]])
    @test_throws ArgumentError update_properties!(runtime,job(runtime),command)
    @test isempty(runtime.submitted)
    runtime = Runtime([[info],[props(2,1)]])
    @test_throws ControlClient.UnknownOutcome update_properties!(runtime,(ticket=(deadline=runtime.time+0.002,),),command)
    @test length(runtime.submitted) == 1
end
@testset "HEART external wrapper remains a separate public profile" begin
    function heart_record(;alive=true,state=UInt32(2),generation=Int64(1),pid=Pod(SPA.Id(UInt32(23))),code=Pod(nothing),path="/tmp/report",digest="a"^64)
        snapshot = policy_struct(Pod(generation),pid,code,Pod(alive),Pod(SPA.Id(UInt32(1))),Pod(true),Pod(true),Pod(path),Pod(digest))
        ControlCodec.encode_completion(CC.ReplyHeader(IDENTITY,Int64(17),Int64(1),UInt32(3),Int32(0)),
            policy_struct(Pod(SPA.Id(state)),Pod(snapshot),Pod(""));endpoint=:lifecycle)
    end
    reply = ControlClient.decode_completion(HeartProfile(),heart_record())
    @test validate_connected(reply) === nothing
    @test_throws ArgumentError validate_connected(ControlClient.decode_completion(HeartProfile(),heart_record(;alive=false)))
    @test_throws ArgumentError validate_connected(ControlClient.decode_completion(HeartProfile(),heart_record(;code=Pod(Int32(0)))))
    @test_throws ArgumentError ControlClient.decode_completion(HeartProfile(),heart_record(;digest="malformed"))
    stopped = ControlClient.decode_completion(HeartProfile(),heart_record(;alive=false,state=UInt32(4),generation=Int64(0),pid=Pod(nothing),path="",digest=""))
    @test validate_stopped(stopped) === nothing
    @test_throws ArgumentError validate_stopped(reply)
end
@testset "typed cold acquisition state acknowledgements" begin
    profile = AC.CALIBRATION_PROFILE
    function cold_reply(;running=false,completed=false,sequence=UInt64(0),operation=UInt32(2),state=AC.Connected)
        cursor = AC.AcquisitionCursor(UInt64(1),UInt64(1),sequence,UInt64(0))
        snapshot = AC.Snapshot(AC.Classic,cursor,cursor,running,completed,"initial",false,false,nothing)
        ControlClient.encode_completion(profile,CC.ReplyHeader(IDENTITY,Int64(17),Int64(1),operation,Int32(0)),state,snapshot,"")
    end
    metadata = Dict("pipewireao.rtc-control.protocol"=>ControlClient.PROTOCOL,
        "pipewireao.rtc-control.profile"=>ControlClient.profile_name(profile),
        "pipewireao.rtc-control.instance"=>"17","pipewireao.rtc-control.owner-pid"=>"19")
    runtime = Runtime([[capability(profile;state=UInt32(3))],[capability(profile;state=UInt32(3)),cold_reply()]];properties=metadata)
    owner = capture_owner(runtime,UInt64(1),profile,17,19)
    acquisition = ColdSource(owner,AC.Classic,nothing)
    snapshot = source_operation!(runtime,job(runtime),acquisition,:run;running=false)
    @test !snapshot.running && snapshot.generation == 1
    @test acquisition.previous !== nothing
    @test length(runtime.submitted) == 1
    mismatched = ControlClient.decode_completion(profile,cold_reply())
    acquisition.instrument = AC.Copper
    @test_throws ArgumentError source_snapshot!(acquisition,mismatched)
    snapshot = SourceSnapshot(false,false,UInt64(2),UInt64(1),UInt64(2),UInt64(1),LegacyDetails(Int32(2),Int64(1),Int32(0)))
    @test_throws ArgumentError validate_source_operation(snapshot,:reset,false)
end
@testset "typed sparse parameter publisher admission" begin
    profile = ParameterSource.PROFILE
    owner = Owner(profile,ControlClient.Observation(profile,Int64(17),UInt32(19)),UInt64(1),UInt32(19),Int64(17),false)
    config = Dict("session"=>Dict("sources"=>[Dict("factory"=>"pipewireao.runtime-parameter","node.name"=>"publisher")],
        "links"=>[Dict("output"=>"publisher:output_1","input"=>"graph:matrix")]))
    metadata = Dict("pipewireao.rtc-control.protocol"=>ControlClient.PROTOCOL,
        "pipewireao.rtc-control.profile"=>ControlClient.profile_name(profile),
        "pipewireao.rtc-control.instance"=>"17","pipewireao.rtc-control.owner-pid"=>"19")
    completion = ControlClient.encode_completion(profile,CC.ReplyHeader(IDENTITY,Int64(17),Int64(1),UInt32(14),Int32(0)),
        "graph","matrix",Int64(3),true,false,"")
    runtime = Runtime([Pod[],[capability(profile)],[capability(profile),completion]];configuration=config,parameters=owner,properties=metadata)
    command = RunnerCodec.RunnerCommand(:parameter,"graph","matrix","F32_LE",UInt32[2,2],"schema","/tmp/parameter")
    result = submit_parameter!(runtime,job(runtime),command)
    @test policy_text(result.values[1]) == "graph"
    @test !policy_bool(result.values[4])
    @test PipeWireAO.pod_type(result.values[3]) == SPA.POD_NONE
    @test length(runtime.submitted) == 1
    runtime = Runtime([Pod[]];configuration=config)
    @test_throws ArgumentError submit_parameter!(runtime,job(runtime),command)
    @test isempty(runtime.submitted)
end
end
