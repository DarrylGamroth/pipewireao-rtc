using Test, PipeWireAORTC, PipeWireAO, TOML
const E = PipeWireAORTC.InstrumentExport
const C = PipeWireAORTC.Common
const D = PipeWireAORTC.DeploymentConfiguration
const PREFIX = PipeWireAO.LibPipeWire.PipeWireAO_jll.artifact_dir

Base.include(@__MODULE__,joinpath(@__DIR__,"composition_documents.jl"))

@testset "composition rejects colliding native queue endpoints" begin
    queue(name, capture, playback)=Dict("name"=>"libpipewire-module-queue","args"=>Dict(
        "node.name"=>name,"queue.max-buffers"=>1,"queue.storage"=>"copy","queue.overflow"=>"drop-oldest",
        "capture.props"=>Dict("node.name"=>capture),"playback.props"=>Dict("node.name"=>playback)))
    base=Dict("context.modules"=>[queue("first","first-input","shared-output")])
    component=Dict("context.modules"=>[queue("second","second-input","shared-output")])
    @test_throws ArgumentError E.merge_composition_core(base,component)
    @test E.merge_composition_core(base,deepcopy(base))==base
    component["context.modules"]=[queue("second","second-input","second-output")]
    @test length(E.merge_composition_core(base,component)["context.modules"])==2
    component["context.modules"]=[queue("second","shared-output","second-output")]
    @test_throws ArgumentError E.merge_composition_core(base,component)
    object=Dict("context.objects"=>[Dict("factory"=>"spa-node-factory",
        "args"=>Dict("node.name"=>"shared-output"))])
    @test_throws ArgumentError E.merge_composition_core(base,object)
    @test_throws ArgumentError E.merge_composition_core(object,base)
end

@testset "component telemetry queues retain the shared core owner" begin
    mktempdir() do directory
        base=composition_fixture(joinpath(directory,"base"),"base","simulator","pupil")
        component=composition_fixture(joinpath(directory,"component"),"component","simulator","sensor")
        capture="sensor-diagnostic-queue-input"
        playback="sensor-diagnostic-queue-output"
        queue=Dict("name"=>"libpipewire-module-queue","args"=>Dict(
            "node.name"=>"sensor-diagnostic-queue","queue.max-buffers"=>1,"queue.storage"=>"copy",
            "queue.overflow"=>"drop-oldest","queue.media"=>"application/ndarray",
            "capture.props"=>Dict("node.name"=>capture,"node.loop.name"=>"rtc-data-loop"),
            "playback.props"=>Dict("node.name"=>playback,"node.loop.name"=>"telemetry-loop")))
        core=Dict("context.modules"=>[queue],"context.objects"=>[Dict("factory"=>"spa-node-factory",
            "args"=>Dict("factory.name"=>"support.node.driver","node.name"=>"telemetry-driver",
                "node.group"=>"pipewireao-telemetry"))])
        E.telemetry_queues!(core)
        @test E.validate_telemetry_groups(core)===nothing
        C.write_json(joinpath(component,"core.conf"),core)
        format=Dict("shape"=>[2],"element-type"=>"F32_LE","layout"=>"ROW_MAJOR","schema"=>"test/diagnostic/1")
        session=C.read_json(joinpath(component,"session.conf"))
        session["sources"][1]["ownership"]="external"
        session["sources"][1]["ports"]=[merge(format,Dict("name"=>"output_1","direction"=>"output"))]
        push!(session["sinks"],Dict("node.name"=>capture,"ownership"=>"external",
            "ports"=>[merge(format,Dict("name"=>"playback_1","direction"=>"input"))]))
        push!(session["links"],Dict("output"=>"sensor:output_1","input"=>capture*":playback_1","passive"=>false))
        C.write_json(joinpath(component,"session.conf"),session)
        spec=C.read_json(joinpath(component,"deployment.conf"))
        spec["node-owners"][capture]="core"
        C.write_json(joinpath(component,"deployment.conf"),spec);E.seal!(component)
        @test E.sealed_application(component,PREFIX)[2]==C.read_json(joinpath(component,"deployment.conf"))
        before=read(joinpath(component,"deployment.conf"))
        replacement=joinpath(directory,"prepared-graph.conf");write(replacement,"{}")
        options=(;namespace="cal2",roles=Dict("simulator"=>"cal2-optics"),links=Any[],
            overrides=Dict("graph.conf"=>replacement),prefix=PREFIX)
        output=E.compose(base,component,joinpath(directory,"accepted");options...)
        merged=E.sealed_application(output,PREFIX)[2]
        @test merged["node-owners"][capture]=="core"
        @test merged["node-owners"]["sensor"]=="cal2-optics"
        @test length(merged["owners"])==2 && merged["auxiliary-source-owners"]==["cal2-optics"]
        @test D.decode(joinpath(output,"core.conf"),PREFIX)["context.modules"]==[queue]
        @test D.decode(joinpath(output,"session.conf"),PREFIX)["links"]==session["links"]
        @test read(joinpath(component,"deployment.conf"))==before
        @test read(joinpath(output,"components/cal2/deployment.conf"))==before
        @test_throws ArgumentError E.compose(base,component,joinpath(directory,"core-role");options...,
            roles=Dict("simulator"=>"cal2-optics","core"=>"core"))
        for (name,owner) in (("forged-core","core"),("unknown-owner","unknown"))
            altered=deepcopy(spec);altered["node-owners"]["sensor"]=owner
            C.write_json(joinpath(component,"deployment.conf"),altered);E.seal!(component)
            rejected=joinpath(directory,name)
            @test_throws D.DeploymentError E.compose(base,component,rejected;options...)
            @test !ispath(rejected)
        end
        C.write_json(joinpath(component,"deployment.conf"),spec)
        C.write_json(joinpath(component,"core.conf"),Dict("context.modules"=>[],"context.objects"=>core["context.objects"]))
        E.seal!(component)
        rejected=joinpath(directory,"missing-queue")
        @test_throws D.DeploymentError E.compose(base,component,rejected;options...)
        @test !ispath(rejected)
        C.write_json(joinpath(component,"core.conf"),core);E.seal!(component)
        other=deepcopy(queue)
        other["args"]["node.name"]="upstream-diagnostic-queue"
        other["args"]["capture.props"]["node.name"]="upstream-diagnostic-queue-input"
        C.write_json(joinpath(base,"core.conf"),Dict("context.modules"=>[other],"context.objects"=>core["context.objects"]))
        E.seal!(base)
        @test E.sealed_application(base,PREFIX)[2]==C.read_json(joinpath(base,"deployment.conf"))
        rejected=joinpath(directory,"playback-collision")
        @test_throws ArgumentError E.compose(base,component,rejected;options...)
        @test !ispath(rejected)
        # A base-owned node cannot be replaced by a component queue endpoint.
        collision=composition_fixture(joinpath(directory,"collision-base"),"base","simulator",capture)
        rejected=joinpath(directory,"collision")
        @test_throws ArgumentError E.compose(collision,component,rejected;options...)
        @test !ispath(rejected)
        @test !any(id->id.name in ("CUDA","AMDGPU"),keys(Base.loaded_modules))
    end
end

@testset "declared cross-link contracts agree before composition publication" begin
    mktempdir() do directory
        base=composition_fixture(joinpath(directory,"base"),"base","simulator","pupil")
        component=composition_fixture(joinpath(directory,"component"),"component","simulator","sensor")
        schema=PipeWireAORTC.Schemas.identifier("requested_pdm_command")
        format=Dict("shape"=>[2],"element-type"=>"F32_LE","layout"=>"ROW_MAJOR","schema"=>schema)
        for (root,name,direction) in ((base,"output_1","output"),(component,"input_1","input"))
            session=C.read_json(joinpath(root,"session.conf"))
            session["sources"][1]["ports"]=[merge(format,Dict("name"=>name,"direction"=>direction))]
            C.write_json(joinpath(root,"session.conf"),session);E.seal!(root)
        end
        replacement=joinpath(directory,"prepared-graph.conf");write(replacement,"{}")
        options=(;namespace="cal2",roles=Dict("simulator"=>"cal2-optics"),
            links=[Dict("output"=>"pupil:output_1","input"=>"sensor:input_1")],
            overrides=Dict("graph.conf"=>replacement),prefix=PREFIX)
        @test isdir(E.compose(base,component,joinpath(directory,"matching");options...))
        for (field,value) in (("schema","pipewireao/requested-pdm-command-opd-m-f32/1"),
                ("shape",[3]),("element-type","F64_LE"),("layout","COLUMN_MAJOR"))
            session=C.read_json(joinpath(component,"session.conf"))
            session["sources"][1]["ports"][1]=merge(format,Dict("name"=>"input_1","direction"=>"input",field=>value))
            C.write_json(joinpath(component,"session.conf"),session);E.seal!(component)
            output=joinpath(directory,"mismatched-"*field)
            @test_throws ArgumentError E.compose(base,component,output;options...)
            @test !ispath(output)
        end
        # Only explicitly shared fields are proved; omission retains legacy admission.
        session=C.read_json(joinpath(component,"session.conf"))
        session["sources"][1]["ports"][1]=Dict("name"=>"input_1","direction"=>"input")
        C.write_json(joinpath(component,"session.conf"),session);E.seal!(component)
        @test isdir(E.compose(base,component,joinpath(directory,"undeclared");options...))
        @test !any(id->id.name in ("CUDA","AMDGPU"),keys(Base.loaded_modules))
    end
end

@testset "sealed applications share one authority and preserve component bytes" begin
    mktempdir() do directory
        base=composition_fixture(joinpath(directory,"base"),"base","simulator","pupil")
        component=composition_fixture(joinpath(directory,"component"),"component","simulator","sensor")
        replacement=joinpath(directory,"prepared-graph.conf");write(replacement,"{\"prepared\":true}")
        original=C.sha256_file(joinpath(component,"deployment.conf"))
        options=(;namespace="cal2",roles=Dict("simulator"=>"cal2-optics"),
            links=[Dict("output"=>"pupil:output_1","input"=>"sensor:input_1")],
            overrides=Dict("graph.conf"=>replacement),prefix=PREFIX)
        output=E.compose(base,component,joinpath(directory,"built");options...)
        spec=C.read_json(joinpath(output,"deployment.conf"))
        @test spec["source-owner"]=="simulator"
        @test spec["auxiliary-source-owners"]==["cal2-optics"]
        @test length(spec["owners"])==2
        auxiliary=last(spec["owners"])
        @test "--project=@PACKAGE@" in auxiliary["argv"]
        @test "@PACKAGE@/components/cal2/entry.jl" in auxiliary["argv"]
        @test "@BOOTSTRAP_INSTANCE_CAL2_OPTICS@" in auxiliary["argv"]
        @test spec["client"]["cal2-optics"]=="components/cal2/client.conf"
        @test C.sha256_file(joinpath(output,"components/cal2/deployment.conf"))==original
        @test C.sha256_file(joinpath(component,"deployment.conf"))==original
        @test read(joinpath(output,"graph.conf"),String)==read(replacement,String)
        session=D.decode(joinpath(output,"session.conf"),PREFIX)
        @test length(session["sources"])==2 && only(session["links"])["output"]=="pupil:output_1"
        @test spec["node-owners"]==Dict("pupil"=>"simulator","sensor"=>"cal2-optics")
        @test haskey(spec["artifacts"],"composition/receipt.yaml")
        @test E.sealed_application(output,PREFIX)[2]==spec
        @test auxiliary["bootstrap-node"]=="cal2.sensor-bootstrap"
        arguments=copy(first(C.read_json(joinpath(base,"deployment.conf"))["owners"])["argv"])
        push!(arguments,"--physical-offsets","@PACKAGE@/offsets.yaml")
        revised=E.compose(base,component,joinpath(directory,"with-offsets");options...,
            owner_arguments=Dict("simulator"=>arguments))
        @test first(C.read_json(joinpath(revised,"deployment.conf"))["owners"])["argv"]==arguments
        @test C.read_yaml(joinpath(revised,"composition/receipt.yaml"))["owner_arguments"]["simulator"]==arguments
        @test_throws ArgumentError E.compose(base,component,joinpath(directory,"unknown-owner");options...,
            owner_arguments=Dict("unknown"=>arguments))
        @test_throws D.DeploymentError E.compose(base,component,joinpath(directory,"invalid-argv");options...,
            owner_arguments=Dict("simulator"=>["julia"]))
        @test !ispath(joinpath(directory,"invalid-argv"))
        @test_throws ArgumentError E.compose(base,component,joinpath(directory,"empty");options...,overrides=Dict())
        @test_throws ArgumentError E.compose(base,component,joinpath(directory,"collision");options...,roles=Dict("simulator"=>"simulator"))
        @test_throws ArgumentError E.compose(base,component,joinpath(directory,"invalid");options...,overrides=Dict("../escape"=>replacement))
        # An input's undeclared file is not admitted by a partial seal.
        write(joinpath(component,"unsealed"),"new bytes")
        @test_throws ArgumentError E.compose(base,component,joinpath(directory,"unsealed");options...)
        @test !ispath(joinpath(directory,"unsealed"))
    end
end

@testset "composition preserves a nested registered runtime" begin
    mktempdir() do temporary
        base=composition_fixture(joinpath(temporary,"base"),"base","simulator","pupil")
        component=composition_fixture(joinpath(temporary,"component"),"component","simulator","sensor")
        uuid="a3e2c7da-f73f-4284-8482-36ac422b34e6"
        for root in (base,component)
            mkpath(joinpath(root,"env"))
            open(joinpath(root,"env/Project.toml"),"w") do io
                TOML.print(io,Dict("deps"=>Dict("PipeWireAORTC"=>uuid)))
            end
            open(joinpath(root,"env/Manifest.toml"),"w") do io
                TOML.print(io,Dict("deps"=>Dict("PipeWireAORTC"=>[Dict("uuid"=>uuid,"version"=>"0.1.0","git-tree-sha1"=>repeat("a",40))])))
            end
            spec=C.read_json(joinpath(root,"deployment.conf"))
            spec["runtime"]=Dict("kind"=>"registered","project"=>"env")
            spec["owners"][1]["argv"]=replace.(spec["owners"][1]["argv"],"--project=@PACKAGE@"=>"--project=@PACKAGE@/env")
            C.write_json(joinpath(root,"deployment.conf"),spec);E.seal!(root)
        end
        bad=joinpath(temporary,"unregistered.toml")
        open(bad,"w") do io
            TOML.print(io,Dict("deps"=>Dict("PipeWireAORTC"=>[Dict("uuid"=>uuid,"path"=>"/tmp/unregistered")])))
        end
        options=(;namespace="cal2",roles=Dict("simulator"=>"cal2-optics"),links=Any[],prefix=PREFIX)
        for name in ("env/Manifest.toml","env/Project.toml")
            output=joinpath(temporary,basename(name))
            @test_throws ArgumentError E.compose(base,component,output;options...,overrides=Dict(name=>bad))
            @test !ispath(output)
        end
        replacement=joinpath(temporary,"graph.conf");write(replacement,"{}")
        output=E.compose(base,component,joinpath(temporary,"valid");options...,overrides=Dict("graph.conf"=>replacement))
        @test D.application_environment(C.read_json(joinpath(output,"deployment.conf")),output)==joinpath(output,"env")
        @test "--project=@PACKAGE@/env" in last(C.read_json(joinpath(output,"deployment.conf"))["owners"])["argv"]
    end
end

@testset "composition admits the native link capacity before publication" begin
    mktempdir() do directory
        base=composition_fixture(joinpath(directory,"base"),"base","simulator","pupil")
        component=composition_fixture(joinpath(directory,"component"),"component","simulator","sensor")
        replacement=joinpath(directory,"prepared-graph.conf");write(replacement,"{}")
        options=(;namespace="cal2",roles=Dict("simulator"=>"cal2-optics"),
            overrides=Dict("graph.conf"=>replacement),prefix=PREFIX)
        for count in (36,64)
            links=[Dict("output"=>"pupil:out_$i","input"=>"sensor:in_$i") for i in 1:count]
            output=E.compose(base,component,joinpath(directory,"links-$count");links,options...)
            @test length(D.decode(joinpath(output,"session.conf"),PREFIX)["links"]) == count
        end
        output=joinpath(directory,"links-65")
        links=[Dict("output"=>"pupil:out_$i","input"=>"sensor:in_$i") for i in 1:65]
        @test_throws D.DeploymentError E.compose(base,component,output;links,options...)
        @test !ispath(output)
    end
end

@testset "composition rejects stale owner CPU pins before publication" begin
    mktempdir() do directory
        base=composition_fixture(joinpath(directory,"base"),"base","simulator","pupil")
        component=composition_fixture(joinpath(directory,"component"),"component","simulator","sensor")
        spec=C.read_json(joinpath(base,"deployment.conf"))
        spec["placement"]["simulator"]["cpus"]=[2,3,4]
        spec["placement"]["simulator"]["leader-cpu"]=3
        owner=only(spec["owners"]);append!(owner["argv"],["--pin-cpus","3,2"])
        C.write_json(joinpath(base,"deployment.conf"),spec);E.seal!(base)
        argv=copy(owner["argv"])
        argv[only(findall(arg->startswith(arg,"--threads="),argv))]="--threads=3,0"
        replacement=joinpath(directory,"prepared-graph.conf");write(replacement,"{}")
        options=(;namespace="cal2",roles=Dict("simulator"=>"cal2-optics"),links=Any[],
            overrides=Dict("graph.conf"=>replacement),prefix=PREFIX)
        output=joinpath(directory,"stale-pins")
        @test_throws D.DeploymentError E.compose(base,component,output;
            owner_arguments=Dict("simulator"=>argv),options...)
        @test !ispath(output)
        for (pins,name) in (("3,2,4","matching-pins"),("3,3,2","repeated-pins"))
            selected=copy(argv);selected[end]=pins
            accepted=E.compose(base,component,joinpath(directory,name);
                owner_arguments=Dict("simulator"=>selected),options...)
            @test only(filter(owner->owner["role"]=="simulator",
                C.read_json(joinpath(accepted,"deployment.conf"))["owners"]))["argv"] == selected
        end
    end
end

@testset "composition preserves disjoint groups and passive CAL2 inputs" begin
    mktempdir() do directory
        base=composition_fixture(joinpath(directory,"base"),"base","simulator","simulator-wfs")
        component=composition_fixture(joinpath(directory,"component"),"component","simulator","cal2-llowfs")
        for (root,names) in ((base,["gpi2-jfg-frame-graph"]),(component,["cal2-llowfs-controller","cal2-scc-controller"]))
            session=C.read_json(joinpath(root,"session.conf"))
            session["sources"][1]["ownership"]="external"
            session["graphs"]=[Dict("node.name"=>name,"ownership"=>"external","run-control"=>"session",
                "ports"=>[Dict("name"=>"image","direction"=>"input","rate"=>endswith(name,"scc-controller") ? "100/1" : "500/1")]) for name in names]
            session["execution-groups"]=[Dict("name"=>name,"nodes"=>[name]) for name in names]
            spec=C.read_json(joinpath(root,"deployment.conf"))
            for name in names;spec["node-owners"][name]="simulator";end
            if root==base
                session["links"]=[Dict("output"=>"simulator-wfs:out_$i","input"=>"gpi2-jfg-frame-graph:in_$i","passive"=>true) for i in 1:31]
            else
                push!(session["sources"],Dict("node.name"=>"cal2-scc","ownership"=>"external"))
                push!(session["sinks"],Dict("node.name"=>"cal2-pupil-input","ownership"=>"external"))
                for name in ("cal2-scc","cal2-pupil-input");spec["node-owners"][name]="simulator";end
                session["links"]=[Dict("output"=>"cal2-$branch:output_1","input"=>"cal2-$branch-controller:image","passive"=>true) for branch in ("llowfs","scc")]
            end
            C.write_json(joinpath(root,"session.conf"),session)
            C.write_json(joinpath(root,"deployment.conf"),spec);E.seal!(root)
        end
        sinks=[Dict("node.name"=>"gpi2-cal2-$branch-offset","ownership"=>"external") for branch in ("llowfs","scc")]
        links=[Dict("output"=>"simulator-wfs:pupil","input"=>"cal2-pupil-input:input_1"),
            [Dict("output"=>"cal2-$branch-controller:physical-offset","input"=>"gpi2-cal2-$branch-offset:input_1") for branch in ("llowfs","scc")]...]
        replacement=joinpath(directory,"prepared-graph.conf");write(replacement,"{}")
        options=(;namespace="cal2",roles=Dict("simulator"=>"cal2-optics"),links,sinks,
            node_owners=Dict(sink["node.name"]=>"simulator" for sink in sinks),
            overrides=Dict("graph.conf"=>replacement),prefix=PREFIX)
        selected=C.read_json(joinpath(component,"session.conf"))
        # The observed application omitted both groups. Reject before copying/publishing.
        invalid=deepcopy(selected);delete!(invalid,"execution-groups")
        C.write_json(joinpath(component,"session.conf"),invalid);E.seal!(component)
        rejected=joinpath(directory,"ungrouped")
        @test_throws D.DeploymentError E.compose(base,component,rejected;options...)
        @test !ispath(rejected)
        C.write_json(joinpath(component,"session.conf"),selected);E.seal!(component)
        output=E.compose(base,component,joinpath(directory,"grouped");options...)
        merged=D.decode(joinpath(output,"session.conf"),PREFIX)
        @test length(merged["execution-groups"])==3 && length(merged["links"])==36
        @test Set(group["name"] for group in merged["execution-groups"])==
            Set(["gpi2-jfg-frame-graph","cal2-llowfs-controller","cal2-scc-controller"])
        @test merged["graphs"][2:3]==selected["graphs"]
        @test merged["execution-groups"][2:3]==selected["execution-groups"]
        @test read(joinpath(output,"components/cal2/session.conf"))==read(joinpath(component,"session.conf"))
        @test D.validate_execution_groups(merged) === nothing
    end
end
