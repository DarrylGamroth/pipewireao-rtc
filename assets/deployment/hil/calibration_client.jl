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

struct PhysicalProbeBasis{E<:AdaptiveOpticsCalibration.AbstractCalibrationMethod,C<:AbstractMatrix{Float32},D}
    estimator::E
    positive_commands::C
    description::D
end

struct DirectionalProbeBasis{E<:AdaptiveOpticsCalibration.AbstractCalibrationMethod,C<:AbstractMatrix{Float32},D}
    estimator::E
    positive_commands::C
    description::D
end

_estimator(basis::PhysicalProbeBasis) = basis.estimator
_estimator(basis::DirectionalProbeBasis) = basis.estimator
_coordinate_kind(::PhysicalProbeBasis) = "physical_actuator"
_coordinate_kind(::DirectionalProbeBasis) = "mode_direction"

_row_length(row::AbstractVector) = length(row)
_row_length(row) = throw(ArgumentError("matrix rows must be arrays"))

function _matrix(value::AbstractMatrix, convert, label)
    Base.require_one_based_indexing(value)
    return convert.(value, label)
end

function _matrix(rows::AbstractVector, convert, label)
    Base.require_one_based_indexing(rows)
    isempty(rows) && throw(ArgumentError("$label must be nonempty"))
    columns = _row_length(first(rows))
    columns > 0 && all(row -> _row_length(row) == columns, rows) ||
        throw(DimensionMismatch("$label rows must have equal nonzero length"))
    foreach(Base.require_one_based_indexing, rows)
    Base.Checked.checked_mul(length(rows), columns)
    result = [convert(rows[row][column], label) for row in eachindex(rows), column in 1:columns]
    return result
end

function _geometry_number(value, label)
    converted = Float64(value)
    isfinite(converted) || throw(ArgumentError("$label must be finite Float64 coordinates"))
    !iszero(value) && iszero(converted) && throw(ArgumentError("$label underflows Float64"))
    return converted
end

function _commands(method, specification=nothing)
    plan = AdaptiveOpticsCalibration.prepare(method, specification)
    result = AdaptiveOpticsCalibration.allocate_result(plan)
    AdaptiveOpticsCalibration.process!(result, nothing, plan, nothing)
    return _float32.(PB.probe_commands(result), "relative probe command"), plan
end

_positive_commands(relative) = relative[1:2:end, :]

function _prepare_basis(::Val{:zonal}, specification, declared)
    amplitudes = _float32.(_get(specification, :amplitudes), "probe amplitude")
    relative, _ = _commands(PB.ZonalPushPull(amplitudes))
    descriptor = PhysicalProbeBasis(IM.ZonalPushPull(amplitudes), _positive_commands(relative),
        (; kind="zonal_push_pull", ordering="positive/negative per physical coordinate"))
    return relative, amplitudes, descriptor
end

function _prepare_basis(::Val{:hadamard}, specification, declared)
    amplitudes = _float32.(_get(specification, :amplitudes), "probe amplitude")
    relative, _ = _commands(PB.HadamardPushPull(amplitudes))
    descriptor = PhysicalProbeBasis(IM.HadamardPushPull(amplitudes), _positive_commands(relative),
        (; kind="hadamard_push_pull", ordering="positive/negative per balanced Sylvester row; DC column excluded"))
    return relative, amplitudes, descriptor
end

function _prepare_basis(::Val{:modal}, specification, declared)
    amplitudes = _float32.(_get(declared, :mode_amplitudes), "mode amplitude")
    positive = _matrix(_get(declared, :positive_commands), _float32, "positive modal command")
    size(positive, 1) == length(amplitudes) || throw(DimensionMismatch("one mode amplitude is required per positive-command row"))
    relative, _ = _commands(PB.ModalPushPull(positive))
    descriptor = DirectionalProbeBasis(IM.ZonalPushPull(amplitudes), _positive_commands(relative),
        (; kind="modal_push_pull", ordering="positive/negative per supplied modal row",
            representation="positive_commands are amplitude-scaled physical deltas; column j estimates D * (positive_commands[j,:] / mode_amplitudes[j])"))
    return relative, amplitudes, descriptor
end

function _prepare_basis(::Val{:spatial_sine}, specification, declared)
    amplitudes = _float32.(_get(declared, :mode_amplitudes), "mode amplitude")
    positions = _matrix(_get(declared, :actuator_positions), _geometry_number, "actuator positions")
    frequencies = _matrix(_get(declared, :spatial_frequencies), _geometry_number, "spatial frequencies")
    method = PB.SpatialSinusoidalPushPull(amplitudes;
        normalization=Symbol(_get(declared, :normalization)),
        minimum_sampled_peak=_get(declared, :minimum_sampled_peak))
    relative, plan = _commands(method, PB.SpatialSinusoidalSpecification(positions, frequencies))
    descriptor = DirectionalProbeBasis(IM.ZonalPushPull(amplitudes), _positive_commands(relative),
        (; kind="spatial_sinusoidal_push_pull", ordering="positive sine, negative sine, positive cosine, negative cosine per frequency",
            actuator_positions=positions, spatial_frequencies=frequencies,
            normalization=String(plan.normalization), minimum_sampled_peak=method.minimum_sampled_peak,
            planned_basis=plan.basis, planned_basis_shape=size(plan.basis), planned_basis_layout="column_major",
            sampled_peak=plan.sampled_peak, sampled_rms=plan.sampled_rms,
            coordinate_units="caller supplied; frequencies are cycles per matching position unit",
            representation="actual Float32 positive commands and mode amplitudes define the measured directions; sampled modes do not establish a physical zonal matrix or independence"))
    return relative, amplitudes, descriptor
end

function _selected_basis(specification)
    declared = _get(specification, :probe_basis)
    kind = _get(declared, :kind)
    kind in ("zonal", "hadamard", "modal", "spatial_sine") || throw(ArgumentError("unknown probe_basis kind"))
    return _prepare_basis(Val(Symbol(kind)), specification, declared)
end

"""Prepare CLI plan plus the AOC interleaved absolute probe figures.

Omitting `probe_basis` preserves the zonal contract. Explicit `kind="zonal"`
or `"hadamard"` uses top-level physical-coordinate `amplitudes`. `"modal"`
requires amplitude-scaled row-by-coordinate `positive_commands` and positive
`mode_amplitudes`. `"spatial_sine"` requires positions, frequencies, positive
mode amplitudes, normalization and minimum sampled peak; geometry is supplied
in the reference's exact coordinate order. JSON matrices are nested rows;
ordinary one-based Julia matrices and views are accepted. Reference, physical
command deltas and amplitudes share the caller's declared command units.
Both modal families estimate directions using their actual deployed Float32
commands, not a full physical D.
"""
function prepare_plan(specification)
    reference = _float32.(_get(specification, :reference), "reference")
    explicit_basis = hasproperty(specification, :probe_basis)
    if explicit_basis
        relative, amplitudes, descriptor = _selected_basis(specification)
        !isempty(reference) && size(relative, 2) == length(reference) ||
            throw(DimensionMismatch("probe commands must match the nonempty reference coordinates"))
    else
        amplitudes = _float32.(_get(specification, :amplitudes), "probe amplitude")
        !isempty(reference) && length(reference) == length(amplitudes) ||
            throw(ArgumentError("reference and amplitudes must have equal nonzero length"))
        relative, _ = _commands(PB.ZonalPushPull(amplitudes))
    end
    all(isfinite, reference) || throw(ArgumentError("reference must be finite"))
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
    estimator = explicit_basis ? _estimator(descriptor) : IM.ZonalPushPull(amplitudes)
    IM.prepare(estimator, IM.ResponseSpecification(measurements))
    plan = (; version=1, run=UInt64(_get(specification, :run)), reference,
        probes=[collect(@view figures[row, :]) for row in axes(figures, 1)],
        measurements, frames_per_probe=frames,
        settling=_get(specification, :settling),
        timeouts_ns=_get(specification, :timeouts_ns))
    plan.run > 0 || throw(ArgumentError("run must be positive"))
    prepared = (; plan, figures, reference, amplitudes, measurements, frames_per_probe=frames)
    return explicit_basis ? merge(prepared, (; probe_basis=descriptor)) : prepared
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

"""Estimate measurement-by-physical-coordinate or measurement-by-mode responses through AOC."""
function estimate_interaction_matrix(prepared, responses::AbstractMatrix)
    size(responses) == (size(prepared.figures, 1), prepared.measurements) ||
        throw(DimensionMismatch("responses must have one interleaved row per AOC probe"))
    values = _float32.(responses, "response value")
    matrix_plan = AdaptiveOpticsCalibration.prepare(
        _estimation_method(prepared), IM.ResponseSpecification(prepared.measurements))
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

_estimation_method(prepared) = hasproperty(prepared, :probe_basis) ?
    _estimator(prepared.probe_basis) : IM.ZonalPushPull(prepared.amplitudes)

_basis_name(prepared) = hasproperty(prepared, :probe_basis) ?
    prepared.probe_basis.description.kind : "zonal_push_pull"

"""Write a validated result artifact only to the caller-supplied path."""
function write_artifact(path::AbstractString, prepared, result, metadata)
    responses = validate_result(result, prepared)
    matrix = estimate_interaction_matrix(prepared, responses)
    record = (; version=1, run=prepared.plan.run,
        command_units=_get(metadata, :command_units), actuator_order=_get(metadata, :actuator_order),
        measurement_units=_get(metadata, :measurement_units), measurement_order=_get(metadata, :measurement_order),
        probe_basis=_basis_name(prepared), amplitudes=prepared.amplitudes,
        reference=prepared.reference, detector_settings=_get(metadata, :detector_settings),
        settings_identity=_get(metadata, :settings_identity), numerical_policy_identity=_get(metadata, :numerical_policy_identity),
        endpoint_identity=_get(metadata, :endpoint_identity), model_identity=_get(metadata, :model_identity),
        source_paths=_get(metadata, :source_paths), artifact_hashes=_get(metadata, :artifact_hashes),
        cli_result=_document(result),
        responses, interaction_matrix=matrix)
    if hasproperty(prepared, :probe_basis)
        basis = prepared.probe_basis
        record = merge(record, (; coordinate_kind=_coordinate_kind(basis),
            command_basis=basis.positive_commands,
            command_basis_shape=size(basis.positive_commands), command_basis_layout="column_major",
            command_basis_representation="ordered amplitude-scaled positive Float32 physical command deltas",
            basis_description=basis.description))
    end
    open(path, "w") do io
        JSON3.write(io, record)
        write(io, '\n')
    end
    return record
end

end
