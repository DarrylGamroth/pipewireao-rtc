using Test, PipeWireAORTC
const S = PipeWireAORTC.SimulatorConfiguration
const C = PipeWireAORTC.Common
const R = PipeWireAORTC.SessionRuntime
operation(::PipeWireAORTC.NativeRunnerCodec.RunnerCommand{O}) where O = O

module DeclaredPlant
describe_hil_settings() = (; defaults=(; geometry=16, atmosphere=(; r0=0.15,
    winds=(2.0,5.0), ids=("ground","high"))), schema=(; type="object", properties=(;
    geometry=(;type="integer",readOnly=true), atmosphere=(;type="object",properties=(;
        r0=(;type="number",exclusiveMinimum=0),
        winds=(;type="array",minItems=1,items=(;type="number",minimum=0)),
        ids=(;type="array",uniqueItems=true,items=(;type="string")))))))
end

module FileConfiguredPlant
describe_hil_settings() = (;defaults=(;gain=0.5),schema=(;type="object",properties=(;
    gain=(;type="number"),mirror_description=(;type="string",readOnly=true))))
end
module SettingsAwarePlant
describe_hil_settings() = (;defaults=(;profile="default"),schema=(;type="object",properties=(;
    profile=(;type="string"))))
describe_hil_settings(settings::NamedTuple) = (;defaults=(;profile=settings.profile,
    command_indices=settings.command_indices, atmosphere=settings.atmosphere),schema=(;type="object",properties=(;
    profile=(;type="string",readOnly=true),command_indices=(;type="array",maxItems=277,readOnly=true,
        items=(;type="integer",minimum=1)),atmosphere=(;type="array",items=(;type="number")))))
end
@testset "required scientific file input has no invented default" begin
    configured=Dict("mirror_description"=>"mirror-description.json")
    declaration=S.declared_settings(FileConfiguredPlant,configured)
    @test declaration["settings"]==merge(configured,Dict("gain"=>0.5))
    @test_throws ArgumentError S.declared_settings(FileConfiguredPlant,Dict())
    changed=merge(declaration["settings"],Dict("mirror_description"=>"other.json"))
    @test_throws ArgumentError S.validate_settings(declaration["schema"],changed,declaration["settings"])
end

@testset "profile-specific simulator declarations and bounded readonly arrays" begin
    command_indices = collect(1:277)
    overrides = Dict("profile"=>"measured", "command_indices"=>command_indices,
        "atmosphere"=>collect(1.0:256.0))
    description = S.declared_settings(SettingsAwarePlant, overrides)
    @test description["settings"]["profile"] == "measured"
    @test description["settings"]["command_indices"] == command_indices
    @test length(description["settings"]["command_indices"]) == 277
    @test_throws ArgumentError S.validate_settings(description["schema"],
        merge(deepcopy(description["settings"]), Dict("atmosphere"=>collect(1.0:257.0))),
        description["settings"])
    oversized = merge(deepcopy(description["settings"]), Dict("command_indices"=>collect(1:278)))
    @test_throws ArgumentError S.validate_settings(description["schema"],oversized,oversized)
    unbounded_schema = Dict("type"=>"array", "readOnly"=>true,
        "maxItems"=>4097, "items"=>Dict("type"=>"integer"))
    @test_throws ArgumentError S.validate_settings(unbounded_schema,[1],[1])
end

@testset "declared simulator settings and immutable structural fields" begin
    description = S.declared_settings(DeclaredPlant, Dict("atmosphere"=>Dict("r0"=>0.2)))
    current = description["settings"]
    @test current["atmosphere"]["r0"] == 0.2
    @test current["atmosphere"]["winds"] == [2.0,5.0]
    @test S.validate_settings(description["schema"],current,current) === nothing
    proposed = deepcopy(current)
    proposed["atmosphere"]["winds"] = [1.0,4.0]
    @test S.validate_settings(description["schema"],proposed,current) === nothing
    for change in (
        v -> (v["geometry"]=32),
        v -> (v["atmosphere"]["r0"]=0.0),
        v -> (v["atmosphere"]["r0"]=NaN),
        v -> (v["atmosphere"]["winds"]=[-1.0,2.0]),
        v -> (v["atmosphere"]["winds"]=Float64[]),
        v -> (v["atmosphere"]["ids"]=["same","same"]),
        v -> (v["extra"]=1),
        v -> delete!(v["atmosphere"],"r0"))
        invalid=deepcopy(current); change(invalid)
        @test_throws ArgumentError S.validate_settings(description["schema"],invalid,current)
    end
    @test_throws ArgumentError S.declared_settings(DeclaredPlant,Dict("unknown"=>1))
    @test_throws ArgumentError S.declared_settings(Main,Dict())
    @test DeclaredPlant.describe_hil_settings().defaults.atmosphere.r0 == 0.15
end

function make_job(root; invocation="b"^32, managed_root=joinpath(root,"managed"))
    id = replace(string(Base.UUID(rand(UInt128))),"-"=>"")
    directory=joinpath(root,id); mkdir(directory)
    identity=Dict("session_id"=>"00000000-0000-0000-0000-000000000001",
        "invocation"=>invocation,"runtime_root"=>managed_root,"configuration_sha256"=>"a"^64)
    mkpath(joinpath(managed_root,invocation))
    request=Dict("id"=>id,"identity"=>identity,"application"=>"/saved/application",
        "relative_config"=>"simulation.conf","settings"=>Dict(),"resume_running"=>true)
    C.write_json(joinpath(directory,"request.json"),request)
    S.save_state(directory,"queued")
    return id,directory,request
end

function fake_rebuild(request,directory,events; fail=nothing, changed=false)
    handle=R.Handle("pipewireao-session@test.service","/runtime","b"^32,1,UInt64(1),"/group",false,false,false,"/original/stage")
    identity=deepcopy(request["identity"])
    changed && (identity["configuration_sha256"]="c"^64)
    prepare=(r,d)->begin
        push!(events,:prepare)
        fail===:prepare && error("invalid scientific candidate")
        mkpath(joinpath(d,"candidate"))
        joinpath(d,"candidate")
    end
    select=id->begin
        push!(events,:select)
        (;handle,identity,application="/saved/application",prefix="/prefix")
    end
    shutdown=(h;deadline)->begin
        push!(events,:quit)
        @test h.stage_root == "/original/stage"
        C.write_json(joinpath(directory,"shutdown-attempt.json"),Dict("accepted"=>false))
        fail===:quit && error("Quit completion unavailable")
        h.shutdown_attempted=true; h.shutdown_accepted=true
    end
    start=(candidate,stage;prefix,deadline)->begin
        push!(events,:start)
        mkpath(joinpath(stage,"installed"))
        write(joinpath(stage,"installed","simulation.conf"),"{}")
        if fail===:start
            C.write_json(joinpath(stage,"start-failure.json"),Dict("cleanup_confirmed"=>true))
            error("candidate startup failed after verified cleanup")
        end
        handle
    end
    control=(h,command;deadline)->begin
        push!(events,operation(command))
        Dict("ok"=>true,"state"=>operation(command)===:status ? "Ready" : "Running")
    end
    ledger=h->Dict("discovery_locator"=>"/new/session.pod","session_uuid"=>"new-session")
    return S.rebuild(request,directory;prepare,select,shutdown,start,control,ledger)
end

@testset "cold replacement ordering and failure fences" begin
    for failure in (nothing,:prepare,:quit,:start,:changed)
        mktempdir() do root
            id,directory,request=make_job(root)
            events=Symbol[]
            execute=(r,d)->fake_rebuild(r,d,events;fail=failure,changed=failure===:changed)
            code=S.run_job(id;root,execute)
            result=C.read_json(joinpath(directory,"result.json"))
            if failure===nothing
                @test code==0
                @test events==[:prepare,:select,:quit,:start,:status,:session_start]
                @test result["state"]=="complete"
                @test result["locator"]=="/new/session.pod"
            elseif failure in (:prepare,:changed)
                @test code==1
                @test :quit ∉ events && :start ∉ events
                @test result["state"]=="failed"
            elseif failure===:quit
                @test :start ∉ events
                @test result["state"]=="unknown"
            elseif failure===:start
                @test result["state"]=="failed"
                @test result["cleanup_confirmed"]===true
            end
            before=copy(events)
            @test S.run_job(id;root,execute)==code
            @test events==before # No request or effect is repeated.
            @test C.read_json(joinpath(directory,"result.json"))==result
        end
    end
end

@testset "one replacement per managed incarnation" begin
    mktempdir() do root
        first_id,first_dir,_=make_job(root)
        second_root=joinpath(root,"second-client");mkdir(second_root)
        second_id,second_dir,_=make_job(second_root; managed_root=joinpath(root,"managed"))
        entered=Channel{Nothing}(1); release=Channel{Nothing}(1)
        execute=(request,directory)->begin
            put!(entered,nothing); take!(release)
            S.save_state(directory,"complete")
        end
        first=@async S.run_job(first_id;root,execute)
        take!(entered)
        @test S.run_job(second_id;root=second_root,execute)==1
        @test C.read_json(joinpath(second_dir,"result.json"))["state"]=="failed"
        put!(release,nothing)
        @test fetch(first)==0
        @test C.read_json(joinpath(first_dir,"result.json"))["state"]=="complete"
    end
end

@testset "bounded simulator management protocol" begin
    for line in ("{}", "not-json", "x"^(S.MAX_REQUEST_BYTES+1),
        "{\"protocol\":\"pipewireao.simulator-settings/1\",\"op\":\"start\",\"arguments\":{}}")
        @test S.respond(line)["ok"]===false
    end
    @test_throws ArgumentError S.job_directory(mktempdir(),"../other")
    input=IOBuffer("{}\n{}\n"); output=IOBuffer()
    @test S.serve(input,output)==0
    @test count(==('\n'),String(take!(output)))==2
end

@testset "record reservation and ambiguous launch observation" begin
    mktempdir() do root
        for index in 1:255
            mkdir(joinpath(root,string(index;base=16,pad=32)))
        end
        request=Dict("id"=>"e"^32)
        open(joinpath(root,".reservation.lock"),"a+") do lock
            @test ccall(:flock,Cint,(Cint,Cint),fd(lock),2|4)==0
            @test_throws ArgumentError S.reserve_job(root,request)
            ccall(:flock,Cint,(Cint,Cint),fd(lock),8)
        end
        @test isdir(S.reserve_job(root,request))
        @test_throws ArgumentError S.reserve_job(root,Dict("id"=>"f"^32))
        @test count(name->occursin(r"^[0-9a-f]{32}$",name),readdir(root))==256
    end
    mktempdir() do root
        id,directory,_=make_job(root)
        absent=(unit;extra)->Dict("ActiveState"=>"inactive")
        @test S.job(id;root,inspect=absent)["state"]=="failed"
        C.write_json(joinpath(directory,"launch-acknowledgement.json"),Dict("acknowledged"=>false))
        @test S.job(id;root,inspect=absent)["state"]=="unknown"
        S.save_state(directory,"preparing")
        @test S.job(id;root,inspect=absent)["state"]=="failed"
        S.save_state(directory,"stopping")
        @test S.job(id;root,inspect=absent)["state"]=="unknown"
        S.save_state(directory,"complete";locator="/exact/new-session.pod")
        @test S.job(id;root,inspect=absent)["locator"]=="/exact/new-session.pod"
    end
end
