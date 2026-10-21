using PipeWireAORTC, Test

length(ARGS)==2 || error("usage: confirm-shutdown.jl STAGE OUTPUT")
stage, output = abspath.(ARGS)
P=PipeWireAORTC
R,C,S=P.SessionRuntime,P.Common,P.SystemdOwners
saved=C.read_json(joinpath(stage,"session.json"))
attempt=C.read_json(joinpath(stage,"shutdown-attempt.json"))
@test attempt["accepted"] === true
@test attempt["unit"]==saved["unit"] && attempt["invocation"]==saved["invocation"]
handle=R.Handle(saved["unit"],saved["runtime_root"],saved["invocation"],
    Int(saved["main_pid"]),UInt64(saved["start_ticks"]),saved["cgroup"],false,true,true,stage)
# Observation only: never send another Quit or repeat an unknown operation.
record=R._stopped_record(handle,R.monotonic()+30)
@test record==C.read_json(joinpath(stage,"final-launch.json"))
@test record["cleanup_complete"] === true
@test record["phase"]=="stopped" && record["error"]===nothing
@test isempty(get(record,"cleanup_errors",[]))
@test !S.old_process_exists(handle.main_pid,handle.start_ticks)
@test S.cgroup_empty(handle.cgroup)
owners=Dict{String,Any}()
for (role,item) in record["owners"]
    @test !S.old_process_exists(Int(item["pid"]),UInt64(item["start-ticks"]))
    @test S.cgroup_empty(item["cgroup"])
    @test S.quiescent_unit(item["unit"];deadline=R.monotonic()+10)
    owners[role]=Dict("pid"=>item["pid"],"process_gone"=>true,"cgroup_empty"=>true)
end
unit_state=S.properties(handle.unit)
@test unit_state["MainPID"]=="0"
@test unit_state["ActiveState"] in ("inactive","failed") || unit_state["LoadState"]=="not-found"
@test !ispath(record["discovery_locator"])
C.write_json(output,Dict("result"=>"passed","unit"=>handle.unit,
    "invocation"=>handle.invocation,"session_id"=>record["session_uuid"],
    "native_quit_accepted"=>true,"cleanup_complete"=>true,"main_pid"=>0,
    "owners"=>owners,"session_locator_removed"=>true,
    "phase"=>record["phase"],"active_state"=>unit_state["ActiveState"],
    "confirmation_scope"=>"Read-only observation after already completed native Quit; no retry"))
println("Accepted native Quit, exact owner cleanup and final stopped state verified")
