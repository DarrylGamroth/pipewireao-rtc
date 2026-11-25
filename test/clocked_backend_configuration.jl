# Without arguments, check a generated optical source. A built configuration
# can still be supplied as an optional positional argument.
using Test, PipeWireAORTC, PipeWireAO
using AdaptiveOpticsSim, AdaptiveOpticsSimPipeWireHIL
using AdaptiveOpticsSim.AlgorithmGraphs: external_pupil_contract

include("pupil_source_documents.jl")
include("helpers/clocked_optical_documents.jl")

function clocked_admission(fixture)
    (; config, path, document, simulation, amplitude, samples) = fixture
    C = PipeWireAORTC.Common
    Owner = PipeWireAORTC.AOSOwner
    options = Owner.configuration(config)
    @test options.version == 6 && options.mode === :clocked_optical
    @test options.pupil_node === nothing
    @test options.command_input === :command && options.command_count == 2
    @test options.command_schema == "example.command/1" && options.command_units == "m"
    @test options.source_pupil_axes == (2, 1)
    @test options.sensor_nodes == (; scc = "optical-scc")
    @test options.period_ns == 2_000_000
    @test Owner.verify_external_pupil_declaration(options) === nothing
    IC = PipeWireAORTC.InstrumentConfiguration
    declaration = IC.load_simulation(path)
    binding = declaration.document["bindings"][options.source_amplitude_binding]
    @test binding["sha256"] == C.sha256_file(amplitude)
    @test IC.binding_values(declaration, IC.settings(declaration), binding) == samples

    port = PipeWireAORTC.InstrumentExport.pupil_output_port_contract(
        path; simulation_graph = options.source_graph,
    )
    expected = external_pupil_contract(;
        pupil_resolution = 4, diameter_m = 0.012, plane = "upstream_of_apodizer",
        curvature = "collimated",
    )
    @test port == Dict(
        "shape" => [2, 4, 4], "element-type" => "F32_LE", "layout" => "ROW_MAJOR",
        "schema" => expected.schema,
    )

    for (field, value, message) in (
        ("source_dm_axes", ["x", "y"], r"DM raster must declare"),
        ("source_pupil_axes", [1, 2], r"native .* spatial AO OPD"),
        ("command_schema", "example.other/1", r"command schema differs"),
        ("command_units", "um", r"command units differ"),
        ("command_limit", 0.5, r"command limit differs"),
        ("rate", 501, r"cadence differs"),
    )
        C.write_json(config, merge(document, Dict(field => value)))
        @test_throws message Owner.configuration(config)
    end
    malformed_identity = Dict("prescription_identity" => "sha256:" * repeat("0", 64))
    C.write_json(config, merge(document, malformed_identity))
    @test_throws r"prescription identity differs" Owner.verify_external_pupil_declaration(
        Owner.configuration(config),
    )
    C.write_json(config, document)

    broken = deepcopy(simulation)
    binding = broken["bindings"][options.source_amplitude_binding]
    pop!(binding, "sha256")
    C.write_yaml(path, broken)
    @test_throws r"amplitude must be hashed Float32 FITS" Owner.configuration(config)
    binding["sha256"] = C.sha256_file(amplitude)
    binding["axes"] = [2, 1]
    C.write_yaml(path, broken)
    @test_throws r"amplitude must be hashed Float32 FITS" Owner.configuration(config)
    binding["axes"] = [1, 2]
    only(broken["components"]["optics"]["config"]["steps"])["sampling_m"] = [0.003, 0.006]
    C.write_yaml(path, broken)
    @test_throws r"mirror plane schema, axes or sampling differ" Owner.configuration(config)
    C.write_yaml(path, simulation)
    return config
end

@testset "clocked optical backend configuration" begin
    args = abspath(PROGRAM_FILE) == (@__FILE__) ? ARGS : String[]
    length(args) <= 1 || error("supply at most one built clocked optical simulation.conf")
    mktempdir() do directory
        path = if isempty(args)
            clocked_admission(clocked_optical_documents(directory))
        else
            source = abspath(only(args))
            application = joinpath(directory, "application")
            cp(dirname(source), application)
            joinpath(application, basename(source))
        end
        document = PipeWireAORTC.DeploymentConfiguration.decode(
            path, get(ENV, "PIPEWIREAO_PREFIX", String(PipeWireAO.LibPipeWire.PipeWireAO_jll.artifact_dir))
        )
        @test document["version"] == 6
        document["backend"] = "cpu"
        document["device"] = 0
        delete!(document, "command_acquisition_version")
        delete!(document, "command_buffers")
        PipeWireAORTC.Common.write_json(path, document)
        cpu = PipeWireAORTC.AOSOwner.configuration(path)
        @test cpu.command_buffers == 3
        for key in (
            "sensor_buffer_properties",
            "sensor_acquisition_versions",
            "command_acquisition_version",
        )
            document[key] = key == "sensor_acquisition_versions" ? Dict("scc" => 3) : 3
            PipeWireAORTC.Common.write_json(path, document)
            @test_throws ArgumentError PipeWireAORTC.AOSOwner.configuration(path)
            delete!(document, key)
        end
        document["command_buffers"] = 3
        PipeWireAORTC.Common.write_json(path, document)
        @test PipeWireAORTC.AOSOwner.configuration(path) == cpu
        for buffers in (2, 64)
            document["command_buffers"] = buffers
            PipeWireAORTC.Common.write_json(path, document)
            @test PipeWireAORTC.AOSOwner.configuration(path) ==
                merge(cpu, (; command_buffers = buffers))
        end
        for buffers in (1, 65, nothing, true, "3", 3.0)
            document["command_buffers"] = buffers
            PipeWireAORTC.Common.write_json(path, document)
            @test_throws ArgumentError PipeWireAORTC.AOSOwner.configuration(path)
        end
        delete!(document, "command_buffers")
        document["backend"] = "amdgpu"
        document["device"] = 1
        PipeWireAORTC.Common.write_json(path, document)
        amd = PipeWireAORTC.AOSOwner.configuration(path)
        @test amd == merge(cpu, (; backend = :amdgpu, device = 1))
        for device in (0, 1)
            document["backend"] = "cuda"
            document["device"] = device
            PipeWireAORTC.Common.write_json(path, document)
            @test PipeWireAORTC.AOSOwner.configuration(path) ==
                merge(cpu, (; backend = :cuda, device))
        end
        for (backend, device) in (
            ("unknown", 0),
            ("amdgpu", 0),
            ("amdgpu", -1),
            ("cpu", 1),
            ("amdgpu", true),
            ("amdgpu", "1"),
            ("amdgpu", nothing),
        )
            document["backend"] = backend
            document["device"] = device
            PipeWireAORTC.Common.write_json(path, document)
            @test_throws ArgumentError PipeWireAORTC.AOSOwner.configuration(path)
        end
        @test !any(id -> id.name in ("Proper", "CUDA", "AMDGPU"), keys(Base.loaded_modules))
    end
end
