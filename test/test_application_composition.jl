using Test, PipeWireAORTC, PipeWireAO, TOML
const E = PipeWireAORTC.InstrumentExport
const C = PipeWireAORTC.Common
const D = PipeWireAORTC.DeploymentConfiguration
const PREFIX = PipeWireAO.LibPipeWire.PipeWireAO_jll.artifact_dir

Base.include(@__MODULE__,joinpath(@__DIR__,"composition_documents.jl"))

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
