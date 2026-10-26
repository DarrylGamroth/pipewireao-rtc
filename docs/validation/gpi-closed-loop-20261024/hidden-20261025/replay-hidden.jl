include("/home/dgamroth/.cache/pipewireao/gpi2-tiptilt-20261025/gpi2_closed_loop_helpers.jl")
using LinearAlgebra, Statistics, Serialization, SHA, Random
const V=GPIClosedLoopValidation
const C=V.C
const OUT=@__DIR__
const APP="/home/dgamroth/.local/state/pipewireao/gpi2-registered-live-20261025/application"
include("resource-path-resolver.jl")
const SOURCE="/home/dgamroth/.cache/pipewireao/gpi2-validation-20261025/instrument-source-v8/gpi2"
function controller(cal,receipt,basis,gain; hidden=true)
 concrete=V.PipeWireAORTC.DeploymentConfiguration.decode(joinpath(APP,"rtc/graph.conf"),"/opt/pipewireao")
 g=concrete["filter.graph"]; node=only(n for n in g["nodes"] if n["name"]=="closed-loop-correction")
 @assert node["label"]=="closed-loop-integrator-f32"
 @assert node["props"]==Dict("gain"=>-0.3,"hidden-mode-gain"=>0,"pole"=>1,"anti-windup-gain"=>1)
 if hidden
  node["label"]="closed-loop-correction-f32";node["config"]["hidden_mode_count"]=64;node["props"]["hidden-mode-gain"]=gain
  append!(g["inputs"],[Dict("name"=>name,"endpoint"=>"closed-loop-correction:"*name) for name in ("shape-to-hidden","hidden-to-shape")])
 end
 append!(g["outputs"],[Dict("name"=>"observed-correction","endpoint"=>"closed-loop-correction:correction"),Dict("name"=>"observed-state","endpoint"=>"closed-loop-correction:controller-state"),Dict("name"=>"observed-error","endpoint"=>"modal-filter:output")])
 configpath=joinpath(OUT,hidden ? "hidden-gain-$(gain).conf" : "baseline-observed.conf")
 V.PipeWireAORTC.ScienceExport.write_spa_config(configpath,concrete;header="Private hidden-mode candidate experiment only")
 graph=V.JuliaFilterGraph.prepare_graph(configpath;algorithms=V.FilterGraphAlgorithms.algorithms())
 parameters=Dict(name=>begin
  text=String(name)
  if text=="shape-to-hidden";basis.H
  elseif text=="hidden-to-shape";basis.B
  elseif endswith(text,"-shape-offset");zeros(format.element_type,format.shape)
  else
   asset=replace(text,"-shape-active-to-full"=>"-active-to-full","-shape-pdm-to-vdm"=>"-pdm-to-vdm")
   V.artifact(cal,receipt,asset,format.element_type,format.shape)
  end
 end for(name,format) in pairs(V.JuliaFilterGraph.parameter_formats(graph)))
 V.JuliaFilterGraph.replace_parameters!(graph,pairs(parameters)...)
 inputs=map(f->zeros(f.element_type,f.shape),V.JuliaFilterGraph.input_formats(graph))
 outputs=map(f->zeros(f.element_type,f.shape),V.JuliaFilterGraph.output_formats(graph))
 return (;graph,parameters,inputs,outputs,props=deepcopy(node["props"]))
end
function exact_control_test!(baseline,zero)
 rng=MersenneTwister(20261025)
 for frame in 1:32
  raw=rand(rng,UInt16,size(baseline.inputs.raw))
  V.process!(baseline,raw);V.process!(zero,raw)
  @assert all(name->isequal(getproperty(baseline.outputs,name),getproperty(zero.outputs,name)),keys(baseline.outputs)) "zero hidden gain mismatches baseline graph at frame$frame"
  for control in (baseline,zero)
   copyto!(control.inputs.var"constraint-feedback",control.outputs.var"controller-constraint-feedback")
  end
 end
 V.JuliaFilterGraph.reset!(baseline.graph);V.JuliaFilterGraph.reset!(zero.graph)
 fill!(baseline.inputs.var"constraint-feedback",0f0);fill!(zero.inputs.var"constraint-feedback",0f0)
 return Dict("passed"=>true,"frames"=>32,"comparison"=>"All graph outputs including correction, feedback-corrected state, residual error, requested commands and constraint feedback are Float32 bit-identical for the same deterministic UInt16 inputs; original integrator versus actual JFG ClosedLoopCorrectionF32 with same gain/pole/antiwindup and hidden gain0")
end
function run!(p,control,basis,gain,frames,report,checkpoint; baseline=nothing,label=string(gain))
 command=V.commands(p.system);V.reset!(p,control,command)
 if baseline!==nothing
  V.JuliaFilterGraph.reset!(baseline.graph);fill!(baseline.inputs.var"constraint-feedback",0f0)
 end
 data=Dict{String,Any}("completed"=>false,"gain"=>gain,"controller_props"=>control.props,"sampled_frames"=>Int[],"series"=>Dict{String,Any}(),"clip_windows"=>Any[],"atmosphere_field_sha256"=>String[],"maximum_state_recurrence_error_nm"=>0.0,"maximum_output_recurrence_error_nm"=>0.0,"maximum_zero_gain_output_difference"=>0.0)
 report["cases"][label]=data
 series=data["series"]
 for name in ("atmosphere_rms_nm","residual_rms_nm","woofer_requested_peak_nm","tweeter_requested_peak_nm","woofer_clipped_count","tweeter_clipped_count","hidden_realized_raw_coordinate_norm_nm","hidden_state_raw_coordinate_norm_nm","hidden_correction_raw_coordinate_norm_nm","hidden_realized_column_RMS_scaled_coordinate_norm_nm")
  series[name]=Float64[]
 end
 H=basis.H;B=basis.B;h=zeros(Float32,64);nh=zeros(Float32,1509);prev=zeros(Float32,1509);fb=similar(prev);realized=similar(prev);expected=similar(prev)
 cliptotal=Dict(name=>0 for name in ("woofer","tweeter"));clipmax=copy(cliptotal)
 started=time_ns();V.progress("begin hidden replay gain=$gain frames=$frames")
 for frame in 1:frames
  copyto!(prev,control.outputs.var"observed-correction");copyto!(fb,control.inputs.var"constraint-feedback")
  raw=V.frame!(p.system,command);V.process!(control,raw)
  if baseline!==nothing
   V.process!(baseline,raw)
   @assert all(name->isequal(getproperty(baseline.outputs,name),getproperty(control.outputs,name)),keys(baseline.outputs)) "zero hidden gain science mismatch frame$frame"
   copyto!(baseline.inputs.var"constraint-feedback",baseline.outputs.var"controller-constraint-feedback")
  end
  for name in keys(command);copyto!(getproperty(command,name),getproperty(control.outputs,name));end
  copyto!(control.inputs.var"constraint-feedback",control.outputs.var"controller-constraint-feedback")
  if frame==1
   fill!(expected,0f0);fill!(realized,0f0);fill!(nh,0f0)
  else
   realized .= prev .- fb;mul!(h,H,realized);mul!(nh,B,h)
   expected .= realized .- Float32(gain).*nh
  end
  state=control.outputs.var"observed-state";correction=control.outputs.var"observed-correction";err=control.outputs.var"observed-error"
  data["maximum_state_recurrence_error_nm"]=max(data["maximum_state_recurrence_error_nm"],1e9*maximum(abs,Float64.(state)-Float64.(expected)))
  expected .= state .+ (-0.3f0).*err
  data["maximum_output_recurrence_error_nm"]=max(data["maximum_output_recurrence_error_nm"],1e9*maximum(abs,Float64.(correction)-Float64.(expected)))
  for name in ("woofer","tweeter")
   clips=count(!iszero,getproperty(control.outputs,Symbol(name*"-constraint-feedback")))
   cliptotal[name]+=clips;clipmax[name]=max(clipmax[name],clips)
  end
  if frame<=32 || frame%64==0
   push!(data["sampled_frames"],frame)
   for (name,fieldname) in (("atmosphere",:atmosphere_opd),("residual",:pupil_opd))
    field=Array(V.AG.graph_output(p.system.graph,fieldname))
    push!(series[name*"_rms_nm"],V.pupil_rms(field,p.valid)*1e9)
    name=="atmosphere" && push!(data["atmosphere_field_sha256"],bytes2hex(sha256(reinterpret(UInt8,vec(field)))))
   end
   for name in ("woofer","tweeter")
    d=Array(getproperty(command,Symbol(name)));feedback=getproperty(control.outputs,Symbol(name*"-constraint-feedback"))
    push!(series[name*"_requested_peak_nm"],1e9*maximum(abs,d+feedback));push!(series[name*"_clipped_count"],count(!iszero,feedback))
   end
   push!(series["hidden_realized_raw_coordinate_norm_nm"],1e9*norm(Float64.(nh)))
   push!(series["hidden_realized_column_RMS_scaled_coordinate_norm_nm"],1e9*norm(basis.rms.*Float64.(nh)))
   push!(series["hidden_state_raw_coordinate_norm_nm"],1e9*norm(Float64.(B)*(Float64.(H)*Float64.(state))))
   push!(series["hidden_correction_raw_coordinate_norm_nm"],1e9*norm(Float64.(B)*(Float64.(H)*Float64.(correction))))
  end
  if frame%512==0
   data["frames_completed"]=frame;data["elapsed_s"]=(time_ns()-started)/1e9
   push!(data["clip_windows"],Dict("start_frame"=>frame-511,"end_frame"=>frame,"mean_clipped_count"=>Dict(name=>cliptotal[name]/512 for name in ("woofer","tweeter")),"max_clipped_count"=>copy(clipmax)))
   for name in ("woofer","tweeter");cliptotal[name]=0;clipmax[name]=0;end
   checkpoint();V.progress("gain=$gain frame=$frame residual_nm=$(last(series["residual_rms_nm"])) elapsed=$(data["elapsed_s"])")
   data["elapsed_s"]>240 && frame<frames && error("4 minute per-case runtime bound")
  end
 end
 @assert data["maximum_state_recurrence_error_nm"]<0.01
 @assert data["maximum_output_recurrence_error_nm"]<0.01
 for (a,b) in ((513,2048),(2049,4096))
  selected=findall(x->a<=x<=b,data["sampled_frames"])
  isempty(selected) && continue
  get!(data,"windows",Dict())["$a-$b"]=Dict(k=>Dict("mean"=>mean(v[selected]),"max"=>maximum(v[selected])) for (k,v) in series)
 end
 data["completed"]=true;checkpoint();return data
end
function main()
 BLAS.set_num_threads(1);V.B.set_fft_provider_threads!(1)
 basis=deserialize(joinpath(OUT,"hidden-basis.jls"));cal=joinpath(APP,"calibration");receipt=C.read_yaml(joinpath(cal,"result.yaml"))
 report=Dict{String,Any}("completed"=>false,"cases"=>Dict{String,Any}(),"scope"=>"Private arrays only; actual registered plant/controller artifacts; replace only integrator node with genuine JFG ClosedLoopCorrectionF32 and weighted discarded64 projection ports; no native core or live changes","driver_sha256"=>C.sha256_file(@__FILE__),"basis_sha256"=>C.sha256_file(joinpath(OUT,"hidden-basis.jls")),"julia_version"=>string(VERSION),"original_graph_sha256"=>C.sha256_file(joinpath(APP,"rtc/graph.conf")),"receipt_sha256"=>C.sha256_file(joinpath(cal,"result.yaml")),"frame_count"=>4096,"model_period_s"=>0.0005,"recurrence"=>"realized_n=c_(n-1)-b_(n-1); s_n=realized_n-hidden_gain*B*H*realized_n; c_n=s_n-0.3e_n. Initial s1=0. H*B≈I. Coordinate norms are not physical optical RMS.")
 path=joinpath(OUT,"replay-hidden-result.json");checkpoint()=C.write_json(path,report);checkpoint()
 try
  report["resource_path_workaround"]=RESOURCE_PATCH
  declaration=V.IC.load_simulation(joinpath(SOURCE,receipt["recipe"]["simulation"]))
  settings=V.IC.settings(declaration,get(receipt["recipe"],"settings",Dict()))
  @assert V.IC.prescription_identity(declaration,settings)==receipt["source_prescription_identity"]
  report["resource_preflight_passed"]=true;checkpoint()
  baseline=controller(cal,receipt,basis,0;hidden=false)
  zero=controller(cal,receipt,basis,0.0)
  report["zero_gain_unit_test"]=exact_control_test!(baseline,zero);checkpoint()
  if "static-only" in ARGS;report["completed"]=true;return;end
  @assert V.CUDA_MODULE!==nothing;V.CUDA_MODULE.allowscalar(false)
  V.progress("zero-gain graph equivalence passed; prepare single CUDA plant")
  p=V.plant(SOURCE,receipt,V.B.AcceleratorComputeDevice(V.B.CUDABackend(),0);calibration=false)
  report["settings"]=p.settings;report["cuda_version"]=string(Base.pkgversion(V.CUDA_MODULE));checkpoint()
  ref=run!(p,zero,basis,0.0,4096,report,checkpoint;baseline,label="0.0")
  for gain in (0.1,1.0)
   candidate=controller(cal,receipt,basis,gain)
   data=run!(p,candidate,basis,gain,4096,report,checkpoint)
   @assert data["atmosphere_field_sha256"]==ref["atmosphere_field_sha256"] "Atmosphere reset differs"
   data["matched_atmosphere_full_field_hashes"]=true
   reference=ref["windows"]["2049-4096"]["residual_rms_nm"]["mean"]
   value=data["windows"]["2049-4096"]["residual_rms_nm"]["mean"]
   data["postsettling_mean_residual_ratio"]=value/reference;checkpoint()
  end
  ratios=[(data["postsettling_mean_residual_ratio"],parse(Float64,label)) for (label,data) in report["cases"] if label!="0.0"]
  ratio,bestgain=minimum(ratios)
  if ratio<0.98
   report["extension_policy"]="Best candidate improves matched2049-4096 mean WFE by at least2%; extend only that candidate to16384 from reset with unchanged parameters"
   best=controller(cal,receipt,basis,bestgain)
   run!(p,best,basis,bestgain,16384,report,checkpoint;label="extended-$(bestgain)")
  else
   report["extension_policy"]="No candidate improves matched2049-4096 mean WFE by at least2%; no long extension"
  end
  report["completed"]=true
 catch err
  report["error"]=sprint(showerror,err,catch_backtrace());rethrow()
 finally
  checkpoint()
 end
end
const RESOURCE_PATCH=install_resource_paths!()
main()
