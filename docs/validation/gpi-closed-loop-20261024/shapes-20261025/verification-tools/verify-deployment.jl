using PipeWireAORTC, SHA
const C=PipeWireAORTC.Common
root=@__DIR__
function unit(name)
    lines=split(read(`systemctl --user show $name -p MainPID -p ActiveState -p SubState -p InvocationID -p LoadState`,String),'\n';keepempty=false)
    Dict((first(split(line,'=';limit=2))=>last(split(line,'=';limit=2))) for line in lines)
end
gui=unit("pipewireao-gpi2-shape-gui-20261025.service")
gui["ActiveState"]=="active" || error("GUI inactive")
pid=parse(Int,gui["MainPID"])
env=Dict((first(split(entry,'=';limit=2))=>last(split(entry,'=';limit=2))) for entry in split(read("/proc/$pid/environ",String),'\0';keepempty=false))
identity=C.read_json(joinpath(root,"live-identity.json"))
env["PIPEWIRE_REMOTE"]==identity["remote"] || error("GUI remote mismatch")
all(key->!haskey(env,key),("LIBGL_ALWAYS_SOFTWARE","GALLIUM_DRIVER","__EGL_VENDOR_LIBRARY_FILENAMES")) || error("software renderer override")
nodes=[Dict("name"=>o["info"]["props"]["node.name"],"state"=>o["info"]["state"]) for o in C.read_json(joinpath(root,"gui-live.json")) if get(o,"type","")=="PipeWire:Interface:Node" && startswith(get(get(o["info"],"props",Dict()),"node.name",""),"pipewireao-gui")]
!isempty(nodes) && all(node->node["state"]=="running",nodes) || error("GUI streams not running")
classic=unit("pipewireao-session@45fe9b6e9f5f.service")
classic["InvocationID"]=="e23f5c8b3e5142ccb11311f4d7c27550" && classic["MainPID"]=="2432242" && classic["ActiveState"]=="active" || error("Classic identity changed")
retirement=C.read_json(joinpath(root,"previous-retirement.json"))
final=retirement["final_record"]
final["cleanup_complete"]===true || error("previous cleanup incomplete")
owners=Dict(role=>Dict("pid"=>o["pid"],"pid_absent"=>!isdir("/proc/$(o["pid"])"),"cgroup_absent"=>!isdir("/sys/fs/cgroup"*o["cgroup"])) for (role,o) in final["owners"])
all(o->o["pid_absent"] && o["cgroup_absent"],values(owners)) && !isdir("/proc/2660185") || error("previous owners remain")
C.write_json(joinpath(root,"gui-live-verification.json"),Dict("completed"=>true,"gui"=>gui,"pid"=>pid,"remote"=>env["PIPEWIRE_REMOTE"],"wayland_display"=>env["WAYLAND_DISPLAY"],"software_overrides_absent"=>true,"binary_sha256"=>bytes2hex(sha256(read(joinpath(root,"bin/pipewireao-gui")))) ,"running_gui_nodes"=>nodes,"classic"=>classic,"manual_visual_acceptance"=>false))
C.write_json(joinpath(root,"previous-cleanup-audit.json"),Dict("completed"=>true,"clean_native_quit"=>retirement["clean_native_quit"],"owners"=>owners,"manager_pid_absent"=>true,"unit"=>unit("pipewireao-session@461ad9bb9189.service")))
println("GUI running on exact new remote; previous owners absent; Classic identity preserved")
