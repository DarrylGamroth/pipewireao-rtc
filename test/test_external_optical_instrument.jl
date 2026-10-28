using Test, PipeWireAORTC
const IC = PipeWireAORTC.InstrumentConfiguration
Base.include(@__MODULE__, joinpath(@__DIR__, "external_optical_documents.jl"))

function optical_reference_documents(directory)
    physical, simulation = external_optical_documents()
    mkpath(joinpath(directory, "optics"))
    prescription = joinpath(directory, "optics", "instrument.zmx")
    catalog = joinpath(directory, "optics", "catalog.zip")
    write(prescription, "Authored optical prescription test input\n")
    write(catalog, "Authored optical catalog test input\n")
    physical["optical_prescription"] = Dict{String,Any}("format" => "zemax",
        "path" => "optics/instrument.zmx", "sha256" => PipeWireAORTC.Common.sha256_file(prescription),
        "catalog_archive" => Dict("path" => "optics/catalog.zip", "sha256" => PipeWireAORTC.Common.sha256_file(catalog)))
    physical["optical_paths"] = Dict{String,Any}(
        "science" => Dict("sensor" => "scc", "lyot_stop_port" => "transmitted"),
        "low_order" => Dict("sensor" => "llowfs", "lyot_stop_port" => "reflected"))
    return physical, simulation
end

function pupil_output_documents()
    physical, simulation = external_optical_documents()
    physical["optical_output"] = deepcopy(physical["optical_input"])
    simulation["pupil_output"] = Dict{String,Any}("opd" => "pupil_opd", "amplitude" => "pupil_amplitude")
    simulation["components"] = Dict()
    simulation["bindings"]["pupil_amplitude"] = Dict("kind" => "pupil_amplitude",
        "resolution" => "pupil_resolution", "type" => "Float32")
    simulation["bindings"]["pupil_opd"]["type"] = "Float32"
    config = Dict("resolution" => Dict("\$ref" => "/settings/pupil_resolution"),
        "pupil_opd_schema" => "example.pupil-opd/1", "uncompensated_opd_schema" => "example.pupil-opd/1",
        "surface_opd_schema" => "example.pupil-opd/1")
    graph = Dict("schema_version" => 1, "name" => "pupil_output_test",
        "nodes" => [Dict("name" => "composition", "type" => "pupil_opd_composition_f32", "config" => config)],
        "inputs" => [Dict("name" => "upstream", "binding" => "pupil_opd", "destination" => "composition.uncompensated_opd"),
            Dict("name" => "mirror", "binding" => "pupil_opd", "destination" => "composition.surface_opd")],
        "outputs" => [Dict("name" => "pupil_opd", "source" => "composition.pupil_opd")])
    simulation["graphs"] = Dict("production" => graph, "diagnostic" => deepcopy(graph))
    only(simulation["graphs"]["diagnostic"]["outputs"])["name"] = "diagnostic_opd"
    return physical, simulation
end

@testset "nominal pupil publication resolves cold physical and graph declarations" begin
    mktempdir() do directory
        physical, simulation = pupil_output_documents()
        declaration = IC.load_simulation(write_external_optical_documents(directory, physical, simulation))
        configured = IC.settings(declaration)
        output = IC.pupil_output(declaration, configured)
        @test output == (; opd=:pupil_opd, amplitude=:pupil_amplitude,
            optical=physical["optical_output"], pupil_resolution=4)
        @test IC.pupil_output(declaration, IC.settings(declaration, (; pupil_resolution=12))).pupil_resolution == 12
        @test IC.physical_definition(declaration.instrument).optical_output == IC._instrument_seal(physical["optical_output"])
        output.optical["diameter_m"] = 0.1
        @test declaration.instrument.document["optical_output"]["diameter_m"] == 0.012
        @test_throws ArgumentError IC.pupil_output(declaration, configured; simulation_graph="missing")
        @test_throws ArgumentError IC.pupil_output(declaration, configured; simulation_graph="diagnostic")
        # Select the authored OPD name exactly; diagnostic synonyms do not match.
        declaration.document["pupil_output"]["opd"] = "diagnostic_opd"
        @test IC.pupil_output(declaration, configured; simulation_graph="diagnostic").opd == :diagnostic_opd
        declaration.document["pupil_output"]["opd"] = "pupil_opd"
        for binding in (Dict("kind" => "zeros", "shape" => [4,4], "type" => "Float32"),
                Dict("kind" => "pupil_amplitude", "resolution" => 4, "type" => "Float64"),
                Dict("kind" => "pupil_amplitude", "resolution" => 5, "type" => "Float32"))
            declaration.document["bindings"]["pupil_amplitude"] = binding
            @test_throws ArgumentError IC.pupil_output(declaration, configured)
        end
        delete!(declaration.document["bindings"], "pupil_amplitude")
        @test_throws ArgumentError IC.pupil_output(declaration, configured)
        delete!(declaration.document, "pupil_output")
        @test IC.pupil_output(declaration, configured) === nothing
    end
    @test all(id -> id.name ∉ ("AdaptiveOpticsSim", "AdaptiveOpticsSimPipeWireHIL", "Proper", "CUDA", "AMDGPU"), keys(Base.loaded_modules))
end

@testset "pupil output rejects unsupported physical and publication contracts" begin
    mktempdir() do directory
        physical, simulation = pupil_output_documents()
        for mutate! in (
                spec -> (spec["curvature"] = "converging"),
                spec -> (spec["diameter_m"] = 0),
                spec -> (spec["registration"] = ""),
                spec -> (spec["unknown"] = true),
                spec -> delete!(spec, "plane"))
            invalid = deepcopy(physical)
            mutate!(invalid["optical_output"])
            @test_throws ArgumentError IC.load_simulation(write_external_optical_documents(directory, invalid, simulation))
        end
        for mutate! in (
                spec -> (spec["opd"] = ""),
                spec -> (spec["unknown"] = true),
                spec -> delete!(spec, "amplitude"))
            invalid = deepcopy(simulation)
            mutate!(invalid["pupil_output"])
            @test_throws ArgumentError IC.load_simulation(write_external_optical_documents(directory, physical, invalid))
        end
        delete!(physical, "optical_output")
        @test_throws ArgumentError IC.load_simulation(write_external_optical_documents(directory, physical, simulation))
    end
end

@testset "physical prescription references and optical paths are cold shared metadata" begin
    mktempdir() do directory
        physical, simulation = optical_reference_documents(directory)
        path = write_external_optical_documents(directory, physical, simulation)
        declaration = IC.load_simulation(path)
        configured = IC.settings(declaration)
        descriptor = IC.physical_definition(declaration.instrument)
        @test descriptor.optical_prescription.format == "zemax"
        @test descriptor.optical_prescription.path == "optics/instrument.zmx"
        @test descriptor.optical_prescription.sha256 == physical["optical_prescription"]["sha256"]
        @test descriptor.optical_prescription.catalog_archive.path == "optics/catalog.zip"
        @test descriptor.optical_paths.science == (; sensor="scc", lyot_stop_port="transmitted")
        @test descriptor.optical_paths.low_order == (; sensor="llowfs", lyot_stop_port="reflected")
        scientific = IC.scientific_definition(path)
        @test scientific.optical_prescription == descriptor.optical_prescription
        @test scientific.optical_paths == descriptor.optical_paths
        context = IC.configuration_context(declaration, configured)
        @test context["instrument"]["optical_prescription"] == physical["optical_prescription"]
        @test context["instrument"]["optical_paths"] == physical["optical_paths"]
        @test Set(IC.artifact_paths(declaration, configured)) == Set(("optics/instrument.zmx", "optics/catalog.zip"))
        mktempdir() do output
            destination = joinpath(output, "application")
            PipeWireAORTC.InstrumentExport.copy_source(directory, destination; runtime_configurations=false)
            copied = IC.load(joinpath(destination, "instrument.yaml"))
            @test IC.physical_definition(copied) == descriptor
            @test read(joinpath(destination, "optics", "instrument.zmx")) == read(joinpath(directory, "optics", "instrument.zmx"))
            @test read(joinpath(destination, "optics", "catalog.zip")) == read(joinpath(directory, "optics", "catalog.zip"))
        end
        reference = Dict("\$ref" => "/instrument/optical_paths/science/lyot_stop_port")
        @test PipeWireAORTC.Common.configuration_value(reference, context) == "transmitted"
        reference["\$ref"] = "/instrument/optical_paths/missing/lyot_stop_port"
        @test_throws ArgumentError PipeWireAORTC.Common.configuration_value(reference, context)
        delete!(physical["optical_prescription"], "catalog_archive")
        write_external_optical_documents(directory, physical, external_optical_documents()[2])
        @test !hasproperty(IC.physical_definition(IC.load(joinpath(directory, "instrument.yaml"))).optical_prescription, :catalog_archive)
    end
    @test all(id -> id.name ∉ ("AdaptiveOpticsSim", "AdaptiveOpticsSimPipeWireHIL", "CUDA", "AMDGPU"), keys(Base.loaded_modules))
end

@testset "optical reference hashes bind current source bytes" begin
    for asset in ("instrument.zmx", "catalog.zip")
        mktempdir() do directory
            physical, simulation = optical_reference_documents(directory)
            path = write_external_optical_documents(directory, physical, simulation)
            declaration = IC.load_simulation(path)
            configured = IC.settings(declaration)
            identity = IC.prescription_identity(declaration, configured)
            write(joinpath(directory, "optics", asset), "Changed optical input\n")
            @test IC.prescription_identity(declaration, configured) != identity
            @test_throws ArgumentError IC.load(joinpath(directory, "instrument.yaml"))
            reference = asset == "instrument.zmx" ? physical["optical_prescription"] : physical["optical_prescription"]["catalog_archive"]
            reference["sha256"] = PipeWireAORTC.Common.sha256_file(joinpath(directory, "optics", asset))
            write_external_optical_documents(directory, physical, simulation)
            @test IC.scientific_definition(path).prescription_identity != identity
        end
    end
end

@testset "physical optical declarations reject unsupported references and routing" begin
    mktempdir() do directory
        physical, simulation = optical_reference_documents(directory)
        for mutate! in (
                document -> (document["optical_prescription"]["format"] = "unknown"),
                document -> (document["optical_prescription"]["sha256"] = uppercase(document["optical_prescription"]["sha256"])),
                document -> (document["optical_prescription"]["sha256"] = "0"^64),
                document -> (document["optical_prescription"]["path"] = "optics/../optics/instrument.zmx"),
                document -> (document["optical_prescription"]["path"] = "../instrument.zmx"),
                document -> (document["optical_prescription"]["path"] = joinpath(directory, "optics", "instrument.zmx")),
                document -> (document["optical_prescription"]["path"] = "optics/missing.zmx"),
                document -> (document["optical_prescription"]["model"] = "unknown"),
                document -> delete!(document["optical_prescription"], "format"),
                document -> (document["optical_prescription"]["catalog_archive"]["format"] = "zip"),
                document -> (document["optical_prescription"]["catalog_archive"]["sha256"] = "short"),
                document -> (document["optical_prescription"]["catalog_archive"]["path"] = "../catalog.zip"),
                document -> (document["optical_paths"] = Dict()),
                document -> (document["optical_paths"]["science"]["sensor"] = "unknown"),
                document -> (document["optical_paths"]["science"]["sensor"] = "llowfs"),
                document -> (document["optical_paths"]["science"]["lyot_stop_port"] = "unknown"),
                document -> (document["optical_paths"]["science"]["graph"] = "scc"),
                document -> delete!(document["optical_paths"]["science"], "lyot_stop_port"),
                document -> (document["optical_paths"]["Invalid"] = pop!(document["optical_paths"], "science")))
            invalid = deepcopy(physical)
            mutate!(invalid)
            write_external_optical_documents(directory, invalid, simulation)
            @test_throws ArgumentError IC.load(joinpath(directory, "instrument.yaml"))
        end
        mktempdir() do outside
            outside_file = joinpath(outside, "instrument.zmx")
            cp(joinpath(directory, "optics", "instrument.zmx"), outside_file)
            symlink(outside_file, joinpath(directory, "optics", "escape.zmx"))
            physical["optical_prescription"]["path"] = "optics/escape.zmx"
            write_external_optical_documents(directory, physical, simulation)
            @test_throws PipeWireAORTC.DeploymentConfiguration.DeploymentError IC.load(joinpath(directory, "instrument.yaml"))
        end
        symlink("instrument.zmx", joinpath(directory, "optics", "contained.zmx"))
        physical["optical_prescription"]["path"] = "optics/contained.zmx"
        write_external_optical_documents(directory, physical, simulation)
        @test IC.load(joinpath(directory, "instrument.yaml")).document["optical_prescription"]["path"] == "optics/contained.zmx"
    end
end

@testset "mirror-free optical plants use shared instrument declarations" begin
    mktempdir() do directory
        physical, simulation = external_optical_documents()
        path = write_external_optical_documents(directory, physical, simulation)
        declaration = IC.load_simulation(path)
        configured = IC.settings(declaration)
        @test isempty(declaration.instrument.document["deformable_mirrors"])
        @test Set(keys(declaration.graphs)) == Set(("scc", "llowfs"))
        @test declaration.templates == ("proper_optical_train_f64",)
        @test !haskey(declaration.document, "hil")
        @test !haskey(declaration.document, "wire_contracts")
        @test_throws ArgumentError IC.graph_document(declaration, configured)
        @test_throws ArgumentError IC.graph_document(declaration, configured; calibration=true)
        graph = IC.graph_document(declaration, configured; simulation_graph="scc")
        config = only(graph["nodes"])["config"]
        @test only(graph["nodes"])["type"] == "proper_optical_train_f64"
        @test config["resolution"] == configured["resolution"]
        @test config["diameter_m"] == physical["optical_input"]["diameter_m"]
        @test config["steps"] == simulation["components"]["optics"]["config"]["steps"]
        @test IC.configuration_context(declaration, configured)["instrument"]["wavefront_sensors"]["scc"] == physical["wavefront_sensors"]["scc"]
        @test size(IC.binding_values(declaration, configured, declaration.document["bindings"]["pupil_opd"])) == (4,4)
        @test_throws ArgumentError IC.settings(declaration, Dict("invented" => 1))
        @test_throws ArgumentError IC.settings(declaration, Dict("resolution" => 0))
        metadata = IC.scientific_definition(path)
        @test isempty(metadata.deformable_mirrors)
        @test metadata.optical_input.diameter_m == 0.012
        @test metadata.wavefront_sensors.scc.layout.detector.name == "SAPHIRA"
        @test metadata.wavefront_sensors.llowfs.layout.detector.name == "CRED2"
        @test !hasproperty(metadata.wavefront_sensors.llowfs.layout, :detector_shape)
        @test occursin(r"^sha256:[0-9a-f]{64}$", metadata.prescription_identity)
        for mutate! in (
                document -> (document["graphs"] = Dict()),
                document -> (document["graphs"]["../escape"] = first(values(document["graphs"]))),
                document -> (document["unknown"] = true),
                document -> (document["hil"] = Dict("command_input" => "pupil_opd", "frame_output" => "intensity")),
                document -> (document["wire_contracts"] = Any[]),
                document -> (document["components"]["unused"] = deepcopy(document["components"]["optics"])),
                document -> (document["components"]["optics"]["config"]["invented"] = 1),
                document -> delete!(document["components"]["optics"]["config"], "steps"))
            invalid = deepcopy(simulation)
            mutate!(invalid)
            write_external_optical_documents(directory, physical, invalid)
            @test_throws ArgumentError IC.load_simulation(path)
        end
    end
end

@testset "HIL and RTC control retain mirror and graph requirements" begin
    mktempdir() do directory
        physical, simulation = external_optical_documents()
        wire = Dict("frame_encoding" => "float32", "frame_schema" => "example.frame/1",
            "command_schema" => "example.command/1", "command_scale" => 1.0)
        simulation["hil"] = Dict("command_input" => "pupil_opd", "frame_output" => "intensity")
        simulation["wire_contracts"] = [wire]
        path = write_external_optical_documents(directory, physical, simulation)
        @test_throws ArgumentError IC.load_simulation(path) # HIL still requires production/calibration.
        graph = first(values(simulation["graphs"]))
        simulation["graphs"] = Dict("production" => graph, "calibration" => deepcopy(graph))
        write_external_optical_documents(directory, physical, simulation)
        exception = try IC.load_simulation(path); nothing catch error; error end
        @test exception isa ArgumentError
        @test occursin("mirrors", sprint(showerror, exception))
        mkpath(joinpath(directory, "rtc"))
        rtc = Dict("schema_version" => 1, "instrument" => "../instrument.yaml", "dimensions" => Dict(),
            "mirror_controls" => "rtc/mirror-controls.yaml", "publication" => "instrument.json", "calibration_identity" => "example")
        rtc_path = joinpath(directory, "rtc", "configuration.yaml")
        PipeWireAORTC.Common.write_yaml(rtc_path, rtc)
        exception = try IC.load_rtc(rtc_path); nothing catch error; error end
        @test exception isa ArgumentError
        @test occursin("at least one deformable mirror", sprint(showerror, exception))
    end
end

@testset "physical optical identities reject unqualified detector geometry" begin
    mktempdir() do directory
        physical, simulation = external_optical_documents()
        for mutate! in (
                document -> (document["optical_input"]["diameter_m"] = 0),
                document -> (document["optical_input"]["curvature"] = "unknown"),
                document -> (document["optical_input"]["zemax_surface"] = 1),
                document -> (document["wavefront_sensors"]["scc"]["configuration_id"] = 3),
                document -> (document["wavefront_sensors"]["llowfs"]["detector_surface"] = 120),
                document -> (document["wavefront_sensors"]["scc"]["detector"]["pixels"] = [1,1]),
                document -> (document["wavefront_sensors"]["scc"]["detector"]["controller"] = ""),
                document -> (document["wavefront_sensors"]["scc"]["detector_shape"] = [1,1]),
                document -> delete!(document["wavefront_sensors"]["llowfs"], "kind"),
                document -> delete!(document["wavefront_sensors"]["llowfs"]["detector"], "name"))
            invalid = deepcopy(physical)
            mutate!(invalid)
            write_external_optical_documents(directory, invalid, simulation)
            @test_throws ArgumentError IC.load(joinpath(directory, "instrument.yaml"))
        end
    end
end

@testset "physical detector controller identity is retained" begin
    mktempdir() do directory
        physical, simulation = external_optical_documents()
        physical["wavefront_sensors"]["scc"]["detector"]["controller"] = "NRC-HAA HIAC"
        path = write_external_optical_documents(directory, physical, simulation)
        @test IC.scientific_definition(path).wavefront_sensors.scc.layout.detector.controller == "NRC-HAA HIAC"
    end
end

@testset "optical sensor acquisition uses shared seconds normalization" begin
    mktempdir() do directory
        physical, simulation = external_optical_documents()
        for name in ("scc", "llowfs")
            physical["wavefront_sensors"][name]["acquisition"] = Dict{String,Any}("exposure_duration_s" => 0.001234567)
            physical["wavefront_sensors"][name]["expected_schema"] = "example.$name/1"
        end
        physical["wavefront_sensors"]["llowfs"]["acquisition"]["roi_origin"] = [2,3]
        path = write_external_optical_documents(directory, physical, simulation)
        declaration = IC.load_simulation(path)
        context = IC.configuration_context(declaration, IC.settings(declaration))
        @test context["simulation"]["frame_period_ns"] == UInt64(2_000_000)
        @test context["simulation"]["rate"] == 500
        for name in ("scc", "llowfs")
            sensor = context["instrument"]["wavefront_sensors"][name]
            @test sensor["expected_schema"] == "example.$name/1"
            @test sensor["acquisition"]["exposure_duration_s"] == 0.001234567
            @test sensor["acquisition"]["exposure_ns"] == UInt64(1234567)
            @test sensor["acquisition"]["exposure_us"] ≈ 1234.567
        end
        @test !haskey(context["instrument"]["wavefront_sensors"]["scc"]["acquisition"], "roi_origin")
        @test context["instrument"]["wavefront_sensors"]["llowfs"]["acquisition"]["roi_origin"] == [2,3]
        @test !haskey(declaration.instrument.document["wavefront_sensors"]["scc"]["acquisition"], "exposure_ns")
        for name in ("scc", "llowfs"), invalid_acquisition in (
                Dict("roi_origin" => [0,0]),
                Dict("exposure_duration_s" => 0),
                Dict("exposure_duration_s" => true),
                Dict("exposure_duration_s" => 1e-10),
                Dict("exposure_duration_s" => 0.002, "exposure_ns" => 2_000_000),
                Dict("exposure_duration_s" => 0.002, "unknown" => 1),
                Dict("exposure_duration_s" => 0.002, "roi_origin" => [-1,0]),
                Dict("exposure_duration_s" => 0.002, "roi_origin" => Any[true,0]),
                Dict("exposure_duration_s" => 0.002, "roi_origin" => [0]),
                Dict("exposure_duration_s" => 0.002, "roi_origin" => [Int64(typemax(Int32)) + 1,0]))
            invalid = deepcopy(physical)
            invalid["wavefront_sensors"][name]["acquisition"] = invalid_acquisition
            write_external_optical_documents(directory, invalid, simulation)
            @test_throws ArgumentError IC.load(joinpath(directory, "instrument.yaml"))
        end
        invalid = deepcopy(physical)
        invalid["wavefront_sensors"]["scc"]["acquisition"]["exposure_duration_s"] = Inf
        @test_throws ArgumentError IC.validate_declaration(invalid, directory)
        invalid = deepcopy(physical)
        invalid["wavefront_sensors"]["scc"]["expected_schema"] = ""
        write_external_optical_documents(directory, invalid, simulation)
        @test_throws ArgumentError IC.load(joinpath(directory, "instrument.yaml"))
    end
end

@testset "shared InGaAs template uses existing complete detector factory" begin
    config = Dict("rows" => 4, "columns" => 6, "pixel_sampling_m" => [15e-6,15e-6],
        "spectral_channel" => "h", "exposure_duration_s" => 0.002, "quantum_efficiency" => 0.8,
        "rng_seed" => 42, "photon_rate_schema" => "example.rate/1", "frame_schema" => "example.frame/1")
    selection = Dict("template" => "ingaas", "config" => config)
    node = IC.component_node("camera", selection, "ingaas", Set{String}())
    @test node["type"] == "detector"
    @test node["detector"] == "ingaas"
    @test node["config"] == config
    @test_throws ArgumentError IC.component_template_path("hgcdte")
end

@testset "shared optical settings schema remains extensible and strict" begin
    mktempdir() do directory
        physical, simulation = external_optical_documents()
        simulation["defaults"]["temperature_c"] = 20
        simulation["defaults"]["masks"] = Dict("radius_m" => 0.001)
        simulation["settings_schema"] = Dict("template" => "proper_optical_train", "title" => "Optical test",
            "properties" => Dict("masks" => Dict("type" => "object", "additionalProperties" => false,
                "required" => ["radius_m"], "properties" => Dict("radius_m" => Dict("type" => "number", "exclusiveMinimum" => 0)))))
        path = write_external_optical_documents(directory, physical, simulation)
        declaration = IC.load_simulation(path)
        @test IC.settings(declaration)["temperature_c"] == 20
        @test declaration.document["settings_schema"]["title"] == "Optical test"
        @test declaration.document["settings_schema"]["additionalProperties"] === false
        @test declaration.document["settings_schema"]["properties"]["profile"]["enum"] == ["reference"]
        @test Set(IC.simulation_catalog_identities(declaration.authoring) |> keys) == Set(["proper_optical_train"])
        @test_throws ArgumentError IC.settings(declaration, Dict("wavelength_um" => 2.0))
        @test IC.settings(declaration, Dict("masks" => Dict("radius_m" => 0.002)))["masks"]["radius_m"] == 0.002
        for overrides in (Dict("temperature_c" => -273.15), Dict("wavelength_um" => 0),
                Dict("resolution" => true), Dict("pupil_resolution" => 0),
                Dict("masks" => Dict("invented" => 0.1)), Dict("invented" => 1))
            @test_throws ArgumentError IC.settings(declaration, overrides)
        end
        empty!(simulation["settings_schema"]["properties"])
        delete!(simulation["defaults"], "masks")
        for mode in ("dark", "calibration")
            simulation["graphs"] = Dict(mode => first(values(simulation["graphs"])))
            write_external_optical_documents(directory, physical, simulation)
            standalone = IC.load_simulation(path)
            @test !isempty(IC.graph_document(standalone, IC.settings(standalone); simulation_graph=mode)["nodes"])
        end
    end
end

@testset "standalone profile replacements and responses are valid in every graph" begin
    mktempdir() do directory
        physical, simulation = external_optical_documents()
        simulation["profiles"]["reference"]["nodes"] = [Dict("name" => "optics", "type" => "proper_optical_train_f64",
            "config" => deepcopy(simulation["components"]["optics"]["config"]))]
        graph = simulation["graphs"]["llowfs"]
        only(graph["nodes"])["name"] = "other_optics"
        for input in graph["inputs"]
            input["destination"] = replace(input["destination"], "optics." => "other_optics.")
        end
        only(graph["outputs"])["source"] = "other_optics.output"
        simulation["components"]["other_optics"] = deepcopy(simulation["components"]["optics"])
        path = write_external_optical_documents(directory, physical, simulation)
        exception = try IC.load_simulation(path); nothing catch error; error end
        @test exception isa ArgumentError
        @test occursin("standalone profile reference replacement optics is absent from graph llowfs", sprint(showerror, exception))
        physical, simulation = external_optical_documents()
        filter!(input -> input["name"] != "pupil_opd", simulation["graphs"]["llowfs"]["inputs"])
        simulation["responses"] = Dict("pupil_opd" => Dict("kind" => "second_order", "natural_frequency_hz" => 20,
            "damping_ratio" => 0.7, "schema" => "example.pupil-opd/1"))
        write_external_optical_documents(directory, physical, simulation)
        exception = try IC.load_simulation(path); nothing catch error; error end
        @test exception isa ArgumentError
        @test occursin("standalone graph llowfs input", sprint(showerror, exception))
    end
end
