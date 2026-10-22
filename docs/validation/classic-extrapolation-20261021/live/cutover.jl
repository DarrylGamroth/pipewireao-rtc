using PipeWireAORTC, TOML
const C=PipeWireAORTC.Common
const R=PipeWireAORTC.SessionRuntime
const prefix="/home/dgamroth/.local/opt/pipewireao-classic-headless-20261021"
const source="/home/dgamroth/workspaces/codex/pipewire/revolt-classic-rtc"
const root="/home/dgamroth/.local/state/pipewireao/classic-cpu-extrapolation-live-20261022"
ispath(root) && error("new live state already exists")
mkpath(root)
application=joinpath(root,"application")
cp(source,application)
isdir(joinpath(application,".git")) && rm(joinpath(application,".git");recursive=true)
simulation=C.read_json(joinpath(application,"simulation.conf"))
simulation["backend"]="cpu"
simulation["wall_rate"]=10
pop!(simulation,"total_exchanges",nothing)
C.write_json(joinpath(application,"simulation.conf"),simulation)
spec=C.read_json(joinpath(application,"deployment.conf"))
spec["name"]="revolt-classic-cpu-extrapolation"
for environment in (spec["environment"],(owner["environment"] for owner in spec["owners"])...)
    environment["CUDA_VISIBLE_DEVICES"]=""
    environment["ROCR_VISIBLE_DEVICES"]=""
end
profile=TOML.parsefile(joinpath(application,"operator-views.toml"))
profile["session"]["label"]=spec["name"]
open(io->TOML.print(io,profile),joinpath(application,"operator-views.toml"),"w")
for name in keys(spec["artifacts"])
    spec["artifacts"][name]=C.sha256_file(joinpath(application,name))
end
C.write_json(joinpath(application,"deployment.conf"),spec)
cp(joinpath(application,"operator-views.toml"),joinpath(root,"operator-views.toml"))
# Shut down only the previously selected CPU review session through native Quit.
old=R.attach("/home/dgamroth/.local/state/pipewireao/classic-cpu-live-20261021/session")
R.shutdown!(old;deadline=R.monotonic()+320)
C.write_json(joinpath(root,"previous-session-final.json"),R.final_record(old.stage))
println("Previous exact CPU session cleaned up");flush(stdout)
handle=R.start!(application,joinpath(root,"session");prefix,deadline=R.monotonic()+1030)
C.write_json(joinpath(root,"ready.json"),R.control!(handle,PipeWireAORTC.RunnerCommands.parse(["status"]);deadline=R.monotonic()+20))
reply=R.control!(handle,PipeWireAORTC.RunnerCommands.parse(["session-start"]);deadline=R.monotonic()+20)
C.write_json(joinpath(root,"start.json"),reply)
reply["ok"]===true && reply["state"]=="Running" || error("Start rejected")
C.write_json(joinpath(root,"live-identity.json"),Dict("unit"=>handle.unit,"pid"=>handle.main_pid,"remote"=>R._ledger(handle)["remote"],"application_commit"=>strip(read(`git -C $source rev-parse HEAD`,String)),"backend"=>"cpu","calibration_identity"=>simulation["calibration_identity"],"requested_wall_rate_hz"=>simulation["wall_rate"],"stage"=>handle.stage))
println("Running ",handle.unit);flush(stdout)
