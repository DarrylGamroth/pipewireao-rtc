using Test, PipeWireAORTC
const IC = PipeWireAORTC.InstrumentConfiguration
Base.include(@__MODULE__, joinpath(@__DIR__, "external_optical_documents.jl"))

function authored_optical_source(directory)
    physical, simulation = external_optical_documents()
    mkpath(joinpath(directory, "optics"))
    prescription = joinpath(directory, "optics", "instrument.zmx")
    write(prescription, "Authored Zemax input; conversion belongs to AOS\n")
    physical["optical_prescription"] = Dict("format" => "zemax", "path" => "optics/instrument.zmx",
        "sha256" => PipeWireAORTC.Common.sha256_file(prescription))
    physical["optical_paths"] = Dict("science" => Dict("sensor" => "scc", "lyot_stop_port" => "transmitted"),
        "low_order" => Dict("sensor" => "llowfs", "lyot_stop_port" => "reflected"))
    delete!(simulation, "graphs")
    simulation["components"] = Dict()
    simulation["preparation"] = Dict{String,Any}("kind" => "zemax", "recipe" => "zemax.yaml")
    simulation["settings_schema"] = "proper_optical_train"
    simulation["defaults"]["temperature_c"] = 20
    mkpath(joinpath(directory, "simulation"))
    write(joinpath(directory, "simulation", "zemax.yaml"), "schema_version: 1\n")
    return physical, simulation
end

@testset "authored source loads before generated execution exists" begin
    mktempdir() do directory
        physical, simulation = authored_optical_source(directory)
        path = write_external_optical_documents(directory, physical, simulation)
        @test !ispath(joinpath(directory, "generated"))
        source = IC.load_simulation_source(path)
        @test source.authoring == simulation
        @test source.instrument.document == physical
        @test source.directory == directory
        @test source.preparation_path == joinpath(directory, "simulation", "zemax.yaml")
        @test !hasproperty(source, :graphs)
        @test !haskey(source.document, "graphs")
        @test IC.settings(source) == simulation["defaults"]
        @test source.document["settings_schema"]["properties"]["profile"]["enum"] == ["reference"]
        @test IC.settings_description(source, Dict())["settings"] == simulation["defaults"]
        @test_throws ArgumentError IC.settings(source, Dict("invented" => 1))
        @test_throws ArgumentError IC.settings(source, Dict("wavelength_um" => 2))
        error = try IC.load_simulation(path); nothing catch caught; caught end
        @test error isa ArgumentError
        @test occursin("preparation first", sprint(showerror, error))
        @test occursin("generated/simulation.yaml", sprint(showerror, error))
        @test !ispath(joinpath(directory, "generated"))
        # Source-relative recipe resolution also permits a contained parent path.
        simulation["preparation"]["recipe"] = "../optics/instrument.zmx"
        write_external_optical_documents(directory, physical, simulation)
        @test IC.load_simulation_source(path).preparation_path == joinpath(directory, "optics", "instrument.zmx")
    end
    @test all(id -> id.name ∉ ("AdaptiveOpticsSim", "AdaptiveOpticsSimPipeWireHIL", "Proper", "CUDA", "AMDGPU"), keys(Base.loaded_modules))
end

@testset "source rejects mixed and unsupported preparation contracts" begin
    mktempdir() do directory
        physical, simulation = authored_optical_source(directory)
        graph = first(values(external_optical_documents()[2]["graphs"]))
        for mutate! in (
                doc -> (doc["graphs"] = Dict("scc" => graph)),
                doc -> delete!(doc, "preparation"),
                doc -> (doc["unknown"] = true),
                doc -> (doc["schema_version"] = 2),
                doc -> (doc["frame_period_s"] = 0),
                doc -> (doc["preparation"]["kind"] = "other"),
                doc -> (doc["preparation"]["unknown"] = true),
                doc -> delete!(doc["preparation"], "recipe"),
                doc -> (doc["preparation"]["recipe"] = "/tmp/zemax.yaml"),
                doc -> (doc["preparation"]["recipe"] = "missing.yaml"),
                doc -> (doc["components"] = Dict("optics" => Dict())),
                doc -> (doc["responses"] = Dict("pupil_opd" => Dict())),
                doc -> (doc["sensors"] = Dict("scc" => Dict("post_readout_gain" => 2))),
                doc -> (doc["sources"] = Dict("star" => Dict())),
                doc -> (doc["imaging"] = Dict("source" => "star")),
                doc -> (doc["settings_bindings"] = [Dict("nodes" => ["optics"])]),
                doc -> (doc["profiles"]["reference"]["nodes"] = [Dict()]),
                doc -> (doc["profiles"]["reference"]["parameters"] = [Dict()]),
                doc -> (doc["profiles"]["reference"]["unknown"] = Any[]),
                doc -> (doc["defaults"]["invented"] = 1),
                doc -> (doc["bindings"]["pupil_opd"]["kind"] = "invented"))
            invalid = deepcopy(simulation)
            mutate!(invalid)
            path = write_external_optical_documents(directory, physical, invalid)
            @test_throws ArgumentError IC.load_simulation_source(path)
        end
        for field in ("optical_prescription", "optical_paths")
            invalid = deepcopy(physical)
            delete!(invalid, field)
            path = write_external_optical_documents(directory, invalid, simulation)
            @test_throws ArgumentError IC.load_simulation_source(path)
        end
        mkpath(joinpath(directory, "generated"))
        write(joinpath(directory, "generated", "recipe.yaml"), "schema_version: 1\n")
        simulation["preparation"]["recipe"] = "../generated/recipe.yaml"
        path = write_external_optical_documents(directory, physical, simulation)
        @test_throws ArgumentError IC.load_simulation_source(path)
        mkpath(joinpath(directory, "simulation", "optics"))
        symlink(joinpath(directory, "generated", "recipe.yaml"), joinpath(directory, "simulation", "optics", "linked.yaml"))
        simulation["preparation"]["recipe"] = "optics/linked.yaml"
        write_external_optical_documents(directory, physical, simulation)
        @test_throws ArgumentError IC.load_simulation_source(path)
        mktempdir() do outside
            write(joinpath(outside, "recipe.yaml"), "schema_version: 1\n")
            simulation["preparation"]["recipe"] = relpath(joinpath(outside, "recipe.yaml"), dirname(path))
            write_external_optical_documents(directory, physical, simulation)
            @test_throws PipeWireAORTC.DeploymentConfiguration.DeploymentError IC.load_simulation_source(path)
        end
    end
end

@testset "graph-bearing definitions retain existing execution semantics" begin
    mktempdir() do directory
        physical, simulation = external_optical_documents()
        path = write_external_optical_documents(directory, physical, simulation)
        execution = IC.load_simulation(path)
        @test IC.load_simulation_source(path).document == execution.document
        @test Set(keys(execution.graphs)) == Set(("scc", "llowfs"))
        @test IC.settings(execution) == simulation["defaults"]
        @test !hasproperty(execution, :preparation_path)
        # Generated execution retains instrument-root-relative graph assets.
        generated = joinpath(directory, "generated")
        mkpath(generated)
        for (name, graph) in simulation["graphs"]
            PipeWireAORTC.Common.write_yaml(joinpath(generated, name * ".yaml"), graph)
        end
        simulation["graphs"] = Dict(name => "generated/" * name * ".yaml" for name in keys(simulation["graphs"]))
        generated_path = joinpath(generated, "simulation.yaml")
        PipeWireAORTC.Common.write_yaml(generated_path, simulation)
        prepared = IC.load_simulation(generated_path)
        @test prepared.instrument.path == joinpath(directory, "instrument.yaml")
        @test prepared.graphs == execution.graphs
        @test IC.settings(prepared) == IC.settings(execution)
    end
end

@testset "authored post-exposure response graphs load without generated optics" begin
    mktempdir() do directory
        physical, simulation = authored_optical_source(directory)
        authored_response!(directory, physical, simulation; mtf=true)
        path = write_external_optical_documents(directory,physical,simulation)
        source = IC.load_simulation_source(path)
        @test !hasproperty(source,:graphs)
        @test Set(keys(source.observation_graphs)) == Set(["low_order_response"])
        @test Set(source.templates) == Set(["ingaas","pixel_mtf"])
        @test source.document["observations"] == simulation["observations"]
        @test source.observation_graphs["low_order_response"]["nodes"][1]["bindings"] == Dict("transfer"=>"mtf_transfer")
        @test !haskey(source.observation_graphs["low_order_response"]["nodes"][2]["config"],"photon_noise")
        @test IC.binding_values(source,IC.settings(source),source.document["bindings"]["mtf_transfer"]) == ones(Float32,8,8)
        @test !ispath(joinpath(directory,"generated"))
        bad_hash = deepcopy(source.document["bindings"]["mtf_transfer"])
        bad_hash["sha256"] = repeat("0",64)
        @test_throws ArgumentError IC.binding_values(source,IC.settings(source),bad_hash)
        for mutate! in (
            doc->(doc["observations"]["low_order"]["graph"]="simulation/missing.yaml"),
            doc->(doc["observations"]["low_order"]["graph"]="generated/low_order_response.yaml"),
            doc->(doc["observations"]["science"]=pop!(doc["observations"],"low_order")),
            doc->(doc["observations"]["low_order"]["normalized_to_photon_rate"]=0),
            doc->(doc["components"]["unused"]=deepcopy(doc["components"]["low_order_detector"])),
            doc->(doc["components"]["low_order_detector"]["sensor"]="scc"),
            doc->delete!(doc["bindings"]["mtf_transfer"],"sha256"),
            doc->(doc["bindings"]["mtf_transfer"]["sha256"]=repeat("0",64)),
            doc->(doc["bindings"]["mtf_transfer"]["shape"]=[7,8]))
            invalid=deepcopy(simulation)
            mutate!(invalid)
            write_external_optical_documents(directory,physical,invalid)
            @test_throws Union{ArgumentError,DimensionMismatch,PipeWireAORTC.DeploymentConfiguration.DeploymentError} IC.load_simulation_source(path)
        end
    end
end
