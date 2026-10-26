using LinearAlgebra, Statistics, Serialization
using PipeWireAORTC
const OUT="/home/dgamroth/.cache/pipewireao/gpi2-tiptilt-20261025"
const C=PipeWireAORTC.Common
stats(x)=Dict("mean"=>mean(x),"minimum"=>minimum(x),"maximum"=>maximum(x),"first"=>first(x),"last"=>last(x),"standard_deviation"=>std(x))
function main()
    BLAS.set_num_threads(1)
    o=deserialize(joinpath(OUT,"optical-maps.jls"))
    raw=C.read_json(joinpath(OUT,"native-samples.json"))
    seq=raw["common_sequences"]
    # JSON stores shortest Float32 decimals; restore wire values before widening.
    stream(name)=hcat((Float64.(Float32.(raw["streams"][name]["samples"][findfirst(==(s),raw["streams"][name]["sequences"])])) for s in seq)...)
    stage=stream("tiptilt")
    report=Dict{String,Any}("scope"=>"Same-sequence retained native samples; offline exact optical piston/ramp least squares; no from-reset buildup inference",
        "sample_count"=>length(seq),"sequences"=>seq,"sample_source_sha256"=>C.sha256_file(joinpath(OUT,"native-samples.json")),
        "stage_tip_nm"=>stats(stage[1,:]*1e9),"stage_tilt_nm"=>stats(stage[2,:]*1e9),
        "stage_samples_at_limit"=>count(x->abs(x)>=0.999999e-6,stage),"mirrors"=>Dict{String,Any}())
    saved=Dict{String,Any}("sequences"=>seq,"stage_coefficients_m"=>stage)
    sumd=zeros(3,length(seq));sumr=zeros(3,length(seq))
    for mirror in ("woofer","tweeter")
        d=stream(mirror); feedback=stream(mirror*"-constraint-feedback"); r=d+feedback
        G=o.maps[mirror]; td=G*d; tr=G*r; sumd .+= td;sumr .+=tr
        exact=all(i->feedback[i]==0 || Float32(d[i])==sign(Float32(feedback[i]))*Float32(1e-6),eachindex(d))
        @assert exact
        m=Dict{String,Any}("exact_signed_limit_feedback"=>exact,
            "clipped_actuators"=>stats(vec(sum(!iszero,feedback;dims=1))),
            "requested_command_piston_nm"=>stats(vec(mean(r;dims=1))*1e9),
            "requested_command_peak_nm"=>stats(vec(maximum(abs,r;dims=1))*1e9),
            "requested_command_span_nm"=>stats(vec(maximum(r;dims=1)-minimum(r;dims=1))*1e9))
        for (kind,v) in (("demanded",td),("requested",tr))
            for (i,name) in enumerate(("pupil_piston_nm","optical_tip_coefficient_nm","optical_tilt_coefficient_nm"))
                m[kind*"_"*name]=stats(v[i,:]*1e9)
            end
            m[kind*"_optical_tt_rms_nm"]=stats(sqrt.(sum(abs2,v[2:3,:];dims=1))[:].*o.report["pupil_xy_rms"][1]*1e9)
        end
        if mirror=="woofer"
            coordinates=o.P\r
            m["requested_fitted_tt_command_coordinate_nm"]=stats(sqrt.(sum(abs2,coordinates[1:2,:];dims=1))[:]*1e9)
            # This is a static allocation counterfactual, never a controller recommendation.
            tt_command=o.F*((G[2:3,:]*o.F)\tr[2:3,:])
            without_tt=r-tt_command
            without_piston=r.-mean(r;dims=1)
            m["counterfactual_clipped_actuators_after_optical_tt_removal"]=stats(vec(sum(x->abs(x)>Float64(Float32(1e-6)),without_tt;dims=1)))
            m["counterfactual_clipped_actuators_after_command_piston_removal"]=stats(vec(sum(x->abs(x)>Float64(Float32(1e-6)),without_piston;dims=1)))
            m["counterfactual_peak_after_optical_tt_removal_nm"]=stats(vec(maximum(abs,without_tt;dims=1))*1e9)
            m["counterfactual_peak_after_command_piston_removal_nm"]=stats(vec(maximum(abs,without_piston;dims=1))*1e9)
        elseif mirror=="tweeter"
            transferred=stage+td[2:3,:]
            m["ideal_optical_tt_transfer_to_stage_tip_nm"]=stats(transferred[1,:]*1e9)
            m["ideal_optical_tt_transfer_to_stage_tilt_nm"]=stats(transferred[2,:]*1e9)
            m["ideal_optical_tt_transfer_stage_limit_exceedances"]=count(x->abs(x)>1e-6,transferred)
        end
        report["mirrors"][mirror]=m
        saved[mirror]=Dict("demanded_coefficients_m"=>td,"requested_coefficients_m"=>tr)
    end
    sumd[2:3,:] .+= stage;sumr[2:3,:] .+= stage
    for (kind,v) in (("demanded",sumd),("requested",sumr))
        report["total_correction_"*kind*"_optical_tip_coefficient_nm"]=stats(v[2,:]*1e9)
        report["total_correction_"*kind*"_optical_tilt_coefficient_nm"]=stats(v[3,:]*1e9)
    end
    saved["metrics"]=report
    C.write_json(joinpath(OUT,"sample-analysis.json"),report)
    C.write_json(joinpath(OUT,"sample-optical-series.json"),saved)
    println("Analyzed ",length(seq)," common sequences ",first(seq),"..",last(seq))
    for mirror in ("woofer","tweeter")
        m=report["mirrors"][mirror]
        for key in sort(collect(keys(m)))
            println(mirror," ",key," ",m[key])
        end
    end
    println("stage_tip_nm ",report["stage_tip_nm"]," stage_tilt_nm ",report["stage_tilt_nm"])
end
main()
