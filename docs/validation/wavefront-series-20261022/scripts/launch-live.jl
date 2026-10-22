using PipeWireAORTC, TOML
gui_binary=realpath(only(ARGS))
C=PipeWireAORTC.Common;R=PipeWireAORTC.SessionRuntime
source="/home/dgamroth/workspaces/codex/pipewire/revolt-classic-rtc"
root="/home/dgamroth/.local/state/pipewireao/classic-cpu-wavefront-series-live-20261022"
prefix="/home/dgamroth/.local/opt/pipewireao-classic-headless-20261021"
ispath(root) && error("new live state already exists")
ispath("/run/user/1000/wayland-mIp9wbaNKd") || error("forwarded GUI display is unavailable")
mkpath(root);application=joinpath(root,"application");cp(source,application)
isdir(joinpath(application,".git")) && rm(joinpath(application,".git");recursive=true)
simulation=C.read_json(joinpath(application,"simulation.conf"))
simulation["backend"]="cpu";simulation["wall_rate"]=10;pop!(simulation,"total_exchanges",nothing)
C.write_json(joinpath(application,"simulation.conf"),simulation)
spec=C.read_json(joinpath(application,"deployment.conf"));spec["name"]="revolt-classic-cpu-wavefront-series"
for env in (spec["environment"],(o["environment"] for o in spec["owners"])...)
    env["CUDA_VISIBLE_DEVICES"]="";env["ROCR_VISIBLE_DEVICES"]=""
end
profile=TOML.parsefile(joinpath(application,"operator-views.toml"));profile["session"]["label"]=spec["name"]
open(io->TOML.print(io,profile),joinpath(application,"operator-views.toml"),"w")
for path in keys(spec["artifacts"]);spec["artifacts"][path]=C.sha256_file(joinpath(application,path));end
C.write_json(joinpath(application,"deployment.conf"),spec)
cp(joinpath(application,"operator-views.toml"),joinpath(root,"operator-views.toml"))
oldstage="/home/dgamroth/.local/state/pipewireao/classic-cpu-wavefront-live-20261022/session"
R.shutdown!(R.attach(oldstage);deadline=R.monotonic()+320)
old=R.final_record(oldstage);old["cleanup_complete"]===true || error("previous cleanup incomplete")
C.write_json(joinpath(root,"previous-session-final.json"),old)
println("Previous CPU session cleaned up");flush(stdout)
handle=R.start!(application,joinpath(root,"session");prefix,deadline=R.monotonic()+1030)
reply=R.control!(handle,PipeWireAORTC.RunnerCommands.parse(["session-start"]);deadline=R.monotonic()+20)
C.write_json(joinpath(root,"start.json"),reply)
reply["ok"]===true && reply["state"]=="Running" || error("Start rejected")
C.write_json(joinpath(root,"live-identity.json"),Dict("unit"=>handle.unit,"pid"=>handle.main_pid,"remote"=>R._ledger(handle)["remote"],"application_commit"=>strip(read(`git -C $source rev-parse HEAD`,String)),"backend"=>"cpu","calibration_identity"=>simulation["calibration_identity"],"stage"=>handle.stage_root,"rtc_version"=>string(Base.pkgversion(PipeWireAORTC))))
wrapper=raw"""
#!/bin/sh
set -eu
set -a
. @ENV@
set +a
export WAYLAND_DISPLAY=wayland-mIp9wbaNKd XDG_RUNTIME_DIR=/run/user/1000
export LIBGL_ALWAYS_SOFTWARE=1 GALLIUM_DRIVER=llvmpipe
export __EGL_VENDOR_LIBRARY_FILENAMES=/usr/share/glvnd/egl_vendor.d/50_mesa.json
export WGPU_BACKEND=vulkan
export VK_DRIVER_FILES=/usr/share/vulkan/icd.d/lvp_icd.json
export VK_ICD_FILENAMES=/usr/share/vulkan/icd.d/lvp_icd.json
export CUDA_VISIBLE_DEVICES= ROCR_VISIBLE_DEVICES=
export JULIA_DEPOT_PATH=/home/dgamroth/.local/share/classic-review-20261020/depot
export JULIA_PKG_GC_AUTO=false JULIA_PKG_PRECOMPILE_AUTO=0
export PIPEWIREAO_CONFIG_DIR="$PIPEWIRE_RUNTIME_DIR/session"
export PIPEWIREAO_PREFIX=/home/dgamroth/.local/opt/pipewireao-classic-headless-20261021
export PIPEWIREAO_SIMULATOR_ROOT=@ROOT@/rebuilds
export PIPEWIREAO_SIMULATOR_COMMAND='["julia","+1.13","--startup-file=no","--project=/home/dgamroth/workspaces/codex/pipewire/revolt-classic-rtc","-e","using PipeWireAORTC; PipeWireAORTC.SimulatorConfiguration.serve()"]'
exec @GUI@ --view-config @ROOT@/operator-views.toml
"""
write(joinpath(root,"gui.sh"),replace(wrapper,"@GUI@"=>gui_binary,"@ENV@"=>joinpath(handle.runtime_root,"current.env"),"@ROOT@"=>root))
old_gui="pipewireao-classic-cpu-wavefront-gui-20261022.service"
if success(`systemctl --user is-active --quiet $old_gui`);run(`systemctl --user stop $old_gui`);end
run(`systemd-run --user --unit=pipewireao-classic-cpu-wavefront-series-gui-20261022 --collect /bin/sh $(joinpath(root,"gui.sh"))`)
println("Running ",handle.unit," with CPU wavefront GUI");flush(stdout)
