using Test, PipeWireAORTC, PipeWireAO, TOML
const E = PipeWireAORTC.InstrumentExport
const C = PipeWireAORTC.Common
const D = PipeWireAORTC.DeploymentConfiguration
const PREFIX = PipeWireAO.LibPipeWire.PipeWireAO_jll.artifact_dir

Base.include(@__MODULE__,joinpath(@__DIR__,"composition_documents.jl"))

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
