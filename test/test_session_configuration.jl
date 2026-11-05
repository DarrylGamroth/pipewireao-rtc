using Test, PipeWireAORTC
using PipeWireAORTC: SessionConfiguration

@testset "declared core-hosted session nodes" begin
    spec = Dict(
        "name" => "core-session",
        "source-owner" => "simulator",
        "owners" => [
            Dict(
                "role" => "simulator",
                "control-protocol" => "pipewireao.source-control/1",
                "control-node" => "simulator-wfs",
            ),
        ],
    )
    session = Dict(
        "sources" => [Dict("node.name" => "simulator-wfs")],
        "sinks" => [Dict("node.name" => "core-sink")],
        "graphs" => [],
        "links" =>
            [Dict("output" => "simulator-wfs:output_1", "input" => "core-sink:input_1")],
    )
    bindings = Dict(
        "RUNTIME" => "/tmp/core-session",
        "REMOTE" => "rtc-core-session",
        "SESSION_UUID" => "00000000-0000-0000-0000-000000000001",
        "SESSION_CONTROL_INSTANCE" => "21",
        "SESSION_CONTROLLER_INSTANCE" => "22",
        "ADMISSION_CONTROLLER_INSTANCE" => "23",
    )
    records = Dict(
        role => Dict{String,Any}(
            "role" => role,
            "pid" => pid,
            "state" => "running",
            "start-ticks" => 1,
            "invocation" => role * "-invocation",
            "cgroup" => "/owners/" * role,
        ) for (role, pid) in (("simulator", 42), ("core", 43))
    )
    records["simulator"]["control-instance"] = "24"
    mapping = Dict("simulator-wfs" => "simulator", "core-sink" => "core")
    configuration = SessionConfiguration.session_configuration(
        spec, session, bindings, records; node_owners = mapping
    )
    policy = configuration["pipewireao.session"]
    @test policy["startup.timeout-ms"] == 300000
    @test Set(keys(configuration)) ==
        Set(("context.properties", "context.modules", "pipewireao.session"))
    @test all(!startswith(key, "wireplumber.") for key in keys(configuration))
    @test Set(keys(policy)) ⊇ Set((
        "session",
        "owners",
        "source",
        "auxiliary-sources",
        "node.pids",
        "core.owner",
        "instance",
        "controller.instance",
        "session.uuid",
        "node.name",
        "controller.node.name",
        "admission.controller-instance",
        "startup.timeout-ms",
        "journal.path",
        "properties",
    ))
    @test policy["journal.path"] ==
        joinpath(PipeWireAORTC.ConfigurationStore.default_root(), "history.sqlite3")
    @test policy["properties"]["pipewireao.rtc.session.session-uuid"] ==
        bindings["SESSION_UUID"]
    @test policy["properties"]["pipewireao.rtc.session.journal"] ==
        "pipewireao.configuration/1"
    disabled = SessionConfiguration.session_configuration(
        spec,
        session,
        bindings,
        records;
        node_owners = mapping,
        configuration_store_root = nothing,
    )
    @test !haskey(disabled["pipewireao.session"], "journal.path")
    @test !haskey(
        disabled["pipewireao.session"]["properties"], "pipewireao.rtc.session.journal"
    )
    @test_throws SessionConfiguration.ConfigurationError SessionConfiguration.session_configuration(
        spec,
        session,
        bindings,
        records;
        node_owners = mapping,
        configuration_store_root = "relative",
    )

    spec["startup-timeout-ms"] = 900000
    budget_configuration = SessionConfiguration.session_configuration(
        spec, session, bindings, records; node_owners = mapping
    )
    @test budget_configuration["pipewireao.session"]["startup.timeout-ms"] == 900000
    delete!(spec, "startup-timeout-ms")
    @test policy["core.owner"] == Dict("pid" => 43, "nodes" => ["core-sink"])
    @test policy["node.pids"] == Dict("simulator-wfs" => 42, "core-sink" => 43)
    @test mapping == Dict("simulator-wfs" => "simulator", "core-sink" => "core")
    mapping["core-sink"] = "simulator"
    configuration = SessionConfiguration.session_configuration(
        spec, session, bindings, records; node_owners = mapping
    )
    policy = configuration["pipewireao.session"]
    @test isempty(policy["core.owner"]["nodes"])
    mktempdir() do runtime
        private = merge(bindings, Dict("RUNTIME" => runtime))
        path = SessionConfiguration.write_session_config(
            spec,
            session,
            private,
            records,
            runtime;
            node_owners = mapping,
            configuration_store_root = nothing,
        )
        @test path == joinpath(runtime, "rtc/rtc.conf")
        @test isfile(path)
    end
    for count in (1, 36, 64)
        selected = merge(session, Dict("links" => fill(only(session["links"]), count)))
        compiled = SessionConfiguration.session_configuration(
            spec, selected, bindings, records; node_owners = mapping
        )
        @test length(compiled["pipewireao.session"]["session"]["links"]) == count
    end
    @test_throws SessionConfiguration.ConfigurationError SessionConfiguration.session_configuration(
        spec, merge(session, Dict("links" => [])), bindings, records; node_owners = mapping
    )
    @test_throws PipeWireAORTC.DeploymentConfiguration.DeploymentError SessionConfiguration.session_configuration(
        spec,
        merge(session, Dict("links" => fill(only(session["links"]), 65))),
        bindings,
        records;
        node_owners = mapping,
    )
    records["core"]["pid"] = 0
    @test_throws SessionConfiguration.ConfigurationError SessionConfiguration.session_configuration(
        spec, session, bindings, records; node_owners = mapping
    )
end

@testset "bounded cold startup budget" begin
    D = PipeWireAORTC.DeploymentConfiguration
    @test D.startup_timeout_ms(Dict()) == 300000
    for timeout in (1000, 300000, 900000, 3600000)
        @test D.startup_timeout_ms(Dict("startup-timeout-ms" => timeout)) == timeout
    end
    for timeout in (0, -1, true, 1000.0, "900000", 3600001)
        @test_throws D.DeploymentError D.startup_timeout_ms(
            Dict("startup-timeout-ms" => timeout)
        )
    end
end

@testset "exact headless RTC invocation and protected environment" begin
    D = PipeWireAORTC.DeploymentConfiguration
    contract = Dict(
        "argv" => ["@PACKAGE@/rtc/bin/pipewireao-rtc", "-c", "@RUNTIME@/rtc/rtc.conf"],
        "environment" => Dict{String,String}(),
    )
    @test D.validate_session_runtime(contract) === nothing
    @test D.session_executable(
        Dict("session-runtime" => contract), "/package", "/prefix"
    ) == "/package/rtc/bin/pipewireao-rtc"
    for argv in (
        ["@PACKAGE@/wireplumber/bin/wireplumber", "-c", "@RUNTIME@/rtc/rtc.conf"],
        [
            "@PACKAGE@/rtc/bin/pipewireao-rtc",
            "-c",
            "@RUNTIME@/rtc/rtc.conf",
            "-p",
            "ao-rtc",
        ],
        [
            "@PACKAGE@/rtc/bin/pipewireao-rtc",
            "-c",
            "@RUNTIME@/wireplumber/wireplumber.conf",
        ],
        ["@PACKAGE@/rtc/bin/pipewireao-rtc", "--config", "@RUNTIME@/rtc/rtc.conf"],
    )
        @test_throws D.DeploymentError D.validate_session_runtime(
            merge(contract, Dict("argv" => argv))
        )
    end
    for key in D.SESSION_PRIVATE_ENVIRONMENT
        @test_throws D.DeploymentError D.validate_session_runtime(
            merge(contract, Dict("environment" => Dict(key => "/untrusted")))
        )
    end
    registered = deepcopy(contract)
    registered["argv"][1] = "@PACKAGE@/rtc/bin/pipewireao-rtc"
    @test D.session_executable(
        Dict("runtime" => Dict(), "session-runtime" => registered),
        "/application",
        "/prefix",
    ) == "/application/rtc/bin/pipewireao-rtc"
    registered["argv"][1] = "@PREFIX@/bin/pipewireao-rtc"
    @test_throws D.DeploymentError D.session_executable(
        Dict("runtime" => Dict(), "session-runtime" => registered),
        "/application",
        "/prefix",
    )
    julia = D.selected_julia_executable(Base.julia_cmd().exec[1])
    project = realpath(dirname(Base.active_project()))
    code = "using PipeWireAORTC; exit(PipeWireAORTC.MediaSession.main(ARGS))"
    binding = Dict{String,Any}(
        "julia" => julia,
        "project" => project,
        "config" => "/runtime/rtc/rtc.conf",
        "argv" => [
            julia,
            "--startup-file=no",
            "--threads=2,1",
            "--project=" * project,
            "-e",
            code,
            "--",
            "-c",
            "/runtime/rtc/rtc.conf",
        ],
    )
    @test_throws D.DeploymentError D.verify_session_process(getpid(), binding)
    tampered = merge(binding, Dict("argv" => [julia, "-c", "/runtime/rtc/rtc.conf"]))
    @test_throws D.DeploymentError D.verify_session_process(getpid(), tampered)
    template = read(
        joinpath(PipeWireAORTC.resource_root(), "pipewireao-session@.service.in"), String
    )
    @test occursin("ExecStart=@RTC_EXECUTABLE@ -c \${RTC_CONFIG}", template)
    @test !occursin("-p ao-rtc", template)
end

@testset "ledger validation verifies the prepared native process" begin
    R = PipeWireAORTC.SessionRuntime
    C = PipeWireAORTC.Common
    D = PipeWireAORTC.DeploymentConfiguration
    mktempdir() do root
        invocation = "0"^32
        runtime = mkpath(joinpath(root, invocation))
        handle = R.Handle(
            "pipewireao-session@test.service",
            root,
            invocation,
            getpid(),
            UInt64(1),
            "/test",
            false,
            false,
            false,
            nothing,
        )
        C.write_json(
            joinpath(runtime, "launch.json"),
            Dict(
                "version" => 2,
                "unit" => handle.unit,
                "invocation" => invocation,
                "runtime" => runtime,
                "session_pid" => getpid(),
                "session_start_ticks" => 1,
                "session_executable" => "/sealed/rtc/bin/pipewireao-rtc",
                "session_process" => Dict(
                    "julia" => "/sealed/julia/bin/julia",
                    "project" => "/sealed/julia/env",
                    "config" => joinpath(runtime, "rtc/rtc.conf"),
                    "argv" => String[],
                ),
                "config" => joinpath(runtime, "rtc/rtc.conf"),
            ),
        )
        @test_throws D.DeploymentError R._ledger(handle)
        retained = R._retained_ledger(handle)
        @test retained["session_pid"] == getpid()
        @test retained["version"] == 2
        @test !haskey(retained, "wireplumber_pid") &&
            !haskey(retained, "wireplumber_start_ticks")
        # A stopped record still has every incarnation fence, even though it
        # cannot require a live native executable. Test each fence separately.
        path = joinpath(runtime, "launch.json")
        for (key, value) in (
            ("unit", "pipewireao-session@other.service"),
            ("invocation", "1"^32),
            ("runtime", joinpath(root, "other")),
            ("session_pid", getpid() + 1),
            ("session_start_ticks", 2),
        )
            changed = merge(retained, Dict(key => value))
            C.write_json(path, changed)
            @test_throws ArgumentError R._retained_ledger(handle)
        end
        C.write_json(path, retained)
        @test_throws D.DeploymentError R._ledger(handle)

        L = PipeWireAORTC.SessionLaunch
        @test L.validate_ledger(retained) === nothing
        for version in (1, 3, 2.0, "2", nothing)
            @test_throws ArgumentError L.validate_ledger(
                merge(retained, Dict("version" => version))
            )
        end
        @test_throws ArgumentError L.validate_ledger(Dict{String,Any}())
        old = merge(retained, Dict("version" => 1, "source_role" => "simulator"))
        C.write_json(path, old)
        before = read(path)
        @test_throws ArgumentError L.launch_record!(runtime, old)
        @test read(path) == before
        @test_throws ArgumentError L.load_record(runtime, invocation, "simulator")
        @test_throws ArgumentError L.cleanup_record!(runtime, old, invocation, "simulator")
        @test_throws ArgumentError L.cleanup_role!(old, "simulator", 0.0)
        @test_throws ArgumentError R._failed_start_record(root, handle.unit, invocation)
        @test_throws ArgumentError R._reconcile_failed_start!(
            root,
            handle.unit,
            root,
            joinpath(root, "missing.service"),
            true,
            ErrorException("injected start failure"),
        )
        @test_throws ArgumentError R.stop!(handle; deadline = 0.0)
        @test !handle.stop_attempted && read(path) == before
        @test_throws ArgumentError PipeWireAORTC.SessionCLI.retire_record!(old, nothing)
        @test_throws ArgumentError PipeWireAORTC.Analysis.start!(root, old, handle.unit)
        @test_throws ArgumentError PipeWireAORTC.Analysis.cleanup!(runtime, old, 0.0)
        @test !ispath(joinpath(runtime, "analysis.lock"))
        @test !ispath(joinpath(runtime, "analysis.json"))
        @test read(path) == before
        L.launch_record!(runtime, retained)
        @test C.read_json(path) == retained

        # Final retained reports reject unsupported layouts before returning data.
        C.write_json(
            joinpath(root, "session.json"),
            Dict(
                "unit" => handle.unit,
                "runtime_root" => joinpath(root, "pipewireao-session-test"),
                "invocation" => invocation,
            ),
        )
        C.write_json(joinpath(root, "final-launch.json"), old)
        @test_throws ArgumentError R.final_record(root)
        C.write_json(joinpath(root, "final-launch.json"), retained)
        @test R.final_record(root) == retained
    end
end

module LaunchLedgerCleanupTests
import Clocks
using PipeWireAORTC
import PipeWireAORTC.SessionLaunch: _read_ledger, validate_ledger, fail
const events = String[]
module S
import PipeWireAORTC.SystemdOwners: valid_invocation, ROLE, PREFIX
import ..events
cancel_start_jobs!(args...; kwargs...) = push!(events, "cancel")
listed_jobs(args...; kwargs...) = Pair{String,String}[]
cleanup_unit(unit; kwargs...) = push!(events, unit)
end
monotonic() = 0.0
cleanup_record!(args...; kwargs...) =
    (push!(events, "consumers"); error("unexpected consumer cleanup"))
launch_record!(args...) = push!(events, "write")
end

@testset "ledger versions fence cleanup before manager mutations" begin
    L = PipeWireAORTC.SessionLaunch
    C = PipeWireAORTC.Common
    source = read(
        joinpath(pkgdir(PipeWireAORTC), "src/deployment/session_launch.jl"), String
    )
    position = first(findfirst("function cleanup_invocation!", source))
    expression, _ = Meta.parse(source, position)
    Core.eval(LaunchLedgerCleanupTests, expression)
    invocation = "0123456789abcdef0123456789abcdef"
    mktempdir() do root
        runtime = mkpath(joinpath(root, invocation))
        path = joinpath(runtime, "launch.json")
        record = Dict(
            "version" => 1,
            "invocation" => invocation,
            "source_role" => "simulator",
            "owners" => Dict(),
            "error" => nothing,
        )
        C.write_json(path, record)
        before = read(path)
        withenv("INVOCATION_ID" => invocation) do
            empty!(LaunchLedgerCleanupTests.events)
            @test_throws ArgumentError LaunchLedgerCleanupTests.cleanup_invocation!(
                root, invocation; source_role = "simulator"
            )
            @test isempty(LaunchLedgerCleanupTests.events) && read(path) == before
            for unreadable in (:missing, :malformed)
                unreadable === :missing ? rm(path) : write(path, "{")
                empty!(LaunchLedgerCleanupTests.events)
                @test_throws L.LaunchError LaunchLedgerCleanupTests.cleanup_invocation!(
                    root, invocation; source_role = "simulator"
                )
                @test LaunchLedgerCleanupTests.events == [
                    "cancel",
                    "pipewireao-owner-$invocation-core.service",
                    "pipewireao-owner-$invocation-simulator.service",
                ]
            end
        end
    end
end

module FailedStartPreflightTests
import Clocks
import PipeWireAORTC
const Common = PipeWireAORTC.Common
const Runtime = PipeWireAORTC.SessionRuntime
const _failed_start_record = Runtime._failed_start_record
_read_failed_start_ledger(args...) = Runtime._read_failed_start_ledger(args...)
const events = String[]
struct ManagerStopObserved <: Exception end
module S
import PipeWireAORTC.SystemdOwners: valid_invocation
import ..ManagerStopObserved
const queries = Ref(0)
function properties(args...; kwargs...)
    queries[] += 1
    queries[] == 1 || throw(ManagerStopObserved())
    return Dict(
        "LoadState" => "loaded",
        "FragmentPath" => "/retained/session.service",
        "InvocationID" => "0123456789abcdef0123456789abcdef",
        "MainPID" => "0",
        "ControlGroup" => "/test.slice/session.service",
    )
end
end
monotonic() = 0.0
remaining(args...) = 1.0
_owned_link(args...) = nothing
_exact_fragment(args...) = true
_unrun_instance(args...; kwargs...) = false
checked(args...; kwargs...) = push!(events, "stop")
end

@testset "failed-start preflight preserves unreadable-ledger emergency stop" begin
    R = PipeWireAORTC.SessionRuntime
    C = PipeWireAORTC.Common
    F = FailedStartPreflightTests
    source = read(
        joinpath(pkgdir(PipeWireAORTC), "src/deployment/session_runtime.jl"), String
    )
    position = first(findfirst("function _reconcile_failed_start!", source))
    expression, _ = Meta.parse(source, position)
    Core.eval(F, expression)
    invocation = "0123456789abcdef0123456789abcdef"
    unit = "pipewireao-session@test.service"
    mktempdir() do root
        runtime = mkpath(joinpath(root, invocation))
        path = joinpath(runtime, "launch.json")
        C.write_json(
            path,
            Dict(
                "version" => 1,
                "unit" => unit,
                "invocation" => invocation,
                "runtime" => runtime,
            ),
        )
        empty!(F.events)
        F.S.queries[] = 0
        @test_throws ArgumentError F._reconcile_failed_start!(
            root,
            unit,
            root,
            "/retained/session.service",
            true,
            ErrorException("start failed"),
        )
        @test isempty(F.events) && F.S.queries[] == 0
        for unreadable in (:missing, :malformed)
            unreadable === :missing ? rm(path) : write(path, "{")
            empty!(F.events)
            F.S.queries[] = 0
            @test_throws F.ManagerStopObserved F._reconcile_failed_start!(
                root,
                unit,
                root,
                "/retained/session.service",
                true,
                ErrorException("start failed"),
            )
            @test F.events == ["stop"]
            @test F.S.queries[] == 2
            # The later strict ledger read still rejects missing/malformed data.
            expected = try
                C.read_json(path)
            catch error
                error
            end
            @test_throws typeof(expected) R._failed_start_record(root, unit, invocation)
        end
    end
end

@testset "native session link admission agrees with cold exports" begin
    D = PipeWireAORTC.DeploymentConfiguration
    @test D.MAX_SESSION_LINKS == 64
    @test isempty(D.validate_session_links(Dict("links" => [])))
    for count in (36, 64)
        @test length(D.validate_session_links(Dict("links" => fill(Dict(), count)))) ==
            count
    end
    for links in (fill(Dict(), 65), "not a list")
        @test_throws D.DeploymentError D.validate_session_links(Dict("links" => links))
    end
    @test PipeWireAORTC.MediaSession.MAX_LINKS == D.MAX_SESSION_LINKS
end
