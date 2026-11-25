# Run with --project=test and the public PipeWireAO ndarray example plugin.
# The fixture exercises managed preparation and ExecStopPost, before RTC admission.
module PortableManagedPrepareTests

using Test, PipeWireAORTC, PipeWireAO, UUIDs

include(joinpath(@__DIR__, "..", "control_private_core.jl"))

const RTC = PipeWireAORTC
const Launch = RTC.SessionLaunch
const S = RTC.SystemdOwners
const D = RTC.DeploymentConfiguration
const C = RTC.Common
const SCHEMA = "test/managed-fgn-f32/1"

function document(path, value)
    RTC.ScienceExport.write_spa_config(path, value)
    return path
end

function fixture(package, plugin, prefix, cpu, julia, project)
    client = Dict(
        "context.properties" => Dict(
            "support.dbus" => false,
            "library.use-fallback" => false,
            "remote.name" => "@RUNTIME@/@REMOTE@",
        ),
        "context.modules" => [
            Dict("name" => "libpipewire-module-$name") for
            name in ("protocol-native", "client-node")
        ],
    )
    document(joinpath(package, "client.conf"), client)
    document(
        joinpath(package, "core.conf"),
        Dict(
            "context.properties" => Dict(
                "core.daemon" => true,
                "core.name" => "@REMOTE@",
                "support.dbus" => false,
                "library.use-fallback" => false,
            ),
            "context.spa-libs" => Dict("support.*" => "support/libspa-support"),
            "context.modules" => [
                Dict("name" => "libpipewire-module-$name") for name in (
                    "scheduler-v1",
                    "protocol-native",
                    "client-node",
                    "link-factory",
                    "metadata",
                    "access",
                )
            ],
        ),
    )
    graphs = mkdir(joinpath(package, "graphs"))
    document(
        joinpath(graphs, "scale.conf.in"),
        Dict(
            "node.name" => "managed.scale",
            "remote.name" => "@RUNTIME@/@REMOTE@",
            "filter.graph" => Dict(
                "nodes" => [
                    Dict(
                        "name" => "scale",
                        "type" => "ndarray",
                        "label" => "scale-f32",
                        "plugin" => plugin,
                        "config" => Dict("shape" => [2], "schema" => SCHEMA),
                    ),
                ],
                "inputs" => ["scale:in", "scale:coefficients"],
                "outputs" => ["scale:out"],
            ),
        ),
    )
    port(name, direction; parameter = false) = Dict(
        "name" => name,
        "direction" => direction,
        "shape" => [2],
        "element-type" => "F32_LE",
        "layout" => "ROW_MAJOR",
        "schema" => SCHEMA,
        "parameter" => parameter,
    )
    node(name, ports) = Dict("node.name" => name, "ports" => ports)
    parameter = merge(
        node("managed.coefficients", [port("output_1", "output"; parameter = true)]),
        Dict("factory" => "pipewireao.runtime-parameter"),
    )
    graph = merge(
        node(
            "managed.scale",
            [
                port("scale:in", "input"),
                port("scale:out", "output"),
                port("scale:coefficients", "input"; parameter = true),
            ],
        ),
        Dict(
            "factory" => "pipewireao.fgn-native",
            "module" => "libpipewire-module-ndarray-filter-chain",
            "config.path" => raw"${MANAGED_FGN_CONFIG}",
        ),
    )
    binding = "PIPEWIREAO_RTC_PARAMETER_COEFFICIENTS"
    write(joinpath(package, "coefficients.bin"), Float32[2, 3])
    document(
        joinpath(package, "session.conf"),
        Dict(
            "sources" =>
                [node("managed.detector", [port("output_1", "output")]), parameter],
            "graphs" => [graph],
            "sinks" => [node("managed.sink", [port("input_1", "input")])],
            "execution-groups" =>
                [Dict("name" => "scale", "nodes" => ["managed.scale", "managed.sink"])],
            "links" => [
                Dict(
                    "output" => "managed.detector:output_1",
                    "input" => "managed.scale:scale:in",
                    "passive" => true,
                ),
                Dict(
                    "output" => "managed.scale:scale:out",
                    "input" => "managed.sink:input_1",
                ),
                Dict(
                    "output" => "managed.coefficients:output_1",
                    "input" => "managed.scale:scale:coefficients",
                    "passive" => true,
                ),
            ],
            "parameters" => Dict("managed.scale:scale:coefficients" => binding),
        ),
    )
    document(
        joinpath(package, "analysis.conf"),
        Dict(
            "graph" => "graphs/scale.conf.in",
            "name" => "managed.optional",
            "rate" => "1/1",
            "links" => [],
        ),
    )
    provider = joinpath(@__DIR__, "portable_direct_provider.jl")
    roles = ("core", "rtc", "session", "detector")
    spec = Dict(
        "name" => "managed-fgn",
        "source-owner" => "detector",
        "cpu-latency-us" => nothing,
        "session" => "session.conf",
        "core" => "core.conf",
        "client" => Dict(role => "client.conf" for role in (roles..., "analysis")),
        "analysis" => [
            Dict("name" => "probe", "cpus" => [cpu], "config" => "analysis.conf"),
            Dict("name" => "missing", "cpus" => [cpu], "config" => "missing-analysis.conf"),
        ],
        "environment" => Dict(
            binding => "@PACKAGE@/coefficients.bin",
            "MANAGED_FGN_CONFIG" => "@RUNTIME@/scale.conf",
        ),
        "node-owners" => Dict(
            "managed.detector" => "detector",
            "managed.sink" => "detector",
            "managed.coefficients" => "parameters",
        ),
        "owners" => [
            Dict(
                "role" => "detector",
                "control-protocol" => "pipewireao.source-control/1",
                "control-node" => "managed.detector.control",
                "environment" => Dict(),
                "argv" => [
                    julia,
                    "--startup-file=no",
                    "--threads=1,0",
                    "--project=$project",
                    provider,
                    "@RUNTIME@/@REMOTE@",
                    "managed.detector",
                    "managed.sink",
                    SCHEMA,
                ],
            ),
        ],
        "placement" => Dict(
            role => Dict(
                "cpus" => [cpu],
                "leader-cpu" => cpu,
                "rt-priority" => 0,
                "locked-bytes" => 0,
                "threads" => [],
            ) for role in roles
        ),
        "session-runtime" => Dict(
            "argv" =>
                ["@PACKAGE@/rtc/bin/pipewireao-rtc", "-c", "@RUNTIME@/rtc/rtc.conf"],
            "environment" => Dict(),
        ),
    )
    return C.write_json(
        joinpath(package, "activation.json"),
        Dict(
            "package" => package,
            "prefix" => prefix,
            "project" => project,
            "julia" => julia,
            "profile" => spec,
            "paths" => D.installed_paths(prefix),
            "graph-templates" => ["scale.conf.in"],
        ),
    )
end

function prepare_fixture(path, unit, root, launcher)
    activation = C.read_json(path)
    request = Launch.Request(
        activation["package"], activation["prefix"], unit, launcher, root
    )
    prepared = Launch.prepare!(
        request;
        activation,
        render! = RTC.SessionAdmission.render!,
        validate_profile = RTC.SessionAdmission.require_node_owners,
    )
    C.write_json(
        joinpath(prepared.runtime, "fixture-environment.json"),
        Dict(
            key => ENV[key] for
            key in ("RTC_CONFIG", "PIPEWIREAO_REMOTE", "PIPEWIREAORTC_PROJECT")
        ),
    )
    RTC.SessionAdmission.notify_ready!()
    wait(Base.Event())
end

function host_has_parameter_port(record, prefix)
    paths = D.installed_paths(prefix)
    env = Dict(
        "PIPEWIREAO_CONFIG_DIR" => joinpath(record["runtime"], "rtc"),
        "PIPEWIREAO_MODULE_DIR" => paths["modules"],
        "PIPEWIREAO_SPA_PLUGIN_DIR" => paths["spa"],
        "LD_LIBRARY_PATH" => paths["library"],
    )
    dump = joinpath(prefix, "bin", "pwao-dump")
    result = C.run_checked(
        [dump, "-N", "-r", record["remote"]];
        env,
        timeout = 5,
        maximum_output_bytes = 1024 * 1024,
    )
    result.returncode == 0 || error(result.stderr)
    objects = C.parse_json(result.stdout)
    graph = filter(objects) do object
        object["type"] == "PipeWire:Interface:Node" &&
            get(object["info"]["props"], "node.name", nothing) == "managed.scale"
    end
    isempty(graph) && return false
    id = only(graph)["id"]
    return any(objects) do object
        object["type"] == "PipeWire:Interface:Port" || return false
        properties = object["info"]["props"]
        return string(properties["node.id"]) == string(id) &&
               properties["port.name"] == "scale:coefficients" &&
               properties["port.direction"] == "in" &&
               get(properties, "port.control", false) === true
    end
end

function check_managed_prepare(plugin)
    mktempdir("/var/tmp"; prefix = "rtc-managed-") do package
        prefix = String(PipeWireAO.LibPipeWire.PipeWireAO_jll.artifact_dir)
        julia = realpath(Base.julia_cmd().exec[1])
        project = dirname(Base.active_project())
        cpu = maximum(RTC.Placement.inherited_cpus())
        name = "rtc-managed-" * first(string(uuid4()), 8)
        unit = name * ".service"
        root = joinpath(ENV["XDG_RUNTIME_DIR"], name)
        fixture(package, plugin, prefix, cpu, julia, project)
        coverage = filter(startswith("--code-coverage="), Base.julia_cmd().exec)
        julia_cleanup = join(D.shell_quote.([julia; coverage]), ' ')
        launcher = joinpath(package, "cleanup")
        write(
            launcher,
            """
#!/bin/sh
if [ "\$1" = stop ]; then exit 0; fi
exec $julia_cleanup --startup-file=no --project=$(D.shell_quote(project)) $(D.shell_quote(@__FILE__)) "\$@"
""",
        )
        chmod(launcher, 0o700)
        fragment = joinpath(package, unit)
        environment = Dict(
            "JULIA_DEPOT_PATH" => join(DEPOT_PATH, ':'),
            "JULIA_LOAD_PATH" => "@:@stdlib",
            "OPENBLAS_NUM_THREADS" => "1",
        )
        command = join(
            S.unit_argument.(
                [
                    julia;
                    coverage;
                    "--startup-file=no";
                    "--threads=1,0";
                    "--project=$project";
                    @__FILE__;
                    "--prepare";
                    joinpath(package, "activation.json");
                    unit;
                    root;
                    launcher
                ],
            ),
            ' ',
        )
        write(
            fragment,
            """
[Service]
Type=notify
NotifyAccess=main
Restart=no
KillMode=control-group
TimeoutStartSec=240
TimeoutStopSec=240
RuntimeDirectory=$name
RuntimeDirectoryMode=0700
RuntimeDirectoryPreserve=yes
UMask=0077
$(join(("Environment=" * S.unit_argument("$key=$value") for (key, value) in environment), '\n'))
ExecStart=$command
ExecStop=$launcher stop --unit $unit --runtime-root $root
ExecStopPost=$launcher cleanup --invocation \${INVOCATION_ID} --runtime-root $root --source-role detector
""",
        )
        link = joinpath(S.runtime_unit_directory(), unit)
        symlink(fragment, link)
        try
            run(`systemctl --user daemon-reload`)
            run(`systemctl --user start $unit`)
            active = S.properties(unit; extra = "ActiveEnterTimestampMonotonic")
            invocation = active["InvocationID"]
            runtime = joinpath(root, invocation)
            record = Launch.load_record(runtime, invocation, "detector")
            @test record["phase"] == "prepared"
            owners = record["owners"]
            @test Set(keys(owners)) ==
                Set(("core", "detector", "fgn", "parameters", "analysis-probe", "analysis-missing"))
            probe = owners["analysis-probe"]
            @test probe["optional"] && probe["state"] == "submitted"
            @test owners["analysis-missing"]["optional"]
            @test occursin("missing-analysis.conf", only(record["analysis_errors"]))
            # The public environment can load the analysis entry point and parse
            # its configuration. Graph execution requires FilterGraphPipeWire.
            @test Base.find_package("FilterGraphPipeWire") === nothing
            wait_proof(60, "optional analysis process failure") do
                S.properties(probe["unit"])["ActiveState"] == "failed"
            end
            failed = S.properties(
                probe["unit"]; extra = "Result,ExecMainStatus,ExecMainStartTimestampMonotonic"
            )
            @test failed["Result"] == "exit-code" && failed["ExecMainStatus"] == "1"
            @test parse(Int64, failed["ExecMainStartTimestampMonotonic"]) >=
                parse(Int64, active["ActiveEnterTimestampMonotonic"])
            @test S.properties(unit)["ActiveState"] == "active"
            @test record["owners"]["fgn"]["graph-nodes"] == ["managed.scale"]
            @test ispath(record["remote"])
            wait_proof(
                () -> host_has_parameter_port(record, prefix),
                15,
                "FGN coefficient Parameter Port",
            )
            env = C.read_json(joinpath(runtime, "fixture-environment.json"))
            @test env == Dict(
                "RTC_CONFIG" => record["config"],
                "PIPEWIREAO_REMOTE" => record["remote"],
                "PIPEWIREAORTC_PROJECT" => project,
            )
            policy = D.decode(record["config"], prefix)["pipewireao.session"]
            @test policy["node.pids"]["managed.scale"] == record["owners"]["fgn"]["pid"]
            config = only(
                RTC.ParameterSource.read_declarations(
                    joinpath(runtime, "parameters", "sources.json"), Base.Event()
                ),
            )
            @test (config.graph, config.inlet) == ("managed.scale", "scale:coefficients")
            @test reinterpret(Float32, config.bytes) == Float32[2, 3]
            graph = only(policy["session"]["graphs"])
            @test_throws "not a rendered invocation asset" Launch.graph_arguments(
                graph,
                Dict("MANAGED_FGN_CONFIG" => joinpath(package, "graphs", "scale.conf.in")),
                runtime,
                prefix,
            )
            run(`systemctl --user stop $unit`)
            stopped = Launch.load_record(runtime, invocation, "detector")
            @test stopped["cleanup_complete"] && stopped["unit_files_removed"]
            @test all(
                role ->
                    !isdir("/proc/$(role["pid"])") ||
                    !S.old_process_exists(Int(role["pid"]), UInt64(role["start-ticks"])),
                (owner for owner in values(owners) if !get(owner, "optional", false)),
            )
            @test all(S.quiescent_unit, S.listed_units(invocation))
            @test isempty(S.listed_jobs(invocation))
            @test S.quiescent_unit(probe["unit"])
            @test !islink(joinpath(S.runtime_unit_directory(), probe["unit"]))
            @test !ispath(record["remote"])
        catch
            run(ignorestatus(`journalctl --user -u $unit -n 35 --no-pager`))
            rethrow()
        finally
            run(ignorestatus(`systemctl --user stop $unit`))
            rm(link)
            run(`systemctl --user daemon-reload`)
            isdir(root) && rm(root; recursive = true)
        end
    end
end

if first(ARGS) == "--prepare"
    prepare_fixture(ARGS[2:end]...)
elseif first(ARGS) == "cleanup"
    RTC.SessionCLI.main(ARGS)
else
    @testset "Portable FGN managed preparation and owned cleanup" begin
        check_managed_prepare(realpath(only(ARGS)))
    end
end

end
