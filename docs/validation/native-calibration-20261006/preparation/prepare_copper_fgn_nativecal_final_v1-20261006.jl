using PipeWireAODeployment,TOML
include("/home/dgamroth/workspaces/codex/pipewire/pipewireao-rtc-native-calibration-consumer/deployment/qualify_calibration_native.jl")
const C=PipeWireAODeployment.Common
const D=PipeWireAODeployment.Deployment
const E=PipeWireAODeployment.CalibrationExport
const N=NativeCalibrationQualification
const W=PipeWireAODeployment.NativeCalibrationActionCodec
base="/tmp/copper-fgn-sdk-interrupt-final-v1-installed"
output="/tmp/copper-fgn-nativecal-final-v1"
installed=output*"-installed"
runner="/tmp/rtc-maintenance-target-20261006/debug/pipewireao-rtc"
calcli="/home/dgamroth/.cache/rtc-live-controls-20261005/native-filter-target/debug/rtc-calibrate"
plan_path="/home/dgamroth/.cache/rtc-calibration-completion-20261003/heart-calibration-copper-nondebug-n2-prepared1/heart-calibration-plan.json"
root="/home/dgamroth/workspaces/codex/pipewire/pipewireao-rtc-native-calibration-consumer"
!ispath(output) && !ispath(installed) || error("fresh output/install paths required")
spec=D.profile(joinpath(base,"deployment.conf"),"/opt/pipewireao")
original=Dict(path=>hash for (path,hash) in spec["artifacts"])
for (path,hash) in original
    C.sha256_file(joinpath(base,path))==hash || error("original sealed artifact changed: $path")
end
@assert C.sha256_file(runner)=="750059d1ee71783b63d1fbb96a6bc92cd9be436f551d1b450688a6aae2c2d5cb"
@assert C.sha256_file(calcli)=="ce0ba26cf04f64ea1cb730c4b89309592c5097843cc326d867c4ddd1bfe9b1cb"
@assert C.sha256_file(joinpath(base,"hil/packages/PipeWireAO/src/thread_loop.jl"))=="d622115599605017b251addf6f23c96d85c272d3c360c46b4048f2fb7eaed420"
@assert TOML.parsefile(joinpath(base,"hil/packages/PipeWireAO/Project.toml"))["version"]=="0.6.16"
@assert TOML.parsefile(joinpath(base,"hil/packages/AdaptiveOpticsSimPipeWireHIL/Project.toml"))["version"]=="0.1.2"
args=(;base_package=base,output,pipewire_prefix="/opt/pipewireao",deployment=true,
    rtc_binary=runner,calibration_binary=calcli,illumination="lamp",calibration_stage="native-functional",capture_max_bytes=45192)
E.export_package(args)
D.install((;package=output,destination=installed,pipewire_prefix="/opt/pipewireao"))
selected=D.profile(joinpath(installed,"deployment.conf"),"/opt/pipewireao")
for (path,hash) in selected["artifacts"]
    C.sha256_file(joinpath(installed,path))==hash || error("installed seal changed: $path")
end
# Compare every retained scientific file with its original, without weakening
# the exporter's selected graph split or treating regenerated metadata as SCI.
scientific(path)=startswith(path,"calibration/") || startswith(path,"lib/") || startswith(path,"hil/packages/") || path=="hil/plant.toml"
retained=Dict(path=>hash for (path,hash) in original if scientific(path) && isfile(joinpath(installed,path)))
for (path,hash) in retained
    C.sha256_file(joinpath(installed,path))==hash || error("retained scientific bytes changed: $path")
end
# Source remains the full immutable base, including arrays intentionally absent
# from this action-only graph export.
for (path,hash) in original
    C.sha256_file(joinpath(base,path))==hash || error("original changed after export: $path")
end
plan=C.read_json(plan_path)
@assert C.sha256_file(plan_path)=="043cfdaef6896fbf09ed2a477a771026cb7045f4cf8b8aa68bf1a14deb990fc5"
@assert plan["run"]==1 && plan["measurements"]==3600 && plan["frames_per_probe"]==2
provenance=C.read_json(joinpath(installed,"provenance.json"))
fixtures=Dict(mode=>N.selected_fixture(selected,provenance,plan;mode) for mode in ("collect","capture"))
@assert all(f->f.profile=="copper" && f.engine=="fgn" && f.backend=="cuda",values(fixtures))
@assert fixtures["capture"].budget==45192==fixtures["capture"].required_payload
runtime=N.runtime_receipt(installed)
for (path,hash) in runtime
    startswith(path,"julia/src/") || continue
    @assert C.sha256_file(joinpath(root,"deployment",path))==hash
end
owner=only(filter(o->o["role"]==selected["source-owner"],selected["owners"]))
@assert count(==("--threads=2,0"),owner["argv"])==1
@assert !("--calibration-socket" in owner["argv"])
record=Dict("scope"=>"cold public calibration export/install and action preflight only; no SCI, numerical or hardware qualification",
    "base"=>base,"output"=>output,"installed"=>installed,"source_checkpoint"=>readchomp(`git -C $root rev-parse HEAD`),
    "source_descriptor_sha256"=>C.sha256_file(joinpath(base,"deployment.conf")),
    "source_original_seals"=>original,"source_original_seal_count"=>length(original),
    "retained_scientific_files"=>retained,"retained_scientific_count"=>length(retained),
    "metadata_policy"=>"generated graph split, descriptor, deployment runtime and provenance excluded from unchanged scientific ledger; original base remains intact",
    "installed_seal_count"=>length(selected["artifacts"]),"installed_descriptor_sha256"=>C.sha256_file(joinpath(installed,"deployment.conf")),
    "installed_runtime_sha256"=>runtime,"runner_sha256"=>C.sha256_file(joinpath(installed,"bin/pipewireao-rtc")),
    "calibration_cli_sha256"=>C.sha256_file(joinpath(installed,"bin/rtc-calibrate")),
    "plan"=>plan_path,"plan_sha256"=>C.sha256_file(plan_path),"run"=>plan["run"],"probes"=>length(plan["probes"]),
    "frames_per_probe"=>plan["frames_per_probe"],"measurements"=>plan["measurements"],
    "collect_reply_empty_message_bytes"=>W.preflight_collect_reply(plan["measurements"],plan["frames_per_probe"]),
    "capture_two_frame_payload_bytes"=>fixtures["capture"].required_payload,
    "helper_sha256"=>C.sha256_file(@__FILE__),"qualifier_sha256"=>C.sha256_file(joinpath(root,"deployment/qualify_calibration_native.jl")),
    "future_qualification_argv"=>Dict(mode=>[Base.julia_cmd().exec[1],"--startup-file=no","--compiled-modules=existing",
        "--project="*joinpath(root,"deployment/julia"),joinpath(root,"deployment/qualify_calibration_native.jl"),installed,
        output*"-"*mode*"-runtime",output*"-"*mode*"-evidence",plan_path,mode] for mode in ("collect","capture")))
C.write_json(output*"-proof.json",record)
println(installed)
println("original_seals=",length(original)," retained_scientific=",length(retained)," installed_seals=",length(selected["artifacts"]))
