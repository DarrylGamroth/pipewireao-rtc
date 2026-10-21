using PipeWireAORTC, Test

length(ARGS)==2 || error("usage: shutdown.jl STAGE OUTPUT")
stage, output = abspath.(ARGS)
P=PipeWireAORTC
R,C,S=P.SessionRuntime,P.Common,P.SystemdOwners
handle=R.attach(stage)
before=R._ledger(handle)
status=R.control!(handle,P.RunnerCommands.parse(["status"]);deadline=R.monotonic()+15)
@test status["ok"] && status["state"]=="Ready"
gpu=Dict{String,Vector{String}}()
for (role,item) in before["owners"]
    pid=item["pid"]
    paths=filter(line->occursin(r"(?i)(libcuda|libcudart|libcublas|libcufft|libamdhip|libhsa-runtime)",line),
        split(read("/proc/$pid/maps",String),'\n'))
    @test isempty(paths)
    gpu[role]=paths
end
record=R.shutdown!(handle;deadline=R.monotonic()+320)
@test record["cleanup_complete"] === true
@test record["phase"] == "stopped" && record["error"] === nothing
@test isempty(get(record,"cleanup_errors",[])) # No unconfirmed owner cleanup.
@test !S.old_process_exists(handle.main_pid,handle.start_ticks)
@test S.cgroup_empty(handle.cgroup)
for item in values(record["owners"])
    @test !S.old_process_exists(Int(item["pid"]),UInt64(item["start-ticks"]))
    @test S.cgroup_empty(item["cgroup"])
end
unit_state=S.properties(handle.unit)
@test unit_state["MainPID"]=="0"
@test unit_state["ActiveState"] in ("inactive","failed") || unit_state["LoadState"]=="not-found"
@test !ispath(record["discovery_locator"])
C.write_json(output,Dict("result"=>"passed","unit"=>handle.unit,
    "invocation"=>handle.invocation,"session_id"=>record["session_uuid"],
    "native_quit_accepted"=>handle.shutdown_accepted,
    "cleanup_complete"=>record["cleanup_complete"],"main_pid"=>0,
    "all_owner_processes_gone"=>true,"all_owner_cgroups_empty"=>true,
    "session_locator_removed"=>true,"gpu_libraries_before_quit"=>gpu,
    "phase"=>record["phase"],"active_state"=>unit_state["ActiveState"]))
println("Native Quit, exact owner cleanup and final stopped state verified")
