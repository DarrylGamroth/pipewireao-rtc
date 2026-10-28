using Test, PipeWireAORTC
Base.include(@__MODULE__,joinpath(@__DIR__,"external_pupil_owner_documents.jl"))
const Owner = PipeWireAORTC.AOSOwner
const C = PipeWireAORTC.Common

@testset "external-pupil configuration has no mirror-command boundary" begin
    mktempdir() do directory
        (;document,config) = external_pupil_owner_documents(directory)
        options = Owner.configuration(config)
        @test options.version == 4 && options.mode === :external_pupil
        @test options.sensor_buffers==2
        for buffers in (3,64)
            C.write_json(config,merge(document,Dict("sensor_buffers"=>buffers)))
            @test Owner.configuration(config).sensor_buffers==buffers
        end
        for buffers in (1,65,0,-1,true,3.0,"3")
            C.write_json(config,merge(document,Dict("sensor_buffers"=>buffers)))
            @test_throws ArgumentError Owner.configuration(config)
        end
        C.write_json(config,document)
        @test options.sensor_nodes == (;llowfs="optical-llowfs",scc="optical-scc")
        @test Owner.requires_proper(options)
        @test Owner.verify_external_pupil_declaration(options) === nothing
        E = PipeWireAORTC.InstrumentExport
        @test E.simulation_override!(directory,Dict("simulation"=>Dict("backend"=>"amdgpu","device"=>1))) == config
        @test Owner.configuration(config).backend === :amdgpu
        before = read(config)
        @test_throws ArgumentError E.simulation_override!(directory,Dict("simulation"=>Dict("pacing_rate_hz"=>0)))
        @test read(config) == before
        C.write_json(config,document)
        for change in (d->(d["mode"]="other"),d->(d["backend"]="unknown"),
                d->(d["device"]=1),d->(d["command_count"]=1),
                d->delete!(d["sensor_nodes"],"scc"),
                d->(d["sensor_nodes"]["scc"]=d["pupil_node"]))
            invalid = deepcopy(document); change(invalid); C.write_json(config,invalid)
            @test_throws ArgumentError Owner.configuration(config)
        end
        cuda=merge(document,Dict("backend"=>"cuda","device"=>0))
        C.write_json(config,cuda)
        @test Owner.configuration(config).backend === :cuda
        cuda["device"]=-1
        C.write_json(config,cuda)
        @test_throws ArgumentError Owner.configuration(config)
        C.write_json(config,document)
        events = Symbol[]
        args = ["--config",config,"--remote","/tmp/external-pupil-test",
            "--control-node","optical-control","--bootstrap-node","rtc.bootstrap.optics","--bootstrap-instance","7"]
        with_owner = (f,options)->begin
            push!(events,:preparing)
            f(merge(options,(;owner_check=()->nothing)))
        end
        @test Owner._main(args;with_owner,load_science=()->push!(events,:science),
            load_proper=()->push!(events,:proper),run=options->push!(events,:run)) == 0
        @test events == [:preparing,:science,:proper,:run]
    end
    @test all(id->id.name ∉ ("AdaptiveOpticsSim","AdaptiveOpticsSimPipeWireHIL","CUDA","AMDGPU","Proper"),keys(Base.loaded_modules))
end

@testset "chopped optical configuration selects explicit auxiliary graphs and polarity" begin
    mktempdir() do directory
        (;document,config,path,physical,simulation) = external_pupil_owner_documents(directory)
        @test isempty(Owner.configuration(config).plant.chopping)
        simulation["graphs"]["scc_unfringed"] = deepcopy(simulation["graphs"]["scc"])
        write_external_optical_documents(directory, physical, simulation)
        document["plant"]["chopping"] = Dict("scc"=>Dict("unfringed_graph"=>"scc_unfringed",
            "initial_phase"=>"fringed", "trigger_high_is_fringed"=>true))
        C.write_json(config, document)
        options = Owner.configuration(config)
        @test keys(options.plant.chopping) == (:scc,)
        @test options.plant.chopping.scc == (;unfringed_graph="scc_unfringed", initial_phase="fringed",
            trigger_high_is_fringed=true)
        for change in (d->(d["plant"]["chopping"]=[]),
                d->(d["plant"]["chopping"]["scc"]["unfringed_graph"]="missing"),
                d->(d["plant"]["chopping"]["scc"]["unfringed_graph"]="llowfs"),
                d->(d["plant"]["chopping"]["scc"]["initial_phase"]="mixed"),
                d->(d["plant"]["chopping"]["scc"]["trigger_high_is_fringed"]=1),
                d->(d["plant"]["chopping"]["scc"]["period"]=2),
                d->(d["plant"]["chopping"]["unknown"]=pop!(d["plant"]["chopping"],"scc")))
            invalid = deepcopy(document); change(invalid); C.write_json(config, invalid)
            @test_throws ArgumentError Owner.configuration(config)
        end
    end
    @test all(id->id.name ∉ ("AdaptiveOpticsSim","AdaptiveOpticsSimPipeWireHIL","CUDA","AMDGPU","Proper"),keys(Base.loaded_modules))
end
