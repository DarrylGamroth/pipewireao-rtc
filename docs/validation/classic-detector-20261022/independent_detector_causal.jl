using AdaptiveOpticsSim, PipeWireAORTC, Random, Libdl
const D=AdaptiveOpticsSim.Detectors
const C=PipeWireAORTC.Common
const root=@__DIR__
const pos=CartesianIndex(297,209)
function detector()
    D.Detector(exposure_duration=Float32(0.001896),qe=Float32(0.27),psf_sampling=1,
        binning=1,gain=Float32(15.848931924611133),dark_current=Float32(0.96),bits=12,
        full_well=Float32(94000),output_type=UInt16,noise=D.NoisePhotonReadout{Float32}(Float32(2.33)),
        sensor=D.CMOSSensor(T=Float32),response_model=D.NullFrameResponse(),T=Float32,
        backend=AdaptiveOpticsSim.Backends.CPUBackend())
end
function trial(label; target_rate=nothing, expected_label=label, frame=14, position=pos, compare_retained=true)
    rates=copy(reshape(reinterpret(Float32,read(joinpath(root,label,"shwfs_photon_rate"*(frame==14 ? "-frame14" : "")*".f32"))),352,352))
    target_rate===nothing || (rates[position]=target_rate)
    states=C.read_json(joinpath(root,label,"rng-frame$frame.json"))
    initial=parse(UInt64,states["before"])
    expected_state=parse(UInt64,states["after"])
    rng=AdaptiveOpticsSim.SplitMix64RNG(initial)
    det=detector()
    adc=copy(D.capture!(det,rates,rng))
    expected=reshape(reinterpret(UInt16,read(joinpath(root,expected_label,"adc.u16"))),352,352,32)[:,:,frame]
    compare_retained && @assert adc==expected
    @assert rng.state==expected_state
    # Trace the unchanged scalar sampler on identical expected-electron input.
    det2=detector(); rng2=AdaptiveOpticsSim.SplitMix64RNG(initial)
    D.prepare_signal_frame!(det2,rates,det2.params.exposure_duration,det2.params.qe)
    lambda=copy(det2.products.frame)
    trace=Dict{String,Any}()
    target=LinearIndices(lambda)[position]
    for i in eachindex(lambda)
        if i==target
            draw=randn(copy(rng2))
            value=float(lambda[i])+sqrt(float(lambda[i]))*draw
            trace["rate"]=Float64(rates[i]);trace["lambda"]=Float64(lambda[i]);trace["normal_draw"]=draw
            trace["sampler_argument"]=value;trace["sampler_rng_before"]=string(rng2.state)
        end
        det2.products.frame[i]=AdaptiveOpticsSim.Backends.poisson_sample(rng2,lambda[i])
    end
    trace["photon_electrons"]=det2.products.frame[position]
    photon=copy(det2.products.frame)
    D.finalize_capture!(det2,rng2,det2.params.exposure_duration)
    trace["pre_output_adc"]=Float64(det2.products.frame[position])
    adc2=copy(D.write_output!(det2))
    @assert adc2==adc
    @assert rng2.state==expected_state
    trace["adc"]=adc[position];trace["rng_before"]=string(initial);trace["rng_after"]=string(rng2.state)
    trace["full_frame_matches_retained"]=adc==expected
    return (;trace,photon,adc,lambda,rates)
end
m=trial("measure-c");n=trial("nosimd-b")
@assert m.trace["rng_before"]==n.trace["rng_before"]
@assert m.trace["normal_draw"]==n.trace["normal_draw"]
h=trial("measure-c";target_rate=n.rates[pos],expected_label="nosimd-b")
r=trial("nosimd-b";target_rate=m.rates[pos],expected_label="measure-c")
result=Dict("single_target_rate_swap_reproduces_full_opposite_adc"=>true,
    "inverse_target_rate_swap_restores_full_measure_adc"=>true,"measure"=>m.trace,"nosimd"=>n.trace,
    "rate_differences"=>count(m.rates.!=n.rates),"lambda_differences"=>count(m.lambda.!=n.lambda),
    "photon_differences"=>count(m.photon.!=n.photon),"adc_differences"=>count(m.adc.!=n.adc),
    "gpu_modules"=>[id.name for id in keys(Base.loaded_modules) if id.name in ("CUDA","AMDGPU","GPUCompiler")],
    "gpu_libraries"=>filter(p->occursin(r"(?i)(libcuda|libcudart|libcublas|libcufft|libamdhip|libhsa-runtime)",p),Libdl.dllist()))
C.write_json(joinpath(root,"independent-detector-causal.json"),result)
println(result)

f10=trial("measure-c";frame=10,position=CartesianIndex(276,189))
println("FRAME10: ",f10.trace)
C.write_json(joinpath(root,"independent-detector-frame10.json"),f10.trace)
f10lower=trial("measure-c";frame=10,position=CartesianIndex(276,189),
    target_rate=prevfloat(f10.rates[276,189]),compare_retained=false)
@assert count(f10.adc.!=f10lower.adc)==1
@assert f10lower.adc[276,189]==109
@assert f10.trace["rng_after"]==f10lower.trace["rng_after"]
C.write_json(joinpath(root,"independent-detector-frame10.json"),Dict(
    "baseline"=>f10.trace,"one_ulp_lower_rate"=>f10lower.trace,
    "adc_differences"=>count(f10.adc.!=f10lower.adc),
    "scope"=>"Controlled one-ULP input counterfactual; original failed oracle input was not retained and its root cause is not established"))
println("FRAME10 LOWER: ",f10lower.trace)
