using PipeWireAORTC
const R=PipeWireAORTC.SessionRuntime
const C=PipeWireAORTC.Common
const old="/home/dgamroth/.local/state/pipewireao/gpi2-yaml-release-live-20261026"
const root="/home/dgamroth/.local/state/pipewireao/gpi2-loop-controls-live-20261026"
const prefix=ENV["PIPEWIREAO_PREFIX"]
const guiunit="pipewireao-gpi2-loop-controls-gui-20261026"
@assert isfile(joinpath(root,"preparation.json"))
classic()=read(`systemctl --user show pipewireao-session@b9298b3627d9.service --property=MainPID,InvocationID,ActiveState`,String)
receipt=Dict{String,Any}("classic_before"=>classic())
identity=C.read_json(joinpath(old,"live-identity.json"))
handle=R.attach(joinpath(old,"session");deadline=R.monotonic()+30)
@assert handle.main_pid==identity["pid"] && handle.invocation==identity["invocation"]
@assert ispath("/run/user/1000/wayland-A8gwBRWoCk")
println("Stopping exact old GPI GUI, preserving layout and binary");flush(stdout)
run(`systemctl --user stop pipewireao-gpi2-yaml-release-gui-20261026.service`)
PipeWireAORTC.RuntimeExport.copy_tree(joinpath(old,"gui-state"),joinpath(root,"gui-state"))
mkpath(joinpath(root,"bin"))
cp(joinpath(old,"bin/pipewireao-gui"),joinpath(root,"bin/pipewireao-gui"))
receipt["gui_binary_sha256"]=C.sha256_file(joinpath(root,"bin/pipewireao-gui"))
println("Supervised stop of exact previous GPI cohort; no native Quit claim");flush(stdout)
try
    receipt["stop"]=R.stop!(handle;deadline=R.monotonic()+320)
finally
    final=joinpath(old,"session/final-launch.json")
    isfile(final) && (receipt["final_record"]=C.read_json(final))
    C.write_json(joinpath(root,"previous-retirement.json"),receipt)
end
@assert receipt["final_record"]["cleanup_complete"]===true
for owner in values(receipt["final_record"]["owners"])
    @assert !isdir("/proc/$(owner["pid"])")
end
println("Starting registered RTC 0.2.14 CUDA GPI2 replacement");flush(stdout)
handle=R.start!(joinpath(root,"application"),joinpath(root,"session");prefix,deadline=R.monotonic()+1030)
record=Dict("unit"=>handle.unit,"pid"=>handle.main_pid,"invocation"=>handle.invocation,
    "remote"=>R._ledger(handle)["remote"],"stage"=>handle.stage_root,"runtime_root"=>handle.runtime_root,
    "backend"=>"cuda","camera"=>"UInt16","rtc_version"=>"0.2.14")
C.write_json(joinpath(root,"live-identity.json"),record)
command(args)=R.control!(handle,PipeWireAORTC.RunnerCommands.parse(args);deadline=R.monotonic()+30)
admission=Dict{String,Any}("before"=>command(["properties","gpi2-jfg-frame-graph"]))
admission["refused"]=command(["property","gpi2-jfg-frame-graph","closed-loop-correction:closed","bool","false"])
C.write_json(joinpath(root,"ready-admission.json"),admission)
@assert admission["refused"]["ok"]===false
@assert occursin("running session",lowercase(admission["refused"]["error"]["message"]))
admission["after"]=command(["properties","gpi2-jfg-frame-graph"])
@assert admission["before"]["result"]["properties"]==admission["after"]["result"]["properties"]
C.write_json(joinpath(root,"ready-admission.json"),admission)
reply=R.control!(handle,PipeWireAORTC.RunnerCommands.parse(["session-start"]);deadline=R.monotonic()+30)
C.write_json(joinpath(root,"start.json"),reply)
@assert reply["ok"]===true && reply["state"]=="Running"
receipt["classic_after"]=classic()
@assert receipt["classic_before"]==receipt["classic_after"]
C.write_json(joinpath(root,"previous-retirement.json"),receipt)
text=replace(read(joinpath(old,"gui.sh"),String),old=>root,
    "/run/user/1000/pipewireao-session-626bfcad2d04/current.env"=>joinpath(handle.runtime_root,"current.env"),
    "/home/dgamroth/.local/opt/pipewireao-classic-headless-20261021"=>prefix)
write(joinpath(root,"gui.sh"),text);chmod(joinpath(root,"gui.sh"),0o755)
run(`systemd-run --user --unit=$guiunit --collect --service-type=exec $(joinpath(root,"gui.sh"))`)
println("Running new GPI2 with preserved GUI: ",handle.unit);flush(stdout)
