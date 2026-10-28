# Optional CPU selector: shared RTC configuration plus AOS/HIL and explicit Proper.
using Test, PipeWireAORTC, AdaptiveOpticsSim, AdaptiveOpticsSimPipeWireHIL, Proper
using AdaptiveOpticsSim.AlgorithmGraphs
const IC = PipeWireAORTC.InstrumentConfiguration
Base.include(@__MODULE__, joinpath(@__DIR__, "zemax_component_documents.jl"))

@testset "imported ZEMAX component composes with an ordinary typed optical graph" begin
    mktempdir() do directory
        physical, simulation = zemax_component_documents(directory)
        physical["telescope"] = Dict("telescope_diameter_m" => 8.0,
            "central_obstruction_ratio" => 0.25, "pupil_reflectivity" => 0.7, "aperture_revision" => 1)
        simulation["bindings"]["pupil_amplitude"] = Dict("kind" => "pupil_amplitude",
            "resolution" => "pupil_resolution", "type" => "Float32")
        transfer_path = joinpath(directory, "transfer.fits")
        IC.FITSIO.FITS(transfer_path, "w") do file
            write(file, ones(Float32, 8, 8))
        end
        simulation["bindings"]["transfer"] = Dict("kind" => "fits", "path" => "transfer.fits", "hdu" => 1,
            "axes" => [1, 2], "type" => "Float32", "shape" => [8, 8],
            "sha256" => PipeWireAORTC.Common.sha256_file(transfer_path))
        simulation["components"]["mtf"] = Dict("template" => "pixel_mtf", "bindings" => Dict("transfer" => "transfer"),
            "config" => Dict("input_shape" => [8, 8], "padding" => 0,
                "input_schema" => "example.intensity/1", "output_schema" => "example.intensity/1"))
        for graph in values(simulation["graphs"])
            push!(graph["nodes"], Dict("name" => "mtf"))
            graph["links"] = [Dict("source" => "optics.output", "destination" => "mtf.input")]
            only(graph["outputs"])["source"] = "mtf.output"
        end
        path = write_external_optical_documents(directory, physical, simulation)
        before = Dict(joinpath(root, file) => read(joinpath(root, file))
            for (root, _, files) in walkdir(directory) for file in files)
        declaration = IC.load_simulation(path)
        configured = IC.settings(declaration)
        document = IC.graph_document(declaration, configured; simulation_graph="scc")
        node = only(node for node in document["nodes"] if node["name"] == "optics")
        @test node["type"] == "proper_optical_train_f32"
        @test !haskey(node, "preparation")
        @test !haskey(node["config"], "temperature_c")
        @test node["config"]["diameter_m"] == 0.012
        @test only(node["config"]["steps"])["distance_m"] == 0.001
        @test document["links"] == simulation["graphs"]["scc"]["links"]
        authored = only(node for node in declaration.graphs["scc"]["nodes"] if node["name"] == "optics")
        @test authored["preparation"]["branch"] == "science_relay"
        changed = IC.graph_document(declaration, IC.settings(declaration, Dict("wavelength_um" => 1.6, "temperature_c" => 10)); simulation_graph="scc")
        @test first(changed["nodes"])["config"]["wavelength_um"] == 1.6
        system = IC.prepare_system(path; simulation_graph="scc")
        @test system.boundary === nothing
        @test system.driver === nothing
        @test eltype(graph_input(system.graph, :pupil_opd)) == Float32
        @test size(graph_output(system.graph, :intensity)) == (8, 8)
        amplitude = copy(graph_input(system.graph, :pupil_amplitude))
        @test all(value -> value in (0f0, 1f0), amplitude)
        @test count(!iszero, amplitude) == 12
        step_graph!(system.graph)
        image = copy(graph_output(system.graph, :intensity))
        @test all(isfinite, image)
        @test sum(image) ≈ 12 rtol=2e-5
        graph_input(system.graph, :pupil_amplitude) .*= 2
        step_graph!(system.graph)
        @test graph_output(system.graph, :intensity) ≈ 4 .* image
        @test all(read(file) == bytes for (file, bytes) in before)
        @test Set(joinpath(root, file) for (root, _, files) in walkdir(directory) for file in files) == Set(keys(before))
        @test !ispath(joinpath(directory, "generated"))
    end
end

@testset "prepared optical schemas inherit native defaults and f64 remains available" begin
    for (template, datatype) in (("proper_optical_train_f32", Float32), ("proper_optical_train_f64", Float64))
        mktempdir() do directory
            physical, simulation = zemax_component_documents(directory)
            selection = simulation["components"]["optics"]
            selection["template"] = template
            for key in ("pupil_opd_schema", "pupil_amplitude_schema", "output_schema")
                delete!(selection["config"], key)
            end
            for binding in values(simulation["bindings"])
                binding["type"] = string(datatype)
            end
            path = write_external_optical_documents(directory, physical, simulation)
            system = IC.prepare_system(path; simulation_graph="llowfs")
            @test eltype(graph_output(system.graph, :intensity)) == datatype
            fill!(graph_input(system.graph, :pupil_amplitude), 1)
            step_graph!(system.graph)
            @test sum(graph_output(system.graph, :intensity)) ≈ 16
        end
    end
end

@testset "generated HIL component graphs preserve authored execution and identity" begin
    mktempdir() do directory
        physical, simulation = zemax_component_documents(directory)
        # HIL declarations require physical mirror metadata even when this
        # bounded optical test supplies an OPD command directly to the relay.
        PipeWireAORTC.Common.write_json(joinpath(directory, "mirror.json"), Dict(
            "schema_version" => 1, "id" => "reference-mirror", "manufacturer" => "Example", "model" => "Synthetic",
            "layout" => Dict("schema_version" => 1, "name" => "Reference grid", "grid_shape" => [2, 2],
                "command_positions" => [[1, 1]], "axis_labels" => ["column", "row"], "command_order" => "physical")))
        physical["deformable_mirrors"] = Dict("reference" => Dict("description" => "mirror.json",
            "pupil_registration" => Dict("actuator_pitch_pupil_radius" => 0.2), "units" => "m", "command_scale_m" => 1))
        production = deepcopy(simulation["graphs"]["scc"])
        PipeWireAORTC.Common.write_yaml(joinpath(directory, "simulation", "production.yaml"), production)
        simulation["graphs"] = Dict("production" => "simulation/production.yaml",
            "calibration" => deepcopy(production), "optical-reference" => deepcopy(production))
        simulation["hil"] = Dict("command" => "optics.pupil_opd", "frame" => "optics.output")
        simulation["wire_contracts"] = [Dict("frame_encoding" => "uint16", "frame_schema" => "example.raw-adc/1",
            "command_schema" => "example.command/1", "command_scale" => 1)]
        source_path = write_external_optical_documents(directory, physical, simulation)
        authored = Dict(joinpath(root, file) => read(joinpath(root, file))
            for (root, _, files) in walkdir(directory) for file in files)
        source = IC.load_simulation(source_path)
        AdaptiveOpticsSim.Optics.Zemax.prepare(directory; yamlfmt=nothing)
        generated_path = joinpath(directory, "generated", "simulation.yaml")
        generated = IC.load_simulation(generated_path)
        @test all(read(path) == bytes for (path, bytes) in authored)
        @test generated.document["hil"] == source.document["hil"]
        @test generated.document["wire_contracts"] == source.document["wire_contracts"]
        @test generated.document["components"] == source.document["components"]
        prepared_bytes = Dict(joinpath(root, file) => read(joinpath(root, file))
            for (root, _, files) in walkdir(directory) for file in files)
        for overrides in (Dict{String,Any}(), Dict{String,Any}("resolution" => 12,
                "pupil_resolution" => 6, "wavelength_um" => 1.6, "temperature_c" => 10.0))
            source_settings = IC.settings(source, overrides)
            generated_settings = IC.settings(generated, overrides)
            @test generated_settings == source_settings
            @test IC.prescription_identity(generated, generated_settings) == IC.prescription_identity(source, source_settings)
            for mode in ("production", "calibration", "optical-reference")
                expected = IC.graph_document(source, source_settings; simulation_graph=mode)
                actual = IC.graph_document(generated, generated_settings; simulation_graph=mode)
                @test actual == expected
                config = only(actual["nodes"])["config"]
                @test config["resolution"] == generated_settings["resolution"]
                @test config["pupil_resolution"] == generated_settings["pupil_resolution"]
                @test config["wavelength_um"] == generated_settings["wavelength_um"]
                @test !haskey(only(actual["nodes"]), "preparation")
            end
            source_system = IC.prepare_system(source_path; settings=overrides)
            generated_system = IC.prepare_system(generated_path; settings=overrides)
            @test generated_system.boundary !== nothing
            @test generated_system.driver !== nothing
            @test size(graph_output(generated_system.graph, :intensity)) ==
                (generated_settings["resolution"], generated_settings["resolution"])
            for system in (source_system, generated_system)
                fill!(graph_input(system.graph, :pupil_amplitude), 1)
                step_hil_frame!(system.boundary)
            end
            @test hil_frame_buffer(generated_system.boundary) ≈ hil_frame_buffer(source_system.boundary)
            @test sum(hil_frame_buffer(generated_system.boundary)) ≈ generated_settings["pupil_resolution"]^2 rtol=2e-5
        end
        @test all(read(path) == bytes for (path, bytes) in prepared_bytes)
        @test Set(joinpath(root, file) for (root, _, files) in walkdir(directory) for file in files) == Set(keys(prepared_bytes))

        # Reject a changed generated graph during loading, before graph creation.
        graph_path = joinpath(directory, "generated", "production.yaml")
        write(graph_path, read(graph_path, String) * "# altered generated graph\n")
        @test_throws ArgumentError IC.load_simulation(generated_path)
        @test_throws ArgumentError IC.prepare_system(generated_path)
        write(graph_path, prepared_bytes[graph_path])
        # Source-byte changes are stale even when the parsed YAML is equivalent.
        write(source_path, read(source_path, String) * "# altered authored source\n")
        @test_throws ArgumentError IC.load_simulation(generated_path)
        @test_throws ArgumentError IC.prescription_identity(generated, IC.settings(generated))
        write(source_path, authored[source_path])
        @test IC.prescription_identity(IC.load_simulation(generated_path), IC.settings(generated)) ==
            IC.prescription_identity(source, IC.settings(source))
    end
end

@testset "runtime OPD inputs and entrance grids survive component preparation" begin
    mktempdir() do directory
        physical, simulation = zemax_component_documents(directory)
        graph = simulation["graphs"]["scc"]
        screen = Dict("surface"=>1,"input"=>"mirror_opd","size"=>[4,4],
            "axes"=>[2,1],"diameter_m"=>0.012,"schema"=>"example.opd-metres/1","outside_opd_m"=>0)
        only(graph["nodes"])["config"] = Dict("phase_screens"=>[screen],
            "pupil_grid"=>Dict("size"=>[4,4],"axes"=>[2,1],"diameter_m"=>0.012))
        simulation["bindings"]["mirror_opd"] = deepcopy(simulation["bindings"]["pupil_opd"])
        push!(graph["inputs"], Dict("name"=>"mirror_opd","binding"=>"mirror_opd","destination"=>"optics.mirror_opd"))
        path = write_external_optical_documents(directory, physical, simulation)
        source = IC.load_simulation(path)
        document = IC.graph_document(source, IC.settings(source); simulation_graph="scc")
        config = only(document["nodes"])["config"]
        @test !haskey(config,"phase_screens")
        @test config["pupil_grid"]["center_pixel"] == [2.5,2.5]
        @test config["pupil_grid"]["sampling_m"] == [0.003,0.003]
        @test only(filter(s->s["op"]=="add_opd",config["steps"]))["input"] == "mirror_opd"
        system = IC.prepare_system(path;simulation_graph="scc")
        fill!(graph_input(system.graph,:pupil_opd),0)
        fill!(graph_input(system.graph,:pupil_amplitude),1)
        fill!(graph_input(system.graph,:mirror_opd),1e-7)
        step_graph!(system.graph)
        image = copy(graph_output(system.graph,:intensity))
        @test all(isfinite,image) && sum(image)>0
        AdaptiveOpticsSim.Optics.Zemax.prepare(directory;yamlfmt=nothing)
        generated = IC.load_simulation(joinpath(directory,"generated/simulation.yaml"))
        @test IC.graph_document(generated,IC.settings(generated);simulation_graph="scc") == document
    end
end

# Keep derived field-grid and wavelength guards in this optional CPU gate.
include("ideal_pupil_relay_preparation.jl")
