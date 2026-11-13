import AdaptiveOpticsSim
const Backends = AdaptiveOpticsSim.Backends
const FFTW = Backends.FFTW
FFTW.set_num_threads(1)
FFTW.forget_wisdom()

function Backends.plan_repeated_fft_backend!(buffer::Array{T,N}, dims) where {T<:Union{ComplexF32,ComplexF64},N}
    return FFTW.plan_fft!(buffer, dims; flags=FFTW.ESTIMATE)
end

function Backends.plan_repeated_ifft_backend!(buffer::Array{T,N}, dims) where {T<:Union{ComplexF32,ComplexF64},N}
    return FFTW.plan_ifft!(buffer, dims; flags=FFTW.ESTIMATE)
end

function Backends.plan_repeated_bfft_backend!(buffer::Array{T,N}, dims) where {T<:Union{ComplexF32,ComplexF64},N}
    return FFTW.plan_bfft!(buffer, dims; flags=FFTW.ESTIMATE)
end
