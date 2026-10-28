using Test, PipeWireAORTC
const E = PipeWireAORTC.InstrumentExport
const C = PipeWireAORTC.Common
const D = PipeWireAORTC.DeploymentConfiguration

@testset "alternate applications select their own owners modes and core modules" begin
    mktempdir() do root
        source=joinpath(root,"source")
        selected="rtc/standalone/application.yaml"
        baseline=Dict("owners"=>[Dict("role"=>"reconstructor")])
        alternate=Dict("owners"=>[Dict("role"=>"simulator")],"runtime-configurations"=>[
            Dict("source"=>"settings.yaml","path"=>"settings.conf","format"=>"json")])
        C.write_yaml(joinpath(source,"rtc/application.yaml"),baseline)
        C.write_yaml(joinpath(source,selected),alternate)
        C.write_yaml(joinpath(source,"settings.yaml"),Dict("kind"=>"pupil"))
        C.write_yaml(joinpath(source,"rtc/modes.yaml"),Dict("default"=>"controller","modes"=>Dict(
            "controller"=>Dict("application"=>Dict("owners"=>[Dict("role"=>"monitor")])))))
        C.write_yaml(joinpath(source,"rtc/standalone/modes.yaml"),Dict("default"=>"source","modes"=>Dict(
            "source"=>Dict("application"=>Dict()))))
        C.write_json(joinpath(source,"rtc/core.conf"),Dict("context.modules"=>[
            Dict("name"=>"libpipewire-module-queue","args"=>Dict("node.name"=>"baseline-queue"))]))
        C.write_json(joinpath(source,"rtc/standalone/core.conf"),Dict("context.modules"=>[]))
        before=Dict(path=>read(joinpath(source,path)) for path in E.application_files(source))
        @test E.source_application(source)==baseline
        @test E.source_application(source,Dict("application"=>"rtc/application.yaml"))==baseline
        @test length(E.merge_configuration(baseline,E.selected_mode(source,Dict())["application"])["owners"])==2
        profile=Dict("application"=>selected,"scheduling"=>Dict("processes"=>Dict("core"=>Dict(
            "rt-priority"=>0,"data-loops"=>Dict("rtc-data-loop"=>[2],"telemetry-loop"=>[3])))))
        mode=E.selected_mode(source,profile)
        authoring=E.merge_configuration(E.source_application(source,profile),mode["application"])
        @test authoring==alternate
        @test only(authoring["owners"])["role"]=="simulator"
        application=E.copy_source(source,joinpath(root,"standalone");runtime_configurations=false)
        E.prepare_runtime_configurations!(application,authoring)
        @test C.read_json(joinpath(application,"settings.conf"))==Dict("kind"=>"pupil")
        @test C.read_json(joinpath(application,"rtc/application.conf"))==Dict("owners"=>alternate["owners"])
        spec=Dict("core"=>"shared-runtime/core.conf.in","client"=>Dict())
        prefix=ENV["PIPEWIREAO_PREFIX"]
        E.render_templates!(application,spec,profile,prefix)
        core=D.decode(joinpath(application,spec["core"]),prefix)
        @test !any(item->item["name"]=="libpipewire-module-queue",core["context.modules"])
        baseline_output=E.copy_source(source,joinpath(root,"baseline");runtime_configurations=false)
        E.render_templates!(baseline_output,deepcopy(spec),Dict("scheduling"=>profile["scheduling"]),prefix)
        core=D.decode(joinpath(baseline_output,spec["core"]),prefix)
        @test count(item->item["name"]=="libpipewire-module-queue",core["context.modules"])==1
        @test all(read(joinpath(source,path))==bytes for (path,bytes) in before)
        @test Set(E.application_files(source))==Set(keys(before))
        @test_throws ArgumentError E.source_application(source,Dict("application"=>"../outside.yaml"))
        @test_throws ArgumentError E.source_application(source,Dict("application"=>"rtc/application.json"))
        mktempdir() do outside
            path=joinpath(outside,"application.yaml");C.write_yaml(path,baseline)
            symlink(path,joinpath(source,"rtc/linked.yaml"))
            @test_throws D.DeploymentError E.source_application(source,Dict("application"=>"rtc/linked.yaml"))
        end
        @test !any(id->id.name in ("AdaptiveOpticsSim","CUDA","AMDGPU"),keys(Base.loaded_modules))
    end
end

@testset "YAML authoring materializes native configurations" begin
    mktempdir() do root
        source = joinpath(root,"source")
        mkpath(joinpath(source,"rtc"))
        C.write_yaml(joinpath(source,"settings.yaml"), Dict("rate"=>500,"enabled"=>true))
        entries = [Dict("source"=>"settings.yaml","path"=>"settings.conf","format"=>"json"),
            Dict("source"=>"settings.yaml","path"=>"native/settings.conf","format"=>"spa-json")]
        declaration = Dict("name"=>"arbitrary-instrument","runtime-configurations"=>entries)
        C.write_yaml(joinpath(source,"rtc/application.yaml"),declaration)
        original = read(joinpath(source,"rtc/application.yaml"))
        application = E.copy_source(source,joinpath(root,"application"))
        @test C.read_json(joinpath(application,"settings.conf")) == Dict("rate"=>500,"enabled"=>true)
        @test D.decode(joinpath(application,"native/settings.conf"),ENV["PIPEWIREAO_PREFIX"]) == C.read_json(joinpath(application,"settings.conf"))
        @test startswith(read(joinpath(application,"native/settings.conf"),String),"# Generated by PipeWireAORTC")
        @test C.read_json(joinpath(application,"rtc/application.conf")) == Dict("name"=>"arbitrary-instrument")
        @test read(joinpath(source,"rtc/application.yaml")) == original
        @test !isfile(joinpath(source,"settings.conf"))
        @test_throws ArgumentError E.prepare_runtime_configurations!(application)
        for invalid in (Dict("source"=>"settings.yaml","path"=>"settings.conf","format"=>"json"),
                Dict("source"=>"settings.yaml","path"=>"../escape","format"=>"json"),
                Dict("source"=>"settings.yaml","path"=>"rtc/application.conf","format"=>"json"),
                Dict("source"=>"settings.yaml","path"=>"settings.yaml","format"=>"json"),
                Dict("source"=>"settings.yaml","path"=>"other.conf","format"=>"toml"),
                Dict("source"=>"settings.yaml","path"=>"other.conf","format"=>"json","unknown"=>true))
            candidate = joinpath(root,"candidate")
            cp(source,candidate)
            C.write_yaml(joinpath(candidate,"rtc/application.yaml"),merge(declaration,Dict("runtime-configurations"=>[first(entries),invalid])))
            @test_throws ArgumentError E.prepare_runtime_configurations!(candidate)
            @test !isfile(joinpath(candidate,"settings.conf"))
            @test !isfile(joinpath(candidate,"rtc/application.conf"))
            rm(candidate;recursive=true)
        end
    end
end

@testset "selected application modes compile their own runtime configurations" begin
    mktempdir() do root
        source = joinpath(root,"source")
        mkpath(joinpath(source,"rtc"))
        base = Dict("runtime-configurations"=>[Dict("source"=>"model.yaml","path"=>"model.conf","format"=>"json")])
        C.write_yaml(joinpath(source,"rtc/application.yaml"),base)
        C.write_yaml(joinpath(source,"model.yaml"),Dict("kind"=>"optical"))
        C.write_yaml(joinpath(source,"parameters.yaml"),Dict("parameters"=>[]))
        mode = Dict("runtime-configurations"=>[Dict("source"=>"parameters.yaml","path"=>"parameters.conf","format"=>"json")])
        selected = E.merge_configuration(base,mode)
        application = E.copy_source(source,joinpath(root,"controller");runtime_configurations=false)
        E.prepare_runtime_configurations!(application,selected)
        @test C.read_json(joinpath(application,"parameters.conf")) == Dict("parameters"=>[])
        @test C.read_json(joinpath(application,"model.conf")) == Dict("kind"=>"optical")
        @test !haskey(C.read_json(joinpath(application,"rtc/application.conf")),"runtime-configurations")
        @test length(selected["runtime-configurations"]) == 2
        optical = E.copy_source(source,joinpath(root,"optical"))
        @test isfile(joinpath(optical,"model.conf"))
        @test !ispath(joinpath(optical,"parameters.conf"))
        @test C.read_yaml(joinpath(source,"rtc/application.yaml")) == base
    end
end
