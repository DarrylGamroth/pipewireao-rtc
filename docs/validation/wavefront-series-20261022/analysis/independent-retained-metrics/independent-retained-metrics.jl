using PipeWireAORTC, AdaptiveOpticsSim, AdaptiveOpticsSimPipeWireHIL
using AdaptiveOpticsSim.AlgorithmGraphs
using LinearAlgebra, Statistics, Test, Libdl
include("/home/dgamroth/workspaces/codex/pipewire/pipewireao-rtc-series/test/integration/classic_replay.jl")
const C=PipeWireAORTC.Common
const O=Base.get_extension(PipeWireAORTC,:PipeWireAORTCAOSExt).OpticalObservation
const root=@__DIR__
const app=joinpath(root,"cpu-application")
const stage=joinpath(root,"managed","generation-1")
BLAS.set_num_threads(1)
AdaptiveOpticsSim.Backends.set_fft_provider_threads!(1)
base=PipeWireAORTC.AOSOwner.configuration(joinpath(app,"simulation.conf"))
@assert base.backend===:cpu
instrument=PipeWireAORTC.AOSOwner.load_instrument(base.plant.package)
science=PipeWireAORTC.AOSOwner.prepare_science(merge(base,(;plant_module=instrument,
    remote="/tmp/unused-retained-metrics",control_node="simulator-wfs")))
config=only(filter(!isnothing,map(n->O.sensor_configuration(n.config),science.definition.nodes)))
telescope=AdaptiveOpticsSim.Optics.prepare_telescope(config.telescope,science.target)
pupil=AdaptiveOpticsSim.Optics.pupil_mask(telescope)
raw(name,T,rows)=reshape(reinterpret(T,read(joinpath(stage,name*".bin"))),rows,32)
detector=raw("detector",UInt16,352^2)
commands=raw("demanded",Float32,277).*1f-6
wavefront=raw("wavefront",Float32,480^2)
meter=raw("rms",Float32,2)
prior=C.read_json(joinpath(stage,"wavefront-replay.json"))
wavefront_sequences=Int.(prior["sequences"])
meter_sequences=Int.(prior["rms_sequences"])
pixel_errors=Float64[]; meter_errors=Float64[]; pupil_errors=Float64[]
adc_differences=Int[]
@testset "Independent retained capture" begin
    @test ClassicReplay.replay(app,detector,commands)==commands
    for frame in 1:32
        stamp=step_hil_frame_at!(science.boundary,science.driver)
        native=permutedims(reshape(detector[:,frame],352,352))
        push!(adc_differences,count(native .!= round.(UInt16,hil_frame_buffer(science.boundary))))
        @test last(adc_differences)==0
        residual=Float64.(graph_output(science.graph,:pupil_opd)[pupil])
        if frame in wavefront_sequences
            image=permutedims(reshape(wavefront[:,frame],480,480))
            @test all(isnan,image[.!pupil]) && all(isfinite,image[pupil])
            push!(pixel_errors,maximum(abs,Float64.(image[pupil]).-(residual.-mean(residual)).*1e9))
            @test last(pixel_errors)<=1e-4
            push!(pupil_errors,abs(sqrt(mean(abs2,Float64.(image[pupil])))-std(residual;corrected=false)*1e9))
            @test last(pupil_errors)<=1e-4
        end
        if frame in meter_sequences
            atmosphere=Float64.(graph_output(science.graph,:atmosphere_opd)[pupil])
            expected=[std(atmosphere;corrected=false),std(residual;corrected=false)].*1e9
            push!(meter_errors,maximum(abs,Float64.(meter[:,frame]).-expected))
            @test last(meter_errors)<=1e-4
        end
        copyto!(hil_command_buffer(science.boundary),@view commands[:,frame])
        adopt_hil_command!(science.boundary,stamp.sequence)
    end
end
C.write_json(joinpath(root,"independent-retained-metrics.json"),Dict(
    "frames"=>32,"native_adc_differing_pixels"=>sum(adc_differences),"exact_controller_replay"=>true,
    "wavefront_samples"=>length(wavefront_sequences),"rms_samples"=>length(meter_sequences),
    "maximum_wavefront_pixel_error_nm"=>maximum(pixel_errors),"maximum_wavefront_rms_error_nm"=>maximum(pupil_errors),
    "maximum_paired_rms_error_nm"=>maximum(meter_errors),"pupil_mask_matches"=>true,
    "manifest_sha256"=>C.sha256_file(joinpath(app,"Manifest.toml")),
    "gpu_modules"=>[id.name for id in keys(Base.loaded_modules) if id.name in ("CUDA","AMDGPU","GPUCompiler")],
    "gpu_libraries"=>filter(p->occursin(r"(?i)(libcuda|libcudart|libcublas|libcufft|libamdhip|libhsa-runtime)",p),Libdl.dllist())))
