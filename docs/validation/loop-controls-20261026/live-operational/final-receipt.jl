using PipeWireAORTC, TOML
const R=PipeWireAORTC.SessionRuntime
const C=PipeWireAORTC.Common
const root="/home/dgamroth/.local/state/pipewireao/gpi2-loop-controls-live-20261026"
const prefix=ENV["PIPEWIREAO_PREFIX"]
identity=C.read_json(joinpath(root,"live-identity.json"))
handle=R.attach(joinpath(root,"session");deadline=R.monotonic()+30)
@assert handle.main_pid==identity["pid"] && handle.invocation==identity["invocation"]
command(args)=R.control!(handle,PipeWireAORTC.RunnerCommands.parse(args);deadline=R.monotonic()+30)
status=command(["status"])
properties=command(["properties","gpi2-jfg-frame-graph"])
@assert status["ok"]===true && status["state"]=="Running"
property_values=properties["result"]["properties"]
key="pipewireao.correction-control.closed-loop-correction:closed"
@assert property_values[key*".state"]["value"]=="Closed"
@assert property_values[key*".fault"]["value"]==""
@assert property_values["closed-loop-correction:closed"]["value"]===true
observations=C.read_json(joinpath(root,"native-stream-verification.json"))
@assert observations["completed"]===true && observations["owned_observers_closed"]===true
unit="pipewireao-gpi2-loop-controls-gui-20261026.service"
gui=PipeWireAORTC.SystemdOwners.properties(unit;deadline=R.monotonic()+10)
@assert gui["ActiveState"]=="active"
gui_pid=parse(Int,gui["MainPID"])
env=split(read("/proc/$gui_pid/environ",String),'\0')
@assert !any(v->startswith(v,"LIBGL_ALWAYS_SOFTWARE=") || startswith(v,"GALLIUM_DRIVER="),env)
dump=C.run_checked([joinpath(prefix,"bin/pwao-dump"),"-N","-r",identity["remote"]];
    timeout=20,maximum_output_bytes=16*1024*1024)
@assert dump.returncode==0
objects=C.parse_json(dump.stdout)
clients=filter(objects) do object
    props=get(get(object,"info",Dict()),"props",Dict())
    string(get(props,"application.process.id",""))==string(gui_pid)
end
@assert !isempty(clients)
classic=PipeWireAORTC.SystemdOwners.properties("pipewireao-session@b9298b3627d9.service";
    deadline=R.monotonic()+10)
@assert classic["MainPID"]=="256761" && classic["ActiveState"]=="active"
@assert classic["InvocationID"]=="df8f66d196d54d4c869aa64e6c7f4562"
app=joinpath(root,"session/installed")
packages=TOML.parsefile(joinpath(app,"Manifest.toml"))["deps"]
@assert only(packages["PipeWireAORTC"])["version"]=="0.2.16"
@assert only(packages["PipeWireAORTC"])["git-tree-sha1"]=="1e8e232f2483ae3eec75a0a2e53a8c2c767cc4ad"
for entries in values(packages),entry in entries
    @assert !haskey(entry,"path") && !haskey(entry,"repo-url")
end
policy=Dict{String,String}()
for name in ("ao-owner.lua","ao-correction.lua")
    installed=joinpath(prefix,"share/pipewireao-rtc/scripts/lib",name)
    @assert read(installed)==read(joinpath(pkgdir(PipeWireAORTC),"native/scripts/lib",name))
    policy[name]=C.sha256_file(installed)
end
C.write_json(joinpath(root,"final-receipt.json"),Dict(
    "completed"=>true,"identity"=>identity,"status"=>status,"properties"=>properties,
    "gui"=>Dict(k=>gui[k] for k in ("MainPID","InvocationID","ActiveState")),
    "gui_native_objects"=>length(clients),"software_renderer_overrides_absent"=>true,
    "classic"=>Dict(k=>classic[k] for k in ("MainPID","InvocationID","ActiveState")),
    "native_policy_sha256"=>policy,"observers_closed"=>true,
    "scope"=>"Live simulated functional checks; no physical device or deadline qualification"))
println("Final Running/Closed readback, GUI attachment, registered package and Classic preservation verified")
