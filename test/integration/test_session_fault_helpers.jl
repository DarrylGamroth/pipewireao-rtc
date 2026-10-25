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

@testset "Fault harness binds the primary native policy failure" begin
    entry(message, time) = Dict("MESSAGE" => message, "__MONOTONIC_TIMESTAMP" => string(time),
        "_BOOT_ID" => "qualification-boot")
    selected = (; case="link-removal")
    injection = (; identity=(; id=UInt32(143), serial=UInt64(144)))
    fault = entry("AO session fault: Required registry incarnation removed kind=\"link\" role=\"link\" id=143 serial=\"144\"", 100)
    uncertain = entry("AO source hold uncertain; systemd emergency cleanup required: outcome unknown", 110)
    timeout = entry("correction_command.sequence 1192 timed out", 120)
    held_policy = policy_fault_evidence([fault], selected, injection)
    @test require_fault_outcome("held", held_policy) === nothing
    shutdown_policy = policy_fault_evidence([uncertain, fault], selected, injection; source_records=[timeout])
    complete = Dict("cleanup_complete" => true, "cleanup_errors" => [])
    @test require_fault_outcome("policy-shutdown", shutdown_policy, complete) === nothing
    @test_throws ArgumentError require_fault_outcome("held", shutdown_policy)
    @test_throws ArgumentError require_fault_outcome("policy-shutdown", held_policy, complete)
    @test_throws ArgumentError require_fault_outcome("policy-shutdown", shutdown_policy)
    @test_throws ArgumentError require_fault_outcome("policy-shutdown", shutdown_policy,
        Dict("cleanup_complete" => false))
    @test_throws ArgumentError require_fault_outcome("policy-shutdown", shutdown_policy,
        Dict("cleanup_complete" => true, "cleanup_errors" => ["surviving owner"]))
    @test_throws ArgumentError require_fault_outcome("unknown", held_policy)
    for message in (
        "AO session fault: Required registry incarnation removed kind=\"port\" role=\"endpoint\" id=94 serial=\"95\"",
        "AO session fault: Required registry incarnation removed kind=\"link\" id=143 serial=\"145\"",
        "AO session fault: Required registry incarnation removed kind=\"link\" id=142 serial=\"144\"",
        "AO session fault: Required session link destroyed",
    )
        @test_throws ArgumentError policy_fault_evidence([entry(message, 90), fault], selected, injection)
    end
    @test_throws ArgumentError policy_fault_evidence([], selected, injection)
    @test_throws ArgumentError policy_fault_evidence([fault, entry(uncertain["MESSAGE"], 90)], selected, injection)
    @test_throws ArgumentError policy_fault_evidence([fault], selected, injection;
        source_records=[entry(timeout["MESSAGE"], 90)])
    wrong_boot = deepcopy(timeout)
    wrong_boot["_BOOT_ID"] = "different-boot"
    @test_throws ArgumentError policy_fault_evidence([fault], selected, injection; source_records=[wrong_boot])
end

@testset "Fault cleanup waits for receipt, manager and every owner together" begin
    handle = (; invocation="retained-invocation", cgroup="/retained-manager", main_pid=42)
    active = Dict("LoadState" => "loaded", "ActiveState" => "active", "InvocationID" => handle.invocation,
        "ControlGroup" => handle.cgroup, "MainPID" => "42")
    @test exact_manager(handle, active)
    deactivating = merge(active, Dict("ActiveState" => "deactivating"))
    @test !exact_manager(handle, deactivating)
    stopped = merge(active, Dict("ActiveState" => "inactive", "MainPID" => "0",
        "ControlGroup" => "", "InvocationID" => ""))
    @test !exact_manager(handle, stopped)
    for (key, value) in (("InvocationID", "replacement"), ("ControlGroup", "/replacement"), ("MainPID", "43"))
        @test_throws ArgumentError exact_manager(handle, merge(active, Dict(key => value)))
    end
    checks = Dict("receipt_complete" => true, "no_cleanup_errors" => true, "unit_quiescent" => true,
        "manager_exited" => true, "manager_cgroup_empty" => true,
        "source_exited" => true, "source_cgroup_empty" => true)
    for pending in ("receipt_complete", "unit_quiescent", "manager_exited", "manager_cgroup_empty",
            "source_exited", "source_cgroup_empty")
        mktempdir() do destination
            ticks, reads = Ref(0.0), Ref(0)
            record = Dict("cleanup_complete" => true, "owners" => Dict(), "phase" => "stopped")
            observed = observe_cleanup!(handle, destination; failed=true, seconds=1,
                now=()->ticks[], pause=seconds->(ticks[] += seconds), read_record=()->record,
                read_checks=_ -> begin
                    reads[] += 1
                    merge(checks, Dict(pending => reads[] >= 3))
                end)
            @test observed === record
            @test reads[] == 3
            evidence = cleanup_evidence(destination)
            @test length(evidence["settling_observations"]) == 2
            @test first(evidence["settling_observations"])["checks"][pending] === false
            @test all(values(evidence["checks"]))
        end
    end
    mktempdir() do destination
        ticks = Ref(0.0)
        record = Dict("cleanup_complete" => true, "owners" => Dict(), "phase" => "stopped")
        @test_throws ErrorException observe_cleanup!(handle, destination; failed=true, seconds=0.2,
            now=()->ticks[], pause=seconds->(ticks[] += seconds), read_record=()->record,
            read_checks=_ -> merge(checks, Dict("manager_cgroup_empty" => false)))
        before = cleanup_evidence(destination)
        @test length(before["observation_errors"]) == 1
        # Later observation may settle, but the first failed observation remains evidence.
        observe_cleanup!(handle, destination; failed=true, seconds=1,
            now=()->ticks[], pause=seconds->(ticks[] += seconds), read_record=()->record,
            read_checks=_ -> copy(checks))
        after = cleanup_evidence(destination)
        @test after["observation_errors"] == before["observation_errors"]
        @test first(after["settling_observations"])["checks"]["manager_cgroup_empty"] === false
        @test last(after["settling_observations"])["checks"]["manager_cgroup_empty"] === true
    end
end

@testset "fault injection selects the exact declared command link" begin
    captured = Dict("controller"=>(;identity=(;id=UInt32(10),serial=UInt64(11))),
        "corrector"=>(;identity=(;id=UInt32(20),serial=UInt64(21))))
    link(path,output,input,id) = (;identity=(;id=UInt32(id),serial=UInt64(id+1)),
        properties=Dict("object.path"=>path,"link.output.node"=>string(output),"link.input.node"=>string(input)))
    optional = link("pipewireao/session/first",10,30,1)
    command = link("pipewireao/session/second",10,20,3)
    reverse = link("pipewireao/session/third",20,10,5)
    links = [optional,command,reverse]
    @test selected_link((;case="link-removal"),captured,links) === optional
    exact = (;case="link-removal",link_nodes=("controller","corrector"))
    @test selected_link(exact,captured,links) === command
    @test_throws ArgumentError selected_link(exact,captured,[optional,reverse])
    @test_throws ArgumentError selected_link(exact,captured,[command,command])
    @test_throws KeyError selected_link((;link_nodes=("unowned","corrector")),captured,links)
end
