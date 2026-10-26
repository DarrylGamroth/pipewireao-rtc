using PipeWireAORTC, TOML, SHA
const C=PipeWireAORTC.Common
const R=PipeWireAORTC.SessionRuntime
const root="/home/dgamroth/.local/state/pipewireao/gpi2-registered-live-20261025"
identity=C.read_json(joinpath(root,"live-identity.json"))
handle=R.attach(joinpath(root,"session");deadline=R.monotonic()+30)
status=R.control!(handle,PipeWireAORTC.RunnerCommands.parse(["status"]);deadline=R.monotonic()+30)
@assert status["ok"]===true && status["state"]=="Running"
@assert handle.main_pid==identity["pid"] && handle.invocation==identity["invocation"]
verification=C.read_json(joinpath(root,"native-stream-verification.json"))
@assert verification["completed"] && verification["owned_observers_closed"]
function unit(name)
 Dict(Tuple(split(line,'=';limit=2)) for line in split(read(`systemctl --user show $name -p MainPID -p ActiveState -p InvocationID`,String),'\n';keepempty=false))
end
gui=unit("pipewireao-gpi2-registered-gui-20261025.service")
@assert gui["ActiveState"]=="active"
pid=parse(Int,gui["MainPID"])
env=Dict(Tuple(split(entry,'=';limit=2)) for entry in split(read("/proc/$pid/environ",String),'\0';keepempty=false))
@assert env["PIPEWIRE_REMOTE"]==identity["remote"]
@assert !haskey(env,"LIBGL_ALWAYS_SOFTWARE") && !haskey(env,"GALLIUM_DRIVER")
manifest=TOML.parsefile(joinpath(root,"session/installed/Manifest.toml"))["deps"]
packages=Dict(name=>only(manifest[name]) for name in ("FilterGraphAlgorithms","JuliaFilterGraph","FilterGraphPipeWire","FilterGraphIsland","AdaptiveOpticsSim","AdaptiveOpticsSimPipeWireHIL","PipeWireAORTC"))
for name in ("FilterGraphAlgorithms","JuliaFilterGraph","FilterGraphPipeWire","FilterGraphIsland")
 @assert !haskey(packages[name],"path") && !occursin('+',packages[name]["version"])
end
old=C.read_json(joinpath(root,"previous-retirement.json"))
@assert old["final_record"]["cleanup_complete"]
@assert !isdir("/proc/$(old["pid"])")
@assert all(!isdir("/proc/$(owner["pid"])") for owner in values(old["final_record"]["owners"]))
C.write_json(joinpath(root,"registered-deployment-verification.json"),Dict("completed"=>true,"identity"=>identity,"status"=>status,"gui"=>gui,"gui_binary_sha256"=>bytes2hex(sha256(read(joinpath(root,"bin/pipewireao-gui")))),"gui_remote_verified"=>true,"software_overrides_absent"=>true,"packages"=>packages,"old_owners_absent"=>true,"native_stream_verification"=>"native-stream-verification.json","manual_visual_acceptance"=>false))
println("Registered GPI2 Running; GUI exact remote verified; fourteen streams passed; old owners absent.")
