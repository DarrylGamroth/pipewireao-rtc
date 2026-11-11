using Test, PipeWireAORTC
import Clocks

const A = PipeWireAORTC.Analysis
const D = PipeWireAORTC.DeploymentConfiguration
const C = PipeWireAORTC.Common
const S = PipeWireAORTC.SystemdOwners
const L = PipeWireAORTC.SessionLaunch
const INVOCATION = "0123456789abcdef0123456789abcdef"

@testset "analysis channel units reject malformed UTF-8" begin
    malformed = String(UInt8[0xff])
    @test !isvalid(malformed)
    for units in (
        Dict("summary" => Dict("mean_flux" => malformed)),
        Dict(malformed => Dict("mean_flux" => "ADC")),
        Dict("summary" => Dict(malformed => "ADC")),
    )
        @test_throws ArgumentError A.channel_units(units)
    end
end

@testset "manager CPU affinity canonicalization" begin
    @test S._unit_cpus("6-7") == [6, 7]
    @test S._unit_cpus("6 7") == [6, 7]
    @test S._unit_cpus("6-7 10") == [6, 7, 10]
end

@testset "bounded optional analysis configuration" begin
    mktempdir() do root
        graph = joinpath(root, "analysis.jfg")
        write(graph, "graph declaration")
        path = joinpath(root, "analysis.conf")
        original = Dict{String,Any}(
            "graph" => "analysis.jfg",
            "name" => "wfs-analysis",
            "rate" => "500/1",
            "links" => [
                Dict(
                    "output" => "detector-observation:output",
                    "input" => "wfs-analysis:detector",
                ),
                Dict("output" => "wfs-analysis:rms", "input" => "rms-observation:input"),
            ],
        )
        save(value = original) = C.write_json(path, value)
        save()
        config = A.configuration(path, root)
        @test config isa A.Config
        @test config.graph == realpath(graph)
        @test config.name == "wfs-analysis"
        @test config.rate == 500//1
        @test config.links[1].output == A.Endpoint("detector-observation", "output")
        @test config.links[1].input == A.Endpoint("wfs-analysis", "detector")
        @test fieldtype(A.Config, :links) == Vector{A.LinkSpec}
        @test isempty(config.channel_units)
        @test isempty(
            A.Config(config.graph, config.name, config.rate, config.links).channel_units
        )
        declared_units = Dict("summary" => Dict("mean_x_slope" => "detector pixel"))
        save(merge(original, Dict("channel-units" => declared_units)))
        @test A.configuration(path, root).channel_units == declared_units
        for units in (
            [],
            Dict("summary" => "pixel"),
            Dict("summary" => Dict("mean-x" => "pixel")),
            Dict("summary" => Dict("mean_x_slope" => nothing)),
            Dict("summary" => Dict("mean_x_slope" => "")),
            Dict("summary" => Dict("mean_x_slope" => "bad\nunits")),
            Dict("summary" => Dict("mean_x_slope" => repeat("µ", 128))),
            Dict("summary" => Dict("channel$i" => "pixel" for i in 1:65)),
            Dict("output$i" => Dict() for i in 1:65),
        )
            save(merge(original, Dict("channel-units" => units)))
            @test_throws ArgumentError A.configuration(path, root)
        end
        for (key, value) in (
            ("rate", "0/1"),
            ("rate", "1/0"),
            ("rate", "500"),
            ("rate", 500),
            ("name", "bad:node"),
            ("unknown", true),
            ("graph", graph),
            ("links", fill(original["links"][1], 65)),
            ("links", [original["links"][1], original["links"][1]]),
            ("links", [Dict("output" => "other:out", "input" => "else:in")]),
            ("links", [Dict("output" => "wfs-analysis:out", "input" => "wfs-analysis:in")]),
        )
            changed = merge(original, Dict(key => value))
            save(changed)
            @test_throws Exception A.configuration(path, root)
        end
        mktempdir() do outside
            write(joinpath(outside, "outside.jfg"), "other graph")
            symlink(joinpath(outside, "outside.jfg"), joinpath(root, "escape.jfg"))
            save(merge(original, Dict("graph" => "escape.jfg")))
            @test_throws D.DeploymentError A.configuration(path, root)
            save(
                merge(
                    original,
                    Dict("graph" => relpath(joinpath(outside, "outside.jfg"), root)),
                ),
            )
            @test_throws D.DeploymentError A.configuration(path, root)
        end
        save()
        entry = Dict{String,Any}(
            "name" => "wfs", "config" => "analysis.conf", "cpus" => [6, 7]
        )
        spec = Dict{String,Any}(
            "analysis" => [entry],
            "placement" => Dict("core" => Dict("cpus" => [2, 3])),
            "node-owners" => Dict("science" => "core"),
            "artifacts" =>
                Dict("analysis.conf" => D.digest(path), "analysis.jfg" => D.digest(graph)),
        )
        client = joinpath(root, "client-analysis.conf")
        write(client, "{}")
        core = joinpath(root, "core.conf")
        C.write_json(
            core,
            Dict(
                "context.modules" => [
                    Dict(
                        "name" => "libpipewire-module-queue",
                        "args" => Dict(
                            "queue.storage" => "copy",
                            "queue.overflow" => "drop-oldest",
                            "queue.max-buffers" => 1,
                            "playback.props" =>
                                Dict("node.name" => "detector-observation"),
                            "capture.props" => Dict("node.name" => "rms-observation"),
                        ),
                    ),
                ],
            ),
        )
        session = joinpath(root, "session.conf")
        C.write_json(session, Dict("links" => []))
        spec["session"] = "session.conf"
        spec["client"] = Dict("analysis" => "client-analysis.conf")
        spec["core"] = "core.conf"
        spec["artifacts"]["client-analysis.conf"] = D.digest(client)
        spec["artifacts"]["core.conf"] = D.digest(core)
        deployment = joinpath(root, "deployment.conf")
        @test A.validate_deployment(spec, deployment, root) === nothing
        # Optional calibrated prefixes retain the ordinary sealed FITS authority.
        bindings = joinpath(root, "parameters.conf")
        fits = joinpath(root, "background.fits")
        write(fits, "sealed bytes; numerical typing is checked by the science selector")
        C.write_json(
            bindings,
            Dict(
                "parameters" => [
                    Dict(
                        "port" => "background",
                        "path" => "background.fits",
                        "axes" => [2, 1],
                    ),
                ],
            ),
        )
        save(merge(original, Dict("fits-bindings" => "parameters.conf")))
        @test A.configuration(path, root).fits_bindings == realpath(bindings)
        @test_throws D.DeploymentError A.validate_deployment(spec, deployment, root)
        spec["artifacts"]["parameters.conf"] = D.digest(bindings)
        @test_throws D.DeploymentError A.validate_deployment(spec, deployment, root)
        spec["artifacts"]["background.fits"] = D.digest(fits)
        @test A.validate_deployment(spec, deployment, root) === nothing
        mktemp() do outside, io
            C.write_json(
                bindings,
                Dict("parameters" => [Dict("port" => "background", "path" => outside)]),
            )
            @test_throws D.DeploymentError A.validate_deployment(spec, deployment, root)
        end
        save()
        second = deepcopy(original)
        second["name"] = "wfs-other"
        for link in second["links"], key in ("input", "output")
            link[key] = replace(link[key], "wfs-analysis:" => "wfs-other:")
        end
        second_path = joinpath(root, "analysis-other.conf")
        C.write_json(second_path, second)
        spec["artifacts"]["analysis-other.conf"] = D.digest(second_path)
        other = merge(entry, Dict("name" => "other", "config" => "analysis-other.conf"))
        @test_throws D.DeploymentError A.validate_deployment(
            merge(spec, Dict("analysis" => [entry, other])), deployment, root
        )
        spec["node-owners"]["rms-observation"] = "core"
        save(
            merge(
                original,
                Dict(
                    "links" => [
                        Dict(
                            "output" => "wfs-analysis:rms",
                            "input" => "rms-observation:input",
                        ),
                    ],
                ),
            ),
        )
        @test A.validate_deployment(spec, deployment, root) === nothing
        save(
            merge(
                original,
                Dict(
                    "links" => [
                        Dict("output" => "science:out", "input" => "wfs-analysis:detector"),
                    ],
                ),
            ),
        )
        @test_throws D.DeploymentError A.validate_deployment(spec, deployment, root)
        save(
            merge(
                original,
                Dict(
                    "links" => [
                        Dict(
                            "output" => "undeclared:out",
                            "input" => "wfs-analysis:detector",
                        ),
                    ],
                ),
            ),
        )
        @test_throws D.DeploymentError A.validate_deployment(spec, deployment, root)
        save()
        C.write_json(
            session,
            Dict(
                "links" =>
                    [Dict("output" => "science:out", "input" => "rms-observation:input")],
            ),
        )
        @test_throws D.DeploymentError A.validate_deployment(spec, deployment, root)
        C.write_json(
            session,
            Dict(
                "links" => [
                    Dict(
                        "output" => "detector-observation:output",
                        "input" => "science:in",
                    ),
                ],
            ),
        )
        @test_throws D.DeploymentError A.validate_deployment(spec, deployment, root)
        C.write_json(session, Dict("links" => []))
        queue_doc = C.read_json(core)
        spoofed = deepcopy(queue_doc)
        args = spoofed["context.modules"][1]["args"]
        args["queue.storage"] = "lease"
        for key in ("capture.props", "playback.props")
            args[key]["queue.storage"] = "copy"
        end
        C.write_json(core, spoofed)
        @test_throws D.DeploymentError A.validate_deployment(spec, deployment, root)
        queue_doc["context.modules"][1]["args"]["capture.props"]["queue.storage"] = "retain"
        C.write_json(core, queue_doc)
        @test_throws D.DeploymentError A.validate_deployment(spec, deployment, root)
        delete!(queue_doc["context.modules"][1]["args"]["capture.props"], "queue.storage")
        C.write_json(core, queue_doc)
        write(client, "{\"context.modules\":[{\"name\":\"libpipewire-module-rt\"}]}")
        @test_throws D.DeploymentError A.validate_deployment(spec, deployment, root)
        write(client, "{}")
        for cpus in ([0], [1], [2], [6, 6], Int[], [true], [6.0], collect(6:134))
            changed = merge(spec, Dict("analysis" => [merge(entry, Dict("cpus" => cpus))]))
            @test_throws D.DeploymentError A.validate_deployment(changed, deployment, root)
        end
        for name in ("Wfs", "../wfs", repeat("a", 24))
            changed = merge(spec, Dict("analysis" => [merge(entry, Dict("name" => name))]))
            @test_throws D.DeploymentError A.validate_deployment(changed, deployment, root)
        end
        @test_throws D.DeploymentError A.validate_deployment(
            merge(spec, Dict("analysis" => [entry, entry])), deployment, root
        )
        @test_throws D.DeploymentError A.validate_deployment(
            merge(spec, Dict("analysis" => fill(entry, 9))), deployment, root
        )
        for asset in ("analysis.conf", "analysis.jfg")
            changed = deepcopy(spec)
            delete!(changed["artifacts"], asset)
            @test_throws D.DeploymentError A.validate_deployment(changed, deployment, root)
        end
        save(
            merge(
                original,
                Dict(
                    "links" =>
                        [Dict("output" => "wfs-analysis:rms", "input" => "science:in")],
                ),
            ),
        )
        @test_throws D.DeploymentError A.validate_deployment(spec, deployment, root)
        @test A.validate_deployment(Dict("analysis" => []), deployment, root) === nothing
        @test A.arguments(["--config", path, "--remote", "/private/remote"]) ==
            (path, "/private/remote")
        for args in (
            ["--config", path],
            ["--remote", "relative", "--config", path],
            ["--config", path, "--remote", "/remote", "--bootstrap-node", "forbidden"],
            ["--config", path, "--config", path, "--remote", "/remote"],
        )
            @test_throws ArgumentError A.arguments(args)
        end
    end
end

@testset "optional analysis uses ordinary isolated services and one-way lifetime" begin
    coordinator = S.Coordinator("pipewireao-session@test.service", INVOCATION, "")
    service = S.Service(coordinator, "analysis-wfs")
    unit = S.service_unit(
        service,
        ["/usr/bin/true"],
        Dict(),
        "/tmp",
        Dict("cpus" => [7, 6], "leader-cpu" => 6);
        part_of = [coordinator.unit],
        ordinary = true,
        stop_signal = "SIGHUP",
    )
    lines = split(unit, '\n')
    for line in (
        "PartOf=$(coordinator.unit)",
        "KillSignal=SIGHUP",
        "CPUAffinity=6 7",
        "Nice=10",
        "RestrictRealtime=yes",
        "LimitRTPRIO=0",
        "Restart=no",
        "KillMode=control-group",
    )
        @test line in lines
    end
    @test !any(
        line ->
            startswith(line, "Requires=") ||
            startswith(line, "Wants=") ||
            startswith(line, "Requisite=") ||
            startswith(line, "BindsTo="),
        lines,
    )
    @test !any(line -> startswith(line, "After=") || startswith(line, "Before="), lines)
    paths = Dict("library" => "/private/lib", "modules" => "/private/modules", "spa" => "/private/spa")
    env = L.analysis_environment(paths, "/private/runtime", "analysis-wfs", "/private/prefix", "core")
    @test env["PIPEWIRE_REMOTE"] == "core"
    @test env["PIPEWIREAO_CONFIG_DIR"] == "/private/runtime/analysis-wfs"
    for key in ("CUDA_VISIBLE_DEVICES", "ROCR_VISIBLE_DEVICES", "HIP_VISIBLE_DEVICES")
        @test env[key] == ""
    end
    for key in ("OPENBLAS_NUM_THREADS", "MKL_NUM_THREADS", "OMP_NUM_THREADS")
        @test env[key] == "1"
    end
    @test env["JULIA_NUM_THREADS"] == "2"
    @test !haskey(env, "INVOCATION_ID")
    mktempdir() do runtime
        launch = Dict(
            "version" => 2,
            "runtime" => runtime,
            "unit" => coordinator.unit,
            "invocation" => INVOCATION,
            "owners" => Dict("core" => Dict("unit" => "required-core")),
        )
        clock = Clocks.CachedNanoClock(10)
        @test_logs (:warn, r"Optional analysis startup failed") L.start_analysis!(
            runtime, "/missing", Dict("analysis" => [Dict()]), launch; deadline = 10, clock
        )
        record = C.read_json(joinpath(runtime, "launch.json"))
        @test length(record["analysis_errors"]) == 1
        @test record["owners"] == launch["owners"]
        @test !ispath(joinpath(runtime, "analysis.json"))
        @test !ispath(joinpath(runtime, "analysis.lock"))
    end
end

# Exercise fragment cleanup without contacting a live user manager. The actual
# remover is loaded with deterministic manager observations and recorded commands.
module FragmentRemovalProof
import PipeWireAORTC
import Clocks
const deadline_ns = PipeWireAORTC.SystemdOwners.deadline_ns
const Placement = PipeWireAORTC.Placement
const Common = PipeWireAORTC.Common
const PREFIX = PipeWireAORTC.SystemdOwners.PREFIX
const observations = Dict{String,Dict{String,String}}()
const commands = Vector{String}[]
fail(message) = throw(ArgumentError(message))
cohort_name(invocation) = PREFIX * invocation * "-cohort.target"
properties(unit; kwargs...) = observations[unit]
quiescent_unit(unit; kwargs...) = true
checked(argv; kwargs...) = (push!(commands, argv); (; returncode = 0))
include(joinpath(pkgdir(PipeWireAORTC), "src/deployment/systemd_unit_files.jl"))
end

@testset "optional fragment removal retains exact identity proof" begin
    F = FragmentRemovalProof
    mktempdir() do runtime_root
        withenv("XDG_RUNTIME_DIR" => runtime_root) do
            runtime = joinpath(runtime_root, "invocation")
            mkpath(joinpath(runtime, "units"))
            unit = S.PREFIX * INVOCATION * "-analysis-wfs.service"
            path = joinpath(runtime, "units", unit)
            write(path, "retained definition")
            link = joinpath(F.runtime_unit_directory(), unit)
            symlink(path, link)
            receipt = Dict{String,Any}(
                "invocation" => INVOCATION,
                "owners" => Dict("analysis-wfs" => Dict()),
                "unit_files" =>
                    Dict(unit => Dict("path" => path, "sha256" => C.sha256_file(path))),
            )
            F.observations[unit] = Dict(
                "LoadState" => "loaded", "FragmentPath" => path, "DropInPaths" => ""
            )
            merge!(
                F.observations[unit],
                Dict(
                    "Type" => "exec",
                    "Restart" => "no",
                    "KillMode" => "control-group",
                    "UMask" => "0077",
                    "CPUAffinity" => "6-7",
                    "LimitRTPRIO" => "0",
                    "LimitMEMLOCK" => "4294967296",
                    "RestrictRealtime" => "yes",
                    "Nice" => "10",
                ),
            )
            placement = Dict("cpus" => [6, 7], "leader-cpu" => 6)
            @test F.verify_fragment!(unit, receipt; placement, ordinary = true) === nothing
            F.observations[unit]["RestrictRealtime"] = "no"
            @test_throws ArgumentError F.verify_fragment!(
                unit, receipt; placement, ordinary = true
            )
            F.observations[unit]["RestrictRealtime"] = "yes"
            delete!(receipt["owners"], "analysis-wfs")
            @test_throws ArgumentError F.remove_fragments!(runtime, receipt, Inf)
            receipt["owners"]["analysis-wfs"] = Dict()
            @test isfile(path) && islink(link)
            write(path, "tampered definition")
            @test_throws ArgumentError F.remove_fragments!(
                runtime, receipt, Inf
            )
            write(path, "retained definition")
            F.observations[unit]["DropInPaths"] = "/foreign.conf"
            @test_throws ArgumentError F.remove_fragments!(
                runtime, receipt, Inf
            )
            F.observations[unit]["DropInPaths"] = ""
            rm(link)
            symlink("/foreign-definition", link)
            @test_throws ArgumentError F.remove_fragments!(
                runtime, receipt, Inf
            )
            rm(link)
            symlink(path, link)
            @test F.remove_fragments!(
                runtime, receipt, Inf
            ) === nothing
            @test !ispath(path) && !islink(link)
            @test receipt["unit_files_removed"]
            @test last(F.commands) == ["systemctl", "--user", "daemon-reload"]
        end
    end
end

module InvocationCleanupProof
import Clocks
import PipeWireAORTC.SessionLaunch: validate_ledger, optional_role
const events = String[]
const invocation = "0123456789abcdef0123456789abcdef"
module S
import ..events, ..invocation
const PREFIX = "pipewireao-owner-"
const ROLE = r"^[a-z][a-z0-9-]*$"
name(role) = PREFIX * invocation * "-" * role * ".service"
listed_units(args...; kwargs...) = name.(["core", "simulator", "julia", "analysis-wfs"])
listed_jobs(args...; kwargs...) = Pair{String,String}[]
cancel_start_jobs!(args...; kwargs...) = nothing
quiescent_unit(unit; kwargs...) = true
remove_fragments!(args...; kwargs...) = push!(events, "remove fragments")
end
cleanup_role!(record, role, deadline; kwargs...) = push!(events, role)
fail(message) = error(message)
launch_record!(args...) = nothing
end

@testset "analysis is stopped and removed in the invocation sweep" begin
    source = read(
        joinpath(pkgdir(PipeWireAORTC), "src/deployment/session_launch.jl"), String
    )
    position = first(findfirst("function cleanup_record!", source))
    expression, _ = Meta.parse(source, position)
    Core.eval(InvocationCleanupProof, expression)
    owners = Dict(role => Dict{String,Any}() for role in ("core", "simulator", "julia"))
    owners["analysis-wfs"] = Dict("optional" => true)
    record = Dict{String,Any}(
        "version" => 2, "invocation" => INVOCATION, "owners" => owners, "error" => nothing,
    )
    @test InvocationCleanupProof.cleanup_record!(
        "/unused", record, INVOCATION, "simulator"
    ) === nothing
    @test InvocationCleanupProof.events ==
        ["core", "simulator", "julia", "analysis-wfs", "remove fragments"]
    @test record["cleanup_complete"] === true
end
