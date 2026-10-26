# Independent checks on saved observations; no optical graph or GPU is loaded.
using JSON, Statistics, Test
read_case(root,label)=JSON.parse(read(joinpath(root,"case-"*label*".json"),String))
function metrics(case,first_frame,last_frame)
    selected=findall(f->first_frame<=f<=last_frame,case["sampled_frames"])
    wfe=case["series"]["residual_rms_nm"][selected]
    frames=first_frame:last_frame
    devices=Dict(name=>(;mean_clipped=mean(case["per_frame"][name*"_clipped_count"][frames]),
        max_clipped=maximum(case["per_frame"][name*"_clipped_count"][frames]),
        clipped_frame_fraction=mean(case["per_frame"][name*"_clipped_count"][frames].>0),
        requested_peak_nm=maximum(case["per_frame"][name*"_requested_peak_nm"][frames]),
        demanded_peak_nm=maximum(case["per_frame"][name*"_demanded_peak_nm"][frames]))
        for name in ("woofer","tweeter","stage"))
    return (;first_frame,last_frame,optical_observations=length(wfe),
        sampled_wfe_mean_nm=mean(wfe),sampled_wfe_max_nm=maximum(wfe),devices,
        stage_tracking_error_peak_nm=maximum(case["per_frame"]["stage_tracking_error_peak_nm"][frames]),
        stage_applied_peak_nm=maximum(case["per_frame"]["stage_applied_peak_nm"][frames]),
        stage_response_exceeds_command_limit_frames=count(>(0),case["per_frame"]["stage_applied_outside_command_limit_count"][frames]))
end
function verify(root,output)
    report=JSON.parse(read(joinpath(root,"replay-result.json"),String))
    @test report["completed"]
    @test report["frozen_graph_receipt_manifest_unchanged"]
    @test report["historical_accepted_woofer_match"]["passed"]
    short_labels=("ideal-identity-4096","ideal-lowpass25-4096","dynamic-identity-4096","dynamic-lowpass25-4096")
    long_labels=("dynamic-identity-16384","dynamic-lowpass25-16384")
    cases=Dict(label=>read_case(root,label) for label in (short_labels...,long_labels...))
    @test all(c["completed"] for c in values(cases))
    @test all(c["frames_completed"]==c["frames_requested"] for c in values(cases))
    # The runner checkpoints the final frame before marking completion; enforce
    # the predeclared warm-case bound here as well as its intermediate guard.
    @test all(0<=c["elapsed_s"]<=300 for c in values(cases))
    reference=cases[first(short_labels)]
    for case in values(cases)
        @test case["all_controller_and_optical_outputs_finite"]
        @test case["atmosphere_field_sha256_every_frame"][1:4096]==reference["atmosphere_field_sha256_every_frame"]
        @test case["reset_detector_rng"]==reference["reset_detector_rng"]
        @test all(isfinite,case["series"]["residual_rms_nm"])
    end
    for prefix in ("dynamic-identity","dynamic-lowpass25")
        short,long=cases[prefix*"-4096"],cases[prefix*"-16384"]
        for (key,observations) in short["per_frame"]
            @test long["per_frame"][key][1:4096]==observations
        end
        for (key,observations) in short["series"]
            @test long["series"][key][1:length(observations)]==observations
        end
        for (key,observations) in short["full_demanded_command_sha256_every_frame"]
            @test long["full_demanded_command_sha256_every_frame"][key][1:4096]==observations
        end
        @test long["raw_camera_sha256_at_observations"][1:length(short["sampled_frames"])]==short["raw_camera_sha256_at_observations"]
    end
    @test cases[first(long_labels)]["atmosphere_field_sha256_every_frame"]==cases[last(long_labels)]["atmosphere_field_sha256_every_frame"]
    result=(;short=Dict(label=>metrics(cases[label],2049,4096) for label in short_labels),
        long=Dict(label=>metrics(cases[label],2049,16384) for label in long_labels),
        scope="Finite one-seed simulator sensitivity; sampled WFE versus every-frame command/response statistics; not measured stage calibration, global stability or hardware qualification")
    write(output,JSON.json(result;pretty=2)*"\n")
end
length(ARGS)==2 || error("usage: verify-results.jl CASE_DIRECTORY OUTPUT_JSON")
@testset "Saved temporal comparison and reset reproducibility" begin
    verify(ARGS...)
end
