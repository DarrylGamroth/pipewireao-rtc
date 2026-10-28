using Test, PipeWireAORTC, FITSIO
const IC = PipeWireAORTC.InstrumentConfiguration
Base.include(@__MODULE__, joinpath(@__DIR__, "external_optical_documents.jl"))

function optical_mask_documents(directory)
    physical, simulation = external_optical_documents()
    mkpath(joinpath(directory, "optics"))
    file = joinpath(directory, "optics", "mask.fits")
    amplitude = Float32[0 0.25 0.5; 0.75 1 0.125]
    phase = Float64[0 0.1 -0.2; 0.3 -0.4 0.5]
    FITS(file, "w") do fits
        write(fits, permutedims(amplitude))
        write(fits, permutedims(phase))
    end
    reference(hdu, type) = Dict{String,Any}("path" => "optics/mask.fits",
        "sha256" => PipeWireAORTC.Common.sha256_file(file), "hdu" => hdu,
        "axes" => [2,1], "type" => type, "shape" => [2,3])
    response = Dict{String,Any}("amplitude" => reference(1,"Float32"), "phase" => reference(2,"Float64"),
        "sampling_m" => [2e-6,3e-6], "center_pixel" => [-2.5, 4.25],
        "outside_amplitude" => 0.25, "outside_phase_rad" => 0.5, "wavelength_m" => 1.55e-6)
    physical["optical_masks"] = Dict{String,Any}("measured" => Dict{String,Any}(
        "transmitted" => response, "reflected" => deepcopy(response)))
    physical["optical_paths"] = Dict(name => Dict("sensor" => name, "lyot_stop_port" => port)
        for (name,port) in (("scc","transmitted"),("llowfs","reflected")))
    simulation["settings_schema"] = "proper_optical_train"
    simulation["defaults"]["temperature_c"] = 20
    simulation["defaults"]["masks"] = Dict(role => Dict("kind" => "fits", "mask" => "measured")
        for role in ("apodizer", "focal_plane", "lyot"))
    config = simulation["components"]["optics"]["config"]
    simulation["components"] = Dict()
    for (name,graph) in simulation["graphs"]
        port = physical["optical_paths"][name]["lyot_stop_port"]
        names = [role * "_" * (role == "lyot" ? port : "transmitted") * "_" * field
            for role in ("apodizer", "focal_plane", "lyot") for field in ("amplitude", "phase")]
        graph["nodes"] = [Dict("name" => "optics", "type" => "proper_optical_train_f64",
            "config" => deepcopy(config), "bindings" => Dict(name => name for name in names))]
    end
    return physical, simulation, amplitude, phase
end

@testset "physical FITS mask responses and normal configuration bindings" begin
    mktempdir() do directory
        physical, simulation, amplitude, phase = optical_mask_documents(directory)
        path = write_external_optical_documents(directory, physical, simulation)
        declaration = IC.load_simulation(path)
        configured = IC.settings(declaration)
        descriptor = IC.physical_definition(declaration.instrument)
        @test descriptor.optical_masks.measured.transmitted.center_pixel == (-2.5,4.25)
        @test IC.configuration_context(declaration, configured)["instrument"]["optical_masks"] == physical["optical_masks"]
        names = Set(role * "_" * port * "_" * field for (role,port) in (
            ("apodizer","transmitted"),("focal_plane","transmitted"),("lyot","transmitted"),("lyot","reflected"))
            for field in ("amplitude","phase"))
        @test Set(keys(declaration.document["bindings"])) == union(names, Set(("pupil_opd","pupil_amplitude")))
        @test issubset(names, IC.selected_binding_names(declaration,configured))
        @test IC.binding_values(declaration, configured, declaration.document["bindings"]["apodizer_transmitted_amplitude"]) == amplitude
        @test IC.binding_values(declaration, configured, declaration.document["bindings"]["lyot_reflected_phase"]) == phase
        @test "optics/mask.fits" in IC.artifact_paths(declaration, configured)
        identity = IC.prescription_identity(declaration, configured)
        @test IC.scientific_definition(path).optical_masks == descriptor.optical_masks
        @test_throws ArgumentError IC.settings(declaration, Dict("masks" => Dict("focal_plane" => Dict("radius_m" => 1e-4))))
        # Wavelength matching also applies to application-local editable schemas.
        editable = merge(declaration, (;document=deepcopy(declaration.document)))
        editable.document["settings_schema"]["properties"]["wavelength_um"]["readOnly"] = false
        @test_throws ArgumentError IC.settings(editable, Dict("wavelength_um" => 1.6))
        editable.document["settings_schema"]["properties"]["masks"]["readOnly"] = false
        @test_throws ArgumentError IC.settings(editable, Dict("masks" => Dict("focal_plane" => Dict("radius_m" => 1e-4))))
        # A selected path requires only its own Lyot port.
        delete!(simulation["graphs"], "llowfs")
        write_external_optical_documents(directory, physical, simulation)
        selected = IC.load_simulation(path)
        @test !haskey(selected.document["bindings"], "lyot_reflected_amplitude")
        @test IC.prescription_identity(selected, IC.settings(selected)) != identity
        # Revalidate the bytes captured for binding preparation after cold loading.
        FITS(joinpath(directory, "optics", "mask.fits"), "w") do fits
            write(fits, fill(Float32(0.5), 3, 2))
        end
        @test_throws ArgumentError IC.binding_values(declaration, configured, declaration.document["bindings"]["apodizer_transmitted_amplitude"])
        @test IC.prescription_identity(declaration, configured) != identity
        @test_throws ArgumentError IC.load(joinpath(directory,"instrument.yaml"))
    end
    @test all(id -> id.name ∉ ("AdaptiveOpticsSim", "AdaptiveOpticsSimPipeWireHIL", "CUDA", "AMDGPU"), keys(Base.loaded_modules))
end

@testset "strict physical mask declarations and FITS snapshots" begin
    mktempdir() do directory
        physical, simulation = optical_mask_documents(directory)
        for mutate! in (
                mask -> empty!(mask),
                mask -> (mask["unknown"] = 1),
                mask -> (mask["other"] = deepcopy(mask["transmitted"])),
                mask -> delete!(mask["transmitted"], "outside_phase_rad"),
                mask -> delete!(mask["transmitted"], "wavelength_m"),
                mask -> (mask["transmitted"]["sampling_m"] = [1,0]),
                mask -> (mask["transmitted"]["center_pixel"] = [Inf,1]),
                mask -> (mask["transmitted"]["outside_amplitude"] = 1.1),
                mask -> (mask["transmitted"]["outside_phase_rad"] = Inf),
                mask -> (mask["transmitted"]["amplitude"]["path"] = "optics/../optics/mask.fits"),
                mask -> (mask["transmitted"]["amplitude"]["sha256"] = "0"^64),
                mask -> (mask["transmitted"]["amplitude"]["hdu"] = 3),
                mask -> (mask["transmitted"]["amplitude"]["axes"] = [1,2]),
                mask -> (mask["transmitted"]["amplitude"]["type"] = "UInt16"),
                mask -> (mask["transmitted"]["amplitude"]["shape"] = [2,2]),
                mask -> (mask["transmitted"]["phase"]["shape"] = [2,2]))
            invalid = deepcopy(physical)
            mutate!(invalid["optical_masks"]["measured"])
            @test_throws Union{ArgumentError,DimensionMismatch} IC.validate_declaration(invalid,directory)
        end
        for values in (fill(Float32(1.1),3,2), fill(Float32(-0.1),3,2), fill(Float32(NaN),3,2))
            file = joinpath(directory,"optics","mask.fits")
            FITS(file,"w") do fits
                write(fits,values)
            end
            invalid = deepcopy(physical)
            invalid["optical_masks"]["measured"] = Dict("transmitted" => invalid["optical_masks"]["measured"]["transmitted"])
            response = invalid["optical_masks"]["measured"]["transmitted"]
            delete!(response,"phase")
            response["amplitude"]["sha256"] = PipeWireAORTC.Common.sha256_file(file)
            write_external_optical_documents(directory,invalid,simulation)
            @test_throws ArgumentError IC.load(joinpath(directory,"instrument.yaml"))
        end
        for key in ("BLANK", "ZIMAGE")
            physical, simulation = optical_mask_documents(directory)
            file = joinpath(directory,"optics","mask.fits")
            FITS(file,"r+") do fits
                write_key(fits[1], key, key == "BLANK" ? -32768 : true)
            end
            for response in values(physical["optical_masks"]["measured"]), field in ("amplitude","phase")
                response[field]["sha256"] = PipeWireAORTC.Common.sha256_file(file)
            end
            write_external_optical_documents(directory,physical,simulation)
            @test_throws ArgumentError IC.load(joinpath(directory,"instrument.yaml"))
        end
        physical, simulation = optical_mask_documents(directory)
        mktempdir() do outside
            outside_file = joinpath(outside,"mask.fits")
            cp(joinpath(directory,"optics","mask.fits"), outside_file)
            symlink(outside_file,joinpath(directory,"optics","escape.fits"))
            physical["optical_masks"]["measured"]["transmitted"]["amplitude"]["path"] = "optics/escape.fits"
            write_external_optical_documents(directory,physical,simulation)
            @test_throws PipeWireAORTC.DeploymentConfiguration.DeploymentError IC.load(joinpath(directory,"instrument.yaml"))
        end
        symlink("mask.fits",joinpath(directory,"optics","contained.fits"))
        response = physical["optical_masks"]["measured"]["transmitted"]
        response["amplitude"]["path"] = "optics/contained.fits"
        delete!(response,"phase")
        delete!(response,"wavelength_m")
        write_external_optical_documents(directory,physical,simulation)
        @test IC.load(joinpath(directory,"instrument.yaml")).document["optical_masks"] == physical["optical_masks"]
    end
end

@testset "mask selections and optional shared settings" begin
    mktempdir() do directory
        physical, simulation = optical_mask_documents(directory)
        for mutate! in (
                document -> (document["defaults"]["masks"]["apodizer"]["mask"] = "missing"),
                document -> (document["defaults"]["wavelength_um"] = 1.6),
                document -> delete!(document["graphs"], "scc"))
            invalid = deepcopy(simulation)
            mutate!(invalid)
            if haskey(invalid["graphs"],"scc")
                path = write_external_optical_documents(directory,physical,invalid)
                @test_throws ArgumentError IC.load_simulation(path)
            else
                delete!(physical["optical_masks"]["measured"],"reflected")
                path = write_external_optical_documents(directory,physical,invalid)
                @test_throws ArgumentError IC.load_simulation(path)
            end
        end
        schema = IC.resolve_settings_schema("proper_optical_train")
        defaults = Dict{String,Any}("profile" => "reference", "resolution" => 8,
            "pupil_resolution" => 4, "wavelength_um" => 1.55, "temperature_c" => 20)
        @test IC.validate_settings(schema,defaults,defaults) === nothing
        ideal = Dict{String,Any}("focal_plane" => Dict{String,Any}("radius_m" => 1e-4),
            "lyot" => Dict("circles" => [Dict("radius_m" => 1e-3,"x_m" => 0,"y_m" => 0)]))
        defaults["masks"] = ideal
        @test IC.validate_settings(schema,defaults,defaults) === nothing
        ideal["apodizer"] = Dict("kind" => "unity")
        ideal["focal_plane"]["kind"] = "ideal"
        @test IC.validate_settings(schema,defaults,defaults) === nothing
        for mutate! in (
                masks -> (masks["focal_plane"]["unknown"] = 1),
                masks -> (masks["lyot"]["circles"][1]["radius_m"] = 0),
                masks -> (masks["focal_plane"] = Dict("kind" => "fits","mask" => "measured","radius_m" => 1)),
                masks -> (masks["apodizer"] = Dict("kind" => "unknown")))
            invalid = deepcopy(defaults)
            mutate!(invalid["masks"])
            @test_throws ArgumentError IC.validate_settings(schema,invalid,invalid)
        end
        # Local application schemas can still declare editable mask values.
        custom = Dict("template" => "proper_optical_train", "properties" => Dict("masks" => Dict(
            "type" => "object", "properties" => Dict("focal_plane" => Dict("type" => "object",
                "properties" => Dict("radius_m" => Dict("type" => "number", "exclusiveMinimum" => 0)))))))
        editable = IC.resolve_settings_schema(custom)
        defaults["masks"] = Dict("focal_plane" => Dict("radius_m" => 1e-4))
        changed = IC.merge_settings(defaults,Dict("masks" => Dict("focal_plane" => Dict("radius_m" => 2e-4))),editable)
        @test IC.validate_settings(editable,changed,defaults) === nothing
        @test changed["masks"]["focal_plane"]["radius_m"] == 2e-4
        optional = Dict("type" => "object", "required" => String[], "properties" => Dict(
            "fixed" => Dict("type" => "number", "readOnly" => true),
            "editable" => Dict("type" => "number")))
        @test_throws ArgumentError IC.validate_settings(optional,Dict(),Dict("fixed" => 1))
        @test_throws ArgumentError IC.validate_settings(optional,Dict("fixed" => 2),Dict())
        @test IC.validate_settings(optional,Dict("editable" => 2),Dict()) === nothing
        @test IC.validate_settings(optional,Dict(),Dict("editable" => 1)) === nothing
        nested = Dict("type" => "object", "required" => String[], "properties" => Dict("nested" => optional))
        @test_throws ArgumentError IC.validate_settings(nested,Dict(),Dict("nested" => Dict("fixed" => 1)))
        @test_throws ArgumentError IC.validate_settings(nested,Dict("nested" => Dict("fixed" => 2)),Dict())
        @test IC.validate_settings(nested,Dict("nested" => Dict("editable" => 2)),Dict()) === nothing
        fixed = Dict("type" => "object", "properties" => Dict(
            "kind" => Dict("type" => "string", "enum" => ["fixed"]),
            "value" => Dict("type" => "number", "readOnly" => true),
            "gain" => Dict("type" => "number")))
        other = Dict("type" => "object", "properties" => Dict(
            "kind" => Dict("type" => "string", "enum" => ["editable"]),
            "other" => Dict("type" => "number")))
        alternatives = Dict("oneOf" => [fixed,other])
        original = Dict{String,Any}("kind" => "fixed", "value" => 1, "gain" => 1)
        updated = Dict{String,Any}("kind" => "editable", "other" => 2)
        @test_throws ArgumentError IC.validate_settings(alternatives,updated,original)
        @test_throws ArgumentError IC.validate_settings(alternatives,original,updated)
        editable_alternatives = deepcopy(alternatives)
        editable_alternatives["oneOf"][1]["properties"]["value"]["readOnly"] = false
        @test IC.validate_settings(editable_alternatives,updated,original) === nothing
        @test IC.validate_settings(alternatives,merge(original,Dict("gain" => 2)),original) === nothing
    end
end

@testset "authored source validates FITS masks against physical optical paths" begin
    mktempdir() do directory
        physical, simulation = optical_mask_documents(directory)
        # Physical path identifiers need not equal any execution graph names.
        paths = physical["optical_paths"]
        physical["optical_paths"] = Dict("science" => paths["scc"], "low_order" => paths["llowfs"])
        prescription = joinpath(directory, "optics", "instrument.zmx")
        write(prescription, "Authored source before Zemax preparation\n")
        physical["optical_prescription"] = Dict("format" => "zemax", "path" => "optics/instrument.zmx",
            "sha256" => PipeWireAORTC.Common.sha256_file(prescription))
        mkpath(joinpath(directory, "simulation"))
        write(joinpath(directory, "simulation", "zemax.yaml"), "schema_version: 1\n")
        simulation["preparation"] = Dict("kind" => "zemax", "recipe" => "zemax.yaml")
        delete!(simulation, "graphs")
        path = write_external_optical_documents(directory, physical, simulation)
        source = IC.load_simulation_source(path)
        @test IC.settings(source) == simulation["defaults"]
        @test !hasproperty(source, :graphs)
        @test Set(keys(source.document["bindings"])) == Set(("pupil_opd", "pupil_amplitude"))
        @test Set(port for (role, port, _) in IC.selected_optical_mask_responses(
            source.document, physical, keys(physical["optical_paths"])) if role == "lyot") == Set(("transmitted", "reflected"))
        @test !ispath(joinpath(directory, "generated"))
        delete!(physical["optical_masks"]["measured"], "reflected")
        write_external_optical_documents(directory, physical, simulation)
        @test_throws ArgumentError IC.load_simulation_source(path)
    end
end

@testset "Lyot-mask routing excludes validated observation graphs" begin
    mktempdir() do directory
        physical, simulation = optical_mask_documents(directory)
        mkpath(joinpath(directory,"simulation"))
        authored_response!(directory,physical,simulation)
        simulation["observations"]["llowfs"] = pop!(simulation["observations"],"low_order")
        simulation["observations"]["llowfs"]["graph"] = "llowfs_response"
        simulation["graphs"] = Dict{String,Any}(simulation["graphs"])
        simulation["graphs"]["llowfs_response"] = "simulation/low_order_response.yaml"
        path = write_external_optical_documents(directory,physical,simulation)
        declaration = IC.load_simulation(path)
        @test IC.settings(declaration) == simulation["defaults"]
        @test haskey(declaration.document["bindings"],"lyot_reflected_amplitude")
        @test Set(IC.optical_graph_names(declaration.document,physical,keys(declaration.graphs))) == Set(["scc","llowfs"])
        for mutate! in (
            doc->(doc["observations"]["llowfs"]["graph"]="absent"),
            doc->(doc["observations"]["llowfs"]["graph"]="scc"),
            doc->delete!(doc,"observations"))
            invalid=deepcopy(simulation)
            mutate!(invalid)
            write_external_optical_documents(directory,physical,invalid)
            @test_throws ArgumentError IC.load_simulation(path)
        end
    end
end
