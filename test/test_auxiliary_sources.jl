using Test, PipeWireAORTC
const D = PipeWireAORTC.DeploymentConfiguration
const S = PipeWireAORTC.SessionConfiguration
const E = PipeWireAORTC.InstrumentExport

function source_declaration(role)
    Dict{String,Any}("role"=>role,"bootstrap-protocol"=>"pipewireao.rtc.owner-bootstrap/1",
        "bootstrap-node"=>role*"-bootstrap","control-protocol"=>"pipewireao.source-control/1",
        "control-node"=>role*"-source","environment"=>Dict{String,String}(),
        "argv"=>["/julia","--threads=2,0","--bootstrap-node",role*"-bootstrap",
            "--bootstrap-instance","@"*D.bootstrap_instance_key(role)*"@",
            "--control-node",role*"-source","--remote","@RUNTIME@/@REMOTE@"])
end

@testset "bounded eight-owner deployment and explicit auxiliary source authority" begin
    mktempdir() do directory
        write(joinpath(directory,"session.conf"),"{}")
        write(joinpath(directory,"core.conf"),"{}")
        write(joinpath(directory,"client.conf"),"{}")
        owners=[source_declaration("source"*string(i)) for i in 1:8]
        roles=vcat(["core","rtc"],getindex.(owners,"role"))
        placement=Dict(role=>Dict("cpus"=>[2],"leader-cpu"=>2,"rt-priority"=>0,
            "threads"=>[],"locked-bytes"=>0) for role in roles)
        spec=Dict{String,Any}("version"=>1,"name"=>"coupled-session","session"=>"session.conf",
            "core"=>"core.conf","client"=>Dict(role=>"client.conf" for role in roles),
            "placement"=>placement,"owners"=>owners,"source-owner"=>"source1",
            "auxiliary-source-owners"=>["source"*string(i) for i in 2:8],
            "environment"=>Dict(),"artifacts"=>Dict(),"cpu-latency-us"=>nothing)
        path=joinpath(directory,"deployment.conf")
        @test length(D.validate_application(spec,path,"/unused")["owners"])==8
        @test length(S.owner_specs(spec))==8
        for auxiliary in (["source1"],["unknown"],["source2","source2"],"source2",[true],
                ["source"*string(i) for i in 2:9])
            invalid=deepcopy(spec);invalid["auxiliary-source-owners"]=auxiliary
            @test_throws D.DeploymentError D.validate_application(invalid,path,"/unused")
        end
        invalid=deepcopy(spec);push!(invalid["owners"],source_declaration("source9"))
        @test_throws D.DeploymentError D.validate_application(invalid,path,"/unused")
        @test_throws S.ConfigurationError S.owner_specs(invalid)
        invalid=deepcopy(spec);delete!(invalid["owners"][2],"control-protocol")
        @test_throws D.DeploymentError D.validate_application(invalid,path,"/unused")
        invalid=deepcopy(spec);invalid["owners"][2]["control-node"]=invalid["owners"][1]["control-node"]
        # Keep argv internally consistent so the cross-owner identity guard is exercised.
        position=findfirst(==("--control-node"),invalid["owners"][2]["argv"])
        invalid["owners"][2]["argv"][position+1]=invalid["owners"][1]["control-node"]
        @test_throws D.DeploymentError D.validate_application(invalid,path,"/unused")
        invalid=deepcopy(spec);delete!(invalid,"source-owner")
        @test_throws D.DeploymentError D.validate_application(invalid,path,"/unused")
    end
end

@testset "auxiliary source generation retains native identities" begin
    declarations=[source_declaration("primary"),source_declaration("optical")]
    spec=Dict("name"=>"coupled-session","source-owner"=>"primary",
        "auxiliary-source-owners"=>["optical"],"owners"=>declarations)
    session=Dict("sources"=>[Dict("node.name"=>"primary-source"),Dict("node.name"=>"optical-sensor")],
        "graphs"=>[],"sinks"=>[])
    bindings=Dict("RUNTIME"=>"/tmp/coupled-session","REMOTE"=>"rtc-coupled-session",
        "SESSION_UUID"=>"00000000-0000-0000-0000-000000000001","SESSION_SCRIPT"=>"/sealed/rtc/scripts/ao/session.lua",
        "SESSION_CONTROL_INSTANCE"=>"21","SESSION_CONTROLLER_INSTANCE"=>"22","ADMISSION_CONTROLLER_INSTANCE"=>"23",
        "BOOTSTRAP_INSTANCE_PRIMARY"=>"24","BOOTSTRAP_INSTANCE_OPTICAL"=>"25")
    records=Dict(role=>Dict{String,Any}("role"=>role,"pid"=>pid,"state"=>"running","start-ticks"=>1,
        "invocation"=>role*"-invocation","cgroup"=>"/owners/"*role)
        for (role,pid) in (("primary",42),("optical",43),("core",44)))
    mapping=Dict("primary-source"=>"primary","optical-sensor"=>"optical")
    configuration=S.session_configuration(spec,session,bindings,records;node_owners=mapping,configuration_store_root=nothing)
    arguments=only(filter(c->c["type"]=="script/lua",configuration["wireplumber.components"]))["arguments"]
    @test arguments["source"]["role"]=="primary"
    auxiliary=only(arguments["auxiliary-sources"])
    @test auxiliary["role"]=="optical" && auxiliary["pid"]==43
    @test auxiliary["control-protocol"]=="pipewireao.source-control/1"
    @test auxiliary["bootstrap-instance"]=="25"
    @test arguments["node.pids"]==Dict("primary-source"=>42,"optical-sensor"=>43)
    for roles in (["primary"],["missing"],["optical","optical"],"optical")
        invalid=deepcopy(spec);invalid["auxiliary-source-owners"]=roles
        @test_throws S.ConfigurationError S.session_configuration(invalid,session,bindings,records;
            node_owners=mapping,configuration_store_root=nothing)
    end
    invalid=deepcopy(spec);delete!(invalid["owners"][2],"control-protocol")
    @test_throws S.ConfigurationError S.session_configuration(invalid,session,bindings,records;
        node_owners=mapping,configuration_store_root=nothing)
    invalid=deepcopy(spec);invalid["owners"][2]["control-node"]="primary-source"
    @test_throws S.ConfigurationError S.session_configuration(invalid,session,bindings,records;
        node_owners=mapping,configuration_store_root=nothing)
    invalid=deepcopy(records);invalid["optical"]["pid"]=0
    @test_throws S.ConfigurationError S.session_configuration(spec,session,bindings,invalid;
        node_owners=mapping,configuration_store_root=nothing)
end

@testset "auxiliary source authoring requires AOS adapter and SourceControl" begin
    process=Dict("workers"=>Dict("pipewire"=>[2]),"leader-cpu"=>1)
    profile=Dict("scheduling"=>Dict("processes"=>Dict("optical"=>process)))
    source=source_declaration("optical");source["kind"]="aos"
    spec=Dict("owners"=>[source],"auxiliary-source-owners"=>["optical"])
    @test E.prepare_owner_scheduling!(spec,profile)===spec
    @test !haskey(source,"kind") && "--pipewire-cpu" in source["argv"]
    for kind in (nothing,"jfg")
        source=source_declaration("optical")
        kind===nothing || (source["kind"]=kind)
        @test_throws ArgumentError E.prepare_owner_scheduling!(Dict("owners"=>[source],
            "auxiliary-source-owners"=>["optical"]),profile)
    end
    source=source_declaration("optical");source["kind"]="aos";delete!(source,"control-protocol")
    @test_throws ArgumentError E.prepare_owner_scheduling!(Dict("owners"=>[source],
        "auxiliary-source-owners"=>["optical"]),profile)
end
