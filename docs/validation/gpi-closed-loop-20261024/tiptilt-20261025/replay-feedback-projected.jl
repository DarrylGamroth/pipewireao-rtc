include("gpi2_closed_loop_helpers.jl")
using LinearAlgebra, Statistics, Serialization, SHA, Libdl
const V=GPIClosedLoopValidation
const C=V.C
const OUT="/home/dgamroth/.cache/pipewireao/gpi2-tiptilt-20261025"
const APP="/home/dgamroth/.local/state/pipewireao/gpi2-registered-live-20261025/application"
const SOURCE="/home/dgamroth/.cache/pipewireao/gpi2-validation-20261025/instrument-source-v8/gpi2"
const HELPER="/home/dgamroth/workspaces/codex/instruments-gpi2-integration/test/gpi2_closed_loop.jl"
function actual_controller(calibration,receipt,report)
    V.progress("actual controller: decode and verify shape-only graph additions")
    path=joinpath(APP,"rtc/graph.conf")
    concrete=V.PipeWireAORTC.DeploymentConfiguration.decode(path,"/opt/pipewireao")
    baseline=V.PipeWireAORTC.DeploymentConfiguration.decode(joinpath(calibration,"graph.conf"),"/opt/pipewireao")
    reduced=deepcopy(concrete);g=reduced["filter.graph"]
    filter!(n->!(n["name"] in ("woofer-shape","tweeter-shape")),g["nodes"])
    filter!(l->!(l["input"] in ("woofer-shape:requested","tweeter-shape:requested")),g["links"])
    for l in g["links"],name in ("woofer","tweeter")
        l["output"]==name*"-shape:output" && (l["output"]=name*"-selection:vdm-command")
    end
    filter!(p->!occursin("current-",p["name"]),g["outputs"])
    filter!(p->!occursin("-shape-",p["name"]),g["inputs"])
    @assert reduced==baseline
    report["controller_science_graph_difference"]="Actual rtc graph adds only two zero initialized controlled-shape nodes, their parameter seams, and offset observation ports; removal and bypass yields calibrated graph exactly"
    report["actual_controller_graph_sha256"]=C.sha256_file(path)
    V.progress("actual controller: prepare untouched RTC graph")
    graph=V.JuliaFilterGraph.prepare_graph(path;algorithms=V.FilterGraphAlgorithms.algorithms())
    V.progress("actual controller: read verified parameter artifacts")
    parameters=Dict(name=>begin
        text=String(name)
        if endswith(text,"-shape-offset")
            zeros(format.element_type,format.shape)
        else
            asset=replace(text,"-shape-active-to-full"=>"-active-to-full","-shape-pdm-to-vdm"=>"-pdm-to-vdm")
            V.artifact(calibration,receipt,asset,format.element_type,format.shape)
        end
    end for(name,format) in pairs(V.JuliaFilterGraph.parameter_formats(graph)))
    V.progress("actual controller: bind all parameters")
    V.JuliaFilterGraph.replace_parameters!(graph,pairs(parameters)...)
    V.progress("actual controller: prepare host input/output storage")
    inputs=map(f->zeros(f.element_type,f.shape),V.JuliaFilterGraph.input_formats(graph))
    outputs=map(f->zeros(f.element_type,f.shape),V.JuliaFilterGraph.output_formats(graph))
    props=deepcopy(only(n for n in concrete["filter.graph"]["nodes"] if n["name"]=="closed-loop-correction")["props"])
    return (;graph,parameters,inputs,outputs,props)
end
function main()
    BLAS.set_num_threads(1); V.B.set_fft_provider_threads!(1)
    @assert V.CUDA_MODULE !== nothing "invoke with cuda argument"
    V.CUDA_MODULE.allowscalar(false)
    frames=16384
    baseline_path=joinpath(OUT,"replay-cuda-result.json")
    baseline=C.read_json(baseline_path)
    @assert baseline["completed"] && baseline["frames_completed"]>=frames
    report=Dict{String,Any}("completed"=>false,"scope"=>"Test-only CUDA private-array feedback projection from zero reset; unchanged production source/calibration/gains/limits; no native session or live changes",
        "experiment"=>"Only delayed constraint feedback is replaced by P32*b after each unchanged full_step!; c, internal state and residual error are not projected",
        "baseline_source"=>baseline_path,"baseline_sha256"=>C.sha256_file(baseline_path),
        "comparison_boundary"=>"Matched baseline optical/stroke/atmosphere observations in first16384frames; baseline full c and b were not retained, so no matched baseline Nc/Nb comparison",
        "source"=>SOURCE,"application"=>APP,"helper_source"=>HELPER,"helper_source_sha256"=>C.sha256_file(HELPER),
        "helper_copy_sha256"=>C.sha256_file(joinpath(OUT,"gpi2_closed_loop_helpers.jl")),
        "helper_change"=>"Only final GPIClosedLoopValidation.main() invocation removed; helper definitions unchanged",
        "julia_version"=>string(VERSION),"frames_requested"=>frames,"series"=>Dict{String,Any}(),
        "observation_cadence"=>"first32 frames, then every64 model frames; per-frame clip counts accumulated in512-frame windows",
        "runtime_bound_after_preparation_s"=>480,
        "driver_sha256"=>C.sha256_file(@__FILE__),"cuda_package_version"=>string(Base.pkgversion(V.CUDA_MODULE)))
    path=joinpath(OUT,"replay-feedback-projected-result.json")
    checkpoint()=C.write_json(path,report)
    checkpoint()
    try
        original=read(HELPER,String)
        @assert original==read(joinpath(OUT,"gpi2_closed_loop_helpers.jl"),String)*"GPIClosedLoopValidation.main()\n"
        calibration=joinpath(APP,"calibration")
        receipt=C.read_yaml(joinpath(calibration,"result.yaml"))
        report["authored_source_graph_sha256"]=C.sha256_file(joinpath(SOURCE,receipt["recipe"]["graph"]))
        report["original_calibration_authored_graph_sha256"]=receipt["source_graph_sha256"]
        report["authored_graph_hash_difference"]="Frozen source includes later controlled-shape nodes; science equivalence checked structurally against calibrated graph using actual RTC graph"
        @assert C.sha256_file(joinpath(calibration,"graph.conf"))==receipt["graph_sha256"]
        for (filename,expected) in receipt["artifact_sha256"]
            @assert C.sha256_file(joinpath(calibration,"artifacts",filename))==expected filename
        end
        report["calibration_receipt_sha256"]=C.sha256_file(joinpath(calibration,"result.yaml"))
        report["source_prescription_identity"]=receipt["source_prescription_identity"]
        report["staged_prescription_identity"]=receipt["staged_prescription_identity"]
        p=V.plant(SOURCE,receipt,V.B.AcceleratorComputeDevice(V.B.CUDABackend(),0);calibration=false)
        staged=V.IC.load_simulation(joinpath(APP,"simulation/definition.yaml"))
        stagedsettings=V.IC.settings(staged,Dict())
        @assert V.IC.prescription_identity(staged,stagedsettings)==receipt["staged_prescription_identity"]
        @assert V.IC.graph_document(staged,stagedsettings)==V.IC.graph_document(p.declaration,p.settings)
        report["resolved_production_graphs_equal"]=true
        report["settings"]=p.settings
        checkpoint()
        control=actual_controller(calibration,receipt,report)
        report["controller_props"]=control.props
        @assert report["controller_props"]==baseline["controller_props"]
        @assert report["actual_controller_graph_sha256"]==baseline["actual_controller_graph_sha256"]
        @assert report["calibration_receipt_sha256"]==baseline["calibration_receipt_sha256"]
        V.progress("prepare test-only retained-feedback projector")
        R32=control.parameters[:reconstructor]
        J32=V.artifact(calibration,receipt,"interaction-matrix",Float32,reverse(size(R32)))
        retained64=Float64.(R32)*Float64.(J32)
        retained32=Float32.(retained64)
        widened32=Float64.(retained32)
        rms=Float64.(receipt["mode_rms"])
        weighted32=rms.*widened32./transpose(rms)
        report["projector"]=Dict("formula"=>"P64=Float64(R)*Float64(J); P32=Float32.(P64); R=W*(J*W)^+, W=diag(1/mode_rms)",
            "interpretation"=>"Oblique in raw coordinates; diag(mode_rms)*P*diag(1/mode_rms) is the TSVD retained orthogonal projector up to stored Float32 calibration errors",
            "P64_relative_idempotence_error"=>norm(retained64*retained64-retained64)/norm(retained64),
            "P32_widened_relative_idempotence_error"=>norm(widened32*widened32-widened32)/norm(widened32),
            "P32_weighted_relative_symmetry_error"=>norm(weighted32-weighted32')/norm(weighted32),
            "P32_relative_quantization_error"=>norm(widened32-retained64)/norm(retained64),
            "P32_raw_bytes_sha256"=>bytes2hex(sha256(reinterpret(UInt8,vec(retained32)))))
        serialize(joinpath(OUT,"feedback-retained-projector-f32.jls"),retained32)
        fb_scratch=zeros(Float32,size(retained32,1))
        pms=control.parameters
        wfwd=Float64.(pms[Symbol("woofer-vdm-to-pdm")])*Float64.(pms[Symbol("woofer-active-to-full")])
        wsolve=lu(wfwd)
        tback=Float64.(pms[Symbol("tweeter-full-to-active")])*Float64.(pms[Symbol("tweeter-pdm-to-vdm")])
        ew=Float64.(pms[Symbol("woofer-vdm-to-controller")]);et=Float64.(pms[Symbol("tweeter-vdm-to-controller")])
        sw=Float64.(pms[Symbol("woofer-selection")]);st=Float64.(pms[Symbol("tweeter-selection")])
        fstage=Float64.(pms[Symbol("tiptilt-to-woofer")])
        tselect=Float64.(pms[Symbol("controller-to-tiptilt")])
        tfwd=Float64.(pms[Symbol("tweeter-vdm-to-pdm")])*Float64.(pms[Symbol("tweeter-active-to-full")])
        c_saved=Vector{Float64}[];b_saved=Vector{Float32}[];sent_saved=Vector{Float32}[]
        reconstruction_errors=Float64[]
        command=V.commands(p.system)
        V.reset!(p,control,command)
        V.progress("actual controller and plant reset; build observation projection")
        opt=deserialize(joinpath(OUT,"optical-maps.jls"))
        B=hcat(ones(length(p.valid)),Float64.(reshape(p.xy,:,2)[p.valid,:])); Q=pinv(B)
        series=report["series"]
        for name in ("stage_tip_nm","stage_tilt_nm","woofer_tip_nm","woofer_tilt_nm","tweeter_tip_nm","tweeter_tilt_nm",
                "atmosphere_tip_nm","atmosphere_tilt_nm","residual_tip_nm","residual_tilt_nm","atmosphere_rms_nm","residual_rms_nm",
                "woofer_clipped_count","tweeter_clipped_count","woofer_requested_peak_nm","tweeter_requested_peak_nm",
                "Nc_raw_coordinate_norm_nm","Nc_column_RMS_scaled_coordinate_norm_nm","Nb_raw_coordinate_norm_nm","Nb_sent_raw_coordinate_norm_nm",
                "Nc_stage_tip_nm","Nc_stage_tilt_nm","Nc_woofer_tip_nm","Nc_woofer_tilt_nm","Nc_tweeter_tip_nm","Nc_tweeter_tilt_nm","Nc_total_tip_nm","Nc_total_tilt_nm")
            series[name]=Float64[]
        end
        started=time_ns()
        samples=Int[];closure=Float64[];clipwindows=Dict{String,Any}[]
        cliptotal=Dict(name=>0 for name in ("woofer","tweeter"))
        clipmax=Dict(name=>0 for name in ("woofer","tweeter"))
        report["sampled_frames"]=samples;report["clip_windows"]=clipwindows
        checkpoint();V.progress("begin test-only feedback-projected CUDA closed loop")
        for frame in 1:frames
            observe=frame<=32 || frame%64==0
            previous=zeros(2)
            if observe
                previous .+= Float64.(Array(command.tiptilt))
                for name in ("woofer","tweeter")
                    previous .+= (opt.maps[name]*Float64.(Array(getproperty(command,Symbol(name)))))[2:3]
                end
            end
            V.full_step!(p.system,control,command)
            # This is the sole A/B intervention: replace only feedback delivered
            # to the NEXT step, leaving outputs and controller history untouched.
            mul!(fb_scratch,retained32,control.inputs.var"constraint-feedback")
            copyto!(control.inputs.var"constraint-feedback",fb_scratch)
            for name in ("woofer","tweeter")
                clips=count(!iszero,getproperty(control.outputs,Symbol(name*"-constraint-feedback")))
                cliptotal[name]+=clips;clipmax[name]=max(clipmax[name],clips)
            end
            if observe
            push!(samples,frame)
            stage=Array(command.tiptilt)
            push!(series["stage_tip_nm"],1e9*stage[1]);push!(series["stage_tilt_nm"],1e9*stage[2])
            requests=Dict{String,Vector{Float64}}()
            for name in ("woofer","tweeter")
                d=Array(getproperty(command,Symbol(name)));f=getproperty(control.outputs,Symbol(name*"-constraint-feedback"))
                coeff=opt.maps[name]*Float64.(d)
                push!(series[name*"_tip_nm"],coeff[2]*1e9);push!(series[name*"_tilt_nm"],coeff[3]*1e9)
                push!(series[name*"_clipped_count"],count(!iszero,f))
                push!(series[name*"_requested_peak_nm"],1e9*maximum(abs,d+f))
                requests[name]=Float64.(d+f)
            end
            c=ew*(wsolve\(requests["woofer"]+fstage*Float64.(stage)))+et*(tback*requests["tweeter"])
            braw=copy(control.outputs.var"controller-constraint-feedback")
            bsent=copy(control.inputs.var"constraint-feedback")
            nc=c-retained64*c;nb=Float64.(braw)-retained64*Float64.(braw)
            nbsent=Float64.(bsent)-retained64*Float64.(bsent)
            push!(c_saved,c);push!(b_saved,braw);push!(sent_saved,bsent)
            push!(series["Nc_raw_coordinate_norm_nm"],norm(nc)*1e9)
            push!(series["Nc_column_RMS_scaled_coordinate_norm_nm"],norm(rms.*nc)*1e9)
            push!(series["Nb_raw_coordinate_norm_nm"],norm(nb)*1e9)
            push!(series["Nb_sent_raw_coordinate_norm_nm"],norm(nbsent)*1e9)
            nstage=tselect*nc
            nw=opt.maps["woofer"][2:3,:]*(wfwd*(sw*nc)-fstage*nstage)
            nt=opt.maps["tweeter"][2:3,:]*(tfwd*(st*nc))
            for (name,v) in (("stage",nstage),("woofer",nw),("tweeter",nt),("total",nstage+nw+nt))
                push!(series["Nc_"*name*"_tip_nm"],v[1]*1e9);push!(series["Nc_"*name*"_tilt_nm"],v[2]*1e9)
            end
            cw=sw*c;ct=st*c
            push!(reconstruction_errors,max(maximum(abs,wfwd*cw-fstage*Float64.(stage)-requests["woofer"]),
                maximum(abs,tfwd*ct-requests["tweeter"]),maximum(abs,clamp.(tselect*c,-Float64(Float32(1e-6)),Float64(Float32(1e-6)))-Float64.(stage)))*1e9)
            for name in ("atmosphere","residual")
                field=V.AG.graph_output(p.system.graph,name=="atmosphere" ? :atmosphere_opd : :pupil_opd)
                vals=Float64.(vec(Array(field))[p.valid]);coeff=Q*vals
                push!(series[name*"_tip_nm"],coeff[2]*1e9);push!(series[name*"_tilt_nm"],coeff[3]*1e9)
                push!(series[name*"_rms_nm"],sqrt(mean(abs2,vals.-mean(vals)))*1e9)
            end
            actual=[last(series["residual_tip_nm"])-last(series["atmosphere_tip_nm"]),last(series["residual_tilt_nm"])-last(series["atmosphere_tilt_nm"])]
            push!(closure,maximum(abs,actual-previous*1e9))
            end
            if frame%512==0
                report["frames_completed"]=frame;report["elapsed_s"]=(time_ns()-started)/1e9
                push!(clipwindows,Dict("start_frame"=>frame-511,"end_frame"=>frame,
                    "mean_clipped_count"=>Dict(name=>cliptotal[name]/512 for name in ("woofer","tweeter")),
                    "max_clipped_count"=>copy(clipmax)))
                for name in ("woofer","tweeter");cliptotal[name]=0;clipmax[name]=0;end
                report["maximum_optical_tt_closure_error_nm"]=maximum(closure)
                report["maximum_correction_reconstruction_roundtrip_error_nm"]=maximum(reconstruction_errors)
                serialize(joinpath(OUT,"replay-feedback-projected-full-samples.jls"),(frames=copy(samples),c=copy(c_saved),b_raw=copy(b_saved),b_sent=copy(sent_saved)))
                checkpoint();V.progress("diagnostic frame=$frame residual_nm=$(last(series["residual_rms_nm"])) elapsed_s=$(report["elapsed_s"])")
                report["elapsed_s"]>480 && frame<frames && error("8 minute diagnostic runtime bound reached after $frame of $frames frames; retained partial evidence")
            end
        end
        report["model_period_s"]=p.system.frame_period_s
        report["series_alignment"]="Atmosphere and residual fields at frame n use preceding command n-1; command series store newly produced controller output n"
        report["windows"]=Dict(string(a)*"-"*string(b)=>begin
            selected=findall(x->a<=x<=b,samples)
            Dict(k=>Dict("mean"=>mean(v[selected]),"min"=>minimum(v[selected]),"max"=>maximum(v[selected])) for (k,v) in series)
        end for(a,b) in ((1,32),(33,512),(513,2048),(2049,8192),(8193,16384)))
        matching=Dict(f=>i for(i,f) in enumerate(baseline["sampled_frames"]))
        report["baseline_atmosphere_match"]=Dict(key=>begin
            observed=series[key]
            reference=[baseline["series"][key][matching[f]] for f in samples]
            Dict("all_float64_values_bit_identical"=>all(isequal.(observed,reference)),
                "maximum_absolute_error_nm"=>maximum(abs,observed-reference),
                "maximum_relative_error_to_baseline_peak"=>maximum(abs,observed-reference)/maximum(abs,reference))
        end for key in ("atmosphere_rms_nm","atmosphere_tip_nm","atmosphere_tilt_nm"))
        @assert C.sha256_file(baseline_path)==report["baseline_sha256"]
        report["gpu_modules_loaded"]=any(id->id.name in ("CUDA","AMDGPU","GPUCompiler"),keys(Base.loaded_modules))
        @assert report["gpu_modules_loaded"]
        report["completed"]=true
    catch err
        report["failure"]=sprint(showerror,err,catch_backtrace());rethrow()
    finally
        checkpoint()
    end
end
main()
