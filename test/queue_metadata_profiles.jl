# Cold export only: no optics, core, service or accelerator.
using Test, PipeWireAORTC, PipeWireAO
const E = PipeWireAORTC.InstrumentExport
const C = PipeWireAORTC.Common
const D = PipeWireAORTC.DeploymentConfiguration
const PREFIX = get(ENV, "PIPEWIREAO_PREFIX", "/opt/pipewireao")
function queue_profile_export(; explicit = nothing, chopped = true, downstream = nothing)
    mktempdir() do directory
        mkpath(joinpath(directory, "rtc"))
        queue(name) = Dict(
            "name" => "libpipewire-module-queue",
            "args" => Dict{String,Any}(
                "node.name" => name,
                "queue.media" => "application/ndarray",
                "queue.storage" => "copy",
                "queue.overflow" => "drop-oldest",
                "capture.props" => Dict("node.name" => name * "-input"),
                "playback.props" => Dict("node.name" => name * "-output"),
            ),
        )
        modules = Any[queue(name) for name in ("scc", "llowfs", "unconnected", "chain")]
        explicit === nothing || (modules[1]["args"]["metadata"] = deepcopy(explicit))
        downstream === nothing || (modules[4]["args"]["metadata"] = deepcopy(downstream))
        C.write_json(
            joinpath(directory, "rtc/core.conf"), Dict("context.modules" => modules)
        )
        session = Dict(
            "links" => [
                Dict("output" => source, "input" => sink) for (source, sink) in (
                    ("scc-output:capture_1", "chain-input:playback_1"),
                    ("camera-scc:output_1", "scc-input:playback_1"),
                    ("camera-llowfs:output_1", "llowfs-input:playback_1"),
                )
            ],
        )
        C.write_json(joinpath(directory, "session.conf"), session)
        C.write_json(
            joinpath(directory, "simulation.conf"),
            Dict(
                "version" => 6,
                "sensor_nodes" => Dict("scc" => "camera-scc", "llowfs" => "camera-llowfs"),
                "plant" => Dict("chopping" => chopped ? Dict("scc" => Dict()) : Dict()),
            ),
        )
        spec = Dict(
            "core" => "shared-runtime/core.conf.in",
            "session" => "session.conf",
            "client" => Dict("core" => "shared-runtime/client-rtc.conf.in"),
        )
        profile = Dict(
            "scheduling" => Dict(
                "processes" => Dict(
                    "core" => Dict(
                        "rt-priority" => 0,
                        "data-loops" => Dict(
                            "rtc-data-loop" => [2], "telemetry-loop" => [3]
                        ),
                    ),
                ),
            ),
        )
        E.render_templates!(directory, spec, profile, PREFIX)
        E.prepare_session_configuration!(
            directory, spec, [], "unused-instrument.json", PREFIX
        )
        core = D.decode(joinpath(directory, spec["core"]), PREFIX)
        return Dict(
            m["args"]["node.name"] => m["args"]["metadata"] for
            m in core["context.modules"] if
            get(m, "name", nothing) == "libpipewire-module-queue"
        )
    end
end
@testset "queue classifications follow final source profiles and links" begin
    profiles = queue_profile_export()
    types(name) = Set(r["type"] for r in profiles[name])
    base = Set(r.type for r in C.TELEMETRY_METADATA)
    classified = union(base, Set((SPA.META_OPTICAL_CHOPPING, SPA.META_ELECTRICAL_TRIGGER)))
    @test types("scc") == classified
    @test types("chain") == classified
    @test types("llowfs") == base
    @test types("unconnected") == base
    @test all(!r["required"] for r in profiles["scc"])
end

@testset "explicit queue profiles preserve authority through queue chains" begin
    base = [
        Dict("type" => r.type, "size" => r.size, "required" => false) for
        r in C.TELEMETRY_METADATA
    ]
    classified = vcat(
        base,
        [
            Dict("type" => type, "size" => 8, "required" => true) for
            type in (SPA.META_OPTICAL_CHOPPING, SPA.META_ELECTRICAL_TRIGGER)
        ],
    )
    # No simulator/source contract supplies classifications: only the explicit
    # first queue profile establishes the capabilities offered to its successor.
    profiles = queue_profile_export(; explicit = classified, chopped = false)
    @test profiles["scc"] == classified
    @test Set(r["type"] for r in profiles["chain"]) == Set(r["type"] for r in classified)
    @test all(!r["required"] for r in profiles["chain"])
    @test_throws ArgumentError queue_profile_export(; explicit = base)
    @test_throws ArgumentError queue_profile_export(; explicit = [])
    @test_throws ArgumentError queue_profile_export(;
        explicit = classified, chopped = false, downstream = base
    )
end
