using PipeWireAORTC, Statistics, LinearAlgebra, Serialization, SHA
const C=PipeWireAORTC.Common
const OUT="/home/dgamroth/.cache/pipewireao/gpi2-tiptilt-20261025"
stats(v)=Dict("mean"=>mean(v),"minimum"=>minimum(v),"maximum"=>maximum(v),"first"=>first(v),"last"=>last(v))
function main()
    apath=joinpath(OUT,"replay-cuda-result.json");bpath=joinpath(OUT,"replay-feedback-projected-result.json")
    a=C.read_json(apath);b=C.read_json(bpath)
    @assert a["completed"] && b["completed"] && b["frames_completed"]==16384
    @assert C.sha256_file(apath)==b["baseline_sha256"]
    indexa=Dict(f=>i for(i,f) in enumerate(a["sampled_frames"]))
    sampledb=Int.(b["sampled_frames"])
    aval(name,idx)=[a["series"][name][indexa[sampledb[i]]] for i in idx]
    bval(name,idx)=Float64.(b["series"][name][idx])
    function ttmetrics(raw,idx)
        fields=raw["series"]
        v(name)=hcat(Float64.(fields[name*"_tip_nm"][idx]),Float64.(fields[name*"_tilt_nm"][idx]))'
        parts=map(v,("stage","woofer","tweeter"));total=sum(parts)
        rms(x)=0.5043631267352171*sqrt.(sum(abs2,x;dims=1))[:]
        Dict("stage_optical_tt_rms_nm"=>rms(parts[1]),"woofer_optical_tt_rms_nm"=>rms(parts[2]),"tweeter_optical_tt_rms_nm"=>rms(parts[3]),
            "combined_correction_optical_tt_rms_nm"=>rms(total),"sum_component_tt_rms_minus_combined_tt_rms_nm"=>sum(map(rms,parts))-rms(total))
    end
    report=Dict{String,Any}("completed"=>false,"scope"=>"One-seed private-array feedback-only A/B diagnostic; no production, live, physical or performance qualification",
        "baseline_sha256"=>C.sha256_file(apath),"projected_sha256"=>C.sha256_file(bpath),
        "baseline_atmosphere_match"=>b["baseline_atmosphere_match"],"projector"=>b["projector"],
        "state_comparison_boundary"=>"Only projected B run retained full correction and feedback; no matched baseline Nc/Nb comparison. Native-window Nc is separate evidence",
        "Nc_optical_component_interpretation"=>"Nc_* optical series are the unsaturated linear allocation equivalent, not an additive decomposition of actual nonlinear stage-clipped commands. Actual stage/DM TT and cancellation metrics use demanded commands and remain valid during clipping",
        "sampling"=>"Window and paired means use uniform every64frame observations. Per-frame clip means use complete512frame windows. Dense first32 startup observations are not mixed into window means",
        "series_alignment"=>b["series_alignment"],"windows"=>Dict{String,Any}())
    report["atmosphere_match_tolerance_nm"]=0.001
    report["atmosphere_all_metrics_bit_identical"]=all(v->v["all_float64_values_bit_identical"],values(b["baseline_atmosphere_match"]))
    report["matched_atmosphere_boundary_passed"]=all(v->v["maximum_absolute_error_nm"]<=0.001,values(b["baseline_atmosphere_match"]))
    report["comparison_claim_boundary"]=report["matched_atmosphere_boundary_passed"] ?
        "Matched atmospheric metric boundary satisfied; only-feedback A/B interpretation applies within recorded metric/state limits" :
        "Atmosphere metric boundary failed; paired output differences cannot isolate the feedback intervention"
    for (lo,hi) in ((1,2048),(2049,8192),(8193,16384),(2049,16384))
        idx=findall(f->lo<=f<=hi && f%64==0,sampledb)
        idxa=[indexa[sampledb[i]] for i in idx]
        block=Dict{String,Any}("model_time_s"=>[(lo-1)*b["model_period_s"],hi*b["model_period_s"]],"observed_frames"=>length(idx))
        for name in ("residual_rms_nm","atmosphere_rms_nm","woofer_requested_peak_nm","tweeter_requested_peak_nm",
                "stage_tip_nm","stage_tilt_nm","woofer_tip_nm","woofer_tilt_nm","tweeter_tip_nm","tweeter_tilt_nm")
            va=aval(name,idx);vb=bval(name,idx)
            block[name]=Dict("baseline"=>stats(va),"projected"=>stats(vb),"paired_projected_minus_baseline"=>stats(vb-va))
        end
        ma=ttmetrics(a,idxa);mb=ttmetrics(b,idx)
        for name in keys(ma)
            block[name]=Dict("baseline"=>stats(ma[name]),"projected"=>stats(mb[name]),"paired_projected_minus_baseline"=>stats(mb[name]-ma[name]))
        end
        for (label,raw) in (("baseline",a),("projected",b))
            selected=filter(w->lo<=w["start_frame"] && w["end_frame"]<=hi,raw["clip_windows"])
            block[label*"_per_frame_mean_clipped_actuators"]=Dict(name=>mean(w["mean_clipped_count"][name] for w in selected) for name in ("woofer","tweeter"))
            ii=label=="baseline" ? idxa : idx
            block[label*"_sampled_stage_at_limit_fraction"]=mean(i->max(abs(raw["series"]["stage_tip_nm"][i]),abs(raw["series"]["stage_tilt_nm"][i]))>=Float64(Float32(1e-6))*1e9-1e-6,ii)
        end
        for name in ("Nc_raw_coordinate_norm_nm","Nc_column_RMS_scaled_coordinate_norm_nm","Nb_raw_coordinate_norm_nm","Nb_sent_raw_coordinate_norm_nm")
            block["projected_"*name]=stats(bval(name,idx))
        end
        report["windows"]["$lo-$hi"]=block
    end
    full=deserialize(joinpath(OUT,"replay-feedback-projected-full-samples.jls"))
    @assert full.frames==sampledb
    cnorm=[norm(c)*1e9 for c in full.c]
    nc=Float64.(b["series"]["Nc_raw_coordinate_norm_nm"])
    nb=Float64.(b["series"]["Nb_raw_coordinate_norm_nm"])
    nsent=Float64.(b["series"]["Nb_sent_raw_coordinate_norm_nm"])
    report["projected_correction_discarded_content"]=Dict("raw_coordinate_Nc_norm_nm"=>stats(nc),
        "Nc_norm_relative_to_c_norm"=>stats(nc./cnorm),
        "sent_vs_raw_discarded_feedback_frobenius_ratio"=>norm(nsent)/norm(nb),
        "interpretation"=>"Coordinate diagnostics only, not actual optical RMS; small nonzero content can arise from approximate stored-calibration projector and Float32 updates/reconstruction")
    projector=deserialize(joinpath(OUT,"feedback-retained-projector-f32.jls"))
    @assert bytes2hex(SHA.sha256(reinterpret(UInt8,vec(projector))))==b["projector"]["P32_raw_bytes_sha256"]
    report["full_correction_feedback_samples"]=length(full.frames)
    report["full_sample_artifact_sha256"]=C.sha256_file(joinpath(OUT,"replay-feedback-projected-full-samples.jls"))
    report["maximum_optical_tt_closure_error_nm"]=b["maximum_optical_tt_closure_error_nm"]
    report["maximum_correction_reconstruction_roundtrip_error_nm"]=b["maximum_correction_reconstruction_roundtrip_error_nm"]
    report["completed"]=true
    C.write_json(joinpath(OUT,"feedback-projection-ab-summary.json"),report)
    for key in ("1-2048","2049-8192","8193-16384","2049-16384")
        w=report["windows"][key]
        println(key," RMS_A_B=",[w["residual_rms_nm"][p]["mean"] for p in ("baseline","projected")],
            " Wpeak_A_B=",[w["woofer_requested_peak_nm"][p]["mean"] for p in ("baseline","projected")],
            " Tpeak_A_B=",[w["tweeter_requested_peak_nm"][p]["mean"] for p in ("baseline","projected")],
            " clip_A=",w["baseline_per_frame_mean_clipped_actuators"]," clip_B=",w["projected_per_frame_mean_clipped_actuators"],
            " Nc_B_mean_max=",[w["projected_Nc_raw_coordinate_norm_nm"][k] for k in ("mean","maximum")])
    end
end
main()
