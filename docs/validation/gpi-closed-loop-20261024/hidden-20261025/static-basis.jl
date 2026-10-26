include("/home/dgamroth/.cache/pipewireao/gpi2-tiptilt-20261025/gpi2_closed_loop_helpers.jl")
using LinearAlgebra, Serialization, SHA, AdaptiveOpticsCalibration
using AdaptiveOpticsCalibration.Reconstructors
const V=GPIClosedLoopValidation
const C=V.C
const OUT=@__DIR__
const APP="/home/dgamroth/.local/state/pipewireao/gpi2-registered-live-20261025/application"
function main()
 BLAS.set_num_threads(1)
 cal=joinpath(APP,"calibration"); receipt=C.read_yaml(joinpath(cal,"result.yaml"))
 report=Dict{String,Any}("completed"=>false,"driver_sha256"=>C.sha256_file(@__FILE__),"julia_version"=>string(VERSION),"environment_manifest_sha256"=>C.sha256_file(joinpath(dirname(Base.active_project()),"Manifest.toml")),"receipt_sha256"=>C.sha256_file(joinpath(cal,"result.yaml")),"loaded_sources"=>Dict(string(m)=>pathof(m) for m in (AdaptiveOpticsCalibration,V.FilterGraphAlgorithms,V.JuliaFilterGraph)))
 C.write_json(joinpath(OUT,"static-basis.json"),report)
 try
  rms=Float64.(receipt["mode_rms"]);n=length(rms); m=11104
  J=Float64.(V.artifact(cal,receipt,"interaction-matrix",Float32,(m,n)))
  R=Float64.(V.artifact(cal,receipt,"reconstructor",Float32,(n,m)))
  Jw=J./transpose(rms)
  V.progress("AOC TSVD recomputation, fixed discarded count64, no reconstructor replacement")
  spec=ReconstructorSpecification(m,n)
  plan=AdaptiveOpticsCalibration.prepare(TSVDInverse(rtol=eps(Float64),n_trunc=64),spec)
  result=AdaptiveOpticsCalibration.allocate_result(plan)
  AdaptiveOpticsCalibration.process!(result,nothing,plan,SVDReconstructorInputs(Jw))
  Vd=copy(corrector_singular_vectors(result)[:,end-63:end]);H=Vd'.*transpose(rms);B=Vd./rms
  N=B*H; originalN=Matrix{Float64}(I,n,n)-R*J
  H32=Float32.(H);B32=Float32.(B);N32=Float64.(B32)*Float64.(H32)
  report["basis"]=Dict("policy"=>"Explicit experimental candidate:64 low singular directions discarded by calibration TSVD; weak nonzero response, not exact optical null modes","formulas"=>"Jw=J*W, W=diag(1/mode_rms); H=Vd'*W^-1, B=W*Vd; N=B*H","rank"=>effective_rank(result),"discarded"=>truncation_count(result),"J_shape"=>size(J),"inverse_error_f64"=>norm(H*B-I),"idempotence_relative_f64"=>norm(N*N-N)/norm(N),"weighted_orthogonality_f64"=>norm(rms.*N./transpose(rms)-(rms.*N./transpose(rms))')/norm(N),"relative_difference_from_I_RJ"=>norm(N-originalN)/norm(originalN),"inverse_error_f32_widened"=>norm(Float64.(H32)*Float64.(B32)-I),"idempotence_relative_f32_widened"=>norm(N32*N32-N32)/norm(N32),"difference_from_I_RJ_f32_widened"=>norm(N32-originalN)/norm(originalN),"weak_singular_values"=>singular_values(result)[end-63:end],"retained_smallest_singular_value"=>singular_values(result)[end-64],"largest_singular_value"=>first(singular_values(result)),"R_recomputed_relative_difference"=>norm(reconstructor(result)./rms-R)/norm(R))
  @assert report["basis"]["rank"]==1445
  @assert report["basis"]["relative_difference_from_I_RJ"]<0.001
  serialize(joinpath(OUT,"hidden-basis.jls"),(H=H32,B=B32,rms,N_original=originalN,retained_rank=1445))
  report["basis_file_sha256"]=C.sha256_file(joinpath(OUT,"hidden-basis.jls"))
  report["completed"]=true
 catch err
  report["error"]=sprint(showerror,err,catch_backtrace());rethrow()
 finally
  C.write_json(joinpath(OUT,"static-basis.json"),report)
 end
end
main()
