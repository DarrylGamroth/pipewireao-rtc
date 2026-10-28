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
