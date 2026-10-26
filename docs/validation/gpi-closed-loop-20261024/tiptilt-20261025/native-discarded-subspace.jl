using PipeWireAORTC, LinearAlgebra, Statistics, Serialization, SHA
const C=PipeWireAORTC.Common
const OUT="/home/dgamroth/.cache/pipewireao/gpi2-tiptilt-20261025"
const APP="/home/dgamroth/.local/state/pipewireao/gpi2-registered-live-20261025/application"
stats(v)=Dict("mean"=>mean(v),"minimum"=>minimum(v),"maximum"=>maximum(v),"first"=>first(v),"last"=>last(v))
norms(x)=sqrt.(sum(abs2,x;dims=1))[:]
function main()
    BLAS.set_num_threads(1)
    report=Dict{String,Any}("completed"=>false,"scope"=>"Offline CPU matrix analysis of retained full native command/feedback samples; no live attachment, no GPU, no settings changes",
        "driver_sha256"=>C.sha256_file(@__FILE__),"blas_threads"=>BLAS.get_num_threads())
    path=joinpath(OUT,"native-discarded-subspace.json")
    checkpoint()=C.write_json(path,report)
    checkpoint()
    try
        receipt=C.read_yaml(joinpath(APP,"calibration/result.yaml"))
        fits=PipeWireAORTC.Artifacts.FITSIO
        function artifact(name)
            filename=name*".fits";p=joinpath(APP,"calibration/artifacts",filename)
            @assert C.sha256_file(p)==receipt["artifact_sha256"][filename] filename
            fits.FITS(p,"r") do file
                a=read(file[1]);ndims(a)==1 ? a : permutedims(a,reverse(ntuple(identity,ndims(a))))
            end
        end
        Pw=Float64.(artifact("woofer-vdm-to-pdm"));Aw=Float64.(artifact("woofer-active-to-full"))
        Mw=Float64.(artifact("woofer-full-to-active"))*Float64.(artifact("woofer-pdm-to-vdm"))
        Pt=Float64.(artifact("tweeter-vdm-to-pdm"));At=Float64.(artifact("tweeter-active-to-full"))
        Mt=Float64.(artifact("tweeter-full-to-active"))*Float64.(artifact("tweeter-pdm-to-vdm"))
        Ew=Float64.(artifact("woofer-vdm-to-controller"));Et=Float64.(artifact("tweeter-vdm-to-controller"))
        Sw=Float64.(artifact("woofer-selection"));St=Float64.(artifact("tweeter-selection"))
        F=Float64.(artifact("tiptilt-to-woofer"));T=Float64.(artifact("controller-to-tiptilt"))
        for name in ("woofer-offset","tweeter-offset","tiptilt-offset","woofer-system-flat","tweeter-system-flat")
            @assert all(iszero,artifact(name))
        end
        for name in ("modal-filter-coefficients","tiptilt-filter-coefficients")
            coeff=artifact(name)
            @assert all(==(1f0),coeff[1,:,:]) && all(iszero,coeff[2:end,:,:])
        end
        @assert Ew==Sw' && Et==St'
        @assert all(==(1.0),sum(Sw;dims=1)+sum(St;dims=1))
        report["inverse_contract"]=Dict("woofer_left_inverse_max_abs_error"=>maximum(abs,Mw*Pw*Aw-I),
            "tweeter_left_inverse_max_abs_error"=>maximum(abs,Mt*Pt*At-I),"woofer_condition"=>cond(Pw*Aw))
        raw=C.read_json(joinpath(OUT,"native-samples.json"));seq=Int.(raw["common_sequences"])
        stream32(name)=hcat((Float32.(raw["streams"][name]["samples"][findfirst(==(s),raw["streams"][name]["sequences"])]) for s in seq)...)
        wd=stream32("woofer");wf=stream32("woofer-constraint-feedback")
        td=stream32("tweeter");tf=stream32("tweeter-constraint-feedback");stage=Float64.(stream32("tiptilt"))
        @assert maximum(abs,stage)<Float64(Float32(1e-6))
        rw=Float64.(wd+wf);rt=Float64.(td+tf)
        cw=(Pw*Aw)\(rw+F*stage);ct=Mt*rt
        correction=Ew*cw+Et*ct
        correction_declared=Ew*(Mw*(rw+F*stage))+Et*ct
        feedback=Ew*(Mw*Float64.(wf))+Et*(Mt*Float64.(tf))
        feedback32=Float64.(Float32.(Ew)*(Float32.(Mw)*wf)+Float32.(Et)*(Float32.(Mt)*tf))
        wrt=Pw*Aw*(Sw*correction)-F*(T*correction)
        trt=Pt*At*(St*correction)
        report["reconstruction"]=Dict("meaning"=>"Controller correction output c_n; not same-frame internal pre-update state",
            "assumptions"=>["Saved calibration mappings and identity filters remain active; zero offsets/shape baseline for absolute c",
                "Any unknown fixed command/shape offset changes absolute c and Nc but cancels from consecutive differences",
                "No same-window parameter readbacks were retained; earlier same-invocation receipt verified zero offsets"],
            "maximum_woofer_command_roundtrip_error_nm"=>maximum(abs,wrt-rw)*1e9,
            "maximum_tweeter_command_roundtrip_error_nm"=>maximum(abs,trt-rt)*1e9,
            "maximum_stage_roundtrip_error_nm"=>maximum(abs,T*correction-stage)*1e9,
            "exact_solve_vs_declared_inverse_max_coordinate_error_nm"=>maximum(abs,correction-correction_declared)*1e9,
            "double_vs_float32_feedback_max_coordinate_error_nm"=>maximum(abs,feedback-feedback32)*1e9)
        report["sequences"]=seq
        report["wire_conversion"]="JSON decimal -> Float32 wire values -> Float64 analysis; requested command reconstructed with Float32 demanded+feedback"
        identities=[(v["first_identity"]["domain"],v["first_identity"]["generation"],v["last_identity"]["domain"],v["last_identity"]["generation"]) for v in values(raw["observations"]["streams"])]
        @assert all(==(first(identities)),identities)
        @assert first(identities)[1]==first(identities)[3] && first(identities)[2]==first(identities)[4]
        report["stream_domain_generation"]=collect(first(identities))
        J=Float64.(artifact("interaction-matrix"));R=Float64.(artifact("reconstructor"))
        @assert size(J)==reverse(size(R)) && size(J,2)==size(correction,1)
        rms=Float64.(receipt["mode_rms"]);@assert all(>(sqrt(eps(Float32))),rms)
        weights=1 ./rms
        sigma=Float64.(artifact("singular-values"));rankcount=count(>(maximum(sigma)*receipt["tsvd_rtol"]),sigma)
        @assert rankcount==receipt["retained_rank"]
        project(x)=R*(J*x)
        discard(x)=x-project(x)
        probes=[sin(0.133i+0.41k)+cos(0.071i-0.2k) for i in axes(R,1),k in 1:8]
        y=[sin(0.027i+0.19k) for i in axes(R,2),k in 1:4]
        pprobe=project(probes);nprobe=discard(probes)
        zp=probes;weightedp=project(weights.*zp)./weights
        weightedq=project(weights.*reverse(zp;dims=1))./weights
        # In z=W^-1 c coordinates the TSVD projection is orthogonal.
        selfadjoint=abs(dot(reverse(zp;dims=1),weightedp)-dot(zp,weightedq))/(norm(zp)*norm(zp))
        report["projector_contract"]=Dict("formula"=>"R=W*(J*W)^+; P=R*J=W*Vr*Vr'*inv(W); N=I-P; W=diag(1/mode_rms)",
            "interpretation"=>"Oblique in raw controller coordinates. W^-1-scaled coordinates restore TSVD orthogonality; their Euclidean norm is not actual optical RMS because physical modal surfaces overlap",
            "retained_rank"=>rankcount,"discarded_dimension"=>size(J,2)-rankcount,
            "probe_projector_idempotence_relative"=>norm(project(pprobe)-pprobe)/norm(pprobe),
            "probe_discard_idempotence_relative"=>norm(discard(nprobe)-nprobe)/norm(nprobe),
            "weighted_self_adjoint_bilinear_relative"=>selfadjoint,
            "reconstructor_range_probe_N_R_relative"=>norm(discard(R*y))/norm(R*y),
            "sample_c_projector_idempotence_relative"=>norm(project(project(correction))-project(correction))/norm(project(correction)))
        nc=discard(correction);nb=discard(feedback);ncdecl=discard(correction_declared)
        pairs=findall(i->seq[i+1]==seq[i]+1,1:length(seq)-1)
        delta=correction[:,pairs.+1]-correction[:,pairs]
        ndelta=discard(delta)
        lhs=discard(delta+feedback[:,pairs])
        wrongsign=discard(delta-feedback[:,pairs])
        wronglag=discard(delta+feedback[:,pairs.+1])
        scaled(x)=rms.*x
        report["discarded_correction_output"]=Dict("raw_coordinate_L2_nm"=>stats(norms(nc)*1e9),
            "column_RMS_scaled_coordinate_L2_nm"=>stats(norms(scaled(nc))*1e9),
            "declared_inverse_sensitivity_max_coordinate_nm"=>maximum(abs,nc-ncdecl)*1e9)
        report["discarded_feedback"]=Dict("raw_coordinate_L2_nm"=>stats(norms(nb)*1e9),
            "column_RMS_scaled_coordinate_L2_nm"=>stats(norms(scaled(nb))*1e9))
        report["consecutive_recurrence"]=Dict("equation"=>"N(c_n-c_(n-1))+N*b_(n-1) approximately 0, since c_n=c_(n-1)-b_(n-1)-0.3e_n and N*e_n approximately 0",
            "consecutive_pairs"=>length(pairs),"ignored_nonconsecutive_pairs"=>length(seq)-1-length(pairs),
            "pair_sequences"=>[[seq[i],seq[i+1]] for i in pairs],
            "lhs_raw_coordinate_L2_nm"=>stats(norms(lhs)*1e9),
            "lhs_column_RMS_scaled_coordinate_L2_nm"=>stats(norms(scaled(lhs))*1e9),
            "N_delta_raw_coordinate_L2_nm"=>stats(norms(ndelta)*1e9),
            "N_previous_feedback_raw_coordinate_L2_nm"=>stats(norms(nb[:,pairs])*1e9),
            "lhs_frobenius_relative_to_N_previous_feedback"=>norm(lhs)/norm(nb[:,pairs]),
            "scaled_lhs_frobenius_relative_to_scaled_N_previous_feedback"=>norm(scaled(lhs))/norm(scaled(nb[:,pairs])),
            "wrong_feedback_sign_relative"=>norm(wrongsign)/norm(nb[:,pairs]),
            "same_frame_feedback_instead_of_previous_relative"=>norm(wronglag)/norm(nb[:,pairs]),
            "N_delta_vs_negative_N_previous_feedback_cosine"=>dot(ndelta,-nb[:,pairs])/(norm(ndelta)*norm(nb[:,pairs])))
        optical=deserialize(joinpath(OUT,"optical-maps.jls"))
        function optical_tt(x)
            s=T*x
            w=optical.maps["woofer"][2:3,:]*(Pw*Aw*(Sw*x)-F*s)
            t=optical.maps["tweeter"][2:3,:]*(Pt*At*(St*x))
            return (;stage=s,woofer=w,tweeter=t,total=s+w+t)
        end
        nctt=optical_tt(nc);nbtt=optical_tt(nb)
        report["optical_component_interpretation"]="Linear contribution under the measured unsaturated allocation; projected components are not independently clipped or separately actuated commands"
        report["Nc_optical_TT_coefficients_nm"]=Dict(String(name)=>Dict("tip"=>stats(x[1,:]*1e9),"tilt"=>stats(x[2,:]*1e9)) for(name,x) in Base.pairs(nctt))
        report["Nb_optical_TT_coefficients_nm"]=Dict(String(name)=>Dict("tip"=>stats(x[1,:]*1e9),"tilt"=>stats(x[2,:]*1e9)) for(name,x) in Base.pairs(nbtt))
        series=Dict("sequences"=>seq,"Nc_raw_coordinate_norm_nm"=>norms(nc)*1e9,"Nb_raw_coordinate_norm_nm"=>norms(nb)*1e9,
            "Nc_column_RMS_scaled_coordinate_norm_nm"=>norms(scaled(nc))*1e9,"Nb_column_RMS_scaled_coordinate_norm_nm"=>norms(scaled(nb))*1e9,
            "Nc_optical_TT_coefficients_nm"=>Dict(String(name)=>x*1e9 for(name,x) in Base.pairs(nctt)),
            "Nb_optical_TT_coefficients_nm"=>Dict(String(name)=>x*1e9 for(name,x) in Base.pairs(nbtt)))
        C.write_json(joinpath(OUT,"native-discarded-subspace-series.json"),series)
        report["input_sha256"]=Dict("native_samples"=>C.sha256_file(joinpath(OUT,"native-samples.json")),"calibration_receipt"=>C.sha256_file(joinpath(APP,"calibration/result.yaml")))
        report["gpu_modules_loaded"]=any(id->id.name in ("CUDA","AMDGPU","GPUCompiler"),keys(Base.loaded_modules));@assert !report["gpu_modules_loaded"]
        report["completed"]=true
    catch err
        report["failure"]=sprint(showerror,err,catch_backtrace());rethrow()
    finally
        checkpoint()
    end
end
main()
