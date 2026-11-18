using AdaptiveOpticsSim, LinearAlgebra, PipeWireAORTC, SHA
const RTC = PipeWireAORTC
const C = RTC.Common
const FITS = RTC.InstrumentConfiguration.FITSIO.FITS
const FFTW = AdaptiveOpticsSim.FFTW

function check_lab_response(selection, lab_response, lab_mask, output)
    record = C.read_json(selection)
    mask = FITS(lab_mask) do file
        read(file[1]) .!= 0
    end
    fits_bins(n) = [k <= fld(n - 1, 2) ? k : k - n for k in 0:(n - 1)]
    band = 29 .<= hypot.(fits_bins(256), fits_bins(200)') .<= 60
    results = FITS(lab_response) do file
        @assert size(file[1]) == (256, 200, 650) && size(mask) == (256, 200)
        map(record["selection"]) do pair
            rows = pair["fits_rows"]
            strengths = map(rows) do mode
                frame = Float64.(read(file[1], :, :, mode))
                @assert all(isfinite, frame) && norm(frame) > 0
                filtered = real.(FFTW.ifft(FFTW.fft(frame) .* band))
                norm(filtered[mask]), norm(filtered) / norm(frame)
            end
            (; fits_rows = rows, in_mask_l2 = first.(strengths), band_fraction_l2 = last.(strengths))
        end
    end
    @assert all(row -> minimum(row.in_mask_l2) > 0, results)
    sha(path) = bytes2hex(open(sha256, path))
    C.write_json(output, (; lab_response, response_sha256 = sha(lab_response),
        lab_mask, mask_sha256 = sha(lab_mask), mask_count = count(mask), lab_camera_fits_shape = (256, 200, 650),
        selected_phase_pairs = results); atomic = true)
end
check_lab_response(ARGS...)
