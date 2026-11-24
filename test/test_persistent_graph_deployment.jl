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
    bindings = (; launcher = "/opt/launcher", package = "/opt/app", prefix = "/opt/pipewireao",
                  executable = "/opt/app/rtc/bin/pipewireao-rtc")
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

@testset "Graph attachment executable pins calibration to its invocation" begin
    mktempdir() do directory
        calibration = joinpath(directory, "reconstructor.fits")
        write(calibration, "first calibration")
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
        prefix = Launch.LibPipeWire.PipeWireAO_jll.artifact_dir
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
        @test !occursin("BindsTo=", unit)
        @test !occursin("PartOf=", unit)
        withenv(Launch.GRAPH_MANIFEST_ENV => installed.digest) do
            retained = Launch.installed_graphs(package, prefix, spec, external)
            item = retained["owners"]["controller"]
            @test item["unit"] == graph_unit
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
        @test_throws Launch.LaunchError Launch.graph_argument_files(
            ["--graph", composition], package, Dict(composition => nothing), prefix;
            check_graph = true,
        )
    end
end
