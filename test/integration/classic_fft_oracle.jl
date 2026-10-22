"""Opt-in CPU oracle: preserve the native owner's measured FFT execution contract."""
module ClassicFFTOracle
using PipeWireAORTC, AdaptiveOpticsSim, LinearAlgebra
const F = AdaptiveOpticsSim.FFTW
const B = AdaptiveOpticsSim.Backends
const C = PipeWireAORTC.Common

# This inspects test-owner storage only. No production API or callback depends
# on an AOS workspace layout. The current graph retains plans in named fields;
# arrays are numerical storage and are deliberately not traversed.
function plans(value, path="graph", depth=0)
    depth <= 16 || throw(ArgumentError("FFT plan inventory exceeds its traversal bound"))
    value isa F.FFTWPlan && return [path => sprint(show, value)]
    value isa Union{AbstractArray,Number,Symbol,AbstractString,Function,Module,Type,Nothing} &&
        return Pair{String,String}[]
    result = Pair{String,String}[]
    for field in fieldnames(typeof(value))
        append!(result, plans(getfield(value, field), path * "." * string(field), depth + 1))
    end
    return result
end

function record(science, directory)
    mkpath(directory)
    inventory = Dict(plans(science.graph))
    isempty(inventory) && throw(ArgumentError("CPU oracle found no retained FFT plans"))
    F.export_wisdom(joinpath(directory, "wisdom"))
    C.write_json(joinpath(directory, "plans.json"), Dict(
        "plans" => inventory,
        "fftw_version" => string(F.version), "provider" => F.get_provider(),
        "fft_threads" => F.get_num_threads(), "julia_version" => string(VERSION),
        "julia_threads" => Threads.nthreads(), "blas_threads" => BLAS.get_num_threads(),
        "blas_configuration" => string(BLAS.get_config()),
        "wisdom_sha256" => C.sha256_file(joinpath(directory, "wisdom"))))
    return science
end

"Install only in the isolated test simulator, before AOSOwner.main."
function record_native!(directory)
    @assert F.get_num_threads() == 1
    @eval PipeWireAORTC.AOSOwner begin
        function prepare_science(options::NamedTuple; check=()->nothing)
            options.backend === :cpu || throw(ArgumentError("FFT oracle requires CPU"))
            science = invoke(prepare_science, Tuple{Any}, options; check)
            Main.ClassicFFTOracle.record(science, $directory)
        end
    end
end

"Require saved wisdom for repeated transforms instead of independently remeasuring."
function restore!(directory)
    provenance = C.read_json(joinpath(directory, "plans.json"))
    provenance["julia_version"] == string(VERSION) &&
        provenance["fftw_version"] == string(F.version) &&
        provenance["provider"] == F.get_provider() &&
        provenance["fft_threads"] == F.get_num_threads() == 1 &&
        provenance["wisdom_sha256"] == C.sha256_file(joinpath(directory, "wisdom")) ||
        throw(ArgumentError("CPU FFT execution contract differs from native capture"))
    F.forget_wisdom()
    F.import_wisdom(joinpath(directory, "wisdom"))
    @eval B begin
        function plan_repeated_fft_backend!(a::Array{T,N}, dims) where {T<:Union{ComplexF32,ComplexF64},N}
            FFTW.plan_fft!(a, dims; flags=FFTW.WISDOM_ONLY)
        end
        function plan_repeated_ifft_backend!(a::Array{T,N}, dims) where {T<:Union{ComplexF32,ComplexF64},N}
            FFTW.plan_ifft!(a, dims; flags=FFTW.WISDOM_ONLY)
        end
        function plan_repeated_bfft_backend!(a::Array{T,N}, dims) where {T<:Union{ComplexF32,ComplexF64},N}
            FFTW.plan_bfft!(a, dims; flags=FFTW.WISDOM_ONLY)
        end
    end
    return provenance
end

function verify(science, provenance)
    actual = Dict(plans(science.graph))
    isempty(actual) && throw(ArgumentError("CPU oracle found no retained FFT plans"))
    actual == provenance["plans"] || throw(ArgumentError(
        "CPU oracle FFT plans differ from the native owner's saved plans"))
    return true
end
end
