using PipeWireAORTC
const R=PipeWireAORTC.SessionRuntime
const C=PipeWireAORTC.Common
root="/home/dgamroth/.local/state/pipewireao/gpi2-shape-live-20261025"
application=joinpath(root,"application")
prefix="/home/dgamroth/.local/opt/pipewireao-classic-headless-20261021"
handle=R.start!(application,joinpath(root,"session");prefix,deadline=R.monotonic()+1030)
reply=R.control!(handle,PipeWireAORTC.RunnerCommands.parse(["session-start"]);deadline=R.monotonic()+30)
C.write_json(joinpath(root,"start.json"),reply)
reply["ok"]===true && reply["state"]=="Running" || error("GPI2 Start rejected")
C.write_json(joinpath(root,"live-identity.json"),Dict("unit"=>handle.unit,"pid"=>handle.main_pid,"remote"=>R._ledger(handle)["remote"],"stage"=>handle.stage_root,"runtime_root"=>handle.runtime_root,"backend"=>"cuda","camera"=>"UInt16"))
println("Annular GPI2 Running: ",handle.unit);flush(stdout)
