using AdaptiveOpticsSim, AdaptiveOpticsSimPipeWireHIL, CUDA, LinearAlgebra, Statistics
using PipeWireAORTC, Proper

const RTC = PipeWireAORTC
const C = RTC.Common
const FITS = RTC.InstrumentConfiguration.FITSIO.FITS

load_array(path) = FITS(path) do file
    image = read(file[1])
    return ndims(image) == 2 ? permutedims(image) : image
end

function prepare_pokes(app, assets)
    OC = OpticalCalibration
    B = AdaptiveOpticsSim.Backends
    CUDA.allowscalar(false)
    BLAS.set_num_threads(1)
    target = B.AcceleratorComputeDevice(B.CUDABackend(), 0)
    recipe = OC.optical_recipe(app, "calibration/optical-dark-hole.yaml")
    plan = OC.optical_publication_plan(
        app, recipe;
        graphs = Dict("llowfs" => "calibration/templates/llowfs-branch.conf",
                      "scc" => "calibration/templates/scc-branch.conf"),
        configuration = "calibration/materialize-dual.yaml",
        prefix = ENV["PIPEWIREAO_PREFIX"],
    )
    # The all-pixel selection is only for these offline observations.
    dimensions = plan.rtc.document["dimensions"]
    dimensions["selected_pixel_count"] = dimensions["image_rows"] * dimensions["image_columns"]
    definition = joinpath(app, "generated/fitted-exposure/definition.yaml")
    execution = OC.optical_upstream_execution(
        app, definition, get(recipe.document, "upstream_settings", Dict()),
    )
    callbacks = OC.optical_callbacks(
        definition, definition;
        mirror = recipe.document["mirror"], branches = recipe.branches,
        upstream_settings = execution.effective,
        settings = get(recipe.document, "settings", Dict()),
        target, chopping = plan.chopping, publication_plan = plan,
        mirror_response = recipe.document["mirror_response"],
    )
    load(name) = load_array(joinpath(assets, name * ".fits"))
    mask = load("scc-pixel-mask") .!= 0
    calibration_difference = load("scc-flat-difference")
    new_difference = callbacks.chopped_references.scc.difference
    flat_error = norm(new_difference - calibration_difference) / norm(calibration_difference)
    @assert flat_error < 1e-4 flat_error
    projection = load("command-projection")
    completion = load("vdm-to-pdm") * load("active-to-full")
    step = Float32(recipe.document["poke_m"])
    return (; callbacks, calibration_difference, flat_error, mask, projection, completion, step)
end

function main(app, assets, output)
    OC = OpticalCalibration
    (; callbacks, flat_error, mask, projection, completion, step) = prepare_pokes(app, assets)
    println("Full flat relative mismatch: ", flat_error)
    flush(stdout)
    load(name) = load_array(joinpath(assets, name * ".fits"))
    raw = load("scc-interaction-matrix")
    half = load("scc-half-interaction-matrix")
    @assert size(projection, 2) == size(raw, 2) == 66
    full = zeros(Float32, size(mask)..., 66, 2)
    for (level, archived) in enumerate((raw, half))
        amplitude = step / 2f0^(level - 1)
        for column in axes(projection, 2)
            function observe(sign)
                command = completion * ((sign * amplitude) .* view(projection, :, column))
                opd = OC.optical_surface(callbacks.surface, command, callbacks.pupil_support)
                return callbacks.observe(opd).scc
            end
            measurement = (observe(1f0) .- observe(-1f0)) ./ (2f0 * amplitude)
            full[:, :, column, level] .= measurement
            error = norm(OC.optical_pixels(measurement, mask) - view(archived, :, column)) /
                norm(view(archived, :, column))
            @assert error < 1e-3 (level, column, error)
            println("Full-frame probe ", level, " / ", column, " relative mismatch: ", error)
            flush(stdout)
        end
        FITS(joinpath(output, level == 1 ? "full-interaction.fits" : "full-half-interaction.fits"), "w") do file
            write(file, full[:, :, :, level])
        end
    end
end

function first_step(app, assets, output)
    OC = OpticalCalibration
    (; callbacks, calibration_difference, flat_error, mask, projection, completion, step) =
        prepare_pokes(app, assets)
    # Reuse the observer's existing static pair sampler to examine the unfringed
    # intensity. The production calibration callback exposes only F-U residuals.
    observe_pairs = getfield(callbacks.observe, :observe_pairs)
    load(name) = load_array(joinpath(output, name * ".fits"))
    residual = OC.optical_pixels(calibration_difference, mask) - load("acquisition-reference")
    direction = -(load("acquisition-reconstructor") * residual)
    @assert all(iszero, view(direction, 1:2))
    magnitude = norm(direction)
    @assert isfinite(magnitude) && magnitude > 0
    function mean_unfringed(coefficient)
        modal = (coefficient / magnitude) .* direction
        command = completion * (projection * modal)
        opd = OC.optical_surface(callbacks.surface, command, callbacks.pupil_support)
        return mean(Float64, observe_pairs(opd).scc.unfringed[mask])
    end
    scale = mean_unfringed(0f0)
    expected_scale = mean(Float64, callbacks.chopped_references.scc.unfringed[mask])
    @assert scale == expected_scale (scale, expected_scale)
    # Evaluate grad(mean(U)) ⋅ direction using central differences along the
    # as-commanded direction. The integrator's positive scalar gain preserves sign.
    changes = map((step, step / 2f0)) do amplitude
        (mean_unfringed(amplitude) - mean_unfringed(-amplitude)) /
        (2 * amplitude) * magnitude
    end
    report = (; flat_error, mean_unfringed_electrons = scale,
        modal_direction_norm_m = magnitude, predicted_electron_changes = changes,
        predicted_relative_changes_with_gain_005 = (0.05 / scale) .* changes)
    C.write_json(joinpath(output, "first-step.json"), report; atomic = true)
    println(report)
end

include(ARGS[1])
if length(ARGS) == 5 && ARGS[5] == "first-step"
    first_step(ARGS[2:4]...)
else
    main(ARGS[2:4]...)
end
