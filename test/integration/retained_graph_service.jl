# Requires the pinned science environment and a Linux systemd user manager.
module RetainedGraphServiceTests

using Test, TOML, UUIDs, PipeWireAO, PipeWireAORTC
include(joinpath(@__DIR__, "..", "control_private_core.jl"))

const RTC = PipeWireAORTC
const L = RTC.SessionLaunch
const S = RTC.SystemdOwners
const B = RTC.OwnerBootstrapClient
const D = RTC.DeploymentConfiguration
const C = RTC.Common
const ROLE = "controller"
const GRAPH = "retained.graph"
const MAILBOX = "retained.bootstrap"
const SCHEMA = "test/retained-graph/1"

systemctl(args...) = `systemctl --user $args`

function registered_environment(directory, application)
    project = dirname(Base.active_project())
    metadata = TOML.parsefile(joinpath(project, "Project.toml"))
    manifest = TOML.parsefile(joinpath(project, "Manifest.toml"))
    # The science workspace uses the checkout by path. The installer requires an
    # immutable package tree, so stage the same committed RTC in a private depot.
    delete!(metadata, "sources")
    rtc = only(manifest["deps"]["PipeWireAORTC"])
    root = pkgdir(RTC)
    success(`git -C $root diff --quiet HEAD -- src ext assets Project.toml`) ||
        error("the RTC checkout must match the source being installed")
    tree = readchomp(`git -C $root rev-parse 'HEAD^{tree}'`)
    delete!(rtc, "path")
    rtc["git-tree-sha1"] = tree
    slug = Base.version_slug(UUID(rtc["uuid"]), Base.SHA1(tree))
    depot = joinpath(directory, "depot")
    source = mkpath(joinpath(depot, "packages", "PipeWireAORTC", slug))
    run(pipeline(`git -C $root archive HEAD`, `tar -x -C $source`))
    for (name, content) in (("Project", metadata), ("Manifest", manifest))
        open(joinpath(application, name * ".toml"), "w") do io
            TOML.print(io, content; sorted = true)
        end
    end
    return join([depot; DEPOT_PATH], ':')
end

function fixture(package, name, cpu, julia)
    write(joinpath(package, "graph.conf"), """
filter.graph = {
    nodes = [ { name=correction type=ndarray label=leaky-integrator-f32
        config={ extent=2 initial_state=0 input_schema=$SCHEMA output_schema=$SCHEMA }
        props={ gain=-0.05 pole=1 closed=false } } ]
    links=[]
    inputs=[ { name=residual endpoint="correction:input" } ]
    outputs=[ { name=offset endpoint="correction:output" } ]
}
""")
    write(joinpath(package, "core.conf"), """
context.properties = { core.daemon = true core.name = private.sock support.dbus = false library.use-fallback = false }
context.spa-libs = { support.* = support/libspa-support }
context.modules = [
    { name = libpipewire-module-scheduler-v1 }
    { name = libpipewire-module-protocol-native }
    { name = libpipewire-module-client-node }
    { name = libpipewire-module-link-factory }
    { name = libpipewire-module-metadata }
    { name = libpipewire-module-access }
]
""")
    write(joinpath(package, "client.conf"), """
context.properties = { support.dbus = false library.use-fallback = false }
context.modules = [
    { name = libpipewire-module-protocol-native }
    { name = libpipewire-module-client-node }
]
""")
    C.write_json(
        joinpath(package, "session.conf"),
        Dict(
            "sources" => [Dict("node.name" => "retained.detector", "ownership" => "external")],
            "graphs" => [Dict("node.name" => GRAPH, "ownership" => "external", "run-control" => "session")],
            "sinks" => [Dict("node.name" => "retained.sink", "ownership" => "external")],
            "execution-groups" => [Dict("name" => "graph", "nodes" => [GRAPH])],
            "links" => [],
        ),
    )
    roles = ("core", "rtc", "detector", ROLE)
    placement = Dict("cpus" => [cpu], "leader-cpu" => cpu, "rt-priority" => 0,
        "locked-bytes" => 0, "threads" => [])
    C.write_json(
        joinpath(package, "deployment.conf"),
        Dict(
            "version" => 1, "name" => name, "source-owner" => "detector",
            "runtime" => Dict("kind" => "registered", "project" => "."),
            "core" => "core.conf", "session" => "session.conf", "cpu-latency-us" => nothing,
            "client" => Dict(role => "client.conf" for role in roles),
            "placement" => Dict(role => placement for role in roles),
            "environment" => Dict("OPENBLAS_NUM_THREADS" => "1"),
            "artifacts" => Dict(asset => nothing for asset in
                ("graph.conf", "client.conf", "core.conf", "session.conf")),
            "node-owners" => Dict("retained.detector" => "detector", "retained.sink" => "detector",
                GRAPH => ROLE),
            "owners" => [
                Dict("role" => "detector", "control-protocol" => "external-stream"),
                Dict(
                    "role" => ROLE, "bootstrap-protocol" => "pipewireao.rtc.owner-bootstrap/1",
                    "bootstrap-node" => MAILBOX, "environment" => Dict(),
                    "argv" => [
                        julia, "--startup-file=no", "--threads=3,0", "--project=@PACKAGE@",
                        "-e", RTC.GraphStartup.ENTRY, "--", "--session-run-control",
                        "--graph", "@PACKAGE@/graph.conf", "--name", GRAPH,
                        "--bootstrap-node", MAILBOX, "--bootstrap-instance",
                        "@BOOTSTRAP_INSTANCE_CONTROLLER@", "--remote", "@RUNTIME@/@REMOTE@",
                        "--correction-property", "correction:closed", "--prime-on-output", "offset",
                    ],
                ),
            ],
        ),
    )
    return nothing
end

function start_provider(unit, cpu, command, environment)
    arguments = ["--setenv=$key=$value" for (key, value) in environment]
    run(`systemd-run --user --quiet --collect --unit=$unit --property=Type=exec
        --property=CPUAffinity=$cpu --property=TimeoutStopSec=8s $arguments $command`)
end

function graph_attachment(external, service, item)
    deadline = RTC.ControlClient.monotonic() + 180
    check() = S.alive(service) || error("retained graph service exited: $(service.unit)")
    instance = parse(Int64, L.graph_bootstrap_instance(service.invocation))
    connection = B.connect(external.socket, MAILBOX, S.pid(service), instance; deadline, check)
    try
        @test B.connect_owner!(connection; deadline, check).lifecycle ==
            RTC.OwnerBootstrapCodec.Connected
        L.verify_persistent_service!(service, item; attached = true)
        graph = only(find_globals(connection.client.registry; properties = ("node.name" => GRAPH,)))
        return (; graph = graph.properties["object.serial"], bootstrap = connection.client.serial)
    finally
        close(connection)
    end
end

function published_nodes(prefix, external, environment)
    result = C.run_checked(
        [joinpath(prefix, "bin", "pwao-dump"), "-N", "-r", external.socket];
        env = environment, timeout = 5, maximum_output_bytes = 1024 * 1024,
    )
    result.returncode == 0 || error(result.stderr)
    properties = (
        object["info"]["props"] for object in C.parse_json(result.stdout)
        if object["type"] == "PipeWire:Interface:Node"
    )
    return Dict(
        item["node.name"] => string(item["object.serial"])
        for item in properties if haskey(item, "node.name") && haskey(item, "object.serial")
    )
end

function verify_retained_service(directory, prefix)
    name = "retained-" * first(string(uuid4()), 8)
    external = (; core = "$name-core.service", source = "$name-source.service",
        socket = joinpath(directory, "private.sock"))
    graph_unit = L.graph_unit_name(name, ROLE)
    package = mkdir(joinpath(directory, "application"))
    cpu = maximum(RTC.Placement.inherited_cpus())
    julia = realpath(first(Base.julia_cmd().exec))
    depot = registered_environment(directory, package)
    fixture(package, name, cpu, julia)
    replacement = joinpath(directory, "replacement")
    cp(package, replacement)
    mkdir(joinpath(package, "systemd"))
    paths = D.installed_paths(prefix)
    environment = Dict("JULIA_DEPOT_PATH" => depot, "JULIA_LOAD_PATH" => "@:@stdlib",
        "OPENBLAS_NUM_THREADS" => "1", "LD_LIBRARY_PATH" => paths["library"],
        "PIPEWIREAO_RUNTIME_DIR" => directory, "PIPEWIREAO_CONFIG_DIR" => package,
        "PIPEWIREAO_MODULE_DIR" => paths["modules"], "PIPEWIREAO_SPA_PLUGIN_DIR" => paths["spa"])
    withenv(environment...) do
        spec = D.profile(joinpath(package, "deployment.conf"), prefix)
        RTC.GraphStartup.stage!(package, spec["owners"])
        installed = L.install_persistent_graphs!(package, prefix, spec, external)
        @test installed.units == [graph_unit]
        replacement_spec = D.profile(joinpath(replacement, "deployment.conf"), prefix)
        @test L.reference_persistent_graphs(
            package, replacement, prefix, replacement_spec, external
        ) == installed
        open(io -> println(io, "# changed replacement asset"), joinpath(replacement, "graph.conf"), "a")
        @test_throws "referenced graph input differs" L.reference_persistent_graphs(
            package, replacement, prefix, replacement_spec, external
        )
        fragment = joinpath(package, "systemd", graph_unit)
        try
            start_provider(external.core, cpu, `$(paths["daemon"]) -c core.conf`, environment)
            wait_proof(() -> ispath(external.socket), 10, "retained private core")
            start_provider(external.source, cpu,
                `$julia --startup-file=no --threads=1,0 --project=$package
                 $(joinpath(@__DIR__, "portable_direct_provider.jl")) $(external.socket)
                 retained.detector retained.sink $SCHEMA`, environment)
            detector_nodes = Set(("retained.detector", "retained.sink"))
            wait_proof(() -> issubset(detector_nodes, keys(published_nodes(prefix, external, environment))),
                20, "independent detector and sink")
            run(systemctl("link", "--runtime", fragment))
            run(systemctl("start", graph_unit))
            withenv(L.GRAPH_MANIFEST_ENV => installed.digest) do
                item = L.installed_graphs(package, prefix, spec, external)["owners"][ROLE]
                invocation = replace(string(uuid4()), "-" => "")
                coordinator = S.Coordinator("pipewireao-session@$name.service", invocation, "/fixture")
                ledger = Dict{String,Any}(
                    "version" => L.LEDGER_VERSION, "runtime" => directory, "name" => name,
                    "owners" => Dict{String,Any}(), "phase" => "preparing",
                )
                retain() = L.retain_persistent_graphs!(
                    package, prefix, spec, external, coordinator, ledger
                ).services[ROLE]
                service = retain()
                first_attachment = graph_attachment(external, service, item)
                L.record_external_service!(ledger, service, spec["placement"][ROLE])
                ledger["owners"][ROLE]["persistent"] = true
                L.cleanup_role!(ledger, ROLE, nothing)
                @test S.alive(service)
                @test S.pid(retain()) == S.pid(service)
                wait_proof(20, "fresh bootstrap after detachment") do
                    serial = get(published_nodes(prefix, external, environment), MAILBOX, nothing)
                    serial !== nothing && serial != string(first_attachment.bootstrap)
                end
                next_attachment = graph_attachment(external, service, item)
                @test next_attachment.graph != first_attachment.graph
                run(systemctl("restart", graph_unit))
                @test !S.alive(service)
                @test_throws "unit differs from its installed service" L.verify_persistent_service!(
                    service, item
                )
                restarted = retain()
                @test restarted.invocation != service.invocation
                @test graph_attachment(external, restarted, item).graph != next_attachment.graph
                run(systemctl("stop", graph_unit))
                @test !S.alive(restarted)
                @test success(systemctl("is-active", "--quiet", external.core))
                @test success(systemctl("is-active", "--quiet", external.source))
                nodes = published_nodes(prefix, external, environment)
                @test issubset(detector_nodes, keys(nodes))
                @test isempty(intersect((GRAPH, MAILBOX), keys(nodes)))
            end
        catch
            run(ignorestatus(`journalctl --user --unit=$graph_unit --no-pager -n 40`))
            rethrow()
        finally
            for unit in (graph_unit, external.source, external.core)
                run(pipeline(ignorestatus(systemctl("stop", unit)); stderr = devnull))
            end
            run(pipeline(ignorestatus(systemctl("reset-failed", graph_unit)); stderr = devnull))
            run(pipeline(ignorestatus(systemctl("disable", "--runtime", graph_unit)); stderr = devnull))
        end
    end
end

@testset "Installed retained graph is reused, restarted and withdrawn independently" begin
    prefix = realpath(String(PipeWireAO.LibPipeWire.PipeWireAO_jll.artifact_dir))
    mktempdir("/var/tmp"; prefix = "rtc-retain-") do directory
        verify_retained_service(directory, prefix)
    end
end

end
