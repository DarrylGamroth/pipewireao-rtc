using Test, PipeWireAORTC
using PipeWireAORTC: SessionConfiguration

@testset "declared core-hosted session nodes" begin
    spec = Dict("name" => "core-session", "source-owner" => "simulator",
        "owners" => [Dict("role" => "simulator",
            "control-protocol" => "pipewireao.source-control/1",
            "control-node" => "simulator-wfs")])
    session = Dict("sources" => [Dict("node.name" => "simulator-wfs")],
        "sinks" => [Dict("node.name" => "core-sink")], "graphs" => [])
    bindings = Dict("RUNTIME" => "/tmp/core-session", "REMOTE" => "rtc-core-session",
        "SESSION_UUID" => "00000000-0000-0000-0000-000000000001",
        "SESSION_SCRIPT" => "/sealed/rtc/scripts/ao/session.lua",
        "SESSION_CONTROL_INSTANCE" => "21", "SESSION_CONTROLLER_INSTANCE" => "22",
        "ADMISSION_CONTROLLER_INSTANCE" => "23")
    records = Dict(role => Dict{String,Any}("role" => role, "pid" => pid, "state" => "running", "start-ticks" => 1,
        "invocation" => role * "-invocation", "cgroup" => "/owners/" * role)
        for (role, pid) in (("simulator", 42), ("core", 43)))
    records["simulator"]["control-instance"] = "24"
    mapping = Dict("simulator-wfs" => "simulator", "core-sink" => "core")
    configuration = SessionConfiguration.session_configuration(
        spec, session, bindings, records; node_owners=mapping)
    script = only(filter(component -> component["type"] == "script/lua",
        configuration["wireplumber.components"]))
    @test script["name"] == "/sealed/rtc/scripts/ao/session.lua"
    @test script["arguments"]["startup.timeout-ms"] == 300000
    @test "support.lua-scripting" in script["requires"]
    @test "ao.lua" in script["requires"]
    @test configuration["wireplumber.profiles"]["ao-rtc"]["ao.lua"] == "required"
    @test only(filter(component -> component["provides"] == "ao.lua",
        configuration["wireplumber.components"]))["name"] == "libwireplumber-module-ao-lua"
    @test all(!startswith(feature, "si.") for feature in script["requires"])
    @test all(!startswith(feature, "si.") for feature in keys(configuration["wireplumber.profiles"]["ao-rtc"]))
    @test all(!startswith(component["name"], "libwireplumber-module-si-")
        for component in configuration["wireplumber.components"])
    @test script["arguments"]["journal.plugin"] == "ao-journal"
    @test "ao.journal" in script["requires"]
    @test configuration["wireplumber.profiles"]["ao-rtc"]["ao.journal"] == "required"
    journal = only(filter(component -> component["name"] == "libwireplumber-module-ao-journal",
        configuration["wireplumber.components"]))
    @test journal["arguments"]["path"] == joinpath(PipeWireAORTC.ConfigurationStore.default_root(), "history.sqlite3")
    disabled = SessionConfiguration.session_configuration(
        spec, session, bindings, records; node_owners=mapping, configuration_store_root=nothing)
    @test !haskey(disabled["wireplumber.profiles"]["ao-rtc"], "ao.journal")
    @test all(component -> component["name"] != "libwireplumber-module-ao-journal",
        disabled["wireplumber.components"])
    @test_throws SessionConfiguration.ConfigurationError SessionConfiguration.session_configuration(
        spec, session, bindings, records; node_owners=mapping, configuration_store_root="relative")

    spec["startup-timeout-ms"] = 900000
    budget_configuration = SessionConfiguration.session_configuration(
        spec, session, bindings, records; node_owners=mapping)
    budget_script = only(filter(component -> component["type"] == "script/lua",
        budget_configuration["wireplumber.components"]))
    @test budget_script["arguments"]["startup.timeout-ms"] == 900000
    delete!(spec, "startup-timeout-ms")
    @test script["arguments"]["core.owner"] == Dict("pid" => 43, "nodes" => ["core-sink"])
    @test script["arguments"]["node.pids"] == Dict("simulator-wfs" => 42, "core-sink" => 43)
    @test mapping == Dict("simulator-wfs" => "simulator", "core-sink" => "core")
    mapping["core-sink"] = "simulator"
    configuration = SessionConfiguration.session_configuration(
        spec, session, bindings, records; node_owners=mapping)
    script = only(filter(component -> component["type"] == "script/lua",
        configuration["wireplumber.components"]))
    @test isempty(script["arguments"]["core.owner"]["nodes"])
    mktempdir() do runtime
        private = merge(bindings, Dict("RUNTIME" => runtime))
        path = SessionConfiguration.write_session_config(spec, session, private, records, runtime;
            node_owners=mapping, configuration_store_root=nothing)
        @test path == joinpath(runtime, "rtc/rtc.conf")
        @test isfile(path)
    end
    for path in ("ao/session.lua", "relative/ao/session.lua", "bad\0path")
        @test_throws SessionConfiguration.ConfigurationError SessionConfiguration.session_configuration(
            spec, session, merge(bindings, Dict("SESSION_SCRIPT" => path)), records;
            node_owners=mapping)
    end
    records["core"]["pid"] = 0
    @test_throws SessionConfiguration.ConfigurationError SessionConfiguration.session_configuration(
        spec, session, bindings, records; node_owners=mapping)
end

@testset "bounded cold startup budget" begin
    D = PipeWireAORTC.DeploymentConfiguration
    @test D.startup_timeout_ms(Dict()) == 300000
    for timeout in (1000, 300000, 900000, 3600000)
        @test D.startup_timeout_ms(Dict("startup-timeout-ms"=>timeout)) == timeout
    end
    for timeout in (0, -1, true, 1000.0, "900000", 3600001)
        @test_throws D.DeploymentError D.startup_timeout_ms(Dict("startup-timeout-ms"=>timeout))
    end
end

@testset "exact headless RTC invocation and protected environment" begin
    D = PipeWireAORTC.DeploymentConfiguration
    contract = Dict("argv" => ["@PACKAGE@/rtc/bin/pipewireao-rtc", "-c", "@RUNTIME@/rtc/rtc.conf"],
        "environment" => Dict{String,String}())
    @test D.validate_session_runtime(contract) === nothing
    @test D.session_executable(Dict("session-runtime" => contract), "/package", "/prefix") ==
        "/package/rtc/bin/pipewireao-rtc"
    for argv in (["@PACKAGE@/wireplumber/bin/wireplumber", "-c", "@RUNTIME@/rtc/rtc.conf"],
            ["@PACKAGE@/rtc/bin/pipewireao-rtc", "-c", "@RUNTIME@/rtc/rtc.conf", "-p", "ao-rtc"],
            ["@PACKAGE@/rtc/bin/pipewireao-rtc", "-c", "@RUNTIME@/wireplumber/wireplumber.conf"],
            ["@PACKAGE@/rtc/bin/pipewireao-rtc", "--config", "@RUNTIME@/rtc/rtc.conf"])
        @test_throws D.DeploymentError D.validate_session_runtime(merge(contract, Dict("argv" => argv)))
    end
    for key in D.SESSION_PRIVATE_ENVIRONMENT
        @test_throws D.DeploymentError D.validate_session_runtime(merge(contract,
            Dict("environment" => Dict(key => "/untrusted"))))
    end
    registered = deepcopy(contract)
    registered["argv"][1] = "@PREFIX@/bin/pipewireao-rtc"
    @test D.session_executable(Dict("runtime" => Dict(), "session-runtime" => registered),
        "/application", "/prefix") == "/prefix/bin/pipewireao-rtc"
    @test_throws D.DeploymentError D.session_executable(Dict("session-runtime" => registered),
        "/application", "/prefix")
    @test_throws D.DeploymentError D.verify_session_process(getpid(), Base.julia_cmd().exec[1], "/runtime/rtc/rtc.conf")
    template = read(joinpath(PipeWireAORTC.resource_root(), "pipewireao-session@.service.in"), String)
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
        handle = R.Handle("pipewireao-session@test.service", root, invocation, getpid(),
            UInt64(1), "/test", false, false, false, nothing)
        C.write_json(joinpath(runtime, "launch.json"), Dict("unit" => handle.unit,
            "invocation" => invocation, "runtime" => runtime,
            "wireplumber_pid" => getpid(), "wireplumber_start_ticks" => 1,
            "session_executable" => "/sealed/rtc/bin/pipewireao-rtc",
            "config" => joinpath(runtime, "rtc/rtc.conf")))
        @test_throws D.DeploymentError R._ledger(handle)
    end
end
