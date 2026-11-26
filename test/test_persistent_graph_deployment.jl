import PipeWireAO
using Test, PipeWireAORTC

const Launch = PipeWireAORTC.SessionLaunch
const Install = PipeWireAORTC.SessionInstall
const Configuration = PipeWireAORTC.SessionConfiguration
const Common = PipeWireAORTC.Common

@testset "Mapped executable paths preserve internal whitespace" begin
    executable = realpath("/proc/self/exe")
    inode = stat(executable).inode
    lines = readlines("/proc/self/maps")
    mapping = first(filter(line -> endswith(line, " " * executable), lines))
    @test Launch.graph_library_mapping(mapping, executable, inode)
    @test !Launch.graph_library_mapping(mapping, executable, inode + 1)
    spaced = "/opt/path with spaces/libpipewire-ao-0.3.so"
    @test Launch.graph_library_mapping(replace(mapping, executable => spaced), spaced, inode)
end

function graph_deployment_owner(args)
    return Dict(
        "role" => "controller",
        "bootstrap-protocol" => "pipewireao.rtc.owner-bootstrap/1",
        "bootstrap-node" => "bootstrap",
        "argv" => ["/opt/julia", "-e", PipeWireAORTC.GraphStartup.ENTRY, "--", args...],
    )
end

@testset "Select supported graph roles without converting ordinary owners" begin
    controller = graph_deployment_owner([
        "--session-run-control", "--execution=complete-frame",
        "--correction-property", "integrator:closed", "--prime-on-output", "measurement",
        "--recovery-node", "conditioner",
    ])
    source = Dict("role" => "detector", "argv" => ["/opt/detector"])
    observer = Dict("role" => "observer", "argv" => ["/opt/observer"])
    spec = Dict(
        "name" => "instrument", "source-owner" => "detector",
        "owners" => [source, controller, observer],
    )
    @test Launch.graph_owners(spec) == [controller]
    role = "controller"
    services = Dict(role => Dict(
        "role" => role, "state" => "running", "pid" => 2, "persistent" => true,
        "start-ticks" => 5, "invocation" => "invocation", "cgroup" => "/owner",
    ))
    bindings = Dict("BOOTSTRAP_INSTANCE_CONTROLLER" => "10")
    @test Configuration.owner_record(role, controller, services, bindings)["persistent"] === true
    delete!(services[role], "persistent")
    @test !haskey(Configuration.owner_record(role, controller, services, bindings), "persistent")
    for arguments in (
        ["--session-run-control", "--execution", "row-block"],
        ["--session-run-control", "--capture-backend=cuda"],
        ["--session-run-control", "--parameter", "matrix", "Float32", "1", "matrix.bin"],
        ["--session-run-control", "--check"],
        ["--session-run-control", "--correction-property", "integrator:closed"],
        ["--prime-on-output", "measurement"],
    )
        spec["owners"] = [source, graph_deployment_owner(arguments), observer]
        @test_throws Launch.LaunchError Launch.graph_owners(spec)
    end
    spec["owners"] = [source, observer]
    @test_throws Launch.LaunchError Launch.graph_owners(spec)
end

@testset "Persistent unit starts independently and cleanup preserves its service" begin
    template = read(joinpath(PipeWireAORTC.resource_root(), "pipewireao-session@.service.in"), String)
    spec = Dict(
        "name" => "instrument", "source-owner" => "detector",
        "placement" => Dict("session" => Dict("leader-cpu" => 2)),
    )
    activation = (; julia = "/opt/julia", project = "/opt/app", digest = repeat("a", 64))
    bindings = (; launcher = "/opt/launcher", package = "/opt/app", prefix = "/opt/pipewireao",
                  executable = "/opt/app/rtc/bin/pipewireao-rtc", activation)
    external = (; core = "core.service", socket = "/run/user/1000/core", source = "source.service")
    unit = Launch.graph_unit_name(spec["name"], "controller")
    persistent = (; digest = repeat("0", 64), units = [unit])
    legacy = Install.installed_unit(template, spec; bindings..., external)
    @test !occursin(unit, legacy)
    @test !occursin(Launch.GRAPH_MANIFEST_ENV, legacy)
    installed = Install.installed_unit(template, spec; bindings..., external, persistent)
    @test occursin("Wants=$unit\n", installed)
    @test occursin("After=$unit core.service source.service\n", installed)
    @test occursin(Launch.GRAPH_MANIFEST_ENV * "=" * persistent.digest, installed)

    record = Dict(
        "version" => Launch.LEDGER_VERSION, "name" => spec["name"],
        "source_role" => spec["source-owner"],
        "owners" => Dict("controller" => Dict(
            "unit" => unit, "persistent" => true, "external" => true,
        )),
    )
    @test Launch.cleanup_role!(record, "controller", 0) === nothing
    record["owners"]["controller"]["unit"] = "other.service"
    @test_throws Launch.LaunchError Launch.cleanup_role!(record, "controller", 0)
end

@testset "Direct installation fixes topology and binds separately supervised services" begin
    mktempdir() do package
        prefix = PipeWireAO.LibPipeWire.PipeWireAO_jll.artifact_dir
        julia = realpath(Base.julia_cmd().exec[1])
        systemd = mkdir(joinpath(package, "systemd"))
        source = "camera"
        controller = "control"
        session = Dict{String,Any}(
            "sources" => [Dict("node.name" => source)],
            "sinks" => [Dict("node.name" => controller)],
            "graphs" => [],
            "links" => [Dict("output" => "$source:out", "input" => "$controller:in")],
        )
        write(joinpath(package, "client.conf"), "{}")
        write(joinpath(package, "analysis.conf"), "{}")
        Common.write_json(joinpath(package, "session.conf"), session)
        spec = Dict(
            "name" => "instrument", "source-owner" => "detector", "session" => "session.conf",
            "owners" => [Dict("role" => "detector"), graph_deployment_owner(["--session-run-control"])],
            "node-owners" => Dict(source => "detector", controller => "controller"),
            "placement" => Dict("session" => Dict("leader-cpu" => 2)),
            "session-runtime" => Dict("environment" => Dict(
                "RTC_LOG" => "@PACKAGE@/log",
                "RTC_RUNTIME_LOG" => "@RUNTIME@/100% \$rtc.log",
            )),
            "client" => Dict("analysis" => "client.conf"),
            "analysis" => [Dict("name" => "pupil", "cpus" => [2, 3], "config" => "analysis.conf")],
        )
        external = (; core = "core.service", socket = "/run/user/1000/private", source = "source.service")
        owners = Install.external_owner_bindings(["controller=site-controller.service"])
        @test owners == Dict("controller" => "site-controller.service")
        @test Install.validate_external_owner_roles(spec, owners) === nothing
        @test_throws ArgumentError Install.validate_external_owner_roles(spec, Dict("detector" => "source.service"))
        @test_throws ArgumentError Install.validate_external_owner_roles(spec, Dict("unknown" => "site.service"))
        @test_throws ArgumentError Install.external_owner_bindings(["controller=site.service", "controller=again.service"])
        @test_throws ArgumentError Install.external_owner_bindings(["controller=pipewireao-graph-instrument-controller.service"])
        @test Install.install_direct!(
            package, prefix, julia, package, spec, external, Dict{String,String}(), nothing;
            generated_graphs = false,
        ) === nothing
        @test isempty(readdir(systemd))
        direct = Install.install_direct!(
            package, prefix, julia, package, spec, external, owners, nothing; generated_graphs = false,
        )
        @test direct.services == merge(owners, Dict("core" => external.core, "detector" => external.source))
        @test direct.config == joinpath(systemd, "rtc.conf")
        fixed = Launch.D.decode(direct.config, prefix)
        @test direct.configuration == fixed
        @test fixed["context.properties"]["remote.name"] == external.socket
        @test fixed["pipewireao.session"] == Dict("session" => session)
        @test direct.topology["node-owners"] == spec["node-owners"]
        @test direct.topology["owners"]["detector"]["control-protocol"] == Launch.D.EXTERNAL_STREAM
        @test !haskey(first(spec["owners"]), "control-protocol")
        plan = Configuration.installed_links(direct.link_plan, session)
        @test plan.order == [1]
        @test plan.prerequisites == [Int[]]
        @test all(isfile, direct.files)
        analysis_unit = Launch.support_unit_name("analysis-pupil", spec["name"], package)
        analysis = read(joinpath(systemd, analysis_unit), String)
        @test occursin("After=pipewireao-session@%i.service", analysis)
        @test occursin("BindsTo=pipewireao-session@%i.service", analysis)
        template = read(joinpath(PipeWireAORTC.resource_root(), "pipewireao-session-direct@.service.in"), String)
        activation = (; julia, project = package, digest = "a"^64)
        unit = Install.installed_unit(template, spec; launcher = "/launcher", package, prefix,
            executable = "/rtc", activation, external, direct)
        @test occursin("\"--compiled-modules=strict\"", unit)
        @test occursin("\"--\" -c \"$(direct.config)\"", unit)
        @test occursin("--runtime-root %t/pipewireao-session-%i --direct", unit)
        @test occursin("After=core.service site-controller.service source.service", unit)
        @test occursin("Requisite=core.service site-controller.service source.service", unit)
        @test occursin("Wants=" * replace(analysis_unit, "@." => "@%i."), unit)
        @test occursin("Environment=\"RTC_LOG=$package/log\"", unit)
        @test occursin("ExecStopPost=\"/launcher\" retire-direct --unit %n", unit)
        @test !occursin("INVOCATION_ID", unit)
        @test occursin("Environment=\"RTC_RUNTIME_LOG=%t/pipewireao-session-%i/100%% \$rtc.log\"", unit)

        # Only the managed cohort can supply an invocation-specific topology path.
        rm(direct.config)
        session["path"] = "@RUNTIME@/input"
        Common.write_json(joinpath(package, "session.conf"), session)
        @test Install.install_direct!(
            package, prefix, julia, package, spec, external, owners, nothing; generated_graphs = false,
        ) === nothing
        @test_throws "requires invocation-dependent runtime paths" Install.install_direct!(
            package, prefix, julia, package, spec, external, owners, nothing;
            generated_graphs = false, explicit = true,
        )
        @test !isfile(direct.config)
    end
end

@testset "Parameter deployment preserves the bound graph inlet and preload" begin
    mktempdir() do package
        prefix = PipeWireAO.LibPipeWire.PipeWireAO_jll.artifact_dir
        julia = realpath(Base.julia_cmd().exec[1])
        systemd = mkdir(joinpath(package, "systemd"))
        payload = joinpath(package, "reference.bin")
        values = Float32[1, 3, 2, 4, 8, 9]
        write(payload, values)
        write(joinpath(package, "client.conf"), "{}")
        binding = "PIPEWIREAO_RTC_PARAMETER_REFERENCE"
        spec = Dict{String,Any}(
            "name" => "instrument",
            "environment" => Dict(binding => "@PACKAGE@/reference.bin"),
            "owners" => [Dict("role" => "controller")],
            "placement" => Dict(
                "session" => Dict{String,Any}(
                    "cpus" => [2], "leader-cpu" => 2, "threads" => Any[]
                ),
            ),
            "client" => Dict("rtc" => "client.conf"),
        )
        format = Dict{String,Any}(
            "parameter" => true,
            "shape" => [2, 3],
            "element-type" => "F32_LE",
            "layout" => "COLUMN_MAJOR",
            "schema" => "pipewireao/reference/1",
        )
        output = merge(format, Dict("name" => "output_1", "direction" => "output"))
        input = merge(format, Dict("name" => "reference", "direction" => "input"))
        source = Dict{String,Any}(
            "node.name" => "parameter-reference",
            "factory" => "pipewireao.runtime-parameter",
            "ports" => [output],
        )
        session = Dict{String,Any}(
            "sources" => [source],
            "graphs" => [Dict("node.name" => "controller", "ports" => [input])],
            "links" => [
                Dict(
                    "output" => "parameter-reference:output_1",
                    "input" => "controller:reference",
                ),
            ],
            "parameters" => Dict("controller:reference" => binding),
        )
        external = (;
            core = "fixture-core.service", socket = joinpath(package, "core.sock")
        )
        installed = Launch.install_direct_parameters!(
            package, prefix, package, spec, session, external, julia
        )
        config = joinpath(systemd, "parameters", "sources.json")
        @test config in installed.files
        @test filemode(config) & 0o777 == 0o600
        declaration = only(
            PipeWireAORTC.ParameterSource.read_declarations(config, Base.Event())
        )
        @test (declaration.node_name, declaration.graph, declaration.inlet) ==
            ("parameter-reference", "controller", "reference")
        @test declaration.shape == [2, 3]
        @test declaration.schema == "pipewireao/reference/1"
        @test declaration.stride == 2 * sizeof(Float32)
        @test declaration.initial
        @test reinterpret(Float32, declaration.bytes) == values

        fragment = installed.service["fragment"]
        @test installed.service["sha256"] == Common.sha256_file(fragment)
        @test installed.unit == replace(basename(fragment), "@." => "@%i.")
        unit = split(read(fragment, String), '\n')
        @test "PartOf=pipewireao-session@%i.service" in unit
        @test "StopWhenUnneeded=yes" in unit
        @test "Requisite=$(external.core)" in unit
        @test installed.service["environment"]["PIPEWIRE_REMOTE"] == external.socket
        @test isempty(spec["placement"]["session"]["threads"])
        @test only(installed.placement["threads"])["name"] == "rtc-bootstrap"

        argv = installed.service["argv"]
        arguments = argv[(findfirst(==("--"), argv)+1):end]
        function bind(invocation)
            args = copy(arguments)
            withenv("INVOCATION_ID" => invocation) do
                Launch.bind_parameter_service!(args)
            end
            @test args[1:length(arguments)] == arguments
            return Dict(args[index] => args[index+1] for index in 1:2:length(args))
        end
        first = bind("1"^32)
        second = bind("2"^32)
        @test first["--config"] == config
        @test first["--remote"] == external.socket
        @test first["--bootstrap-instance"] != first["--control-instance"]
        @test second["--bootstrap-instance"] != first["--bootstrap-instance"]
        @test second["--control-instance"] != first["--control-instance"]

        links = Launch.D.session_links(session)
        bindings = Dict("PACKAGE" => package, "REMOTE" => "core.sock")
        runtime = mkdir(joinpath(package, "managed"))
        request = Launch.Request(package, prefix, "fixture.service", julia, runtime)
        managed = Launch.parameter_owner!(
            request, spec, session, links, bindings, runtime; project = package
        )
        @test managed["control-node"] == installed.owner["control-node"]
        @test managed["control-instance"] == bindings["PARAMETER_OWNER_INSTANCE"]
        @test joinpath(runtime, "core.sock") in managed["argv"]
        managed_config = joinpath(runtime, "parameters", "sources.json")
        @test Common.read_json(managed_config) == Common.read_json(config)

        input["layout"] = "ROW_MAJOR"
        rejected = mkdir(joinpath(package, "rejected"))
        @test_throws "parameter layouts differ" Launch.parameter_owner!(
            request, spec, session, links, bindings, rejected; project = package
        )
        @test !isfile(joinpath(rejected, "parameters", "sources.json"))
    end
end

@testset "Graph attachment executable pins calibration to its invocation" begin
    mktempdir() do directory
        calibration = joinpath(directory, "reconstructor.fits")
        write(calibration, "{}")
        manifest = joinpath(directory, "graph-owner-assets.json")
        expected = merge(
            Launch.graph_file_identity(calibration),
            Dict("sha256" => Common.sha256_file(calibration)),
        )
        Common.write_json(manifest, Dict("version" => 1, "files" => Dict(calibration => expected)))
        digest = Common.sha256_file(manifest)
        argv = [manifest, digest, "--bootstrap-instance", "1", "--graph", calibration]
        withenv(
            "INVOCATION_ID" => "00000000000000100000000000000000",
            "PIPEWIREAO_PREFIX" => "/opt/pipewireao",
        ) do
            @test Launch.bind_persistent_graph!(argv) === nothing
        end
        @test argv == ["--bootstrap-instance", "2", "--graph", calibration, "--persistent"]
        @test Launch.graph_bootstrap_instance("00000000000000200000000000000000") == "3"
        @test_throws Launch.LaunchError Launch.verify_graph_assets!(manifest, repeat("a", 64))
        @test Launch.verify_graph_assets!(manifest, digest)[calibration] == expected
        @test Launch.graph_argument_files(
            ["--graph", calibration], directory, Dict(calibration => expected), "/opt/pipewireao"
        ) == Set([calibration])
        other = joinpath(directory, "other.fits")
        write(other, "same length as first")
        @test_throws Launch.LaunchError Launch.graph_argument_files([
            "--graph", other,
        ], directory, Dict(calibration => expected), "/opt/pipewireao")
        mv(other, calibration; force = true)
        @test_throws Launch.LaunchError Launch.verify_graph_assets!(manifest, digest)
    end
end

@testset "Installation generates static graph arguments and a retained unit manifest" begin
    mktempdir() do package
        prefix = realpath(String(PipeWireAO.LibPipeWire.PipeWireAO_jll.artifact_dir))
        write(joinpath(package, "Project.toml"), """
        [deps]
        PipeWireAORTC = "a3e2c7da-f73f-4284-8482-36ac422b34e6"
        """)
        write(joinpath(package, "Manifest.toml"), """
        manifest_format = "2.0"
        [[deps.PipeWireAORTC]]
        uuid = "a3e2c7da-f73f-4284-8482-36ac422b34e6"
        version = "0.1.2"
        git-tree-sha1 = "0000000000000000000000000000000000000000"
        """)
        write(joinpath(package, "deployment.conf"), "{}")
        write(joinpath(package, "graph.conf"), "{}")
        write(joinpath(package, "client.conf"), "{}")
        calibration = joinpath(package, "reconstructor.fits")
        write(calibration, "first calibration")
        Common.write_json(joinpath(package, "parameters.conf"), Dict(
            "parameters" => [Dict("port" => "reconstructor", "path" => basename(calibration))],
        ))
        mkpath(joinpath(package, "systemd"))
        controller = graph_deployment_owner([
            "--graph", "@PACKAGE@/graph.conf", "--session-run-control",
            "--bootstrap-node", "bootstrap", "--bootstrap-instance",
            "@BOOTSTRAP_INSTANCE_CONTROLLER@", "--remote", "@RUNTIME@/@REMOTE@",
            "--fits-bindings", "@PACKAGE@/parameters.conf",
        ])
        controller["environment"] = Dict{String,String}()
        splice!(
            controller["argv"], 1:1,
            [Base.julia_cmd().exec[1], "--startup-file=no", "--threads=2,0", "--project=@PACKAGE@"],
        )
        placement = Dict("leader-cpu" => 2, "cpus" => [2, 3])
        source = Dict("role" => "detector", "argv" => ["/opt/detector"])
        spec = Dict(
            "name" => "instrument", "source-owner" => "detector",
            "runtime" => Dict("kind" => "registered", "project" => "."),
            "artifacts" => Dict(name => nothing for name in (
                "graph.conf", "client.conf", basename(calibration), "parameters.conf",
            )),
            "client" => Dict("controller" => "client.conf"),
            "owners" => [source, controller], "placement" => Dict("controller" => placement),
            "environment" => Dict{String,String}(),
        )
        external = (; core = "core.service", socket = "/run/user/1000/core", source = "source.service")
        installed = Launch.install_persistent_graphs!(package, prefix, spec, external)
        graph_unit = only(installed.units)
        unit = read(joinpath(package, "systemd", graph_unit), String)
        @test occursin("After=core.service\nRequisite=core.service\n", unit)
        @test occursin("Type=notify\nNotifyAccess=main\n", unit)
        stop_timeout = only(last(collect(eachmatch(r"(?m)^TimeoutStopSec=(\d+)s?$", unit))).captures)
        @test parse(Int, stop_timeout) > PipeWireAORTC.ControlClient.maximum_budget(PipeWireAORTC.OwnerBootstrapCodec.PROFILE)
        @test occursin("RuntimeDirectory=%N\n", unit)
        @test occursin(raw"ExecStop=/usr/bin/touch -- %t/%N/${INVOCATION_ID}.stop", unit)
        @test occursin(raw"/usr/bin/waitpid --exited", unit)
        @test !occursin("BindsTo=", unit)
        @test !occursin("PartOf=", unit)
        withenv(Launch.GRAPH_MANIFEST_ENV => installed.digest) do
            retained = Launch.installed_graphs(package, prefix, spec, external)
            item = retained["owners"]["controller"]
            @test item["unit"] == graph_unit
            @test item["type"] == "notify"
            @test item["placement"] == placement
            arguments = item["argv"]
            @test external.socket in arguments
            @test item["environment"]["JULIA_LOAD_PATH"] == "@:@stdlib"
            @test isfile(joinpath(item["environment"]["PIPEWIREAO_CONFIG_DIR"], "client.conf"))
            write(calibration, "new calibration")
            @test_throws "persistent graph input changed" Launch.installed_graphs(
                package, prefix, spec, external
            )
            invocation = "0123456789abcdef0123456789abcdef"
            root = mkdir(joinpath(package, "run"))
            runtime = mkdir(joinpath(root, invocation))
            source_role = spec["source-owner"]
            unit_name = "pipewireao-session@instrument.service"
            coordinator = Launch.S.Coordinator(unit_name, invocation, "/session")
            record = Dict{String,Any}(
                "version" => Launch.LEDGER_VERSION, "phase" => "preparing",
                "name" => spec["name"], "unit" => unit_name,
                "invocation" => invocation, "runtime" => runtime, "source_role" => source_role,
                "owners" => Dict{String,Any}(), "error" => nothing,
            )
            systemctl = joinpath(root, "systemctl")
            log = joinpath(root, "systemctl.log")
            write(systemctl, raw"""
            #!/bin/sh
            printf '%s\n' "$2" >> "$RTC_TEST_SYSTEMCTL_LOG"
            case "$2" in
                list-units) printf '%s loaded active running\n' core.service source.service pipewireao-graph-instrument-controller.service ;;
                list-jobs) printf '%s\n' '12 pipewireao-graph-instrument-controller.service start running' ;;
                *) exit 1 ;;
            esac
            """)
            chmod(systemctl, 0o700)
            withenv(
                "INVOCATION_ID" => invocation, "SERVICE_RESULT" => "exit-code",
                "PATH" => root, "RTC_TEST_SYSTEMCTL_LOG" => log,
            ) do
                @test_throws "persistent graph input changed" Launch.retain_persistent_graphs!(
                    package, prefix, spec, external, coordinator, record
                )
                @test !isfile(log)
                @test Launch.cleanup_invocation!(root, invocation; source_role) === nothing
            end
            failed = Launch.load_record(runtime, invocation, source_role)
            @test failed["phase"] == "failed"
            @test failed["error"] == "persistent graph input changed: $calibration"
            @test failed["cleanup_complete"] === true
            @test isempty(failed["owners"])
            @test Set(readlines(log)) == Set(("list-units", "list-jobs"))
        end
        composition = joinpath(package, "graph.conf")
        write(composition, "{\"filter.composition\":{}}")
        @test_throws ArgumentError Launch.graph_argument_files(
            ["--graph", composition], package, Dict(composition => nothing), prefix,
        )
        branch, shared = joinpath.(package, ("branch.conf", "shared.conf"))
        foreach(path -> write(path, "{}"), (branch, shared))
        Common.write_json(composition, Dict("filter.composition" => Dict(
            "branches" => [Dict("graph" => basename(branch))], "shared" => basename(shared),
        )))
        inventory = Dict(path => nothing for path in (composition, branch, shared))
        @test Launch.graph_argument_files(
            ["--graph", composition], package, inventory, prefix,
        ) == Set(keys(inventory))
        delete!(inventory, branch)
        @test_throws Launch.LaunchError Launch.graph_argument_files(
            ["--graph", composition], package, inventory, prefix,
        )
    end
end
