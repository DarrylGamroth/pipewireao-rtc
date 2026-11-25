using Test, PipeWireAORTC
const Owner = PipeWireAORTC.AOSOwner
const IC = PipeWireAORTC.InstrumentConfiguration
const C = PipeWireAORTC.Common
Base.include(@__MODULE__, joinpath(@__DIR__, "aos_graph_documents.jl"))

@testset "version 3 selects a bounded declared graph without scientific imports" begin
    mktempdir() do directory
        (; document, declaration, path) = aos_graph_documents(directory)
        metadata = IC.load_simulation(path; validate_optics = false)
        @test metadata.document == declaration.document
        @test IC.graph_requires_proper(
            metadata, IC.settings(metadata); simulation_graph = "optical-reference"
        )
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
        @test !IC.graph_requires_proper(
            declaration, IC.settings(declaration); simulation_graph = "internal-source"
        )
        # An explicit selected profile replacement owns the final native type.
        declaration.document["profiles"]["reference"]["nodes"] = [
            Dict("name" => "optics", "type" => "other", "config" => Dict())
        ]
        @test !IC.graph_requires_proper(
            declaration, IC.settings(declaration); simulation_graph = "optical-reference"
        )
        declaration.document["defaults"]["native_type"] = "proper_optical_train_f64"
        declaration.document["settings_schema"]["properties"]["native_type"] = Dict(
            "type" => "string"
        )
        only(declaration.document["profiles"]["reference"]["nodes"])["type"] = Dict(
            "\$ref" => "/settings/native_type"
        )
        @test IC.graph_requires_proper(
            declaration, IC.settings(declaration); simulation_graph = "optical-reference"
        )
        for selection in ("absent", "calibration", "../production", "", true, 1)
            document["plant"]["graph"] = selection
            C.write_json(config, document)
            @test_throws ArgumentError Owner.configuration(config)
        end
        @test all(
            id ->
                id.name ∉ (
                    "AdaptiveOpticsSim",
                    "AdaptiveOpticsSimPipeWireHIL",
                    "CUDA",
                    "AMDGPU",
                    "Proper",
                ),
            keys(Base.loaded_modules),
        )
    end
end
