using Test, PipeWireAORTC
const Owner = PipeWireAORTC.AOSOwner
const IC = PipeWireAORTC.InstrumentConfiguration
const C = PipeWireAORTC.Common
Base.include(@__MODULE__, joinpath(@__DIR__, "aos_graph_documents.jl"))

@testset "version 3 selects a bounded declared graph without scientific imports" begin
    mktempdir() do directory
        (; document, declaration, path) = aos_graph_documents(directory)
        metadata = IC.load_simulation(path; validate_optics=false)
        @test metadata.document == declaration.document
        @test IC.graph_requires_proper(metadata, IC.settings(metadata); simulation_graph="optical-reference")
        config = joinpath(directory, "simulation.conf")
        C.write_json(config, document)
        @test Owner.configuration(config).plant.graph == "production"
        @test !Owner.configuration(config).pupil_output
        document["pupil_output"] = true
        C.write_json(config, document)
        @test_throws ArgumentError Owner.configuration(config)
        delete!(document, "pupil_output")
        C.write_json(config, document)
        @test !Owner.requires_proper(Owner.configuration(config))
        document["plant"]["graph"] = "optical-reference"
        C.write_json(config, document)
        options = Owner.configuration(config)
        @test options.plant.graph == "optical-reference"
        @test Owner.requires_proper(options)
        @test !IC.graph_requires_proper(declaration, IC.settings(declaration); simulation_graph="internal-source")
        # An explicit selected profile replacement owns the final native type.
        declaration.document["profiles"]["reference"]["nodes"] = [Dict("name" => "optics", "type" => "other", "config" => Dict())]
        @test !IC.graph_requires_proper(declaration, IC.settings(declaration); simulation_graph="optical-reference")
        declaration.document["defaults"]["native_type"] = "proper_optical_train_f64"
        declaration.document["settings_schema"]["properties"]["native_type"] = Dict("type" => "string")
        only(declaration.document["profiles"]["reference"]["nodes"])["type"] = Dict("\$ref" => "/settings/native_type")
        @test IC.graph_requires_proper(declaration, IC.settings(declaration); simulation_graph="optical-reference")
        for selection in ("absent", "calibration", "../production", "", true, 1)
            document["plant"]["graph"] = selection
            C.write_json(config, document)
            @test_throws ArgumentError Owner.configuration(config)
        end
        @test all(id -> id.name ∉ ("AdaptiveOpticsSim", "AdaptiveOpticsSimPipeWireHIL", "CUDA", "AMDGPU", "Proper"), keys(Base.loaded_modules))
    end
end

@testset "Preparing precedes selected Proper loading and ordinary graphs skip it" begin
    mktempdir() do directory
        (; document) = aos_graph_documents(directory)
        config = joinpath(directory, "simulation.conf")
        args = ["--config", config, "--remote", "/tmp/aos-graph-selection",
            "--control-node", "simulator-wfs", "--bootstrap-node", "rtc.bootstrap.aos", "--bootstrap-instance", "7"]
        events = Symbol[]
        with_owner = (f, options) -> begin
            push!(events, :preparing)
            f(merge(options, (; owner_check=() -> push!(events, :check))))
        end
        for graph in ("production", "optical-reference", "internal-source", "dark")
            empty!(events)
            document["plant"]["graph"] = graph
            C.write_json(config, document)
            @test Owner._main(args; with_owner, load_science=() -> push!(events, :science),
                load_proper=() -> push!(events, :proper), run=options -> begin
                    @test options.plant.graph == graph
                    push!(events, :run)
                end) == 0
            expected = [:preparing, :check, :science, :check, :check]
            graph == "optical-reference" && append!(expected, [:proper, :check])
            @test events == [expected; :run]
        end
        document["plant"]["graph"] = "optical-reference"
        C.write_json(config, document)
        empty!(events)
        project = Base.ACTIVE_PROJECT[]
        try
            # An ambient/global Proper package cannot substitute for an app dependency.
            application = joinpath(directory, "application")
            mkpath(application)
            write(joinpath(application, "Project.toml"), "[deps]\n")
            Base.ACTIVE_PROJECT[] = joinpath(application, "Project.toml")
            error = try Owner._main(args; with_owner, load_science=() -> push!(events, :science), run=identity) catch error; error end
            @test error isa ArgumentError
            @test occursin("Proper must be a direct dependency", sprint(showerror, error))
            @test events == [:preparing, :check, :science, :check, :check]
        finally
            Base.ACTIVE_PROJECT[] = project
        end
    end
end
