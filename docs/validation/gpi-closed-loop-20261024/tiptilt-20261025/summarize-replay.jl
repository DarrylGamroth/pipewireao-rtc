using PipeWireAORTC, Statistics, LinearAlgebra
const C=PipeWireAORTC.Common
const OUT="/home/dgamroth/.cache/pipewireao/gpi2-tiptilt-20261025"
stats(v)=Dict("mean"=>mean(v),"minimum"=>minimum(v),"maximum"=>maximum(v),"first"=>first(v),"last"=>last(v))
function main()
    path=joinpath(OUT,"replay-cuda-result.json")
    raw=C.read_json(path)
    @assert raw["completed"]
    s=raw["series"];frames=Int.(raw["sampled_frames"])
    tt(name)=hcat(Float64.(s[name*"_tip_nm"]),Float64.(s[name*"_tilt_nm"]))'
    stage=tt("stage");woofer=tt("woofer");tweeter=tt("tweeter")
    total=stage+woofer+tweeter
    scale=0.5043631267352171
    opticalrms(v)=sqrt.(sum(abs2,v;dims=1))[:]*scale
    metrics=Dict{String,Vector{Float64}}(
        "stage_optical_tt_rms_nm"=>opticalrms(stage),
        "woofer_optical_tt_rms_nm"=>opticalrms(woofer),
        "tweeter_optical_tt_rms_nm"=>opticalrms(tweeter),
        "combined_correction_optical_tt_rms_nm"=>opticalrms(total),
        "atmosphere_optical_tt_rms_nm"=>opticalrms(tt("atmosphere")),
        "residual_optical_tt_rms_nm"=>opticalrms(tt("residual")),
        "sum_component_tt_rms_minus_combined_tt_rms_nm"=>opticalrms(stage)+opticalrms(woofer)+opticalrms(tweeter)-opticalrms(total),
        "sum_dm_tt_rms_minus_combined_dm_tt_rms_nm"=>opticalrms(woofer)+opticalrms(tweeter)-opticalrms(woofer+tweeter),
        "residual_rms_nm"=>Float64.(s["residual_rms_nm"]),
        "atmosphere_rms_nm"=>Float64.(s["atmosphere_rms_nm"]),
        "woofer_requested_peak_nm"=>Float64.(s["woofer_requested_peak_nm"]),
        "tweeter_requested_peak_nm"=>Float64.(s["tweeter_requested_peak_nm"]),
        "sampled_woofer_clipped_actuators"=>Float64.(s["woofer_clipped_count"]),
        "sampled_tweeter_clipped_actuators"=>Float64.(s["tweeter_clipped_count"]),
        "combined_current_correction_tip_nm"=>vec(total[1,:]),
        "combined_current_correction_tilt_nm"=>vec(total[2,:]),
        "summed_dm_tip_nm"=>vec((woofer+tweeter)[1,:]),
        "summed_dm_tilt_nm"=>vec((woofer+tweeter)[2,:]),
        "stage_tip_plus_same_frame_atmosphere_tip_nm"=>Float64.(s["stage_tip_nm"])+Float64.(s["atmosphere_tip_nm"]),
        "stage_tilt_plus_same_frame_atmosphere_tilt_nm"=>Float64.(s["stage_tilt_nm"])+Float64.(s["atmosphere_tilt_nm"]))
    stage_saturated=vec(any(abs.(stage).>=Float64(Float32(1e-6))*1e9-1e-6;dims=1))
    dm_opposed=vec(sum(woofer.*tweeter;dims=1).<0)
    stage_dm_opposed=vec(sum(stage.*(woofer+tweeter);dims=1).<0)
    summary=Dict{String,Any}("scope"=>raw["scope"],"completed"=>raw["completed"],
        "frames"=>raw["frames_completed"],"model_duration_s"=>raw["frames_completed"]*raw["model_period_s"],
        "elapsed_processing_s"=>raw["elapsed_s"],"optical_tt_closure_error_nm"=>raw["maximum_optical_tt_closure_error_nm"],
        "input_sha256"=>C.sha256_file(path),"source"=>path,
        "observation_cadence"=>raw["observation_cadence"],"series_alignment"=>raw["series_alignment"],
        "window_mean_sampling"=>"Only uniform every64frame observations enter window means; first32 dense startup observations are summarized separately",
        "limits"=>["Finite one-seed moving-atmosphere model trajectory; no physical, deadline or long-term stability qualification",
            "Mirror optical tilt is not the same as the two dedicated controller tip/tilt coordinates",
            "Changes across moving-atmosphere windows do not alone establish integrator windup",
            "Optical component cancellation is observed; the full controller modal state and its nullspace projections were not retained, so nullspace growth is not directly established",
            "CPU and CUDA atmosphere realizations differ for the same configured seed; no exact cross-backend trajectory parity claimed"],
        "windows"=>Dict{String,Any}(),"stage_saturation_associations"=>Dict{String,Any}())
    live=C.read_json(joinpath(OUT,"sample-analysis.json"))
    summary["live_snapshot_comparison"]=Dict("stage_axis_values_at_limit"=>live["stage_samples_at_limit"],
        "samples"=>live["sample_count"],"note"=>"Live retained window has no stage clipping; longer from-reset model trajectory visits other atmospheric states and can saturate stage")
    eligible=findall(i->frames[i]>2048 && frames[i]%64==0,eachindex(frames))
    summary["startup_first32_frames"]=Dict(metric=>stats(v[findall(<=(32),frames)]) for(metric,v) in metrics)
    for (name,idx) in (("saturated",filter(i->stage_saturated[i],eligible)),("not_saturated",filter(i->!stage_saturated[i],eligible)))
        association=Dict{String,Any}("sampled_frames"=>length(idx),"fraction_of_eligible_observed_frames"=>length(idx)/length(eligible),
            "scope"=>"Association in uniform every64frame observations after first2048 model frames; not a causal stage-clipping experiment")
        for (metric,v) in metrics;association[metric]=stats(v[idx]);end
        summary["stage_saturation_associations"][name]=association
    end
    for (a,b) in ((1,2048),(2049,8192),(8193,16384),(16385,32768),(32769,49152),(49153,65536))
        idx=findall(f->a<=f<=b && f%64==0,frames)
        block=Dict{String,Any}("model_time_s"=>[(a-1)*raw["model_period_s"],b*raw["model_period_s"]],"observed_frames"=>length(idx))
        for(name,v) in metrics;block[name]=stats(v[idx]);end
        for name in ("stage","woofer","tweeter","atmosphere","residual")
            for axis in ("tip","tilt");block[name*"_"*axis*"_nm"]=stats(s[name*"_"*axis*"_nm"][idx]);end
        end
        block["sampled_stage_axis_values_at_limit"]=count(x->abs(x)>=Float64(Float32(1e-6))*1e9-1e-6,stage[:,idx])
        block["sampled_frames_with_any_stage_axis_at_limit_fraction"]=mean(stage_saturated[idx])
        block["sampled_woofer_tweeter_tt_vectors_opposed_fraction"]=mean(dm_opposed[idx])
        block["sampled_stage_combined_dm_tt_vectors_opposed_fraction"]=mean(stage_dm_opposed[idx])
        clipidx=findall(w->a<=w["start_frame"] && w["end_frame"]<=b,raw["clip_windows"])
        block["per_frame_mean_clipped_actuators"]=Dict(name=>mean(raw["clip_windows"][i]["mean_clipped_count"][name] for i in clipidx) for name in ("woofer","tweeter"))
        summary["windows"]["$a-$b"]=block
    end
    mid=summary["windows"]["16385-32768"];late=summary["windows"]["49153-65536"]
    changes=Dict{String,Any}("comparison"=>"Late24.576-32.768s minus middle8.192-16.384s; descriptive moving-atmosphere block means, not a causal isolation experiment")
    for key in ("stage_tip_nm","woofer_tip_nm","tweeter_tip_nm","atmosphere_tip_nm","residual_tip_nm",
            "combined_current_correction_tip_nm","summed_dm_tip_nm","stage_tip_plus_same_frame_atmosphere_tip_nm",
            "stage_tilt_nm","woofer_tilt_nm","tweeter_tilt_nm","atmosphere_tilt_nm","residual_tilt_nm",
            "combined_current_correction_tilt_nm","summed_dm_tilt_nm","stage_tilt_plus_same_frame_atmosphere_tilt_nm",
            "sum_component_tt_rms_minus_combined_tt_rms_nm","woofer_requested_peak_nm","tweeter_requested_peak_nm")
        changes[key]=Dict("middle_mean"=>mid[key]["mean"],"late_mean"=>late[key]["mean"],"late_minus_middle"=>late[key]["mean"]-mid[key]["mean"])
    end
    summary["post_settling_redistribution_observation"]=changes
    C.write_json(joinpath(OUT,"replay-cuda-summary.json"),summary)
    for(a,b) in ((1,2048),(2049,8192),(8193,16384),(16385,32768),(32769,49152),(49153,65536))
        v=summary["windows"]["$a-$b"]
        println(a,"-",b," model_s=",v["model_time_s"]," residual_mean_nm=",v["residual_rms_nm"]["mean"],
            " atmosphere_mean_nm=",v["atmosphere_rms_nm"]["mean"]," clip_mean=",v["per_frame_mean_clipped_actuators"],
            " stage_tt=",v["stage_optical_tt_rms_nm"]["mean"]," woofer_tt=",v["woofer_optical_tt_rms_nm"]["mean"],
            " tweeter_tt=",v["tweeter_optical_tt_rms_nm"]["mean"]," combined_tt=",v["combined_correction_optical_tt_rms_nm"]["mean"],
            " cancellation=",v["sum_component_tt_rms_minus_combined_tt_rms_nm"]["mean"])
    end
end
main()
