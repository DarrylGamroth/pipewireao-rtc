using PipeWireAORTC,LinearAlgebra,Serialization,SHA
const C=PipeWireAORTC.Common
BLAS.set_num_threads(1)
diagnostic=deserialize(joinpath(@__DIR__,"hidden-basis.jls"))
root="/home/dgamroth/workspaces/codex/worktrees/instruments-gpi2-heart-20261025/gpi2/rtc/heart"
function load(name,shape)
 path=joinpath(root,name*".fits")
 descriptor=PipeWireAORTC.Artifacts.FITSArtifact(path;axes=(2,1))
 return PipeWireAORTC.Artifacts.prepare(descriptor,Float32,shape).data
end
H=load("shape-to-hidden",(64,1509));B=load("hidden-to-shape",(1509,64))
Np=Float64.(B)*Float64.(H);Nd=Float64.(diagnostic.B)*Float64.(diagnostic.H)
rms=diagnostic.rms;wp=rms.*Np./transpose(rms);wd=rms.*Nd./transpose(rms)
report=Dict("production_shape_to_hidden_sha256"=>C.sha256_file(joinpath(root,"shape-to-hidden.fits")),"production_hidden_to_shape_sha256"=>C.sha256_file(joinpath(root,"hidden-to-shape.fits")),"production_receipt_sha256"=>C.sha256_file(joinpath(root,"result.yaml")),"production_receipt"=>C.read_yaml(joinpath(root,"result.yaml")),"diagnostic_basis_sha256"=>C.sha256_file(joinpath(@__DIR__,"hidden-basis.jls")),"raw_projector_relative_difference"=>norm(Np-Nd)/norm(Np),"weighted_projector_relative_difference"=>norm(wp-wd)/norm(wp),"production_inverse_frobenius_error"=>norm(Float64.(H)*Float64.(B)-I),"production_relative_idempotence_error"=>norm(Np*Np-Np)/norm(Np),"production_weighted_relative_symmetry_error"=>norm(wp-wp')/norm(wp),"production_vs_I_RJ_relative_difference"=>norm(Np-diagnostic.N_original)/norm(diagnostic.N_original),"interpretation"=>"Diagnostic recomputes weighted J in Float64. Shared production helper reproduces original Float32 weighting/SVD. Basis vector entries may differ by orientation; compare raw and weighted projectors, not entries. Short diagnostic results qualify only its basis. Any positive extension must use the exact production FITS.")
serialize(joinpath(@__DIR__,"production-hidden-basis.jls"),(H,B,rms,N_original=diagnostic.N_original,retained_rank=1445))
C.write_json(joinpath(@__DIR__,"production-basis-comparison.json"),report)
println("raw projector relative difference=",report["raw_projector_relative_difference"]," weighted=",report["weighted_projector_relative_difference"])
