# Cold contract checks only: including the harness never starts a service.
using Test
include("session_faults.jl")

function source_dump(; running=true, run_token=4, snapshot_token=5, sequence=9)
    source = Dict("role" => "simulator", "control-node" => "simulator-wfs",
        "control-protocol" => "pipewireao.source-control/1")
    owner = Dict("pid" => 42, "control-node" => "simulator-wfs",
        "control-protocol" => "pipewireao.source-control/1")
    values = PipeWireAORTC.NativeSourceControl.snapshot_values(Int64(101), Int32(3),
        Int64(snapshot_token), Int32(0), Int64(1), Int64(sequence), running, false, Int64(1), Int64(0))
    snapshot = Any[]
    for (name, value) in zip(PipeWireAORTC.NativeSourceControl.SNAPSHOT_NAMES, values)
        push!(snapshot, name, value)
    end
    run = Any["pipewireao.run-control.version", 1, "pipewireao.run-control.completed-token", run_token,
        "pipewireao.run-control.result", 0, "pipewireao.run-control.actual-state", running ? "running" : "stopped"]
    node = Dict("id" => 95, "type" => "PipeWire:Interface:Node", "info" => Dict(
        "props" => Dict{String,Any}("node.name" => "simulator-wfs", "object.serial" => 96,
            "client.id" => 89, "pipewireao.source-control.instance" => 101,
            "pipewireao.source-control.owner-pid" => 42, "pipewireao.run-control" => true,
            "pipewireao.source-snapshot.version" => 1),
        "params" => Dict("Props" => [Dict("params" => snapshot), Dict("params" => run)])))
    client = Dict("id" => 89, "type" => "PipeWire:Interface:Client", "info" => Dict(
        "props" => Dict("pipewire.sec.pid" => 42)))
    return (; objects=[node, client], source, owner, node_identity=(; id=UInt32(95), serial=UInt64(96)))
end

@testset "Fault harness source profiles and declared startup budget" begin
    aos = Dict("source-owner" => "simulator", "startup-timeout-ms" => 900_000,
        "owners" => [Dict("role" => "simulator", "control-protocol" => "pipewireao.source-control/1",
            "control-node" => "simulator-wfs")])
    @test qualification_source(aos)["control-node"] == "simulator-wfs"
    @test startup_budget(aos) == 1030
    @test startup_budget(Dict()) == 430
    for instrument in ("classic", "copper")
        calibration = deepcopy(aos)
        calibration["owners"][1] = Dict("role" => "simulator",
            "control-protocol" => "pipewireao.rtc.calibration-lifecycle/1", "instrument" => instrument)
        @test qualification_source(calibration)["instrument"] == instrument
    end
    invalid = deepcopy(aos)
    invalid["owners"][1]["control-protocol"] = "unsupported/1"
    @test_throws ErrorException qualification_source(invalid)
end

@testset "Fault source observations bind ACK, process and report identity" begin
    original = source_dump()
    decode(data; instance=nothing) = decode_aos_source(data.objects, data.source, data.owner, data.node_identity; instance)
    before = decode(original)
    @test before["snapshot"]["running"] === true
    @test before["instance"] == 101
    held = source_dump(running=false, run_token=6, snapshot_token=7, sequence=12)
    after = decode(held; instance=before["instance"])
    @test require_aos_hold(before, after) === nothing
    report = Dict{String,Any}("owner_pid" => 42, "source_instance" => 101,
        "generation" => 1, "sequence" => 0, "failures" => [])
    # A valid retained report may precede the current held acquisition cursor.
    @test validate_source_report(report, after) === nothing
    for mutation in (
        data -> (data.objects[1]["info"]["props"]["object.serial"] = 97),
        data -> (data.objects[1]["info"]["props"]["pipewireao.source-control.owner-pid"] = 43),
        data -> (data.objects[2]["info"]["props"]["pipewire.sec.pid"] = 43),
        data -> (data.objects[1]["info"]["props"]["pipewireao.source-control.instance"] = 102),
        data -> (data.owner["control-node"] = "other-source"),
        data -> pop!(data.objects[1]["info"]["params"]["Props"][1]["params"]),
        data -> append!(data.objects[1]["info"]["params"]["Props"][1]["params"],
            ["pipewireao.source-snapshot.sequence", 9]),
    )
        invalid = deepcopy(held)
        mutation(invalid)
        @test_throws ArgumentError decode(invalid; instance=101)
    end
    # Validate the contract's report-cursor ordering and scalar types.
    for (name, value) in (("report-sequence", 13), ("generation", true), ("result", -1), ("running", 0))
        invalid = deepcopy(held)
        fields = invalid.objects[1]["info"]["params"]["Props"][1]["params"]
        index = findfirst(==("pipewireao.source-snapshot." * name), fields)
        fields[index+1] = value
        @test_throws ArgumentError decode(invalid)
    end
    @test_throws ArgumentError require_aos_hold(before, decode(original))
    @test_throws ArgumentError require_aos_hold(before,
        decode(source_dump(running=false, run_token=4, snapshot_token=5, sequence=12)))
    @test_throws ArgumentError decode(source_dump(running=false, run_token=6, snapshot_token=5))
    for (field, value) in (("source_instance", 102), ("owner_pid", 43), ("generation", 2),
            ("sequence", 1), ("failures", ["failed"]))
        invalid = deepcopy(report)
        invalid[field] = value
        @test_throws ArgumentError validate_source_report(invalid, after)
    end
end
