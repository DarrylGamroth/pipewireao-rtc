using Test, PipeWireAODeployment
include(joinpath(dirname(@__DIR__), "wireplumber_configuration.jl"))

@testset "declared core-hosted session nodes" begin
    spec = Dict("name" => "core-session", "source-owner" => "simulator",
        "owners" => [Dict("role" => "simulator",
            "control-protocol" => "pipewireao.source-control/1",
            "control-node" => "simulator-wfs")])
    session = Dict("sources" => [Dict("node.name" => "simulator-wfs")],
        "sinks" => [Dict("node.name" => "core-sink")], "graphs" => [])
    bindings = Dict("RUNTIME" => "/tmp/core-session", "REMOTE" => "rtc-core-session",
        "SESSION_UUID" => "00000000-0000-0000-0000-000000000001",
        "SESSION_CONTROL_INSTANCE" => "21", "SESSION_CONTROLLER_INSTANCE" => "22",
        "ADMISSION_CONTROLLER_INSTANCE" => "23")
    records = Dict(role => Dict{String,Any}("role" => role, "pid" => pid, "state" => "running", "start-ticks" => 1,
        "invocation" => role * "-invocation", "cgroup" => "/owners/" * role)
        for (role, pid) in (("simulator", 42), ("core", 43)))
    records["simulator"]["control-instance"] = "24"
    mapping = Dict("simulator-wfs" => "simulator", "core-sink" => "core")
    configuration = WirePlumberConfiguration.session_configuration(
        spec, session, bindings, records; node_owners=mapping)
    script = only(filter(component -> component["type"] == "script/lua",
        configuration["wireplumber.components"]))
    @test script["arguments"]["core.owner"] == Dict("pid" => 43, "nodes" => ["core-sink"])
    @test script["arguments"]["node.pids"] == Dict("simulator-wfs" => 42, "core-sink" => 43)
    @test mapping == Dict("simulator-wfs" => "simulator", "core-sink" => "core")
    mapping["core-sink"] = "simulator"
    configuration = WirePlumberConfiguration.session_configuration(
        spec, session, bindings, records; node_owners=mapping)
    script = only(filter(component -> component["type"] == "script/lua",
        configuration["wireplumber.components"]))
    @test isempty(script["arguments"]["core.owner"]["nodes"])
    records["core"]["pid"] = 0
    @test_throws WirePlumberConfiguration.ConfigurationError WirePlumberConfiguration.session_configuration(
        spec, session, bindings, records; node_owners=mapping)
end
