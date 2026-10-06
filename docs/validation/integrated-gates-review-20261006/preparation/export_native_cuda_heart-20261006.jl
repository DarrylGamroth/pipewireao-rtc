using PipeWireAODeployment
const H=PipeWireAODeployment.HeartExport
const D=PipeWireAODeployment.Deployment
profile,base,output=ARGS
profile in ("classic","copper") || error("unknown profile")
root=joinpath(homedir(),".cache/rtc-heart-native-20261006")
config=profile=="classic" ? "/home/dgamroth/workspaces/codex/heart/revolt-rtc/config/classic_config_sim.yaml" :
    "/home/dgamroth/workspaces/codex/pipewire/JuliaFilterGraph.jl/benchmark/heart/copper_config_aos_matched.yaml"
args=(;base_package=base,output,heart_root=joinpath(root,"qualified-heart-source"),heart_source_config=config,
    calibration_root="/home/dgamroth/workspaces/codex/heart/revolt-rtc",
    rtc_binary="/tmp/rtc-maintenance-target-20261006/debug/pipewireao-rtc",pipewire_prefix="/opt/pipewireao")
println(H.export_package(args;simulator_backend="cuda"))
println(D.install((;package=output,destination=output*"-installed",pipewire_prefix=args.pipewire_prefix)))
