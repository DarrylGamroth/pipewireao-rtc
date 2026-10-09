#!/usr/bin/env julia
# Cold scientific reduction after the deployed stage has restored/released/stopped.
using AdaptiveOpticsCalibration
using JSON3
using SHA
include("calibration_client.jl")
const RF = AdaptiveOpticsCalibration.ReferenceFrames
Base.ENDIAN_BOM == 0x04030201 || throw(ArgumentError("campaign packed data requires a little-endian host"))

function prepare_recipe(recipe)
    specification = (; run=1, reference=recipe.reference, amplitudes=recipe.amplitudes,
        measurements=376, frames_per_probe=recipe.frames_per_probe, settling=recipe.settling,
        timeouts_ns=(; ownership=recipe.request_timeout_ns, adoption=recipe.request_timeout_ns,
            settling=recipe.request_timeout_ns, collection=recipe.request_timeout_ns,
            restoration=recipe.request_timeout_ns))
    return CalibrationClient.prepare_plan(specification)
end

function read_packed(path, ::Type{T}, count) where {T}
    bytes = read(path)
    length(bytes) == sizeof(T) * count || throw(DimensionMismatch("wrong payload length: $path"))
    return collect(reinterpret(T, bytes))
end

function write_packed(path, values)
    ispath(path) && throw(ArgumentError("candidate output already exists: $path"))
    temporary = path * ".partial"
    open(temporary, "w") do io
        write(io, reinterpret(UInt8, vec(values)))
    end
    mv(temporary, path)
    return bytes2hex(open(sha256, path))
end

function read_window(evidence)
    stage = JSON3.read(read(joinpath(evidence, "stage-result.json"), String))
    stage.restoration_confirmed && stage.release_confirmed && stage.shutdown_confirmed ||
        throw(ArgumentError("stage lifecycle is incomplete"))
    path = joinpath(evidence, "captured", stage.capture.manifest)
    bytes2hex(open(sha256, path)) == stage.capture.sha256 || throw(ArgumentError("manifest digest mismatch"))
    manifest = JSON3.read(read(path, String))
    count = Int(manifest.frames)
    count <= 64 || throw(ArgumentError("campaign window exceeds its memory budget"))
    raw = Array{UInt16}(undef, 352, 352, count)
    slopes = Matrix{Float64}(undef, 376, count)
    flux = Matrix{Float32}(undef, 188, count)
    validity = Matrix{Bool}(undef, 188, count)
    for (frame, exposure) in enumerate(manifest.exposures)
        directory = joinpath(dirname(path), exposure.directory)
        for record in values(exposure.files)
            bytes2hex(open(sha256, joinpath(directory, record.path))) == record.sha256 ||
                throw(ArgumentError("payload digest mismatch"))
        end
        packed = read_packed(joinpath(directory, "raw.u16le"), UInt16, 352 * 352)
        # Public wire ROW_MAJOR -> explicit Julia row,column axes, outside callbacks.
        @views raw[:, :, frame] .= transpose(reshape(packed, 352, 352))
        @views slopes[:, frame] .= read_packed(joinpath(directory, "slopes.f32le"), Float32, 376)
        @views flux[:, frame] .= read_packed(joinpath(directory, "flux.f32le"), Float32, 188)
        valid = read_packed(joinpath(directory, "validity.u8"), UInt8, 188)
        all(x -> x == 0 || x == 1, valid) || throw(ArgumentError("invalid BOOL8 payload"))
        @views validity[:, frame] .= valid .== 1
    end
    return (; raw, slopes, flux, validity, manifest, stage)
end

function lamp_product(window, recipe)
    count = size(window.raw, 3)
    plan = AdaptiveOpticsCalibration.prepare(
        RF.LampReference(Float64.(recipe.minimum_flux), Int(recipe.adc_upper_rail)),
        RF.LampReferenceSpecification(352, 352, 188, count))
    inputs = RF.LampReferenceInputs(window.slopes, window.flux, window.validity, window.raw;
        centroids_are_absolute=true)
    return AdaptiveOpticsCalibration.process(plan, inputs)
end

function main(stage, output, evidence)
    recipe = JSON3.read(read(joinpath(output, "recipe.json"), String))
    if stage == "prepare"
        CalibrationClient.write_plan(joinpath(output, "interaction-plan.json"), prepare_recipe(recipe))
        report = (; stage, status="prepared-public-zonal-plan", signed_commands=554)
    elseif stage == "interaction"
        prepared = prepare_recipe(recipe)
        result = read(joinpath(evidence, "rtc-calibrate.json"), String)
        responses = CalibrationClient.validate_result(result, prepared)
        matrix = CalibrationClient.estimate_interaction_matrix(prepared, responses)
        hash = write_packed(joinpath(output, "measured-interaction-matrix.f32le"), permutedims(matrix))
        report = (; stage, status="valid-structured-estimate", shape=size(matrix),
            layout="ROW_MAJOR", sha256=hash,
            acceptance="precision, linearity, observability and reconstructor remain separate gates")
    else
        window = read_window(evidence)
        if stage == "dark"
            plan = AdaptiveOpticsCalibration.prepare(RF.DarkFrameMoments(),
                RF.DarkFrameSpecification(352, 352, size(window.raw, 3)))
            product = AdaptiveOpticsCalibration.process(plan, window.raw)
            product.status === RF.Valid || throw(ArgumentError("dark moments invalid"))
            background = Float32.(product.mean)
            all(isfinite, background) || throw(ArgumentError("background cannot be represented as Float32"))
            hash = write_packed(joinpath(output, "measured-background.f32le"), permutedims(background))
            variance_hash = write_packed(joinpath(output, "measured-dark-variance.f64le"), permutedims(product.variance))
            report = (; stage, samples=size(window.raw, 3), status="valid", background_sha256=hash,
                variance_sha256=variance_hash, variance_normalization="N-1", units="ADC")
        elseif stage == "training"
            product = lamp_product(window, recipe)
            product.status === RF.Valid || throw(ArgumentError("lamp reference invalid: $(product.status)"))
            all(!product.eligible[i] || recipe.candidate_mask[i] for i in eachindex(product.eligible)) ||
                throw(ArgumentError("selected ROI outside declared candidate universe"))
            reference = Float32.(product.reference_centroids)
            all(isfinite, reference) || throw(ArgumentError("reference cannot be represented as Float32"))
            reference_hash = write_packed(joinpath(output, "measured-reference-slopes.f32le"), reference)
            mask_hash = write_packed(joinpath(output, "measured-active.u8"), UInt8.(product.eligible))
            report = (; stage, status="valid", selected=count(product.eligible),
                eligible=product.eligible, minimum_flux=product.minimum_flux,
                all_training_valid=product.all_training_valid, adc_maximum=product.adc_maximum,
                reference_sha256=reference_hash, mask_sha256=mask_hash,
                reference_convention="mean of individual absolute deployed centroids; inactive positions zero")
        elseif stage == "qualification"
            frozen = read_packed(joinpath(output, "measured-reference-slopes.f32le"), Float32, 376)
            mask = read_packed(joinpath(output, "measured-active.u8"), UInt8, 188) .== 1
            # Reconstruct absolute measured centroids from known startup reference;
            # no simulator optical field or ideal centroid is consulted.
            window.slopes .+= frozen
            product = lamp_product(window, recipe)
            product.status === RF.Valid && all(!mask[i] || product.eligible[i] for i in eachindex(mask)) ||
                throw(ArgumentError("frozen selected ROI fails independent qualification"))
            residual = maximum(abs(product.reference_centroids[i] - frozen[i])
                for i in eachindex(frozen) if mask[(i + 1) ÷ 2])
            residual <= recipe.maximum_reference_residual || throw(ArgumentError("reference residual exceeds declared pixel bound: $residual"))
            report = (; stage, status="qualified-frozen-reference", selected=count(mask),
                maximum_reference_residual_pixels=residual,
                declared_bound_pixels=recipe.maximum_reference_residual,
                adc_maximum=product.adc_maximum, mask_reselection=false)
        else
            throw(ArgumentError("unknown campaign stage"))
        end
    end
    path = joinpath(evidence, "analysis.json")
    ispath(path) && throw(ArgumentError("analysis output already exists"))
    open(path, "w") do io
        JSON3.write(io, report)
        write(io, '\n')
    end
    println(JSON3.write(report))
end

length(ARGS) == 3 || throw(ArgumentError("usage: calibration_campaign_analysis.jl stage candidate evidence"))
main(ARGS...)
