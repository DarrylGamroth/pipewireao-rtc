using PipeWireAORTC, AdaptiveOpticsSim, AdaptiveOpticsSimPipeWireHIL
using AdaptiveOpticsSim.AlgorithmGraphs
using LinearAlgebra, SHA, Libdl
const C = PipeWireAORTC.Common
const O = Base.get_extension(PipeWireAORTC, :PipeWireAORTCAOSExt).OpticalObservation
const root = @__DIR__
const app = joinpath(root, "cpu-application")
const output = joinpath(root, "independent-observation-invariance")
mkpath(output)
BLAS.set_num_threads(1)
AdaptiveOpticsSim.Backends.set_fft_provider_threads!(1)
base = PipeWireAORTC.AOSOwner.configuration(joinpath(app, "simulation.conf"))
@assert base.backend === :cpu
instrument = PipeWireAORTC.AOSOwner.load_instrument(base.plant.package)
options = merge(base, (; plant_module=instrument, remote="/tmp/unused-independent-invariance", control_node="simulator-wfs"))
science = PipeWireAORTC.AOSOwner.prepare_science(options)
# Prepare analysis once before either comparison arm. This avoids changing the
# prepared science owner or its plans between the analysis-off/on passes.
observation = O.prepare(science.definition, science.graph)
const commanded = reshape(reinterpret(Float32, read(joinpath(root,"managed","generation-1","demanded.bin"))),277,32) .* 1f-6
const native = reshape(reinterpret(UInt16,read(joinpath(root,"managed","generation-1","detector.bin"))),352^2,32)
array_hash(values) = bytes2hex(sha256(reinterpret(UInt8,vec(values))))
function replay(science, observation, enabled)
    outputs = Dict(string(n)=>String[] for n in (:atmosphere_opd,:pupil_opd,:shwfs_photon_rate,:shwfs_frame))
    source_unchanged = true
    native_difference_count = 0
    for frame in 1:32
        stamp = step_hil_frame_at!(science.boundary, science.driver)
        for name in keys(outputs)
            push!(outputs[name],array_hash(graph_output(science.graph,Symbol(name))))
        end
        pixels = round.(UInt16,hil_frame_buffer(science.boundary))
        native_difference_count += count(pixels .!= permutedims(reshape(native[:,frame],352,352)))
        if enabled
            @assert O.submit!(observation;generation=UInt64(1),pts=Int64(frame))
            @assert O.poll!(observation)
            try
                O.form_products!(observation)
                for name in keys(outputs)
                    source_unchanged &= last(outputs[name]) == array_hash(graph_output(science.graph,Symbol(name)))
                end
            finally
                O.release!(observation)
            end
        end
        copyto!(hil_command_buffer(science.boundary),@view commanded[:,frame])
        adopt_hil_command!(science.boundary,stamp.sequence)
    end
    Dict("analysis_enabled"=>enabled,"per_frame_sha256"=>outputs,
        "source_unchanged_by_analysis"=>source_unchanged,"native_differing_pixels"=>native_difference_count)
end
println("Analysis-off replay"); flush(stdout)
without = replay(science,observation,false)
reset_hil_boundary!(science.boundary,science.driver)
println("Analysis-on replay"); flush(stdout)
with = try replay(science,observation,true) finally O.close!(observation) end
report = Dict("without_analysis"=>without,"with_analysis"=>with,
    "all_science_outputs_exactly_equal"=>without["per_frame_sha256"]==with["per_frame_sha256"],
    "julia_version"=>string(VERSION),"julia_threads"=>Threads.nthreads(),"blas_threads"=>BLAS.get_num_threads(),
    "fft_threads_requested"=>1,"manifest_sha256"=>C.sha256_file(joinpath(app,"Manifest.toml")),
    "scope"=>"One fixed prepared CPU science owner, same32 captured commands, public reset; synchronous optional cohort/product formation each frame. No native transport or concurrent worker in this experiment.",
    "gpu_modules"=>[id.name for id in keys(Base.loaded_modules) if id.name in ("CUDA","AMDGPU","GPUCompiler")],
    "gpu_libraries"=>filter(p->occursin(r"(?i)(libcuda|libcudart|libcublas|libcufft|libamdhip|libhsa-runtime)",p),Libdl.dllist()))
C.write_json(joinpath(output,"result.json"),report)
@assert report["all_science_outputs_exactly_equal"]
@assert with["source_unchanged_by_analysis"]
println("PASS exact atmosphere, pupil, photon rate and detector equality across32 frames")
