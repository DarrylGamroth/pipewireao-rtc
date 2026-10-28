using Test, PipeWireAORTC
Base.include(@__MODULE__,joinpath(@__DIR__,"pupil_source_documents.jl"))
const Owner=PipeWireAORTC.AOSOwner
const C=PipeWireAORTC.Common

@testset "clocked pupil source declares one actual physical command and no camera" begin
    mktempdir() do directory
        (;document,config)=pupil_source_documents(directory)
        options=Owner.configuration(config)
        @test options.version==5 && options.mode===:pupil_source
        @test options.command_input===:command && options.mirror=="primary"
        @test options.command_count==2 && startswith(options.command_order,"sha256:")
        @test options.period_ns==2_000_000 && options.pacing_period_ns==1_000_000_000
        @test options.pupil_output && !hasproperty(options,:frame_output)
        @test !options.applied_command_observation
        C.write_json(config,merge(document,Dict("applied_command_observation"=>true)))
        @test Owner.configuration(config).applied_command_observation
        C.write_json(config,merge(document,Dict("applied_command_observation"=>1)))
        @test_throws ArgumentError Owner.configuration(config)
        C.write_json(config,document)
        @test Owner.verify_pupil_source_declaration(options)===nothing
        @test !Owner.requires_proper(options)
        for change in (d->(d["mode"]="external-pupil"),d->(d["plant"]["graph"]="calibration"),
                d->(d["command_input"]="residual"),d->(d["mirror"]="missing"),
                d->(d["rate"]=1000),d->(d["device"]=1),d->(d["frame_output"]="camera"))
            invalid=deepcopy(document);change(invalid);C.write_json(config,invalid)
            @test_throws ArgumentError Owner.configuration(config)
        end
        for (backend,device) in (("cuda",0),("amdgpu",1))
            C.write_json(config,merge(document,Dict("backend"=>backend,"device"=>device)))
            @test Owner.configuration(config).backend===Symbol(backend)
        end
        C.write_json(config,document)
        args=["--config",config,"--remote","/tmp/pupil-source-test","--control-node","plant-control",
            "--bootstrap-node","rtc.bootstrap.plant","--bootstrap-instance","7"]
        @test_throws ArgumentError Owner._main(args;load_science=()->error("must reject before science"))
        args=[args;"--physical-offsets";joinpath(directory,"offsets.yaml")]
        events=Symbol[]
        with_owner=(f,o)->begin
            push!(events,:preparing)
            f(merge(o,(;owner_check=()->nothing)))
        end
        @test Owner._main(args;with_owner,load_science=()->push!(events,:science),
            run=o->begin
                @test o.physical_offsets==joinpath(directory,"offsets.yaml")
                push!(events,:run)
            end)==0
        @test events==[:preparing,:science,:run]
        fixture=C.read_yaml(joinpath(directory,"simulation/definition.yaml"))
        for mutate in (g->(g["links"][1]["destination"]="composition.uncompensated_opd"),
                g->(g["nodes"][2]["type"]="different_operator"),
                g->push!(g["links"],Dict("source"=>"primary.surface_opd","destination"=>"composition.uncompensated_opd")),
                g->(g["delayed_links"]=[Dict("source"=>"primary.surface_opd","destination"=>"composition.uncompensated_opd","initial"=>"residual")]))
            invalid=deepcopy(fixture)
            mutate(invalid["graphs"]["plant"])
            C.write_yaml(joinpath(directory,"simulation/definition.yaml"),invalid)
            @test_throws ArgumentError Owner.configuration(config)
        end
        C.write_yaml(joinpath(directory,"simulation/definition.yaml"),fixture)
        document["prescription_identity"]="other"
        C.write_json(config,document)
        @test_throws ArgumentError Owner.verify_pupil_source_declaration(Owner.configuration(config))
    end
    @test all(id->id.name ∉ ("AdaptiveOpticsSim","AdaptiveOpticsSimPipeWireHIL","CUDA","AMDGPU","Proper"),keys(Base.loaded_modules))
end

@testset "physical command binding is exclusive before either pupil route" begin
    mktempdir() do directory
        (;config,path,simulation)=pupil_source_documents(directory)
        for direct in (false,true)
            aliased=aliased_pupil_source(simulation)
            direct && (aliased["graphs"]["plant"]["outputs"][1]["source"]="primary.surface_opd")
            C.write_yaml(path,aliased)
            @test_throws ArgumentError Owner.configuration(config)
            for section in ("parameters","delayed_links","nodes")
                candidate=deepcopy(simulation)
                graph=candidate["graphs"]["plant"]
                direct && (graph["outputs"][1]["source"]="primary.surface_opd")
                if section=="parameters"
                    graph[section]=[Dict("destination"=>"composition.uncompensated_opd","binding"=>"command")]
                elseif section=="delayed_links"
                    graph[section]=[Dict("source"=>"primary.surface_opd","destination"=>"composition.uncompensated_opd","initial"=>"command")]
                else
                    graph["nodes"][2]["bindings"]=Dict("external"=>"command")
                end
                C.write_yaml(path,candidate)
                @test_throws ArgumentError Owner.configuration(config)
            end
        end
        C.write_yaml(path,simulation)
        @test Owner.configuration(config).command_input===:command
    end
    @test all(id->id.name ∉ ("AdaptiveOpticsSim","AdaptiveOpticsSimPipeWireHIL","CUDA","AMDGPU"),keys(Base.loaded_modules))
end
