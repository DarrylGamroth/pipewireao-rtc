using PipeWireAORTC
const C=PipeWireAORTC.Common
const R=PipeWireAORTC.SessionRuntime
const source="/home/dgamroth/workspaces/codex/pipewire/revolt-classic-rtc"
const root="/home/dgamroth/.local/state/pipewireao/classic-cpu-extrapolation-live-20261022"
const oldstage="/home/dgamroth/.local/state/pipewireao/classic-cpu-live-20261021/session"
old=R.final_record(oldstage)
old["cleanup_complete"]===true && isempty(get(old,"cleanup_errors",[])) || error("previous cleanup incomplete")
C.write_json(joinpath(root,"previous-session-final.json"),old)
println("Previous exact CPU session cleaned up");flush(stdout)
application=joinpath(root,"application")
handle=R.start!(application,joinpath(root,"session");prefix="/home/dgamroth/.local/opt/pipewireao-classic-headless-20261021",deadline=R.monotonic()+1030)
C.write_json(joinpath(root,"ready.json"),R.control!(handle,PipeWireAORTC.RunnerCommands.parse(["status"]);deadline=R.monotonic()+20))
reply=R.control!(handle,PipeWireAORTC.RunnerCommands.parse(["session-start"]);deadline=R.monotonic()+20)
C.write_json(joinpath(root,"start.json"),reply)
reply["ok"]===true && reply["state"]=="Running" || error("Start rejected")
simulation=C.read_json(joinpath(application,"simulation.conf"))
C.write_json(joinpath(root,"live-identity.json"),Dict("unit"=>handle.unit,"pid"=>handle.main_pid,"remote"=>R._ledger(handle)["remote"],"application_commit"=>strip(read(`git -C $source rev-parse HEAD`,String)),"backend"=>"cpu","calibration_identity"=>simulation["calibration_identity"],"requested_wall_rate_hz"=>simulation["wall_rate"],"stage"=>handle.stage_root))
println("Running ",handle.unit);flush(stdout)
