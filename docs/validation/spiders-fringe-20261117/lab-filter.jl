using AdaptiveOpticsSim: FFTW
using LinearAlgebra
using PipeWireAORTC
using Statistics

const FITS = PipeWireAORTC.InstrumentConfiguration.FITSIO.FITS


function audit(lab)
    asset(name) = joinpath(lab, name * ".fits")
    reference = FITS(f -> read(f[1]), asset("reference-image"))
    mask = FITS(f -> read(f[1]), asset("mask-overall")) .!= 0
    nx, ny = size(reference)
    @assert (nx, ny) == (256, 200) && size(mask) == size(reference)
    passband = [29 <= hypot(x - (1+nx)/2, y - (1+ny)/2) <= 60 for x in 1:nx, y in 1:ny]
    kept_power = Float64[]
    errors = Float64[]
    FITS(asset("differential-response-images")) do raw
        FITS(asset("differential-response-images-spotmasked")) do stored
            @assert size(raw[1]) == size(stored[1]) == (nx, ny, 650)
            for mode in 1:650
                response = read(raw[1], :, :, mode)
                expected = read(stored[1], :, :, mode)
                selected = expected .!= 0
                any(selected) || continue
                spectrum = FFTW.fftshift(FFTW.fft(response))
                filtered = real.(FFTW.ifft(FFTW.fftshift(spectrum .* passband)))
                push!(kept_power, sum(abs2, spectrum[passband]) / sum(abs2, spectrum))
                push!(errors, norm(filtered[selected] - expected[selected]) / norm(expected[selected]))
            end
        end
    end
    return (; dimensions=size(mask), mask_pixels=count(mask), reference_peak=maximum(abs,reference),
        compared_modes=length(errors), median_response_power_in_band=median(kept_power),
        median_relative_error_on_stored_support=median(errors), maximum_relative_error=maximum(errors))
end
println(PipeWireAORTC.Common.JSON.json(audit(only(ARGS))))
