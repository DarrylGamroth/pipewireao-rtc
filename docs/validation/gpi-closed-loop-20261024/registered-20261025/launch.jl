using PipeWireAORTC, TOML
const R=PipeWireAORTC.SessionRuntime
const C=PipeWireAORTC.Common
const root="/home/dgamroth/.local/state/pipewireao/gpi2-registered-live-20261025"
previous=C.read_json(joinpath(root,"previous-retirement.json"))
@assert previous["final_record"]["cleanup_complete"]===true
handle=R.start!(joinpath(root,"application"),joinpath(root,"session");prefix=ENV["PIPEWIREAO_PREFIX"],deadline=R.monotonic()+1030)
reply=R.control!(handle,PipeWireAORTC.RunnerCommands.parse(["session-start"]);deadline=R.monotonic()+30)
C.write_json(joinpath(root,"start.json"),reply)
reply["ok"]===true && reply["state"]=="Running" || error("GPI2 Start rejected")
C.write_json(joinpath(root,"live-identity.json"),Dict("unit"=>handle.unit,"pid"=>handle.main_pid,"invocation"=>handle.invocation,"remote"=>R._ledger(handle)["remote"],"stage"=>handle.stage_root,"runtime_root"=>handle.runtime_root,"backend"=>"cuda","camera"=>"UInt16"))
println("GPI2 with registered JFG packages Running: ",handle.unit);flush(stdout)
