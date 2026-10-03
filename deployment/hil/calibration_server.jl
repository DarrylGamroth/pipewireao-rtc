module CalibrationServer

using JSON3
using Sockets
using SHA
import ..CalibrationAcquisition

const MAX_REQUEST_BYTES = 16 * 1024
const MAX_REPLY_BYTES = 64 * 1024
const MAX_FRAMES = 4096
const MAX_PROBE = 16_383
const CLASSIC_CAPTURE_BYTES = UInt64(250_252)
const COPPER_CAPTURE_BYTES = UInt64(22_596)
const MAX_CAPTURE_SETTINGS_BYTES = 16 * 1024
const Cursor = NamedTuple{(:domain, :generation, :sequence, :model_ns),NTuple{4,UInt64}}
const Exposure = NamedTuple{(:domain, :generation, :sequence, :start_model_ns, :duration_ns),NTuple{5,UInt64}}

struct InvalidRequest <: Exception end
struct EndpointFailure <: Exception end

# These dispatch boundaries keep focused protocol tests independent of native
# endpoints. Only the serialized operational owner calls acquisition methods.
session_cursor(session) = CalibrationAcquisition.cursor(session)
session_domain(session) = session.domain
session_hold!(session) = CalibrationAcquisition.hold!(session)
session_release!(session) = CalibrationAcquisition.release!(session)
session_fault!(session) = CalibrationAcquisition.fault!(session)
session_adopt!(session, figure; timeout_ns) = CalibrationAcquisition.adopt_probe!(session, figure; timeout_ns)
session_acquire!(session; timeout_ns, require_valid) = CalibrationAcquisition.acquire_exposure!(session; timeout_ns, require_valid)
session_response_values(session) = CalibrationAcquisition.array_values(first(session.responses))
exposure_start_ns(exposure) = CalibrationAcquisition.model_nanoseconds(exposure.timestamp)
session_domain_bytes(session) = collect(session.domain.bytes)
session_profile(session) = Val(:generic)
session_profile(session::CalibrationAcquisition.AcquisitionSession) = Val(session.profile)
session_capture_values(session) = session_capture_values(session, session_profile(session))
session_capture_values(session, ::Val{:classic}) = (; raw=CalibrationAcquisition.array_values(session.raw),
    slopes=CalibrationAcquisition.array_values(session.responses[1]),
    flux=CalibrationAcquisition.array_values(session.responses[2]),
    validity=CalibrationAcquisition.array_values(session.responses[3]))
session_capture_values(session, ::Val{:copper}) = (; raw=CalibrationAcquisition.array_values(session.raw),
    pixels=CalibrationAcquisition.array_values(session.responses[1]),
    intensity=CalibrationAcquisition.array_values(session.responses[2]))
capture_write_payload(session, io, payload) = write(io, payload)

struct ClassicCaptureLayout end
struct CopperCaptureLayout end
capture_layout(::Val{:classic}) = ClassicCaptureLayout()
capture_layout(::Val{:copper}) = CopperCaptureLayout()
capture_layout(profile) = throw(ArgumentError("unsupported capture profile"))
capture_profile(::ClassicCaptureLayout) = Val(:classic)
capture_profile(::CopperCaptureLayout) = Val(:copper)
capture_profile_name(::ClassicCaptureLayout) = "classic"
capture_profile_name(::CopperCaptureLayout) = "copper"
capture_bytes(::ClassicCaptureLayout) = CLASSIC_CAPTURE_BYTES
capture_bytes(::CopperCaptureLayout) = COPPER_CAPTURE_BYTES
capture_measurements(::ClassicCaptureLayout) = 376
capture_measurements(::CopperCaptureLayout) = 3600

"""Owner-selected local capture storage. The budget counts payload bytes;
metadata is separately bounded by 16 KiB settings and 4096 bytes per frame.
Completed files remain owned and immutable until the stage consumer verifies
and reduces them after restoration/release and public shutdown.
"""
mutable struct CaptureStore{Layout}
    layout::Layout
    directory::String
    maximum_bytes::UInt64
    reserved_bytes::UInt64
    stage::String
    illumination::String
    settings_json::String
    settings_sha256::String
    pending_manifest::Union{Nothing,String}
end

function require_capture_endian(bom::UInt32)
    bom == 0x04030201 || throw(ArgumentError("capture requires a little-endian host"))
    return nothing
end

function CaptureStore(directory::AbstractString; maximum_bytes::UInt64,
    profile::Symbol=:classic, stage::AbstractString="calibration",
    illumination::Symbol=:lamp, settings=(;),
)
    require_capture_endian(Base.ENDIAN_BOM)
    layout = capture_layout(Val(profile))
    0 < maximum_bytes <= UInt64(typemax(Int64)) || throw(ArgumentError("invalid capture payload budget"))
    occursin(r"^[A-Za-z][A-Za-z0-9_-]{0,63}$", stage) || throw(ArgumentError("invalid calibration stage"))
    illumination in (:dark, :lamp) || throw(ArgumentError("invalid illumination"))
    settings_json = JSON3.write(settings)
    ncodeunits(settings_json) <= MAX_CAPTURE_SETTINGS_BYTES || throw(ArgumentError("capture settings exceed the metadata bound"))
    target = abspath(directory)
    (ispath(target) || islink(target)) && throw(ArgumentError("capture directory must be fresh"))
    # Resolve the existing parent once, then own a fresh private directory.
    target = joinpath(realpath(dirname(target)), basename(target))
    mkdir(target; mode=0o700)
    return CaptureStore(layout, target, maximum_bytes, UInt64(0), String(stage), String(illumination),
        settings_json, bytes2hex(sha256(settings_json)), nothing)
end

mutable struct Owner{Session,Domain,Capture,Profile}
    session::Session
    domain::Domain
    command_count::Int
    measurement_count::Int
    maximum_timeout_ns::UInt64
    run::UInt64
    serial::UInt64
    probe::Union{Nothing,UInt64}
    phase::Symbol
    held::Bool
    faulted::Bool
    restored::Bool
    effect_started::Bool
    capture::Capture
    profile::Profile
    adoption_sequence::UInt64
end

validate_session_measurements(::Val{:generic}, measurements) = nothing
validate_session_measurements(::Val{:classic}, measurements) = measurements == 376 ? nothing : throw(ArgumentError("Classic measurement contract differs"))
validate_session_measurements(::Val{:copper}, measurements) = measurements == 3600 ? nothing : throw(ArgumentError("Copper measurement contract differs"))
validate_session_measurements(profile, measurements) = throw(ArgumentError("unsupported acquisition profile"))
validate_capture_profile(::Val{:generic}, layout) = nothing
validate_capture_profile(::Val{:classic}, ::ClassicCaptureLayout) = nothing
validate_capture_profile(::Val{:copper}, ::CopperCaptureLayout) = nothing
validate_capture_profile(profile, layout) = throw(ArgumentError("capture and acquisition profiles differ"))
function validate_capture(profile, capture::CaptureStore, measurements)
    measurements == capture_measurements(capture.layout) || throw(ArgumentError("capture measurement contract differs"))
    validate_capture_profile(profile, capture.layout)
    return nothing
end
validate_capture(profile, ::Nothing, measurements) = nothing
owner_profile(profile, capture) = profile
owner_profile(::Val{:generic}, capture::CaptureStore) = capture_profile(capture.layout)

require_measurement_ready(profile, owner) = nothing
function require_measurement_ready(::Val{:copper}, owner)
    current_cursor(owner).sequence > owner.adoption_sequence || throw(InvalidRequest())
    return nothing
end
validate_measurement_settling(profile, rule) = nothing
function validate_measurement_settling(::Val{:copper}, rule)
    ((rule.kind == "discard_exposures" && rule.frames >= 1) ||
        (rule.kind == "model_time" && rule.duration_ns >= 1)) || throw(InvalidRequest())
    return nothing
end

"""
Prepare the protocol owner for the initial calibration topology. The normal
controller and its command producer MUST be absent; this is an explicit caller
precondition, not discovery or a physical command-ownership claim.
"""
function Owner(session; command_count::Int=277,
    measurement_count::Int,
    maximum_timeout_ns::UInt64=UInt64(10_000_000_000), normal_controller_absent::Bool,
    capture::Union{Nothing,CaptureStore}=nothing,
)
    normal_controller_absent || throw(ArgumentError("initial calibration requires the normal controller to be absent"))
    command_count > 0 && measurement_count > 0 || throw(ArgumentError("empty endpoint contract"))
    profile = session_profile(session)
    validate_session_measurements(profile, measurement_count)
    validate_capture(profile, capture, measurement_count)
    0 < maximum_timeout_ns <= UInt64(typemax(Int64)) || throw(ArgumentError("invalid maximum timeout"))
    return Owner(session, session_domain(session), command_count, measurement_count,
        maximum_timeout_ns, UInt64(0), UInt64(0), nothing, :initial, false, false, false, false, capture,
        owner_profile(profile, capture), UInt64(0))
end

"""Prepare ordinary acquisition endpoints; the launcher still owns graph links/startup."""
function prepare_owner(plant, driver, profile; rate, normal_controller_absent::Bool, kwargs...)
    normal_controller_absent || throw(ArgumentError("initial calibration requires the normal controller to be absent"))
    session = CalibrationAcquisition.prepare_session(plant, driver, profile; rate)
    try
        return Owner(session; normal_controller_absent, kwargs...)
    catch
        CalibrationAcquisition.close_session!(session)
        rethrow()
    end
end

function fault!(owner::Owner)
    owner.faulted = true
    owner.held = true
    owner.restored = false
    owner.phase = :fault
    owner.probe = nothing
    session_fault!(owner.session)
    return nothing
end

_fields(value::JSON3.Object, names) = length(value) == length(names) &&
    Set(String.(keys(value))) == Set(names) ? nothing : throw(InvalidRequest())
_fields(value, names) = throw(InvalidRequest())
_integer(value::Bool, minimum, maximum) = throw(InvalidRequest())
_integer(value::Integer, minimum, maximum) = minimum <= value <= maximum ? UInt64(value) : throw(InvalidRequest())
_integer(value, minimum, maximum) = throw(InvalidRequest())
_number(value::Bool) = throw(InvalidRequest())
_number(value::Real) = isfinite(value) && isfinite(Float32(value)) ? Float32(value) : throw(InvalidRequest())
_number(value) = throw(InvalidRequest())
_kind(value::AbstractString) = String(value)
_kind(value) = throw(InvalidRequest())

function figure_type(action)
    values = action.figure
    _figure(values)
    return Vector{Float32}
end
function _figure(values::JSON3.Array)
    isempty(values) && throw(InvalidRequest())
    foreach(_number, values)
    return nothing
end
_figure(values) = throw(InvalidRequest())

function cursor_type(cursor)
    _fields(cursor, ("domain", "generation", "sequence", "model_ns"))
    _integer(cursor.domain, 1, typemax(UInt64))
    _integer(cursor.generation, 1, typemax(UInt64))
    _integer(cursor.sequence, 0, typemax(UInt64))
    _integer(cursor.model_ns, 0, typemax(Int64))
    return Cursor
end

function rule_type(rule)
    kind = _kind(rule.kind)
    if kind == "immediate"
        _fields(rule, ("kind",))
        return NamedTuple{(:kind,),Tuple{String}}
    elseif kind == "discard_exposures"
        _fields(rule, ("kind", "frames"))
        _integer(rule.frames, 1, MAX_FRAMES)
        return NamedTuple{(:kind, :frames),Tuple{String,UInt32}}
    elseif kind == "model_time"
        _fields(rule, ("kind", "duration_ns"))
        _integer(rule.duration_ns, 1, typemax(Int64))
        return NamedTuple{(:kind, :duration_ns),Tuple{String,UInt64}}
    end
    throw(InvalidRequest())
end

function action_type(action)
    kind = _kind(action.kind)
    if kind in ("hold", "release")
        _fields(action, ("kind",))
        return NamedTuple{(:kind,),Tuple{String}}
    elseif kind == "adopt"
        _fields(action, ("kind", "probe", "figure"))
        _integer(action.probe, 0, MAX_PROBE)
        return NamedTuple{(:kind, :probe, :figure),Tuple{String,UInt64,figure_type(action)}}
    elseif kind == "settle"
        _fields(action, ("kind", "probe", "after", "rule"))
        _integer(action.probe, 0, MAX_PROBE)
        return NamedTuple{(:kind, :probe, :after, :rule),Tuple{String,UInt64,cursor_type(action.after),rule_type(action.rule)}}
    elseif kind == "collect"
        _fields(action, ("kind", "probe", "after", "measurements", "frames"))
        _integer(action.probe, 0, MAX_PROBE)
        _integer(action.measurements, 1, MAX_REPLY_BYTES)
        _integer(action.frames, 1, MAX_FRAMES)
        return NamedTuple{(:kind, :probe, :after, :measurements, :frames),Tuple{String,UInt64,cursor_type(action.after),UInt64,UInt64}}
    elseif kind == "capture"
        _fields(action, ("kind", "probe", "after", "frames"))
        _integer(action.probe, 0, MAX_PROBE)
        _integer(action.frames, 1, MAX_FRAMES)
        return NamedTuple{(:kind, :probe, :after, :frames),Tuple{String,UInt64,cursor_type(action.after),UInt64}}
    elseif kind == "restore"
        _fields(action, ("kind", "figure", "rule"))
        return NamedTuple{(:kind, :figure, :rule),Tuple{String,figure_type(action),rule_type(action.rule)}}
    end
    throw(InvalidRequest())
end

"""Validate version-one records, retaining integer JSON token types at every level."""
function parse_request(payload::AbstractString)
    ncodeunits(payload) + 1 <= MAX_REQUEST_BYTES || throw(InvalidRequest())
    try
        parsed = JSON3.read(payload)
        _fields(parsed, ("version", "run", "serial", "timeout_ns", "action"))
        _integer(parsed.version, 1, 1)
        _integer(parsed.run, 1, typemax(UInt64))
        _integer(parsed.serial, 1, typemax(UInt64))
        _integer(parsed.timeout_ns, 1, typemax(Int64))
        action = action_type(parsed.action)
        # Untyped JSON3 can normalize 7.0 to an integer. A typed parse of the
        # original bytes rejects floats/exponents masquerading as identities.
        return JSON3.read(payload, NamedTuple{(:version, :run, :serial, :timeout_ns, :action),Tuple{UInt8,UInt64,UInt64,UInt64,action}})
    catch
        throw(InvalidRequest())
    end
end

function remaining(until::UInt64)
    now = time_ns()
    now < until || throw(EndpointFailure())
    return until - now
end

function current_cursor(owner::Owner)
    session_domain(owner.session) == owner.domain || throw(EndpointFailure())
    cursor = session_cursor(owner.session)
    cursor.domain == 1 && cursor.generation > 0 && cursor.model_ns <= UInt64(typemax(Int64)) || throw(EndpointFailure())
    return Cursor((cursor.domain, cursor.generation, cursor.sequence, cursor.model_ns))
end

function same_cursor(owner, after)
    current_cursor(owner) == after || throw(InvalidRequest())
    return nothing
end

function exposure!(owner, until, check_connection; require_valid)
    check_connection()
    previous = current_cursor(owner)
    timeout_ns = remaining(until)
    owner.effect_started = true
    receipt = session_acquire!(owner.session; timeout_ns, require_valid)
    remaining(until)
    check_connection()
    exposure = receipt.exposure
    exposure.identity.domain == owner.domain || throw(EndpointFailure())
    start = exposure_start_ns(exposure)
    start >= 0 || throw(EndpointFailure())
    duration = exposure.exposure_duration_nanoseconds
    duration > 0 || throw(EndpointFailure())
    model_end = Base.checked_add(UInt64(start), duration)
    cursor = current_cursor(owner)
    cursor.generation == previous.generation == exposure.identity.generation &&
        exposure.identity.sequence == Base.checked_add(previous.sequence, UInt64(1)) == cursor.sequence &&
        UInt64(start) >= previous.model_ns && cursor.model_ns == model_end || throw(EndpointFailure())
    receipt.valid === true || (!require_valid && receipt.valid === false) || throw(EndpointFailure())
    record = Exposure((UInt64(1), exposure.identity.generation, exposure.identity.sequence, UInt64(start), duration))
    return (; record, valid=receipt.valid)
end

function settling_boundary(cursor, rule)
    if rule.kind == "model_time"
        rule.duration_ns <= UInt64(typemax(Int64)) - cursor.model_ns || throw(InvalidRequest())
        return cursor.model_ns + rule.duration_ns
    elseif rule.kind == "discard_exposures"
        UInt64(rule.frames) <= typemax(UInt64) - cursor.sequence || throw(InvalidRequest())
    elseif rule.kind != "immediate"
        throw(InvalidRequest())
    end
    return cursor.model_ns
end

function settle!(owner, rule, until, check_connection;
    boundary::UInt64=settling_boundary(current_cursor(owner), rule),
)
    if rule.kind == "discard_exposures"
        for _ in 1:rule.frames
            exposure!(owner, until, check_connection; require_valid=false)
        end
    elseif rule.kind == "model_time"
        while current_cursor(owner).model_ns < boundary
            exposure!(owner, until, check_connection; require_valid=false)
        end
    end
    remaining(until)
    check_connection()
    return current_cursor(owner)
end

function adopted!(owner, figure, until, check_connection)
    length(figure) == owner.command_count || throw(InvalidRequest())
    check_connection()
    before = current_cursor(owner)
    timeout_ns = remaining(until)
    owner.effect_started = true
    result = session_adopt!(owner.session, figure; timeout_ns)
    remaining(until)
    check_connection()
    result.cursor == current_cursor(owner) && result.cursor == before || throw(EndpointFailure())
    length(result.figure) == owner.command_count && all(isfinite, result.figure) || throw(EndpointFailure())
    typeof(result.clipped) === Bool || throw(EndpointFailure())
    result.clipped || reinterpret(UInt32, result.figure) == reinterpret(UInt32, figure) || throw(EndpointFailure())
    return result
end

function collect!(owner, action, until, check_connection)
    require_measurement_ready(owner.profile, owner)
    action.measurements == owner.measurement_count || throw(InvalidRequest())
    # Worst-case finite Float32 tokens and UInt64 identity fields fit the reply
    # before any model side effect. The encoded bound is checked again below.
    512 + 16 * action.measurements + 180 * action.frames <= MAX_REPLY_BYTES || throw(InvalidRequest())
    sums = zeros(Float64, owner.measurement_count)
    exposures = Vector{Exposure}(undef, Int(action.frames))
    valid = true
    for index in eachindex(exposures)
        # A complete finite but quality-invalid WFS response is evidence for an
        # invalid batch, not an unknown transport outcome. Keep every requested
        # exposure so the coordinator can reject the batch and restore safely.
        receipt = exposure!(owner, until, check_connection; require_valid=false)
        exposures[index] = receipt.record
        valid &= receipt.valid
        values = session_response_values(owner.session)
        length(values) == owner.measurement_count && all(isfinite, values) || throw(EndpointFailure())
        for measurement in eachindex(sums, values)
            sums[measurement] += Float64(values[measurement])
        end
    end
    values = Float32.(sums ./ action.frames)
    all(isfinite, values) || throw(EndpointFailure())
    remaining(until)
    return (; kind="responses", values, exposures, valid)
end

function capture_file!(owner, directory, name, values::StridedVector{T}, element_type, shape,
    until, check_connection,
) where {T}
    length(values) == prod(shape) && stride(values, 1) == 1 || throw(EndpointFailure())
    all(isfinite, values) || throw(EndpointFailure())
    remaining(until)
    check_connection()
    # Direct borrowed packed storage; it cannot be rearmed until this write returns.
    payload = reinterpret(UInt8, values)
    path = joinpath(directory, name)
    (ispath(path) || islink(path)) && throw(EndpointFailure())
    written = open(path, "w") do io
        capture_write_payload(owner.session, io, payload)
    end
    written == length(payload) && filesize(path) == length(payload) || throw(EndpointFailure())
    remaining(until)
    check_connection()
    return (; path=name, element_type, shape, layout="ROW_MAJOR",
        bytes=length(payload), sha256=bytes2hex(sha256(payload)))
end

function capture_frame!(owner, directory, until, check_connection)
    values = session_capture_values(owner.session)
    return capture_frame_payload!(owner, directory, values, until, check_connection)
end

capture_frame_payload!(owner, directory, values, until, check_connection) =
    capture_frame_payload!(owner.capture.layout, owner, directory, values, until, check_connection)
function capture_frame_payload!(::ClassicCaptureLayout, owner, directory,
    values::NamedTuple{(:raw, :slopes, :flux, :validity),Tuple{R,S,F,V}},
    until, check_connection,
) where {R<:StridedVector{UInt16},S<:StridedVector{Float32},F<:StridedVector{Float32},V<:StridedVector{Bool}}
    return (;
        raw=capture_file!(owner, directory, "raw.u16le", values.raw, "U16_LE", [352, 352], until, check_connection),
        slopes=capture_file!(owner, directory, "slopes.f32le", values.slopes, "F32_LE", [188, 2], until, check_connection),
        flux=capture_file!(owner, directory, "flux.f32le", values.flux, "F32_LE", [188], until, check_connection),
        validity=capture_file!(owner, directory, "validity.u8", values.validity, "BOOL8", [188], until, check_connection))
end
function capture_frame_payload!(::CopperCaptureLayout, owner, directory,
    values::NamedTuple{(:raw, :pixels, :intensity),Tuple{R,P,I}},
    until, check_connection,
) where {R<:StridedVector{UInt16},P<:StridedVector{Float32},I<:StridedVector{Float32}}
    return (;
        raw=capture_file!(owner, directory, "raw.u16le", values.raw, "U16_LE", [64, 64], until, check_connection),
        pixels=capture_file!(owner, directory, "pixels.f32le", values.pixels, "F32_LE", [4, 900], until, check_connection),
        intensity=capture_file!(owner, directory, "intensity.f32le", values.intensity, "F32_LE", [1], until, check_connection))
end
capture_frame_payload!(layout, owner, directory, values, until, check_connection) = throw(EndpointFailure())

function capture_domain_bytes(domain::AbstractVector{UInt8})
    length(domain) == 16 || throw(EndpointFailure())
    return collect(domain)
end
capture_domain_bytes(domain) = throw(EndpointFailure())

function discard_pending_manifest!(owner)
    store = owner.capture
    store === nothing && return nothing
    if store.pending_manifest !== nothing
        rm(store.pending_manifest; force=true)
        store.pending_manifest = nothing
    end
    return nothing
end

function capture!(owner, action, until, check_connection)
    require_measurement_ready(owner.profile, owner)
    store = owner.capture
    store === nothing && throw(InvalidRequest())
    payload_bytes = capture_bytes(store.layout)
    bytes = Base.checked_mul(payload_bytes, action.frames)
    bytes <= store.maximum_bytes - store.reserved_bytes || throw(InvalidRequest())
    action.frames <= typemax(UInt64) - current_cursor(owner).sequence || throw(InvalidRequest())
    domain = capture_domain_bytes(session_domain_bytes(owner.session))
    directory = joinpath(store.directory, string(owner.serial))
    islink(store.directory) && throw(EndpointFailure())
    (ispath(directory) || islink(directory)) && throw(InvalidRequest())
    remaining(until)
    check_connection()
    mkdir(directory; mode=0o700)
    owner.effect_started = true
    store.reserved_bytes += bytes
    records = map(1:Int(action.frames)) do index
        receipt = exposure!(owner, until, check_connection; require_valid=false)
        frame_directory = joinpath(directory, string(index))
        mkdir(frame_directory; mode=0o700)
        files = capture_frame!(owner, frame_directory, until, check_connection)
        sum(file.bytes for file in files) == payload_bytes || throw(EndpointFailure())
        (; receipt.record..., valid=receipt.valid, directory=string(index), files)
    end
    manifest = (; version=1, run=owner.run, serial=owner.serial, probe=action.probe,
        stage=store.stage, illumination=store.illumination, profile=capture_profile_name(store.layout),
        settings=JSON3.read(store.settings_json), settings_sha256=store.settings_sha256,
        acquisition_domain_mapping=(; opaque_domain=UInt64(1), complete_domain=domain),
        frames=action.frames, bytes, exposures=records)
    encoded = JSON3.write(manifest) * "\n"
    ncodeunits(encoded) <= MAX_CAPTURE_SETTINGS_BYTES + 4096 * action.frames || throw(EndpointFailure())
    temporary = joinpath(directory, "manifest.partial.json")
    open(temporary, "w") do io
        write(io, encoded) == ncodeunits(encoded) || throw(EndpointFailure())
    end
    remaining(until)
    check_connection()
    completed = joinpath(directory, "manifest.json")
    store.pending_manifest = completed
    mv(temporary, completed; force=false)
    remaining(until)
    check_connection()
    return (; kind="captured", cursor=current_cursor(owner),
        manifest=string(owner.serial, "/manifest.json"), sha256=bytes2hex(sha256(encoded)),
        frames=action.frames, bytes, metadata_bytes=ncodeunits(encoded))
end

function effect!(owner, action, until, check_connection)
    kind = action.kind
    if kind == "hold"
        owner.phase == :initial || throw(InvalidRequest())
        owner.effect_started = true
        cursor = session_hold!(owner.session)
        cursor == current_cursor(owner) || throw(EndpointFailure())
        owner.held = true
        owner.phase = :held
        return (; kind="held", cursor)
    elseif kind == "restore"
        owner.phase == :released && throw(InvalidRequest())
        length(action.figure) == owner.command_count || throw(InvalidRequest())
        # Validate the complete settling range before replacing the held figure.
        # A rejected request must leave the prior probe association truthful.
        boundary = settling_boundary(current_cursor(owner), action.rule)
        remaining(until)
        check_connection()
        owner.effect_started = true
        owner.probe = nothing
        owner.phase = :restoring
        if !owner.held
            session_hold!(owner.session)
            owner.held = true
        end
        owner.restored = false
        result = adopted!(owner, action.figure, until, check_connection)
        settle!(owner, action.rule, until, check_connection; boundary)
        if result.clipped
            fault!(owner)
        else
            owner.restored = true
            owner.phase = :restored
        end
        return (; kind="restored", figure=result.figure, clipped=result.clipped)
    elseif kind == "release"
        owner.held && owner.restored && owner.phase == :restored || throw(InvalidRequest())
        remaining(until)
        check_connection()
        owner.effect_started = true
        session_release!(owner.session)
        owner.held = false
        owner.phase = :released
        return (; kind="released")
    end
    owner.held || throw(InvalidRequest())
    if kind == "adopt"
        owner.phase in (:held, :collected) || throw(InvalidRequest())
        expected_probe = owner.probe === nothing ? UInt64(0) : Base.checked_add(owner.probe, UInt64(1))
        action.probe == expected_probe || throw(InvalidRequest())
        result = adopted!(owner, action.figure, until, check_connection)
        owner.probe = action.probe
        owner.adoption_sequence = result.cursor.sequence
        owner.phase = :adopted
        owner.restored = false
        return (; kind="adopted", cursor=result.cursor, figure=result.figure, clipped=result.clipped)
    end
    action.probe == owner.probe || throw(InvalidRequest())
    same_cursor(owner, action.after)
    if kind == "settle"
        owner.phase == :adopted || throw(InvalidRequest())
        validate_measurement_settling(owner.profile, action.rule)
        cursor = settle!(owner, action.rule, until, check_connection)
        require_measurement_ready(owner.profile, owner)
        owner.phase = :settled
        return (; kind="settled", cursor)
    elseif kind == "collect"
        owner.phase == :settled || throw(InvalidRequest())
        result = collect!(owner, action, until, check_connection)
        owner.phase = :collected
        return result
    elseif kind == "capture"
        owner.phase == :settled || throw(InvalidRequest())
        result = capture!(owner, action, until, check_connection)
        owner.phase = :collected
        return result
    end
    throw(InvalidRequest())
end

function execute!(owner::Owner, request; started::UInt64=time_ns(), check_connection=() -> nothing)
    failure(reason) = (; version=1, run=request.run, serial=request.serial,
        result=(; kind="failed", reason))
    owner.faulted && return failure("endpoint")
    if request.timeout_ns > owner.maximum_timeout_ns ||
       (owner.run != 0 && request.run != owner.run) || request.serial <= owner.serial ||
       (owner.run == 0 && !(request.action.kind in ("hold", "restore")))
        return failure("invalid_evidence")
    end
    owner.run = request.run
    owner.serial = request.serial
    owner.effect_started = false
    try
        until = Base.checked_add(started, request.timeout_ns)
        remaining(until)
        check_connection()
        result = effect!(owner, request.action, until, check_connection)
        remaining(until)
        check_connection()
        return (; version=1, run=request.run, serial=request.serial, result)
    catch exception
        reason = failure_reason!(owner, exception)
        discard_pending_manifest!(owner)
        return failure(reason)
    finally
        owner.effect_started = false
        owner.capture === nothing || (owner.capture.pending_manifest = nothing)
    end
end

function failure_reason!(owner, ::InvalidRequest)
    owner.effect_started || return "invalid_evidence"
    # Once an endpoint effect begins, even a validation exception has an
    # operational outcome. The old probe can no longer authorize collection.
    fault!(owner)
    return "endpoint"
end
function failure_reason!(owner, exception)
    fault!(owner)
    return "endpoint"
end

function encode_reply(reply)
    payload = JSON3.write(reply)
    ncodeunits(payload) + 1 <= MAX_REPLY_BYTES || throw(EndpointFailure())
    return payload * "\n"
end

"""Read one bounded record. Closing the socket interrupts an incomplete record."""
function read_record(socket; timeout_ns::UInt64)
    0 < timeout_ns <= UInt64(typemax(Int64)) || throw(ArgumentError("invalid I/O timeout"))
    timer = Timer(Float64(timeout_ns) / 1e9) do _
        close(socket)
    end
    bytes = UInt8[]
    sizehint!(bytes, MAX_REQUEST_BYTES)
    try
        for _ in 1:MAX_REQUEST_BYTES
            byte = read(socket, UInt8)
            byte == UInt8('\n') && return String(bytes)
            push!(bytes, byte)
        end
        throw(InvalidRequest())
    finally
        close(timer)
    end
end

function check_reader(reader)
    istaskdone(reader) || return nothing
    # EOF/timeout and pipelined requests are rejected before the owner can
    # acknowledge another model operation or release command ownership.
    fetch(reader)
    throw(EndpointFailure())
end

function service_owner!(should_stop, service_control)
    service_control()
    should_stop() && throw(EndpointFailure())
    return nothing
end

function wait_io(task, should_stop, service_control)
    while !istaskdone(task)
        service_owner!(should_stop, service_control)
        # Control-plane interruption only. This poll never establishes science,
        # adoption, settling or acquisition completion.
        sleep(0.005)
    end
    service_owner!(should_stop, service_control)
    return fetch(task)
end

"""Serve one client/run; socket readers observe I/O only, never AOS state."""
function serve_connection!(owner::Owner, socket; io_timeout_ns::UInt64=owner.maximum_timeout_ns,
    should_stop=() -> false, service_control=() -> nothing, admission_enabled=() -> true,
)
    reader = @async read_record(socket; timeout_ns=io_timeout_ns)
    check_connection = () -> begin
        service_owner!(should_stop, service_control)
        check_reader(reader)
    end
    try
        while owner.phase != :released
            payload = wait_io(reader, should_stop, service_control)
            started = time_ns()
            request = parse_request(payload)
            until = Base.checked_add(started, request.timeout_ns)
            reader = @async read_record(socket; timeout_ns=io_timeout_ns)
            reply = if !admission_enabled() && !(request.action.kind in ("restore", "release"))
                (; version=1, run=request.run, serial=request.serial,
                    result=(; kind="failed", reason="cancelled"))
            else
                execute!(owner, request; started, check_connection)
            end
            timer = Timer(Float64(remaining(until)) / 1e9) do _
                close(socket)
            end
            try
                # Accepted PipeEndpoints are unbuffered: write waits for the
                # complete libuv write and reports its byte count. A separate
                # flush issues another write that can fail after a client has
                # already consumed the terminal ACK and closed normally.
                payload = encode_reply(reply)
                write(socket, payload) == ncodeunits(payload) || throw(EndpointFailure())
                remaining(until)
            finally
                close(timer)
            end
        end
        return owner
    catch
        fault!(owner)
        rethrow()
    finally
        close(socket)
        try
            fetch(reader)
        catch
        end
    end
end

"""Serve a published listener; start the finite client budget after admission."""
function serve!(owner::Owner, listener::Sockets.PipeServer;
    accept_timeout_ns::UInt64=owner.maximum_timeout_ns, kwargs...,
)
    0 < accept_timeout_ns <= UInt64(typemax(Int64)) || throw(ArgumentError("invalid accept timeout"))
    should_stop = get(kwargs, :should_stop, () -> false)
    service_control = get(kwargs, :service_control, () -> nothing)
    admission_enabled = get(kwargs, :admission_enabled, () -> true)
    timer = pending = nothing
    try
        # The launcher bounds graph preparation and keeps acquisition paused.
        # Publishing the listener is readiness evidence, not client admission.
        while !admission_enabled()
            service_owner!(should_stop, service_control)
            sleep(0.005)
        end
        service_owner!(should_stop, service_control)
        timer = Timer(Float64(accept_timeout_ns) / 1e9) do _
            close(listener)
        end
        pending = @async accept(listener)
        socket = wait_io(pending, should_stop, service_control)
        close(timer)
        return serve_connection!(owner, socket; kwargs...)
    catch
        fault!(owner)
        rethrow()
    finally
        timer === nothing || close(timer)
        close(listener)
        if pending !== nothing
            try
                socket = fetch(pending)
                isopen(socket) && close(socket)
            catch
            end
        end
    end
end

"""Accept one client within a finite setup budget; refuse an existing socket path."""
function serve!(owner::Owner, path::AbstractString; kwargs...)
    ispath(path) && throw(ArgumentError("calibration socket path already exists"))
    listener = listen(path)
    try
        return serve!(owner, listener; kwargs...)
    finally
        close(listener)
        rm(path; force=true)
    end
end

end
