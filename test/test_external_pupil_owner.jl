using Test, PipeWireAORTC
Base.include(@__MODULE__,joinpath(@__DIR__,"external_pupil_owner_documents.jl"))
const Owner = PipeWireAORTC.AOSOwner
const C = PipeWireAORTC.Common

@testset "external-pupil configuration has no mirror-command boundary" begin
    mktempdir() do directory
        (;document,config) = external_pupil_owner_documents(directory)
        options = Owner.configuration(config)
        @test options.version == 4 && options.mode === :external_pupil
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
        for change in (d->(d["mode"]="other"),d->(d["backend"]="cuda"),
                d->(d["device"]=1),d->(d["command_count"]=1),
                d->delete!(d["sensor_nodes"],"scc"),
                d->(d["sensor_nodes"]["scc"]=d["pupil_node"]))
            invalid = deepcopy(document); change(invalid); C.write_json(config,invalid)
            @test_throws ArgumentError Owner.configuration(config)
        end
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
