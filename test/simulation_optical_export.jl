# Optional CPU integration selector: no PipeWire core, devices or accelerator imports.
using Test,
    Serialization,
    PipeWireAORTC,
    AdaptiveOpticsSim,
    AdaptiveOpticsSimPipeWireHIL,
    Proper,
    PipeWireAO
using AdaptiveOpticsSim.AlgorithmGraphs
import AdaptiveOpticsSimPipeWireHIL:
    stage_pipewire_array!, drain_pipewire_array!, array_stream_status
import PipeWireAO: trigger_process!

include(joinpath(@__DIR__, "external_pupil_owner_documents.jl"))
const IC = PipeWireAORTC.InstrumentConfiguration
const C = PipeWireAORTC.Common
const Optical = AdaptiveOpticsSimPipeWireHIL.ExternalPupil
const Simulation = AdaptiveOpticsSimPipeWireHIL.Simulation
using PipeWireAORTC.InstrumentExport: prepare_external_pupil_ports

mutable struct ExportExposureTransport
    events::Vector{Any}
    streams::NTuple{3,Nothing}
    commands::Vector{Vector{Float32}}
    sequence::UInt64
end
ExportExposureTransport(events, commands = Vector{Float32}[]) =
    ExportExposureTransport(events, (nothing, nothing, nothing), commands, UInt64(0))
array_stream_status(::ExportExposureTransport, index) = (; failed = false)
function drain_pipewire_array!(buffer, transport::ExportExposureTransport, index)
    isempty(transport.commands) && return nothing
    copyto!(buffer, popfirst!(transport.commands))
    transport.sequence += 1
    return PipeWireArrayReceipt(
        Int64(2_000_000 * (transport.sequence - 1)),
        UInt64(2_000_000),
        AcquisitionIdentity(
            AcquisitionDomain(ntuple(UInt8, 16)), UInt64(1), transport.sequence
        ),
        UInt64(0),
    )
end

function clocked_trajectory(execution, commands)
    transport = ExportExposureTransport(Any[], [copy(command) for command in commands])
    rasters = Matrix{Float32}[]
    Optical.run!(execution, transport) do owner, streams, now_ns
        sequence = Optical.snapshot(owner).sequence
        if sequence > 0
            push!(rasters, copy(owner.science.source_dm_opd))
            @test all(iszero, owner.science.source_opd)
        end
        return sequence == length(commands) ? Optical.Stop() : Optical.Run(Int64(0))
    end
    return transport.events, rasters
end
function stage_pipewire_array!(transport::ExportExposureTransport, index, image; kwargs...)
    metadata = (; kwargs...)
    push!(
        transport.events,
        (;
            index,
            image = copy(image),
            sequence = metadata.identity.sequence,
            pts = metadata.pts,
            duration = metadata.duration,
            trigger = string(metadata.trigger_state),
            optical = string(metadata.optical_classification),
        ),
    )
    return true
end
trigger_process!(transport::ExportExposureTransport) = push!(transport.events, :trigger)

function optical_trajectory(execution; samples = 8)
    transport = ExportExposureTransport(Any[])
    publisher = Optical.ExposurePublisher(transport)
    emit = Optical.emitter(execution, publisher)
    packet = execution.packet
    domain = AcquisitionDomain(ntuple(UInt8, 16))
    for sequence in UInt64(1):UInt64(samples)
        packet[1, :, :] .= Float32(sequence - 1) * 1.0f-9
        packet[2, :, :] .= 1
        receipt = (;
            identity = AcquisitionIdentity(domain, UInt64(1), sequence),
            pts = Int64((sequence - 1) * 1_000_000),
            duration = UInt64(1_000_000),
            lost_samples = UInt64(0),
        )
        @test Optical.publish_exposures!(publisher) do
            Optical.feed!(emit, execution.science.plant, packet, receipt)
        end
    end
    return transport.events
end

function authored_snapshot(directory)
    return Dict(
        relpath(joinpath(root, name), directory) => read(joinpath(root, name)) for
        (root, _, names) in walkdir(directory) for name in names
    )
end

# The child deliberately imports only the standalone HIL package and numerical
# dependencies. Its source declaration is removed before this process starts.
const RELOCATED_OPTICAL_CHILD = raw"""
using Test, Serialization, AdaptiveOpticsSim, AdaptiveOpticsSimPipeWireHIL, Proper, PipeWireAO
using AdaptiveOpticsSim.AlgorithmGraphs
import AdaptiveOpticsSimPipeWireHIL: stage_pipewire_array!
import PipeWireAO: trigger_process!
const Optical = AdaptiveOpticsSimPipeWireHIL.ExternalPupil
struct RelocatedTransport
    events::Vector{Any}
end
function stage_pipewire_array!(transport::RelocatedTransport, index, image; kwargs...)
    metadata = (; kwargs...)
    push!(transport.events, (; index, image=copy(image), sequence=metadata.identity.sequence,
        pts=metadata.pts, duration=metadata.duration, trigger=string(metadata.trigger_state),
        optical=string(metadata.optical_classification)))
    return true
end
trigger_process!(transport::RelocatedTransport) = push!(transport.events, :trigger)
prepared = AdaptiveOpticsSimPipeWireHIL.Simulation.prepare(
    AdaptiveOpticsSimPipeWireHIL.Simulation.load(ARGS[1]))
execution = prepared.execution
Optical.warmup!(execution)
transport = RelocatedTransport(Any[])
publisher = Optical.ExposurePublisher(transport)
emit = Optical.emitter(execution, publisher)
domain = AcquisitionDomain(ntuple(UInt8, 16))
for sequence in UInt64(1):UInt64(8)
    execution.packet[1,:,:] .= Float32(sequence - 1) * 1f-9
    execution.packet[2,:,:] .= 1
    receipt = (; identity=AcquisitionIdentity(domain, UInt64(1), sequence),
        pts=Int64((sequence-1)*1_000_000), duration=UInt64(1_000_000), lost_samples=UInt64(0))
    @test Optical.publish_exposures!(publisher) do
        Optical.feed!(emit, prepared.science.plant, execution.packet, receipt)
    end
end
@test all(id -> id.name ∉ ("PipeWireAORTC", "CUDA", "AMDGPU"), keys(Base.loaded_modules))
serialize(ARGS[2], transport.events)
"""

const COLD_OPTICAL_EXPORT_CHILD = raw"""
using Test, PipeWireAORTC, AdaptiveOpticsSim, AdaptiveOpticsSimPipeWireHIL, PipeWireAO
@test all(id -> id.name != "Proper", keys(Base.loaded_modules))
configuration = PipeWireAORTC.Common.read_yaml(ARGS[2])
exported = PipeWireAORTC.InstrumentConfiguration.export_simulation(
    ARGS[1], ARGS[3]; configuration)
@test any(id -> id.name == "Proper", keys(Base.loaded_modules))
prepared = AdaptiveOpticsSimPipeWireHIL.Simulation.prepare(
    AdaptiveOpticsSimPipeWireHIL.Simulation.load(exported))
@test prepared.science.pupil.shape == (2,4,4)
@test all(id -> id.name ∉ ("CUDA", "AMDGPU"), keys(Base.loaded_modules))
"""

@testset "standalone optical export preserves authored CPU science" begin
    mktempdir() do directory
        source = joinpath(directory, "authoring")
        mkpath(source)
        (; config, path, physical, simulation, document) = external_pupil_owner_documents(
            source
        )
        authored_response!(source, physical, simulation)
        observation = pop!(simulation["observations"], "low_order")
        observation["graph"] = "response"
        observation["normalized_to_photon_rate"] = 1e8
        simulation["observations"]["llowfs"] = observation
        simulation["graphs"] = Dict{String,Any}(simulation["graphs"])
        simulation["graphs"]["response"] = "simulation/low_order_response.yaml"
        detector = simulation["components"]["low_order_detector"]["config"]
        detector["pixel_sampling_m"] = [0.003, 0.003]
        detector["photon_noise"] = true
        simulation["graphs"]["scc_unfringed"] = deepcopy(simulation["graphs"]["scc"])
        # Different optical amplitudes make a swapped F/U phase observable.
        simulation["graphs"]["scc_unfringed"]["nodes"] = [
            Dict(
                "name" => "optics",
                "type" => "proper_optical_train_f64",
                "config" => merge(
                    deepcopy(simulation["components"]["optics"]["config"]),
                    Dict("steps" => [Dict("op" => "multiply", "amplitude" => 0.25)]),
                ),
            ),
        ]
        chopping = (;
            scc = (;
                unfringed_graph = "scc_unfringed",
                initial_phase = "fringed",
                trigger_high_is_fringed = true,
            ),
        )
        document["plant"]["chopping"] = Dict(
            "scc" => Dict(string(k) => v for (k, v) in pairs(chopping.scc))
        )
        write_external_optical_documents(source, physical, simulation)
        C.write_json(config, document)
        before = authored_snapshot(source)
        expected_science = prepare_external_pupil_ports(path; chopping)
        expected_execution = Optical.prepare(expected_science)
        Optical.warmup!(expected_execution)
        expected = optical_trajectory(expected_execution)
        bundle = joinpath(directory, "exported")
        configuration = Dict(
            "mode" => "external_pupil",
            "pipewire" => Dict(
                "remote" => "standalone-test",
                "pupil_node_name" => "test-pupil",
                "sensor_node_names" =>
                    Dict("scc" => "test-scc", "llowfs" => "test-llowfs"),
                "sensor_buffers" => 4,
                "reference_clock" => "realtime",
            ),
        )
        exported = IC.export_simulation(path, bundle; configuration, chopping)
        @test authored_snapshot(source) == before
        prepared = Simulation.prepare(Simulation.load(exported))
        @test prepared.remote == "standalone-test"
        @test prepared.science.pupil.shape == (2, 4, 4)
        @test prepared.science.pupil.schema == expected_science.pupil.schema
        @test keys(prepared.science.sensors) == keys(expected_science.sensors)
        for name in keys(expected_science.sensors)
            @test prepared.science.sensors[name].schema ==
                expected_science.sensors[name].schema
            @test size(prepared.science.sensors[name].image) == (8, 8)
            @test prepared.science.sensors[name].properties ==
                expected_science.sensors[name].properties
        end
        Optical.warmup!(prepared.execution)
        actual = optical_trajectory(prepared.execution)
        @test actual == expected
        @test count(==(:trigger), actual) == 4
        events = filter(!=(:trigger), actual)
        @test length(events) == 6
        @test sort(unique(event.duration for event in events)) == [2_000_000, 4_000_000]
        @test all(event -> all(isfinite, event.image) && sum(event.image) > 0, events)
        Optical.reset!(prepared.execution, (; streams = ()))
        @test optical_trajectory(prepared.execution) == expected
        # Warmup must restore the same authored detector RNG, exposure and chop state.
        Optical.reset!(prepared.execution, (; streams = ()))
        Optical.warmup!(prepared.execution)
        @test optical_trajectory(prepared.execution) == expected
        @test authored_snapshot(source) == before
        cold_configuration = deepcopy(configuration)
        cold_configuration["chopping"] = Dict(
            "scc" => Dict(string(k) => v for (k, v) in pairs(chopping.scc))
        )
        cold_path = joinpath(directory, "cold-export.yaml")
        C.write_yaml(cold_path, cold_configuration)
        project = dirname(Base.active_project())
        cold_bundle = joinpath(directory, "cold-bundle")
        run(
            `$(Base.julia_cmd()) --startup-file=no --project=$project -e $COLD_OPTICAL_EXPORT_CHILD $path $cold_path $cold_bundle`,
        )
        @test authored_snapshot(source) == before
        relocated = joinpath(directory, "relocated")
        mv(bundle, relocated)
        relocated_config = joinpath(relocated, relpath(exported, bundle))
        rm(source; recursive = true)
        result = joinpath(directory, "child-result.bin")
        project = dirname(Base.active_project())
        run(
            `$(Base.julia_cmd()) --startup-file=no --project=$project -e $RELOCATED_OPTICAL_CHILD $relocated_config $result`,
        )
        @test deserialize(result) == expected
    end
    @test all(id -> id.name ∉ ("CUDA", "AMDGPU"), keys(Base.loaded_modules))
end

module ClockedSourceDocuments
using PipeWireAORTC
include(joinpath(@__DIR__, "pupil_source_documents.jl"))
end

@testset "standalone clocked optics retain native mirror and entrance pupil planes" begin
    mktempdir() do directory
        source = joinpath(directory, "source")
        mkpath(source)
        (; physical, simulation) = ClockedSourceDocuments.pupil_source_documents(source)
        source_graph = deepcopy(simulation["graphs"]["plant"])
        # Inline this tiny public AOS node declaration: a mirror profile applies
        # replacements to every graph, while optical paths contain no mirror node.
        source_graph["nodes"][1] = Dict(
            "name" => "primary",
            "type" => "grid_gaussian_deformable_mirror_surface_f32",
            "config" => Dict(
                "actuator_axis_count" => 2,
                "actuator_count" => 2,
                "actuator_pitch" => 0.2,
                "influence_width" => 0.2 / sqrt(-2log(0.15)),
                "aperture_revision" => 1,
                "central_obstruction_ratio" => 0.0,
                "pupil_reflectivity" => 1.0,
                "resolution" => 4,
                "telescope_diameter_m" => 0.012,
                "actuator_grid_indices_schema" => "example.grid/1",
                "pdm_command_schema" => "example.command/1",
                "surface_opd_schema" => "example.surface/1",
            ),
        )
        source_graph["parameters"] = [
            Dict(
                "binding" => "primary_indices",
                "destination" => "primary.actuator_grid_indices",
            ),
        ]
        simulation["bindings"]["primary_indices"] = Dict(
            "kind" => "mirror_grid_indices", "mirror" => "primary"
        )
        simulation["profiles"] = Dict(
            "grid_gaussian" => Dict("nodes" => Any[], "parameters" => Any[])
        )
        empty!(simulation["components"])
        # Entrance OPD is independent of the physical mirror output. Apply the
        # measured mirror only at the explicit downstream PROPER DM plane.
        empty!(source_graph["links"])
        push!(
            source_graph["inputs"],
            Dict(
                "name" => "zero_surface",
                "binding" => "zero_surface",
                "destination" => "composition.surface_opd",
            ),
        )
        push!(
            source_graph["outputs"],
            Dict("name" => "dm_opd", "source" => "primary.surface_opd"),
        )
        simulation["bindings"]["zero_surface"] = Dict(
            "kind" => "zeros", "type" => "Float32", "shape" => [4, 4]
        )
        optical_physical, optical_simulation = external_optical_documents()
        physical["wavefront_sensors"] = optical_physical["wavefront_sensors"]
        physical["optical_paths"] = Dict(
            name => Dict("sensor" => name, "lyot_stop_port" => port) for
            (name, port) in (("scc", "transmitted"), ("llowfs", "reflected"))
        )
        for sensor in values(physical["wavefront_sensors"])
            sensor["acquisition"] = Dict("exposure_duration_s" => 0.002)
        end
        optical = optical_simulation["components"]["optics"]
        optical["template"] = "proper_optical_train_f32"
        optical["config"]["steps"] = [
            Dict(
                "op" => "add_opd",
                "name" => "physical_mirror",
                "input" => "dm_opd",
                "size" => [4, 4],
                "axes" => [1, 2],
                "sampling_m" => [0.003, 0.003],
                "center_pixel" => [3, 3],
                "schema" => "example.surface/1",
                "outside_opd_m" => 0.0,
            ),
        ]
        simulation["components"]["optics"] = optical
        for name in ("pupil_opd", "pupil_amplitude", "dm_opd")
            simulation["bindings"][name] = Dict(
                "kind" => "zeros", "type" => "Float32", "shape" => [4, 4]
            )
        end
        # Preserve the source's physical telescope aperture amplitude binding.
        simulation["bindings"]["source_amplitude"] = Dict(
            "kind" => "pupil_amplitude",
            "type" => "Float32",
            "resolution" => "pupil_resolution",
        )
        graphs = optical_simulation["graphs"]
        for graph in values(graphs)
            push!(
                graph["inputs"],
                Dict(
                    "name" => "dm_opd",
                    "binding" => "dm_opd",
                    "destination" => "optics.dm_opd",
                ),
            )
        end
        simulation["graphs"] = merge(graphs, Dict("source" => source_graph))
        path = write_external_optical_documents(source, physical, simulation)
        before = authored_snapshot(source)
        configuration = Dict(
            "mode" => "clocked_optical",
            "pipewire" => Dict(
                "remote" => "clocked-test",
                "sensor_node_names" =>
                    Dict("scc" => "clocked-scc", "llowfs" => "clocked-llowfs"),
                "sensor_buffers" => 4,
                "reference_clock" => "realtime",
                "command" => Dict(
                    "node_name" => "mirror-command",
                    "schema" => "example.command/1",
                    "properties" => Dict("command.units" => "m"),
                    "buffers" => 4,
                ),
            ),
            "source" => Dict(
                "graph" => "source",
                "command_input" => "command",
                "amplitude_binding" => "source_amplitude",
                "pupil_axes" => [2, 1],
                "period_ns" => 2_000_000,
                "command_limit" => 1.0,
                "pacing_period_ns" => 0,
            ),
        )
        exported = IC.export_simulation(path, joinpath(directory, "bundle"); configuration)
        prepared = Simulation.prepare(Simulation.load(exported))
        @test prepared.execution.clocked
        @test prepared.execution.command == zeros(Float32, 2)
        @test authored_snapshot(source) == before
        expected_source = IC.prepare_system(path; simulation_graph = "source")
        reference_science = prepare_external_pupil_ports(path)
        declaration = IC.load_simulation(path)
        amplitude = IC.binding_values(
            declaration,
            IC.settings(declaration),
            declaration.document["bindings"]["source_amplitude"],
        )
        reference_science = Optical.prepare_clocked_source(
            reference_science;
            source = expected_source,
            command_input = :command,
            amplitude,
            pupil_axes = (2, 1),
            period_ns = 2_000_000,
        )
        reference_execution = Optical.prepare(
            reference_science; clocked = true, command_count = 2
        )
        Optical.warmup!(reference_execution)
        Optical.warmup!(prepared.execution)
        commands = (Float32[0, 0], Float32[1e-8, -2e-8], Float32[-1e-8, 2e-8])
        expected_events, expected_rasters = clocked_trajectory(
            reference_execution, commands
        )
        actual_events, actual_rasters = clocked_trajectory(prepared.execution, commands)
        @test actual_events == expected_events
        @test actual_rasters == expected_rasters
        oracle = IC.prepare_system(path; simulation_graph = "source")
        driver = FixedStepModelTimeDriver(PeriodicSchedule(; period_ns = 2_000_000))
        for (index, command) in enumerate(commands)
            copyto!(graph_input(oracle.graph, :command), command)
            @test step_graph_at!(oracle.graph, driver) ==
                ModelTimestamp((index - 1) * 2_000_000)
            @test actual_rasters[index] == graph_output(oracle.graph, :dm_opd)
        end
        @test Optical.snapshot(prepared.execution).sequence == 3
        @test any(!iszero, prepared.science.source_dm_opd)
        @test length(filter(!=(:trigger), actual_events)) == 6
        @test [event.pts for event in actual_events if event !== :trigger] == repeat([0, 2_000_000, 4_000_000]; inner = 2)
        @test authored_snapshot(source) == before
    end
end
