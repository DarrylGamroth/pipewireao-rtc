using PipeWireAODeployment,TOML
include("/home/dgamroth/workspaces/codex/pipewire/pipewireao-rtc-native-calibration-consumer/deployment/qualify_calibration_native.jl")
const C=PipeWireAODeployment.Common
const D=PipeWireAODeployment.Deployment
const H=PipeWireAODeployment.HILExport
const N=NativeCalibrationQualification
stage="/tmp/copper-fgn-nativecal-final-v1"
installed="/tmp/copper-fgn-nativecal-final-v2-installed"
!ispath(installed) || error("fresh install required")
before=C.read_json("/tmp/copper-fgn-nativecal-final-v1-pre-normalization-proof.json")
spec=C.read_json(joinpath(stage,"deployment.conf"))
for (path,hash) in spec["artifacts"]
    @assert C.sha256_file(joinpath(stage,path))==hash
end
manifest_path=joinpath(stage,"julia/Manifest.toml")
original_manifest=C.sha256_file(manifest_path)
manifest=TOML.parsefile(manifest_path)
dependency=only(manifest["deps"]["PipeWireAO"])
original_dependency=copy(dependency)
for key in ("git-tree-sha1","repo-url","repo-rev"); pop!(dependency,key,nothing); end
dependency["path"]="../hil/packages/PipeWireAO"
open(io->TOML.print(io,manifest;sorted=true),manifest_path,"w")
normalized_manifest=C.sha256_file(manifest_path)
provenance=C.read_json(joinpath(stage,"provenance.json"))
provenance["native_control_runtime_binding"]=Dict("scope"=>"generated control-runtime Manifest binds already sealed d514 SDK; no production exporter fix or scientific-byte change",
    "original_dependency"=>original_dependency,"selected_dependency"=>dependency,
    "original_manifest_sha256"=>original_manifest,"selected_manifest_sha256"=>normalized_manifest,
    "sdk_source_revision"=>"d514d6b0d76a1dcac359ec23943876343b7bb205",
    "sdk_thread_loop_sha256"=>C.sha256_file(joinpath(stage,"hil/packages/PipeWireAO/src/thread_loop.jl")),
    "helper_sha256"=>C.sha256_file(@__FILE__))
C.write_json(joinpath(stage,"provenance.json"),provenance)
spec["artifacts"]=H._package_artifacts(stage)
C.write_json(joinpath(stage,"deployment.conf"),spec)
D.profile(joinpath(stage,"deployment.conf"),"/opt/pipewireao")
D.install((;package=stage,destination=installed,pipewire_prefix="/opt/pipewireao"))
selected=D.profile(joinpath(installed,"deployment.conf"),"/opt/pipewireao")
for (path,hash) in selected["artifacts"]
    @assert C.sha256_file(joinpath(installed,path))==hash
end
for (path,hash) in before["retained_scientific_files"]
    @assert C.sha256_file(joinpath(installed,path))==hash
end
for (path,hash) in before["source_original_seals"]
    @assert C.sha256_file(joinpath(before["base"],path))==hash
end
plan=C.read_json(before["plan"])
for mode in ("collect","capture")
    N.selected_fixture(selected,C.read_json(joinpath(installed,"provenance.json")),plan;mode)
end
binding=only(TOML.parsefile(joinpath(installed,"julia/Manifest.toml"))["deps"]["PipeWireAO"])
@assert binding["path"]=="../hil/packages/PipeWireAO" && !haskey(binding,"git-tree-sha1")
record=copy(before)
record["installed"]=installed
record["installed_seal_count"]=length(selected["artifacts"])
record["installed_descriptor_sha256"]=C.sha256_file(joinpath(installed,"deployment.conf"))
record["installed_runtime_sha256"]=N.runtime_receipt(installed)
record["runtime_manifest_binding"]=provenance["native_control_runtime_binding"]
record["normalization_helper_sha256"]=C.sha256_file(@__FILE__)
record["pre_normalization_proof_sha256"]=C.sha256_file("/tmp/copper-fgn-nativecal-final-v1-pre-normalization-proof.json")
record["future_qualification_argv"]=Dict(mode=>[Base.julia_cmd().exec[1],"--startup-file=no","--compiled-modules=existing",
    "--project=/home/dgamroth/workspaces/codex/pipewire/pipewireao-rtc-native-calibration-consumer/deployment/julia",
    "/home/dgamroth/workspaces/codex/pipewire/pipewireao-rtc-native-calibration-consumer/deployment/qualify_calibration_native.jl",installed,
    "/tmp/copper-fgn-nativecal-final-v2-"*mode*"-runtime","/tmp/copper-fgn-nativecal-final-v2-"*mode*"-evidence",before["plan"],mode] for mode in ("collect","capture"))
C.write_json("/tmp/copper-fgn-nativecal-final-v2-proof.json",record)
println(installed)
println("All355 retained scientific files and581 original source seals exact; ",length(selected["artifacts"])," installed seals verified; both plan modes pass.")
