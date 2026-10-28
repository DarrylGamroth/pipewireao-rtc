using Test, PipeWireAORTC
const IC = PipeWireAORTC.InstrumentConfiguration
Base.include(@__MODULE__, joinpath(@__DIR__, "external_optical_documents.jl"))

function optical_spectra_documents(directory; source=true)
    physical, simulation = external_optical_documents()
    physical["optical_paths"] = Dict(name => Dict{String,Any}("sensor" => name, "lyot_stop_port" => port)
        for (name, port) in (("scc", "transmitted"), ("llowfs", "reflected")))
    physical["optical_filters"] = Dict("h_band" => Dict{String,Any}(
        "wavelength_m" => [1.4e-6, 1.6e-6, 1.8e-6], "transmission" => [0.0, 0.8, 0.0]))
    physical["optical_paths"]["scc"]["filters"] = ["h_band"]
    defaults = simulation["defaults"]
    delete!(defaults, "wavelength_um")
    defaults["temperature_c"] = 20
    defaults["spectra"] = Dict(name => Dict{String,Any}("wavelength_um" => 1.55,
        "fractional_bandwidth" => 0.0, "samples" => 1,
        "filter" => name == "scc" ? "h_band" : "none") for name in ("scc", "llowfs"))
    simulation["settings_schema"] = "proper_optical_train"
    if source
        mkpath(joinpath(directory, "optics"))
        prescription = joinpath(directory, "optics", "instrument.zmx")
        write(prescription, "Authored optical prescription for cold validation\n")
        physical["optical_prescription"] = Dict("format" => "zemax", "path" => "optics/instrument.zmx",
            "sha256" => PipeWireAORTC.Common.sha256_file(prescription))
        mkpath(joinpath(directory, "simulation"))
        write(joinpath(directory, "simulation", "zemax.yaml"), "schema_version: 1\n")
        simulation["preparation"] = Dict("kind" => "zemax", "recipe" => "zemax.yaml")
        delete!(simulation, "graphs")
        simulation["components"] = Dict()
    else
        simulation["components"]["optics"]["config"]["wavelength_um"] = 1.55
    end
    return physical, simulation
end

@testset "bounded physical optical filter declarations" begin
    mktempdir() do directory
        physical, _ = optical_spectra_documents(directory)
        @test IC.validate_declaration(physical, directory) === nothing
        for mutate! in (
                filter -> (filter["unknown"] = 1),
                filter -> delete!(filter, "transmission"),
                filter -> (filter["wavelength_m"] = [1e-6]),
                filter -> (filter["wavelength_m"] = [1e-6, 1e-6, 2e-6]),
                filter -> (filter["wavelength_m"] = [2e-6, 1e-6, 3e-6]),
                filter -> (filter["wavelength_m"] = [0, 1e-6, 2e-6]),
                filter -> (filter["wavelength_m"] = [NaN, 1e-6, 2e-6]),
                filter -> (filter["transmission"] = [0, 1]),
                filter -> (filter["transmission"] = [0, -0.1, 1]),
                filter -> (filter["transmission"] = [0, 1.1, 1]),
                filter -> (filter["transmission"] = [0, Inf, 1]),
                filter -> (filter["transmission"] = Any[0, true, 1]),
                filter -> (filter["wavelength_m"] = collect(1.0:4097); filter["transmission"] = zeros(4097)))
            invalid = deepcopy(physical)
            mutate!(invalid["optical_filters"]["h_band"])
            @test_throws ArgumentError IC.validate_declaration(invalid, directory)
        end
        for filters in (["absent"], ["h_band", "h_band"], ["none"], "h_band")
            invalid = deepcopy(physical)
            invalid["optical_paths"]["scc"]["filters"] = filters
            @test_throws ArgumentError IC.validate_declaration(invalid, directory)
        end
        invalid = deepcopy(physical)
        invalid["optical_filters"]["none"] = pop!(invalid["optical_filters"], "h_band")
        @test_throws ArgumentError IC.validate_declaration(invalid, directory)
        @test IC._validate_optical_filters(Dict()) === nothing
    end
end

@testset "per-path spectra and schema-driven cold settings" begin
    mktempdir() do directory
        physical, simulation = optical_spectra_documents(directory)
        path = write_external_optical_documents(directory, physical, simulation)
        declaration = IC.load_simulation_source(path)
        configured = IC.settings(declaration)
        schema = IC.settings_description(declaration, Dict())["schema"]
        @test configured == simulation["defaults"]
        @test !haskey(schema["properties"], "wavelength_um")
        @test "wavelength_um" ∉ schema["required"]
        spectra = schema["properties"]["spectra"]
        @test !spectra["readOnly"]
        @test Set(spectra["required"]) == Set(keys(physical["optical_paths"]))
        for name in ("scc", "llowfs")
            fields = spectra["properties"][name]["properties"]
            @test Set(keys(fields)) == Set(("wavelength_um", "fractional_bandwidth", "samples", "filter"))
            @test fields["filter"]["enum"] == (name == "scc" ? ["h_band"] : ["none"])
        end
        edited = IC.settings(declaration, Dict("spectra" => Dict("scc" => Dict(
            "wavelength_um" => 1.65, "fractional_bandwidth" => 0.2, "samples" => 5))))
        @test edited["spectra"]["scc"]["wavelength_um"] == 1.65
        @test edited["spectra"]["llowfs"] == configured["spectra"]["llowfs"]
        @test declaration.document["defaults"] == simulation["defaults"]
        for geometry in ("resolution", "pupil_resolution", "temperature_c")
            @test schema["properties"][geometry]["readOnly"]
            @test_throws ArgumentError IC.settings(declaration, Dict(geometry => configured[geometry] + 1))
        end
        for mutate! in (
                defaults -> (defaults["wavelength_um"] = 1.55),
                defaults -> delete!(defaults["spectra"], "llowfs"),
                defaults -> (defaults["spectra"]["unknown"] = deepcopy(defaults["spectra"]["scc"])),
                defaults -> (defaults["spectra"]["scc"]["unknown"] = 1),
                defaults -> delete!(defaults["spectra"]["scc"], "filter"),
                defaults -> (defaults["spectra"]["scc"]["wavelength_um"] = 0),
                defaults -> (defaults["spectra"]["scc"]["fractional_bandwidth"] = -0.1),
                defaults -> (defaults["spectra"]["scc"]["fractional_bandwidth"] = 2),
                defaults -> (defaults["spectra"]["scc"]["fractional_bandwidth"] = 0.1),
                defaults -> (defaults["spectra"]["scc"]["samples"] = 65),
                defaults -> (defaults["spectra"]["scc"]["samples"] = 2),
                defaults -> (defaults["spectra"]["scc"]["samples"] = 1.0),
                defaults -> (defaults["spectra"]["scc"]["samples"] = true),
                defaults -> (defaults["spectra"]["scc"]["filter"] = "none"),
                defaults -> (defaults["spectra"]["llowfs"]["filter"] = "h_band"))
            invalid = deepcopy(simulation)
            mutate!(invalid["defaults"])
            write_external_optical_documents(directory, physical, invalid)
            @test_throws ArgumentError IC.load_simulation_source(path)
        end
        nonfinite = deepcopy(simulation["defaults"])
        nonfinite["spectra"]["scc"]["wavelength_um"] = Inf
        @test_throws ArgumentError IC.validate_optical_spectra(nonfinite, physical)
        # Explicit unfiltered paths may also declare an empty installed list.
        physical["optical_paths"]["llowfs"]["filters"] = String[]
        @test IC.validate_optical_spectra(configured, physical) === nothing
        legacy = deepcopy(simulation["defaults"])
        delete!(legacy, "spectra")
        legacy["wavelength_um"] = 1.55
        @test IC.validate_optical_spectra(legacy, physical) === nothing
    end
end

@testset "spectral physical metadata, context and prescription hashes" begin
    mktempdir() do directory
        physical, simulation = optical_spectra_documents(directory; source=false)
        path = write_external_optical_documents(directory, physical, simulation)
        declaration = IC.load_simulation(path)
        configured = IC.settings(declaration)
        # Static baked graphs lack the source recipe required for re-preparation.
        @test declaration.document["settings_schema"]["properties"]["spectra"]["readOnly"]
        @test_throws ArgumentError IC.settings(declaration, Dict("spectra" => Dict("scc" => Dict("wavelength_um" => 1.6))))
        descriptor = IC.physical_definition(declaration.instrument)
        @test descriptor.optical_filters.h_band.transmission == (0.0, 0.8, 0.0)
        scientific = IC.scientific_definition(path)
        @test scientific.spectra.scc.filter == "h_band"
        @test scientific.optical_paths.scc.filters == ("h_band",)
        context = IC.configuration_context(declaration, configured)
        @test context["instrument"]["optical_filters"] == physical["optical_filters"]
        @test context["settings"]["spectra"] == configured["spectra"]
        identity = IC.prescription_identity(declaration, configured)
        physical["optical_filters"]["h_band"]["transmission"][2] = 0.75
        write_external_optical_documents(directory, physical, simulation)
        @test IC.scientific_definition(path).prescription_identity != identity
    end
    @test all(id -> id.name ∉ ("AdaptiveOpticsSim", "Proper", "CUDA", "AMDGPU"), keys(Base.loaded_modules))
end

@testset "measured mask wavelength must cover every selected optical path" begin
    mktempdir() do directory
        physical, simulation = optical_spectra_documents(directory)
        physical["optical_masks"] = Dict("measured" => Dict(port => Dict("phase" => Dict(),
            "wavelength_m" => 1.55e-6) for port in ("transmitted", "reflected")))
        simulation["defaults"]["masks"] = Dict("lyot" => Dict("kind" => "fits", "mask" => "measured"))
        paths = keys(physical["optical_paths"])
        @test length(IC.selected_optical_mask_responses(simulation, physical, paths)) == 2
        for (key, value) in (("wavelength_um", 1.6), ("fractional_bandwidth", 0.1))
            configured = deepcopy(simulation["defaults"])
            configured["spectra"]["llowfs"][key] = value
            configured["spectra"]["llowfs"]["samples"] = key == "fractional_bandwidth" ? 3 : 1
            @test_throws ArgumentError IC.selected_optical_mask_responses(simulation, physical, paths, configured)
        end
        # Only the selected path's Lyot port must match; other ports are unused.
        physical["optical_masks"]["measured"]["reflected"]["wavelength_m"] = 1.6e-6
        @test length(IC.selected_optical_mask_responses(simulation, physical, ("scc",))) == 1
        simulation["defaults"]["masks"] = Dict("apodizer" => Dict("kind" => "fits", "mask" => "measured"))
        configured = deepcopy(simulation["defaults"])
        configured["spectra"]["llowfs"]["wavelength_um"] = 1.6
        @test_throws ArgumentError IC.selected_optical_mask_responses(simulation, physical, paths, configured)
    end
end

@testset "prepared spectra identify their authored Zemax source" begin
    mktempdir() do directory
        physical, authored = optical_spectra_documents(directory)
        write_external_optical_documents(directory, physical, authored)
        _, execution = optical_spectra_documents(directory;source=false)
        execution["instrument"] = "../instrument.yaml"
        execution["optical_model"] = Dict("format"=>"zemax","source"=>"../simulation/definition.yaml")
        mkpath(joinpath(directory,"generated"))
        path = joinpath(directory,"generated","simulation.yaml")
        save(document) = PipeWireAORTC.Common.write_yaml(path,document)
        save(execution)
        declaration = IC.load_simulation(path)
        @test !declaration.document["settings_schema"]["properties"]["spectra"]["readOnly"]
        @test IC.settings(declaration,Dict("spectra"=>Dict("scc"=>Dict("wavelength_um"=>1.6))))["spectra"]["scc"]["wavelength_um"]==1.6
        for model in (Dict("format"=>"other","source"=>"../simulation/definition.yaml"),
                Dict("format"=>"zemax","source"=>"../simulation/definition.yaml","extra"=>1),
                Dict("format"=>"zemax","source"=>joinpath(directory,"simulation","definition.yaml")),
                Dict("format"=>"zemax","source"=>"../instrument.yaml"))
            invalid = deepcopy(execution)
            invalid["optical_model"] = model
            save(invalid)
            @test_throws ArgumentError IC.load_simulation(path)
        end
        save(execution)
        delete!(authored,"preparation")
        PipeWireAORTC.Common.write_yaml(joinpath(directory,"simulation","definition.yaml"),authored)
        @test_throws ArgumentError IC.load_simulation(path)
    end
end
