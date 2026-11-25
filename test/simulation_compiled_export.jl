# Optional CPU RTC exporter check for real compiled AOS optical-model assets.
using Test,
    Serialization,
    PipeWireAORTC,
    AdaptiveOpticsSim,
    AdaptiveOpticsSimPipeWireHIL,
    Proper,
    PipeWireAO

# Reuse the HIL package's tiny model-data writer instead of duplicating its
# compiled-model schema. Including this helper also runs the HIL optical and
# compiled-model selectors; no numerical implementation is copied here.
include(
    joinpath(
        dirname(dirname(pathof(AdaptiveOpticsSimPipeWireHIL))),
        "test",
        "simulation_compiled_optical.jl",
    ),
)

module RTCCompiledExportTests
using Test,
    Serialization,
    PipeWireAORTC,
    AdaptiveOpticsSim,
    AdaptiveOpticsSimPipeWireHIL,
    Proper,
    PipeWireAO
using AdaptiveOpticsSim.AlgorithmGraphs
using ..CompiledOpticalSimulationTests: compiled_bundle
include(joinpath(@__DIR__, "external_optical_documents.jl"))
const IC = PipeWireAORTC.InstrumentConfiguration
const C = PipeWireAORTC.Common
const Simulation = AdaptiveOpticsSimPipeWireHIL.Simulation
const Optical = AdaptiveOpticsSimPipeWireHIL.ExternalPupil

function exposure(plant)
    packet = zeros(Float32, 2, 4, 4)
    for row in 1:4, column in 1:4
        packet[1, row, column] = 1.0f-8 * sin(Float32(row + column))
        packet[2, row, column] = 0.5f0 + 0.01f0 * row
    end
    receipt = (;
        identity = AcquisitionIdentity(
            AcquisitionDomain(ntuple(UInt8, 16)), UInt64(1), UInt64(1)
        ),
        pts = Int64(0),
        duration = UInt64(2_000_000),
        lost_samples = UInt64(0),
    )
    frames = Any[]
    @test Optical.feed!(plant, packet, receipt) do name, image, metadata
        push!(
            frames,
            (; name, image = copy(image), pts = metadata.pts, duration = metadata.duration),
        )
    end
    return frames
end

const RELOCATED_COMPILED_CHILD = raw"""
using Test, Serialization, AdaptiveOpticsSim, AdaptiveOpticsSimPipeWireHIL, Proper, PipeWireAO
using AdaptiveOpticsSim.AlgorithmGraphs
prepared = AdaptiveOpticsSimPipeWireHIL.Simulation.prepare(
    AdaptiveOpticsSimPipeWireHIL.Simulation.load(ARGS[1]))
packet = zeros(Float32,2,4,4)
for row in 1:4, column in 1:4
    packet[1,row,column] = 1f-8 * sin(Float32(row + column))
    packet[2,row,column] = 0.5f0 + 0.01f0 * row
end
receipt = (; identity=AcquisitionIdentity(AcquisitionDomain(ntuple(UInt8,16)),
    UInt64(1),UInt64(1)),pts=Int64(0),duration=UInt64(2_000_000),lost_samples=UInt64(0))
frames = Any[]
@test AdaptiveOpticsSimPipeWireHIL.ExternalPupil.feed!(prepared.science.plant,packet,receipt) do name,image,metadata
    push!(frames,(;name,image=copy(image),pts=metadata.pts,duration=metadata.duration))
end
@test all(id -> id.name ∉ ("PipeWireAORTC","CUDA","AMDGPU"),keys(Base.loaded_modules))
serialize(ARGS[2],frames)
"""

@testset "RTC compiled export owns exact model assets after relocation" begin
    mktempdir() do directory
        model_source = joinpath(directory, "model-authoring")
        mkpath(model_source)
        product = compiled_bundle(model_source)
        source = joinpath(directory, "authoring")
        mkpath(source)
        cp(joinpath(model_source, "models"), joinpath(source, "compiled"))
        physical, simulation = external_optical_documents()
        physical["optical_input"]["diameter_m"] = 0.004
        physical["optical_paths"] = Dict(
            "scc" => Dict("sensor" => "scc", "lyot_stop_port" => "transmitted")
        )
        physical["wavefront_sensors"] = Dict("scc" => physical["wavefront_sensors"]["scc"])
        physical["wavefront_sensors"]["scc"]["acquisition"] = Dict(
            "exposure_duration_s" => 0.002
        )
        simulation["defaults"]["resolution"] = 4
        simulation["components"] = Dict()
        graph = deepcopy(product.graph)
        graph["nodes"][1]["config"]["model_path"] = "compiled/model.yaml"
        simulation["graphs"] = Dict("scc" => graph)
        bindings = Dict{String,Any}()
        mkpath(joinpath(source, "bindings"))
        for (name, entry) in product.bindings
            destination = joinpath("bindings", name * ".fits")
            cp(joinpath(model_source, entry["path"]), joinpath(source, destination))
            bindings[name] = Dict(
                "kind" => "fits",
                "path" => destination,
                "hdu" => 1,
                "axes" => [1, 2],
                "type" => entry["eltype"],
                "shape" => entry["shape"],
                "sha256" => entry["sha256"],
            )
        end
        simulation["bindings"] = bindings
        path = write_external_optical_documents(source, physical, simulation)
        original = Dict(
            relpath(joinpath(root, name), source) => read(joinpath(root, name)) for
            (root, _, names) in walkdir(source) for name in names
        )
        expected = exposure(IC.prepare_external_pupil(path))
        @test length(expected) == 1
        @test size(only(expected).image) == (4, 4)
        @test all(isfinite, only(expected).image) && sum(only(expected).image) > 0
        configuration = Dict(
            "mode" => "external_pupil",
            "pipewire" => Dict(
                "remote" => "unopened-compiled-export-core",
                "pupil_node_name" => "compiled-pupil",
                "sensor_node_names" => Dict("scc" => "compiled-scc"),
                "sensor_buffers" => 3,
                "reference_clock" => "realtime",
            ),
        )
        bundle = joinpath(directory, "exported")
        exported = IC.export_simulation(path, bundle; configuration)
        @test Dict(
            relpath(joinpath(root, name), source) => read(joinpath(root, name)) for
            (root, _, names) in walkdir(source) for name in names
        ) == original
        manifest = C.read_yaml(exported)
        descriptor = manifest["graphs"]["scc"]
        exported_graph = C.read_yaml(joinpath(bundle, descriptor["path"]))
        node = only(exported_graph["nodes"])
        digest = product.graph["nodes"][1]["config"]["model_sha256"]
        model_path = joinpath("models", digest, "model.yaml")
        @test node["config"]["model_path"] == model_path
        @test node["config"]["model_sha256"] == digest
        metadata = C.read_yaml(joinpath(source, "compiled/model.yaml"))
        @test read(joinpath(bundle, model_path)) ==
            read(joinpath(source, "compiled/model.yaml"))
        @test length(descriptor["assets"]) == 1 + length(metadata["arrays"])
        for entry in values(metadata["arrays"])
            copied = joinpath(bundle, dirname(model_path), entry["path"])
            @test read(copied) == read(joinpath(source, "compiled", entry["path"]))
            @test C.sha256_file(copied) == entry["sha256"]
        end
        relocated = joinpath(directory, "relocated")
        mv(bundle, relocated)
        relocated_config = joinpath(relocated, relpath(exported, bundle))
        rm(source; recursive = true)
        rm(model_source; recursive = true)
        prepared = Simulation.prepare(Simulation.load(relocated_config))
        @test exposure(prepared.science.plant) == expected
        result = joinpath(directory, "compiled-result.bin")
        project = dirname(Base.active_project())
        run(
            `$(Base.julia_cmd()) --startup-file=no --project=$project -e $RELOCATED_COMPILED_CHILD $relocated_config $result`,
        )
        @test deserialize(result) == expected
        array = first(values(metadata["arrays"]))
        write(
            joinpath(relocated, dirname(model_path), array["path"]),
            "tampered compiled array",
        )
        @test_throws AdaptiveOpticsSimPipeWireHIL.PipeWireHILError Simulation.load(
            relocated_config
        )
    end
    @test all(id -> id.name ∉ ("CUDA", "AMDGPU"), keys(Base.loaded_modules))
end
end
