using AdaptiveOpticsSim, LinearAlgebra, PipeWireAORTC, Statistics

const RTC = PipeWireAORTC
const C = RTC.Common
const FITS = RTC.InstrumentConfiguration.FITSIO.FITS
const FFTW = AdaptiveOpticsSim.FFTW

function load_array(path)
    return FITS(path) do file
        image = read(file[1])
        ndims(image) == 2 ? permutedims(image) : image
    end
end

function fft_bins(n)
    return [i <= fld(n - 1, 2) ? i : i - n for i in 0:(n - 1)]
end

# The lab iFTS generator used 29–60 DFT bins on a 256-column by 200-row
# frame sampled at 5.75 × 1.24 pixels per lambda/D. Map frequencies from
# the fitted model into those bins before testing the laboratory limits.
function laboratory_band(shape, fitted_plate_scale)
    rows, columns = shape
    laboratory_plate_scale = 5.75 * 1.24
    v = fft_bins(rows) * (fitted_plate_scale * 200 / (laboratory_plate_scale * rows))
    u = fft_bins(columns) * (fitted_plate_scale * 256 / (laboratory_plate_scale * columns))
    return 29 .<= hypot.(v, u') .<= 60
end

function filter_image(image, band)
    return real.(FFTW.ifft(FFTW.fft(image) .* band))
end

function laboratory_spots(selected, coordinates, frequencies, plate_scale)
    radius = plate_scale * (9 / 5.75) * 0.8
    y, x = coordinates
    function spot(direction, angle, reflected)
        fv, fu = frequencies[direction]
        fu *= reflected
        s, c = sincosd(angle)
        sy = 2plate_scale * (c * fv - s * fu)
        sx = 2plate_scale * (s * fv + c * fu)
        return (hypot.(y .- sy, x .- sx) .<= radius) .|
               (hypot.(y .+ sy, x .+ sx) .<= radius)
    end
    power = [vec(sum(abs2, view(selected, :, (2j - 1):2j); dims = 2)) for j in eachindex(frequencies)]
    fractions = [p ./ sum(p) for p in power]
    function score(angle, reflected)
        return mean(sum(fractions[j][spot(j, angle, reflected)]) for j in eachindex(frequencies))
    end
    angle, reflected = argmax(
        pair -> score(pair...),
        [(angle, reflected) for angle in 0:179 for reflected in (-1, 1)],
    )
    spotmask = repeat(hcat((spot(j, angle, reflected) for j in eachindex(frequencies))...), inner = (1, 2))
    return spotmask, (; angle, reflected, radius_pixels = radius,
        included_fraction = score(angle, reflected),
        perpendicular_fraction = score(mod(angle + 90, 180), reflected))
end

function stability(reconstructor, raw, gain)
    response = reconstructor * raw
    eigenvalues = eigvals(response)
    minimum_real_response = minimum(real, eigenvalues)
    return (;
        minimum_real_response,
        maximum_real_response = maximum(real, eigenvalues),
        maximum_imaginary_response = maximum(z -> abs(imag(z)), eigenvalues),
        maximum_linear_factor = maximum(abs, 1 .- gain .* eigenvalues),
        maximum_gain_at_flat = minimum_real_response > 0 ?
            minimum(z -> 2real(z) / abs2(z), eigenvalues) : 0.0,
        maximum_step_norm = opnorm(I - gain * response),
    )
end

function build_reconstructor(design, raw, half, rtol; gain = 0.05)
    U, S, V = svd(design)
    retained = count(>(first(S) * rtol), S)
    @assert retained > 0 "The calibration design has no observable modes"
    lambda = S[retained]
    active = (V .* (S ./ (S .^ 2 .+ lambda^2))') * U'
    active = Float32.(active)
    observed = stability(Float64.(active), raw, gain)
    checked = stability(Float64.(active), half, gain)
    report = (;
        lambda, retained_modes = retained, singular_values = (; minimum = S[end], maximum = S[1]),
        full_probe = observed, half_probe = checked,
    )
    return active, report
end

function describe_spectrum(image, band, plate_scale)
    spectrum = abs2.(FFTW.fft(Float64.(image)))
    ys, xs = fft_bins(size(image, 1)), fft_bins(size(image, 2))
    radius = hypot.(ys, xs')
    separation = radius * (plate_scale / size(image, 1))
    spectrum[1, 1] = 0
    peak = argmax(spectrum .* band)
    return (;
        band_fraction = sum(spectrum[band]) / sum(spectrum),
        band_peak = (y = ys[peak[1]], x = xs[peak[2]], diameter_units = separation[peak]),
    )
end

function main(source, assets, output)
    BLAS.set_num_threads(1)
    load(name) = load_array(joinpath(assets, name * ".fits"))
    mask = load("scc-pixel-mask") .!= 0
    fringed = load("scc-flat-fringed")
    unfringed = load("scc-flat-unfringed")
    reference = load("scc-reference-difference")
    indices = sort!(findall(mask); by = Tuple)
    @assert (fringed .- unfringed)[indices] == reference
    sky = C.read_yaml(joinpath(source, "optics/generated/fitted/sky.yaml"))
    @assert sky["configuration"] == "reference"
    plate_scale = sky["lod"]
    recipe = C.read_yaml(joinpath(source, "calibration/optical-dark-hole.yaml"))
    frequencies = recipe["spatial_frequencies"]
    modes = recipe["branch_modes"]["scc"]
    @assert modes == collect(3:66) && length(modes) == 2length(frequencies)
    band = laboratory_band(size(mask), plate_scale)
    flat_difference = fringed - unfringed
    spectra = (;
        chopped_flat = describe_spectrum(flat_difference, band, plate_scale),
        unfringed_flat = describe_spectrum(unfringed, band, plate_scale),
    )
    println("Flat spectra ", spectra)
    flush(stdout)
    isfile(joinpath(output, "full-half-interaction.fits")) || return nothing
    full = load_array(joinpath(output, "full-interaction.fits"))
    full_half = load_array(joinpath(output, "full-half-interaction.fits"))
    raw = Float64.(load("scc-interaction-matrix")[:, modes])
    half = Float64.(load("scc-half-interaction-matrix")[:, modes])
    select_modes(cube) = hcat([Float64.(view(cube, :, :, j)[indices]) for j in modes]...)
    full_replay_error = norm(select_modes(full) - raw) / norm(raw)
    half_replay_error = norm(select_modes(full_half) - half) / norm(half)
    @assert max(full_replay_error, half_replay_error) < 1e-3
    @assert size(full_half) == size(full) == (size(mask)..., 66)
    filtered = hcat(map(modes) do mode
        filter_image(Float64.(view(full, :, :, mode)), band)[indices]
    end...)
    scale = norm(filtered) / norm(raw)
    println("Filtered/raw selected interaction norm ratio: ", scale)
    center = (size(mask) .+ 1) ./ 2
    coordinates = (getindex.(indices, 1) .- center[1], getindex.(indices, 2) .- center[2])
    spots, spot_report = laboratory_spots(filtered, coordinates, frequencies, plate_scale)
    println("Spot alignment: ", spot_report)
    diagnostics = Dict{String,Any}()
    reference_only_path = normpath(joinpath(source, "..", "reference-only-selected.fits"))
    pinhole_only = isfile(reference_only_path) ? load_array(reference_only_path) : nothing
    candidates = (
        ("band-and-spots", filtered .* spots),
        ("band-only", filtered),
    )
    selected = nothing
    for (name, design) in candidates
        active, report = build_reconstructor(design, raw, half, recipe["tsvd_rtol"])
        diagnostics[name] = merge(report, (;
            initial_modal_norm_m = norm(active * reference),
            pinhole_only_modal_norm_m =
                pinhole_only === nothing ? nothing : norm(active * pinhole_only),
            reference_motion_m = report.retained_modes == length(modes) ?
                norm((Float64.(active) * raw) \ (active * reference)) : nothing,
        ))
        println(name, " ", diagnostics[name])
        if selected === nothing && report.retained_modes == length(modes) &&
           all(result -> result.maximum_linear_factor < 1,
                                       (report.full_probe, report.half_probe))
            selected = (; name, active, design)
        end
    end
    selected === nothing && error("Laboratory preprocessing produced no stable raw-camera candidate")
    reconstructor = zeros(Float32, size(full, 3), count(mask))
    reconstructor[modes, :] .= selected.active
    zero_reference = zero(reference)
    save(name, values; kw...) = RTC.InstrumentCalibration.write_fits(
        joinpath(output, name * ".fits"), values; kw...
    )
    save("acquisition-reconstructor", reconstructor; units = "m OPD / electron")
    save("acquisition-reference", zero_reference; units = "electron")
    save("filtered-interaction", Float32.(selected.design); units = "electron / m OPD")
    @assert load_array(joinpath(output, "acquisition-reconstructor.fits")) == reconstructor
    @assert load_array(joinpath(output, "acquisition-reference.fits")) == zero_reference
    results = (; selected = selected.name, plate_scale, laboratory_band_bins = (29, 60),
        laboratory_frame_rows_columns = (200, 256), laboratory_plate_scale = 5.75 * 1.24,
        selected_pixels = count(mask), calibrated_modes = modes, spot_alignment = spot_report,
        live_reference = "zero selected pixels",
        live_measurement = "raw selected fringed minus unfringed",
        calibration_frame_rows_columns = size(mask),
        filtered_raw_selected_interaction_norm_ratio = scale,
        spectra, full_replay_error, half_replay_error, diagnostics)
    C.write_json(joinpath(output, "acquisition-conditioning.json"), results; atomic = true)
end

main(ARGS...)
