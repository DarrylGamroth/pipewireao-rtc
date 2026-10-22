using PipeWireAORTC, AdaptiveOpticsSim, AdaptiveOpticsSimPipeWireHIL
using AdaptiveOpticsSim.AlgorithmGraphs
using LinearAlgebra, SHA, Libdl
const C = PipeWireAORTC.Common
const B = AdaptiveOpticsSim.Backends
const F = AdaptiveOpticsSim.FFTW
const root = @__DIR__
const prior = "/home/dgamroth/workspaces/codex/worktrees/wavefront-series-20261022"
const app = joinpath(prior, "cpu-application")
const label = ARGS[1]
const flags = length(ARGS)>1 ? ARGS[2] : "measure"
const output = joinpath(root,label)
mkpath(output)
BLAS.set_num_threads(1)
B.set_fft_provider_threads!(1)
@assert Threads.nthreads()==1
# Experimental planner control only: do not change any installed package.
if flags!="measure"
    flag = flags=="estimate" ? F.ESTIMATE : flags=="nosimd" ? F.MEASURE|F.NO_SIMD : flags=="reverse" ? F.ESTIMATE : error(flags)
    reverse_dimensions=flags=="reverse"
    @eval B begin
        function plan_repeated_fft_backend!(a::Array{T,N}, dims) where {T<:Union{ComplexF32,ComplexF64},N}
            FFTW.plan_fft!(a,$reverse_dimensions ? reverse(dims) : dims;flags=$flag)
        end
        function plan_repeated_ifft_backend!(a::Array{T,N}, dims) where {T<:Union{ComplexF32,ComplexF64},N}
            FFTW.plan_ifft!(a,$reverse_dimensions ? reverse(dims) : dims;flags=$flag)
        end
        function plan_repeated_bfft_backend!(a::Array{T,N}, dims) where {T<:Union{ComplexF32,ComplexF64},N}
            FFTW.plan_bfft!(a,$reverse_dimensions ? reverse(dims) : dims;flags=$flag)
        end
    end
end
base = PipeWireAORTC.AOSOwner.configuration(joinpath(app,"simulation.conf"))
@assert base.backend===:cpu
instrument=PipeWireAORTC.AOSOwner.load_instrument(base.plant.package)
science=PipeWireAORTC.AOSOwner.prepare_science(merge(base,(;plant_module=instrument,remote="/tmp/unused-probe",control_node="simulator-wfs")))
println("prepared ",label);flush(stdout)
commands=reshape(reinterpret(Float32,read(joinpath(prior,"managed/generation-1/demanded.bin"))),277,32).*1f-6
observed=reshape(reinterpret(UInt16,read(joinpath(prior,"managed/generation-1/detector.bin"))),352^2,32)
function plans(x,path="graph",depth=0)
    depth>12 && return Pair{String,String}[]
    x isa F.FFTWPlan && return [path=>sprint(show,x)]
    x isa Union{AbstractArray,Number,Symbol,String,Function,Module,Type,Nothing} && return Pair{String,String}[]
    out=Pair{String,String}[]
    for field in fieldnames(typeof(x))
        append!(out,plans(getfield(x,field),path*"."*string(field),depth+1))
    end
    out
end
differences=[]
adc=zeros(UInt16,352,352,32)
for n in 1:32
    rng_state=science.graph.nodes.detector.owner.rng.state
    stamp=step_hil_frame_at!(science.boundary,science.driver)
    adc[:,:,n].=round.(UInt16,hil_frame_buffer(science.boundary))
    indices=findall(adc[:,:,n].!=permutedims(reshape(observed[:,n],352,352)))
    isempty(indices)||push!(differences,Dict("sequence"=>n,"pixels"=>[Dict("row"=>i[1],"column"=>i[2],"expected"=>Int(adc[i[1],i[2],n]),"observed"=>Int(observed[(i[1]-1)*352+i[2],n])) for i in indices]))
    if n in (10,14)
        for name in (:atmosphere_opd,:pupil_opd,:shwfs_photon_rate)
            write(joinpath(output,string(name)*(n==10 ? "" : "-frame14")*".f32"),graph_output(science.graph,name))
        end
        C.write_json(joinpath(output,"rng-frame$n.json"),Dict("before"=>string(rng_state),"after"=>string(science.graph.nodes.detector.owner.rng.state)))
    end
    copyto!(hil_command_buffer(science.boundary),view(commands,:,n))
    adopt_hil_command!(science.boundary,stamp.sequence)
end
write(joinpath(output,"adc.u16"),adc)
F.export_wisdom(joinpath(output,"wisdom"))
rates=reshape(reinterpret(Float32,read(joinpath(output,"shwfs_photon_rate.f32"))),352,352)
C.write_json(joinpath(output,"result.json"),Dict("label"=>label,"planner"=>flags,"differences"=>differences,"target_adc"=>adc[276,189,10],"target_photon_rate"=>rates[276,189],"plans"=>Dict(plans(science.graph)),"julia_version"=>string(VERSION),"julia_threads"=>Threads.nthreads(),"blas_threads"=>BLAS.get_num_threads(),"aos_path"=>pathof(AdaptiveOpticsSim),"manifest_sha256"=>C.sha256_file(joinpath(app,"Manifest.toml")),"gpu_libraries"=>filter(p->occursin(r"(?i)(libcuda|libcudart|libcublas|libcufft|libamdhip|libhsa-runtime)",p),Libdl.dllist())))
println(label," target=",adc[276,189,10]," rate=",rates[276,189]," differing frames=",length(differences));flush(stdout)
