using PipeWireAORTC, Test
const R=PipeWireAORTC
const C=R.Common
const S=R.SystemdOwners
root=@__DIR__
stage=joinpath(root,"closed-loop-005")
result=C.read_json(joinpath(stage,"offline-verification.json"))
phase=C.read_json(joinpath(stage,"phase-timing.json"))
columns=Dict(name=>index for (index,name) in enumerate(phase["columns"]))
field(row,name)=row[columns[name]]
session=C.read_json(joinpath(stage,"session.json"))
ledger=C.read_json(joinpath(stage,"final-launch.json"))
@testset "Final Classic CPU order and cleanup evidence" begin
    @test result["complete"] && result["exact_controller_replay"] && result["exact_plant_detector_replay"]
    @test phase["capture_complete"] && phase["record_count"]==256
    @test [field(row,"sequence") for row in phase["rows"]]==collect(1:256)
    for (index,row) in enumerate(phase["rows"])
        @test field(row,"step_started_ns")<=field(row,"step_finished_ns")<=field(row,"staged_ns")<=
            field(row,"published_ns")<=field(row,"received_ns")<=field(row,"adoption_started_ns")<=field(row,"finished_ns")
        @test field(row,"generation")==1
        if index>1
            @test field(phase["rows"][index-1],"finished_ns")<=field(row,"step_started_ns")
        end
    end
    @test ledger["cleanup_complete"] && isempty(get(ledger,"cleanup_errors",Any[]))
    @test ledger["phase"]=="stopped" && get(ledger,"error",nothing)===nothing
    @test !S.old_process_exists(session["main_pid"],UInt64(session["start_ticks"]))
    for owner in values(ledger["owners"])
        @test !S.old_process_exists(owner["pid"],UInt64(owner["start-ticks"]))
        @test S.cgroup_empty(owner["cgroup"])
    end
    # Also reconcile the three retained failed/partial managed attempts without any control request.
    prior=Dict("closed-loop-001"=>("2e08f7698dac","f51096a5755b46feb3b6c017376fc9a1"),
        "closed-loop-002"=>("22f22a02c7c1","6148037302bd47ed9e2ad335cd8e8f64"),
        "closed-loop-003"=>("fcfc329dde63","453b900db8734ff3b0de9d861dab743b"))
    reconciled=Dict{String,Any}()
    for (name,(unit_id,invocation)) in prior
        path=joinpath("/run/user/1000","pipewireao-session-"*unit_id,invocation,"launch.json")
        record=C.read_json(path)
        @test record["cleanup_complete"] && isempty(get(record,"cleanup_errors",Any[]))
        for owner in values(record["owners"])
            @test !S.old_process_exists(owner["pid"],UInt64(owner["start-ticks"]))
            @test S.cgroup_empty(owner["cgroup"])
        end
        C.write_json(joinpath(root,name*"-retained-cleanup.json"),record)
        reconciled[name]=Dict("cleanup_complete"=>true,"phase"=>record["phase"],
            "error"=>get(record,"error",nothing))
    end
    C.write_json(joinpath(root,"prior-cleanup-summary.json"),reconciled)
end
C.write_json(joinpath(root,"final-verification.json"),Dict("complete"=>true,
    "scope"=>"Read-only exchange ordering and final cleanup; no native control or mutation retry",
    "frames"=>256,"session"=>session["unit"],"invocation"=>session["invocation"],
    "corrected_mean_rms_nm"=>result["corrected_mean_rms_nm"],
    "uncorrected_mean_rms_nm"=>result["uncorrected_mean_rms_nm"]))
