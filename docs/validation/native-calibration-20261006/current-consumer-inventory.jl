# Cold files/schema/plan inspection only. No export, deployment or scientific replay.
using PipeWireAODeployment,TOML
const D=PipeWireAODeployment.Deployment
const C=PipeWireAODeployment.Common
const E=PipeWireAODeployment.CalibrationExport
const H=PipeWireAODeployment.HeartCalibrationExport
const W=PipeWireAODeployment.NativeCalibrationActionCodec
const Root="/home/dgamroth/.cache/rtc-calibration-completion-20261003"
const Plans=Dict("classic"=>"/home/dgamroth/.cache/rtc-calibration-quality-20261003/method-smoke-reverse-v2/canonical-plan.json",
    "copper"=>joinpath(Root,"heart-calibration-copper-nondebug-n2-prepared1/heart-calibration-plan.json"))
const Bases=["/tmp/$profile-$engine-sdk-interrupt-final-v1-installed" for profile in ("classic","copper") for engine in ("fgn","jfg")]
append!(Bases,["/tmp/$profile-heart-sdk-interrupt-final-v2-installed" for profile in ("classic","copper")])
results=Any[]
for package in Bases
    specification=D.profile(joinpath(package,"deployment.conf"),"/opt/pipewireao")
    provenance=C.read_json(joinpath(package,"provenance.json"))
    for (relative,hash) in specification["artifacts"]
        C.sha256_file(joinpath(package,relative)) == hash || error("base seal differs: $package/$relative")
    end
    profile,engine=provenance["profile"],provenance["engine"]
    plan_path=Plans[profile];plan=C.read_json(plan_path)
    W.preflight_collect_reply(plan["measurements"],plan["frames_per_probe"])
    row=Dict{String,Any}("package"=>package,"profile"=>profile,"engine"=>engine,
        "sealed_artifact_count"=>length(specification["artifacts"]),"descriptor_sha256"=>C.sha256_file(joinpath(package,"deployment.conf")),
        "provenance_sha256"=>C.sha256_file(joinpath(package,"provenance.json")),"plant_sha256"=>C.sha256_file(joinpath(package,"hil/plant.toml")),
        "runner_sha256"=>C.sha256_file(joinpath(package,"bin/pipewireao-rtc")),"called_plan"=>plan_path,"called_plan_sha256"=>C.sha256_file(plan_path),
        "capture_two_frame_payload_bytes"=>2*(profile == "classic" ? 250252 : 22596))
    if engine != "heart"
        graph=D.decode(joinpath(package,"graphs/graph.conf.in"),"/opt/pipewireao")
        pieces=E.split_graph(graph,profile,engine,"cold-inventory")
        row["calibration_graph_split_roles"]=sort!(collect(keys(pieces)))
    end
    if profile == "classic" && engine == "fgn"
        directory=joinpath(Root,"classic-native-selected-proof-v1/native-probe-plan-v1")
        policy_path=joinpath(directory,"policy.json")
        declared_plan=joinpath(directory,"interaction-plan.json")
        args=(;classic_transfer=directory,classic_transfer_sha256=C.sha256_file(policy_path),pipewire_prefix="/opt/pipewireao")
        try
            admitted=H.classic_transfer_inputs(args,package,provenance,declared_plan,98)
            row["classic_fresh_transfer_input_admission"]="passed"
            row["classic_accepted_inverse_sha256"]=admitted["record"]["accepted_inverse_sha256"]
        catch error
            row["classic_fresh_transfer_input_admission"]="failed"
            row["classic_fresh_transfer_input_failure"]=sprint(showerror,error)
        end
    end
    push!(results,row)
end
println(C.JSON3.write(Dict("scope"=>"cold current package seal/shape inventory; no SCI/export/install", "packages"=>results)))
