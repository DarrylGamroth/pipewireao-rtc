using LinearAlgebra, Statistics

include("push-pull.jl")

const LABELS = (:raw66, :raw64, :filtered64)
const GAIN = 0.05f0

function raw64_fit(raw)
    active = 3:66
    # Match the band-only recipe's precision and Tikhonov policy.
    U, S, V = svd(Float64.(raw[:, active]))
    lambda = S[end]
    @assert lambda > 1e-4 * S[1]
    R = zeros(Float32, 66, size(raw, 1))
    R[active, :] .= (V .* (S ./ (S .^ 2 .+ lambda^2))') * U'
    return R, lambda
end

function optical_motion(direction, mean_unfringed, flat_mean, step)
    magn = norm(direction)
    unit = direction ./ magn
    amplitudes = (step, step / 2f0)
    changes = map(amplitudes) do amplitude
        (mean_unfringed(amplitude .* unit) - mean_unfringed(-amplitude .* unit)) /
        (2 * amplitude) * magn
    end
    actual = mean_unfringed(GAIN .* direction)
    return (; directional_derivative_electrons = changes,
        predicted_relative_changes = (GAIN / flat_mean) .* changes,
        actual_first_step_electrons = actual,
        actual_first_step_relative_change = (actual - flat_mean) / flat_mean)
end

function compare(calibration_module, app, assets, output, legacy, target)
    BLAS.set_num_threads(1)
    load_asset(name) = load_array(joinpath(assets, name * ".fits"))
    load_output(name) = load_array(joinpath(output, name * ".fits"))
    raw = load_asset("scc-interaction-matrix")
    raw64, lambda = raw64_fit(raw)
    raw64_path = joinpath(output, "matched-raw64-reconstructor.fits")
    RTC.InstrumentCalibration.write_fits(raw64_path, raw64; units = "m OPD / electron")
    @assert load_array(raw64_path) == raw64
    reference = load_output("acquisition-reference")
    residual = load_asset("scc-reference-difference") - reference
    @assert iszero(reference)
    matrices = NamedTuple{LABELS}((load_array(legacy), raw64, load_output("acquisition-reconstructor")))
    directions = map(R -> -(R * residual), matrices)
    @assert all(direction -> iszero(view(direction, 1:2)), directions)
    norms = map(norm, directions)
    overlaps = Dict(
        "$left × $right" => dot(directions[left], directions[right]) /
            (norms[left] * norms[right])
        for (left, right) in ((:raw66, :raw64), (:raw66, :filtered64), (:raw64, :filtered64))
    )
    relative_distances = Dict(
        "$left to $right" => norm(directions[left] - directions[right]) / norms[left]
        for (left, right) in ((:raw66, :raw64), (:raw66, :filtered64), (:raw64, :filtered64))
    )
    gains = map(matrices) do R
        B = Float64.(view(R, 3:66, :)) * Float64.(view(raw, :, 3:66))
        (; spectral_radius = maximum(abs, 1 .- GAIN .* eigvals(B)),
            norm = opnorm(I - GAIN * B))
    end
    report = (; reference = "same all-zero selected target", gain = GAIN, raw64_lambda = lambda,
        modal_norm_m = norms, modal_adjustment_m = directions, cosine_similarity = overlaps,
        relative_direction_distance = relative_distances, raw_probe_static_response = gains)
    C.write_json(joinpath(output, "modal-directions.json"), report; atomic = true)
    println("Modal norms (m) ", norms, "\nCosine similarities ", overlaps)
    flush(stdout)
    target == "matrix-only" && return nothing
    @assert target in ("cpu", "cuda")
    Base.include(Main, calibration_module)
    Base.invokelatest(complete_optical_comparison, app, assets, output, target, directions, report)
end

function complete_optical_comparison(app, assets, output, target, directions, report)
    OC = OpticalCalibration
    (; callbacks, flat_error, mask, projection, completion, step) =
        prepare_pokes(app, assets; use_gpu = target == "cuda")
    observe_pairs = getfield(callbacks.observe, :observe_pairs)
    function mean_unfringed(modal)
        command = completion * (projection * modal)
        opd = OC.optical_surface(callbacks.surface, command, callbacks.pupil_support)
        return mean(Float64, observe_pairs(opd).scc.unfringed[mask])
    end
    scale = mean_unfringed(zeros(Float32, size(projection, 2)))
    @assert scale == mean(Float64, callbacks.chopped_references.scc.unfringed[mask])
    optical = map(direction -> optical_motion(direction, mean_unfringed, scale, step), directions)
    expected = C.read_json(joinpath(output, "first-step.json"))
    previous = expected["predicted_relative_changes_with_gain_005"]
    difference = maximum(abs, collect(optical.filtered64.predicted_relative_changes) - previous)
    @assert difference < 2e-5 difference
    result = merge(report, (; target, flat_error, mean_unfringed_electrons = scale,
        directional_poke_m = (step, step / 2f0), filtered64_previous_check_difference = difference,
        optical))
    C.write_json(joinpath(output, "compare-first-step.json"), result; atomic = true)
    println("Predicted first-step fractional changes ", map(v -> v.predicted_relative_changes, optical))
    println("Actual static first-step fractional changes ", map(v -> v.actual_first_step_relative_change, optical))
end

compare(ARGS...)
