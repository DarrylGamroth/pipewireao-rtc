# Independent aggregation and reset checks on the saved numerical observations.
using JSON, Statistics, Test
read_case(root, label) = JSON.parse(read(joinpath(root, "case-" * label * ".json"), String))

function verify(root, output)
    cases = Dict(label => read_case(root, label) for label in
        ("baseline-4096", "candidate-4096", "baseline-16384", "candidate-16384"))
    @test all(case["completed"] for case in values(cases))
    for prefix in ("baseline", "candidate")
        short, long = cases[prefix * "-4096"], cases[prefix * "-16384"]
        @test long["atmosphere_field_sha256_every_frame"][1:4096] == short["atmosphere_field_sha256_every_frame"]
        @test long["raw_camera_sha256_at_observations"][1:length(short["sampled_frames"])] == short["raw_camera_sha256_at_observations"]
        for (name, samples) in short["per_frame"]
            @test long["per_frame"][name][1:4096] == samples
        end
        for (name, samples) in short["series"]
            @test long["series"][name][1:length(samples)] == samples
        end
    end
    baseline, candidate = cases["baseline-16384"], cases["candidate-16384"]
    @test baseline["atmosphere_field_sha256_every_frame"] == candidate["atmosphere_field_sha256_every_frame"]
    @test baseline["reset_detector_rng"] == candidate["reset_detector_rng"]
    result = Dict()
    for (label, case) in (("baseline", baseline), ("candidate", candidate))
        sampled = findall(frame -> 2049 <= frame <= 16384, case["sampled_frames"])
        wfe = case["series"]["residual_rms_nm"][sampled]
        @test all(isfinite, wfe)
        metrics = Dict{String,Union{Real,Dict{String,Real}}}("sampled_wfe_mean_nm"=>mean(wfe), "sampled_wfe_max_nm"=>maximum(wfe),
            "optical_observations"=>length(sampled))
        for (name, count) in (("woofer", 97), ("tweeter", 2304), ("stage", 2))
            clipped = case["per_frame"][name * "_clipped_count"][2049:16384]
            requested = case["per_frame"][name * "_requested_peak_nm"][2049:16384]
            demanded = case["per_frame"][name * "_demanded_peak_nm"][2049:16384]
            @test all(value -> 0 <= value <= count, clipped)
            metrics[name] = Dict("mean_clipped"=>mean(clipped), "max_clipped"=>maximum(clipped),
                "fraction_frames_clipped"=>mean(clipped .> 0), "max_requested_nm"=>maximum(requested),
                "max_demanded_nm"=>maximum(demanded))
        end
        result[label] = metrics
    end
    result["wfe_ratio"] = result["candidate"]["sampled_wfe_mean_nm"] / result["baseline"]["sampled_wfe_mean_nm"]
    result["scope"] = "Independent late-window aggregation and exact short/long reset-prefix checks; not hardware or stability qualification"
    write(output, JSON.json(result; pretty=2) * "\n")
end

length(ARGS) == 2 || error("usage: verify-results.jl RAW_CASE_DIRECTORY OUTPUT_JSON")
@testset "Saved stroke comparison and reset reproducibility" begin
    verify(ARGS...)
end
