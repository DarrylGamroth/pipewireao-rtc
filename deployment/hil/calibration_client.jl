"""
    CalibrationClient

Scientific plan/result helpers for operational RTC calibration. This module
uses AdaptiveOpticsCalibration for probe construction and matrix estimation;
it does not acquire, activate, install, or choose a reconstructor.
"""
module CalibrationClient

using AdaptiveOpticsCalibration
using JSON3

const PB = AdaptiveOpticsCalibration.ProbeBases
const IM = AdaptiveOpticsCalibration.InteractionMatrices

export prepare_plan, write_plan, validate_result, estimate_interaction_matrix, write_artifact

_get(value, key) = hasproperty(value, key) ? getproperty(value, key) : throw(ArgumentError("missing field: $key"))

function _float32(value, label)
    converted = try
        Float32(value)
    catch
        throw(ArgumentError("$label is not representable as Float32"))
    end
    isfinite(converted) || throw(ArgumentError("$label is outside the finite Float32 range"))
    !iszero(value) && iszero(converted) &&
        throw(ArgumentError("$label underflows the Float32 range"))
    return converted
end

"""Prepare CLI plan plus the AOC interleaved absolute probe figures."""
function prepare_plan(specification)
    reference = _float32.(_get(specification, :reference), "reference")
    amplitudes = _float32.(_get(specification, :amplitudes), "probe amplitude")
    !isempty(reference) && length(reference) == length(amplitudes) ||
        throw(ArgumentError("reference and amplitudes must have equal nonzero length"))
    all(isfinite, reference) || throw(ArgumentError("reference must be finite"))
    basis = PB.ZonalPushPull(amplitudes)
    basis_plan = AdaptiveOpticsCalibration.prepare(basis, nothing)
    basis_result = AdaptiveOpticsCalibration.allocate_result(basis_plan)
    AdaptiveOpticsCalibration.process!(basis_result, nothing, basis_plan, nothing)
    relative = PB.probe_commands(basis_result)
    figures = Matrix{Float32}(undef, size(relative))
    for row in axes(relative, 1), col in axes(relative, 2)
        figures[row, col] = reference[col] + relative[row, col]
        figures[row, col] - reference[col] == relative[row, col] ||
            throw(ArgumentError("absolute Float32 probe figure does not preserve its AOC command delta"))
    end
    all(isfinite, figures) || throw(ArgumentError("absolute probe figures must be finite"))
    measurements = Int(_get(specification, :measurements))
    frames = Int(_get(specification, :frames_per_probe))
    measurements > 0 && frames > 0 || throw(ArgumentError("measurement and frame counts must be positive"))
    IM.prepare(IM.ZonalPushPull(amplitudes), IM.ResponseSpecification(measurements))
    plan = (; version=1, run=UInt64(_get(specification, :run)), reference,
        probes=[collect(@view figures[row, :]) for row in axes(figures, 1)],
        measurements, frames_per_probe=frames,
        settling=_get(specification, :settling),
        timeouts_ns=_get(specification, :timeouts_ns))
    plan.run > 0 || throw(ArgumentError("run must be positive"))
    return (; plan, figures, reference, amplitudes, measurements, frames_per_probe=frames)
end

"""Write the exact prepared plan to an explicit path for `rtc-calibrate`."""
function write_plan(path::AbstractString, prepared)
    open(path, "w") do io
        JSON3.write(io, prepared.plan)
        write(io, '\n')
    end
    return path
end

function _is_integer(value)
    return typeof(value) <: Integer && typeof(value) !== Bool
end

_document(result::AbstractString) = JSON3.read(result)
_document(result) = result

function _positive_integer(value, label)
    _is_integer(value) && value > 0 || throw(ArgumentError("$label must be a positive integer"))
    return UInt64(value)
end

function _uint64(value, label; allow_zero=false)
    _is_integer(value) || throw(ArgumentError("$label must be an integer"))
    minimum = allow_zero ? 0 : 1
    minimum <= value <= typemax(UInt64) || throw(ArgumentError("$label is outside the UInt64 range"))
    return UInt64(value)
end

"""Validate complete `rtc-calibrate` JSON and return responses in probe order."""
function validate_result(result, prepared)
    document = _document(result)
    _get(document, :version) == 1 || throw(ArgumentError("unsupported result version"))
    _get(document, :run) == prepared.plan.run || throw(ArgumentError("result run differs from plan"))
    _get(document, :phase) == "complete" || throw(ArgumentError("calibration did not complete"))
    _get(document, :restoration_confirmed) === true || throw(ArgumentError("reference restoration is unconfirmed"))
    _get(document, :resume_permitted) === true || throw(ArgumentError("ownership release is unconfirmed"))
    _get(document, :failure) === nothing || throw(ArgumentError("calibration result reports failure"))
    _get(document, :recovery_failure) === nothing || throw(ArgumentError("calibration recovery reports failure"))
    batches = _get(document, :responses)
    batches === nothing && throw(ArgumentError("complete result has no response batches"))
    length(batches) == size(prepared.figures, 1) || throw(ArgumentError("response batch count differs from probe count"))
    responses = Matrix{Float32}(undef, length(batches), prepared.measurements)
    exposure_ids = Set{Tuple{UInt64,UInt64,UInt64}}()
    domain_generation = nothing
    previous_sequence = UInt64(0)
    previous_exposure_end = UInt64(0)
    for (row, batch) in enumerate(batches)
        values = _get(batch, :values)
        length(values) == prepared.measurements || throw(ArgumentError("response measurement dimension differs"))
        _get(batch, :valid) === true || throw(ArgumentError("response batch is marked invalid"))
        exposures = _get(batch, :exposures)
        length(exposures) == prepared.frames_per_probe || throw(ArgumentError("response exposure count differs"))
        for column in eachindex(values)
            responses[row, column] = _float32(values[column], "response value")
        end
        for exposure in exposures
            domain = _positive_integer(_get(exposure, :domain), "exposure domain")
            generation = _positive_integer(_get(exposure, :generation), "exposure generation")
            sequence = _positive_integer(_get(exposure, :sequence), "exposure sequence")
            start = _uint64(_get(exposure, :start_model_ns), "exposure start time"; allow_zero=true)
            duration = _uint64(_get(exposure, :duration_ns), "exposure duration")
            start <= typemax(UInt64) - duration || throw(ArgumentError("exposure end time overflows UInt64"))
            start >= previous_exposure_end || throw(ArgumentError("exposure intervals overlap or are out of order"))
            previous_exposure_end = start + duration
            identity = (domain, generation, sequence)
            identity in exposure_ids && throw(ArgumentError("duplicate exposure identity"))
            push!(exposure_ids, identity)
            current = (domain, generation)
            domain_generation === nothing ? (domain_generation = current) :
                current == domain_generation || throw(ArgumentError("exposure domain or generation changed"))
            sequence > previous_sequence || throw(ArgumentError("exposure sequence is not increasing in probe order"))
            previous_sequence = sequence
        end
    end
    return responses
end

"""Estimate the measurement-by-corrector matrix through AOC's public API."""
function estimate_interaction_matrix(prepared, responses::AbstractMatrix)
    size(responses) == (size(prepared.figures, 1), prepared.measurements) ||
        throw(DimensionMismatch("responses must have one interleaved row per AOC probe"))
    values = _float32.(responses, "response value")
    matrix_plan = AdaptiveOpticsCalibration.prepare(
        IM.ZonalPushPull(prepared.amplitudes), IM.ResponseSpecification(prepared.measurements))
    result = AdaptiveOpticsCalibration.allocate_result(matrix_plan)
    workspace = AdaptiveOpticsCalibration.allocate_workspace(matrix_plan)
    product = AdaptiveOpticsCalibration.process!(result, workspace, matrix_plan, values)
    product.status === IM.StructuredValid || throw(ArgumentError(
        "AdaptiveOpticsCalibration rejected the structured estimate: $(product.status)",
    ))
    matrix = IM.interaction_matrix(result)
    all(isfinite, matrix) || throw(ArgumentError("estimated interaction matrix contains non-finite values"))
    return matrix
end

"""Write a validated result artifact only to the caller-supplied path."""
function write_artifact(path::AbstractString, prepared, result, metadata)
    responses = validate_result(result, prepared)
    matrix = estimate_interaction_matrix(prepared, responses)
    record = (; version=1, run=prepared.plan.run,
        command_units=_get(metadata, :command_units), actuator_order=_get(metadata, :actuator_order),
        measurement_units=_get(metadata, :measurement_units), measurement_order=_get(metadata, :measurement_order),
        probe_basis="zonal_push_pull", amplitudes=prepared.amplitudes,
        reference=prepared.reference, detector_settings=_get(metadata, :detector_settings),
        settings_identity=_get(metadata, :settings_identity), numerical_policy_identity=_get(metadata, :numerical_policy_identity),
        endpoint_identity=_get(metadata, :endpoint_identity), model_identity=_get(metadata, :model_identity),
        source_paths=_get(metadata, :source_paths), artifact_hashes=_get(metadata, :artifact_hashes),
        cli_result=_document(result),
        responses, interaction_matrix=matrix)
    open(path, "w") do io
        JSON3.write(io, record)
        write(io, '\n')
    end
    return record
end

end
