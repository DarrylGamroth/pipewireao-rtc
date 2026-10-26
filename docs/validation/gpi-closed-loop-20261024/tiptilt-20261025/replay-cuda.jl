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
    frames=65536
    report=Dict{String,Any}("completed"=>false,"scope"=>"CUDA private-array from-reset production replay; no native session, no settings changes or physical validation",
        "source"=>SOURCE,"application"=>APP,"helper_source"=>HELPER,"helper_source_sha256"=>C.sha256_file(HELPER),
        "helper_copy_sha256"=>C.sha256_file(joinpath(OUT,"gpi2_closed_loop_helpers.jl")),
        "helper_change"=>"Only final GPIClosedLoopValidation.main() invocation removed; helper definitions unchanged",
        "julia_version"=>string(VERSION),"frames_requested"=>frames,"series"=>Dict{String,Any}(),
        "observation_cadence"=>"first32 frames, then every64 model frames; per-frame clip counts accumulated in512-frame windows",
        "runtime_bound_after_preparation_s"=>720,
        "driver_sha256"=>C.sha256_file(@__FILE__),"cuda_package_version"=>string(Base.pkgversion(V.CUDA_MODULE)))
    path=joinpath(OUT,"replay-cuda-result.json")
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
        command=V.commands(p.system)
        V.reset!(p,control,command)
        V.progress("actual controller and plant reset; build observation projection")
        opt=deserialize(joinpath(OUT,"optical-maps.jls"))
        B=hcat(ones(length(p.valid)),Float64.(reshape(p.xy,:,2)[p.valid,:])); Q=pinv(B)
        series=report["series"]
        for name in ("stage_tip_nm","stage_tilt_nm","woofer_tip_nm","woofer_tilt_nm","tweeter_tip_nm","tweeter_tilt_nm",
                "atmosphere_tip_nm","atmosphere_tilt_nm","residual_tip_nm","residual_tilt_nm","atmosphere_rms_nm","residual_rms_nm",
                "woofer_clipped_count","tweeter_clipped_count","woofer_requested_peak_nm","tweeter_requested_peak_nm")
            series[name]=Float64[]
        end
        started=time_ns()
        samples=Int[];closure=Float64[];clipwindows=Dict{String,Any}[]
        cliptotal=Dict(name=>0 for name in ("woofer","tweeter"))
        clipmax=Dict(name=>0 for name in ("woofer","tweeter"))
        report["sampled_frames"]=samples;report["clip_windows"]=clipwindows
        checkpoint();V.progress("begin CUDA from-reset closed loop")
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
            for name in ("woofer","tweeter")
                clips=count(!iszero,getproperty(control.outputs,Symbol(name*"-constraint-feedback")))
                cliptotal[name]+=clips;clipmax[name]=max(clipmax[name],clips)
            end
            if observe
            push!(samples,frame)
            stage=Array(command.tiptilt)
            push!(series["stage_tip_nm"],1e9*stage[1]);push!(series["stage_tilt_nm"],1e9*stage[2])
            for name in ("woofer","tweeter")
                d=Array(getproperty(command,Symbol(name)));f=getproperty(control.outputs,Symbol(name*"-constraint-feedback"))
                coeff=opt.maps[name]*Float64.(d)
                push!(series[name*"_tip_nm"],coeff[2]*1e9);push!(series[name*"_tilt_nm"],coeff[3]*1e9)
                push!(series[name*"_clipped_count"],count(!iszero,f))
                push!(series[name*"_requested_peak_nm"],1e9*maximum(abs,d+f))
            end
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
                checkpoint();V.progress("diagnostic frame=$frame residual_nm=$(last(series["residual_rms_nm"])) elapsed_s=$(report["elapsed_s"])")
                report["elapsed_s"]>720 && frame<frames && error("12 minute diagnostic runtime bound reached after $frame of $frames frames; retained partial evidence")
            end
        end
        report["model_period_s"]=p.system.frame_period_s
        report["series_alignment"]="Atmosphere and residual fields at frame n use preceding command n-1; command series store newly produced controller output n"
        report["windows"]=Dict(string(a)*"-"*string(b)=>begin
            selected=findall(x->a<=x<=b,samples)
            Dict(k=>Dict("mean"=>mean(v[selected]),"min"=>minimum(v[selected]),"max"=>maximum(v[selected])) for (k,v) in series)
        end for(a,b) in ((1,32),(33,512),(513,2048),(2049,8192),(8193,16384),(16385,32768),(32769,49152),(49153,65536)))
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
