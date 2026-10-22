using PipeWireAORTC, AdaptiveOpticsSim, AdaptiveOpticsSimPipeWireHIL
using AdaptiveOpticsSim.AlgorithmGraphs
using LinearAlgebra, Statistics, SHA, Libdl
const C = PipeWireAORTC.Common
const root = @__DIR__
const app = joinpath(root, "cpu-application")
const output = joinpath(root, "independent-oracle-check")
mkpath(output)
BLAS.set_num_threads(1)
AdaptiveOpticsSim.Backends.set_fft_provider_threads!(1)
function prepare()
    base = PipeWireAORTC.AOSOwner.configuration(joinpath(app, "simulation.conf"))
    @assert base.backend === :cpu
    instrument = PipeWireAORTC.AOSOwner.load_instrument(base.plant.package)
    options = merge(base, (; plant_module=instrument, remote="/tmp/unused-independent-oracle", control_node="simulator-wfs"))
    PipeWireAORTC.AOSOwner.prepare_science(options)
end
function raw(name, T, rows, generation)
    reshape(reinterpret(T, read(joinpath(root, "managed", "generation-$generation", name*".bin"))), rows, 32)
end
const demanded = raw("demanded", Float32, 277, 1)
const observed = raw("detector", UInt16, 352^2, 1)
const commands = demanded .* 1f-6
function run(science, label)
    adc = zeros(UInt16, 352, 352, 32)
    selected = Dict{String,Matrix{Float32}}()
    differences = []
    for frame in 1:32
        stamp = step_hil_frame_at!(science.boundary, science.driver)
        adc[:,:,frame] .= round.(UInt16, hil_frame_buffer(science.boundary))
        native = permutedims(reshape(observed[:,frame], 352, 352))
        indices = findall(native .!= adc[:,:,frame])
        isempty(indices) || push!(differences, Dict("sequence"=>frame, "pixels"=>[
            Dict("row"=>i[1], "column"=>i[2], "native"=>Int(native[i]), "oracle"=>Int(adc[i[1],i[2],frame])) for i in indices]))
        if frame == 10
            for name in (:shwfs_photon_rate, :pupil_opd, :atmosphere_opd)
                values = Matrix{Float32}(graph_output(science.graph, name))
                selected[string(name)] = values
                write(joinpath(output, label*"-"*string(name)*"-frame10.f32"), values)
            end
        end
        copyto!(hil_command_buffer(science.boundary), @view commands[:,frame])
        adopt_hil_command!(science.boundary, stamp.sequence)
    end
    write(joinpath(output,label*"-adc.u16"),adc)
    report = Dict("label"=>label, "native_differences"=>differences,
        "adc_sha256"=>bytes2hex(sha256(reinterpret(UInt8,vec(adc)))),
        "frame10_pixel_276_189"=>Int(adc[276,189,10]),
        "frame10_photon_rate_276_189"=>Float64(selected["shwfs_photon_rate"][276,189]))
    C.write_json(joinpath(output,label*".json"),report)
    println(label, " native differing frames=", length(differences), " target ADC=", adc[276,189,10]); flush(stdout)
    (;adc, selected, report)
end
function compare(a,b)
    Dict("adc_differing_pixels"=>count(a.adc .!= b.adc),
        "frame10_arrays"=>Dict(name=>Dict("differing_pixels"=>count(a.selected[name] .!= b.selected[name]),
            "max_absolute_difference"=>maximum(abs, Float64.(a.selected[name]).-Float64.(b.selected[name]))) for name in keys(a.selected)))
end
println("Preparing A"); flush(stdout)
a=prepare(); a1=run(a,"a1"); reset_hil_boundary!(a.boundary,a.driver); a2=run(a,"a2-reset")
println("Preparing B"); flush(stdout)
b=prepare(); b1=run(b,"b1"); reset_hil_boundary!(b.boundary,b.driver); b2=run(b,"b2-reset")
report=Dict("julia_version"=>string(VERSION),"julia_threads"=>Threads.nthreads(),"blas_threads"=>BLAS.get_num_threads(),
    "manifest_sha256"=>C.sha256_file(joinpath(app,"Manifest.toml")),
    "native_detector_generation_equal"=>observed==raw("detector",UInt16,352^2,2),
    "native_commands_generation_equal"=>demanded==raw("demanded",Float32,277,2),
    "a_reset"=>compare(a1,a2),"b_reset"=>compare(b1,b2),"fresh_preparations"=>compare(a1,b1),
    "runs"=>[a1.report,a2.report,b1.report,b2.report],
    "gpu_modules"=>[id.name for id in keys(Base.loaded_modules) if id.name in ("CUDA","AMDGPU","GPUCompiler")],
    "gpu_libraries"=>filter(p->occursin(r"(?i)(libcuda|libcudart|libcublas|libcufft|libamdhip|libhsa-runtime)",p),Libdl.dllist()))
C.write_json(joinpath(output,"result.json"),report)
println("COMPLETE ",joinpath(output,"result.json"))
