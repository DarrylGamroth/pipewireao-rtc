#!/usr/bin/env julia
include("calibration_owner.jl")
include("heart_calibration_telemetry.jl")

module HeartCalibrationOwner

using PipeWireAO, AdaptiveOpticsSimPipeWireHIL, SHA, Sockets
using AdaptiveOpticsSim.AlgorithmGraphs
import ..CalibrationAcquisition, ..CalibrationServer, ..HeartCalibrationTelemetry
import ..Protocol
const Acquisition = CalibrationAcquisition
const Telemetry = HeartCalibrationTelemetry

struct NativeHold
    child_pid::Int
    generation::Int
    run_acknowledged::Bool
    endpoints_acknowledged::Bool
    endpoint_enable_command::String
    endpoint_reply_sha256::String
    admitted_frames::UInt64
    ingress_mode::String
    ingress_environment::String
end

mutable struct Session{Plant,Driver,Source,Sink,Options,Domain,Service}
    plant::Plant
    driver::Driver
    source::Source
    dm_sink::Sink
    options::Options
    domain::Domain
    state::Acquisition.AcquisitionState
    active::Union{Nothing,Vector{Bool}}
    diagnostics::Acquisition.ExposureDiagnostics
    native_controller_held::Union{Nothing,NativeHold}
    readers::Dict{String,Telemetry.TelemetryReader}
    native_dm_bucket::Union{Nothing,UInt64}
    association::Telemetry.FrameAssociation
    native_command_serial::UInt64
    receive_task::Union{Nothing,Task}
    service::Service
    raw::Vector{UInt16}
    values::Vector{Float32}
    flux::Vector{Float32}
    validity::Vector{Bool}
    intensity::Vector{Float32}
    pupil_locations::Vector{Tuple{Int,Int}}
    previous_intensity::Float32
    evidence_count::UInt64
    evidence_bytes::UInt64
end

function require_usable(session)
    Acquisition.require_usable(session)
    session.service()
    proof = session.native_controller_held
    if proof !== nothing
        status_path = joinpath(session.options.heart_native_runtime, "heart-owner-status.json")
        filesize(status_path) <= 64 * 1024 || error("native owner status exceeds its bound")
        status = Protocol.JSON3.read(read(status_path, String))
        get(status, :generation, nothing) == proof.generation &&
            get(status, :child_pid, nothing) == proof.child_pid &&
            status.native_ingress.mode == proof.ingress_mode &&
            status.native_ingress.observed_environment == proof.ingress_environment &&
            isdir("/proc/$(proof.child_pid)") || error("native HEART owner generation changed or exited")
    end
    return nothing
end

const MAX_COMMAND_REPLY_BYTES = 64 * 1024

function bounded_text(path, maximum_bytes=MAX_COMMAND_REPLY_BYTES)
    isfile(path) || return (; text="", truncated=false)
    bytes = open(path) do io
        read(io, maximum_bytes + 1)
    end
    truncated = length(bytes) > maximum_bytes
    resize!(bytes, min(length(bytes), maximum_bytes))
    return (; text=String(bytes), truncated)
end

function require_command_success(name, result)
    output = result.stdout * result.stderr
    result.exitcode == 0 && result.termsignal == 0 && result.failure === nothing &&
        !result.truncated && occursin("ack<0><ACCEPTED>", output) &&
        occursin("status<0><SUCCESS>", output) && return nothing
    error("native HEART $name did not acknowledge SUCCESS; exit=$(result.exitcode) " *
        "signal=$(result.termsignal) failure=$(result.failure) truncated=$(result.truncated) " *
        "evidence=$(result.path)\nstdout:\n$(result.stdout)\nstderr:\n$(result.stderr)")
end

function native_command!(session, name, extra, until)
    session.service()
    session.native_command_serial = Base.checked_add(session.native_command_serial, UInt64(1))
    path = joinpath(session.options.heart_probe_directory, "command-$(session.native_command_serial).log")
    paths = (path, path * ".stderr", path * ".json")
    any(ispath, paths) && error("native command evidence already exists")
    argv = [session.options.heart_client, "-cmdName", name, "-address", "127.0.0.1", "-port", "5001", extra...]
    process = nothing
    failure = nothing
    open(paths[1], "w") do stdout
        open(paths[2], "w") do stderr
            try
                process = run(pipeline(Cmd(Cmd(argv); dir=session.options.heart_native_runtime);
                    stdin=devnull, stdout, stderr); wait=false)
                while process_running(process)
                    Acquisition.remaining(until)
                    session.service()
                    filesize(paths[1]) + filesize(paths[2]) <= MAX_COMMAND_REPLY_BYTES ||
                        error("native command reply exceeds its bound")
                    sleep(0.001)
                end
                wait(process)
                Acquisition.remaining(until)
            catch exception
                failure = sprint(showerror, exception)
            finally
                if process !== nothing && process_running(process)
                    kill(process, Base.SIGKILL)
                    wait(process)
                end
            end
        end
    end
    stdout = bounded_text(paths[1])
    stderr = bounded_text(paths[2], MAX_COMMAND_REPLY_BYTES - ncodeunits(stdout.text))
    if stdout.truncated || stderr.truncated
        # Keep the persistent files within the same total reply budget even if
        # a process wrote a burst between size checks.
        write(paths[1], stdout.text)
        write(paths[2], stderr.text)
    end
    result = (; name, argv, path, exitcode=process === nothing ? nothing : process.exitcode,
        termsignal=process === nothing ? nothing : process.termsignal, failure,
        stdout=stdout.text, stderr=stderr.text, truncated=stdout.truncated || stderr.truncated)
    Protocol.write_json_atomic(paths[3], result)
    require_command_success(name, result)
    return path
end

function retain_startup_failure(options, exception; session=nothing)
    directory = options.heart_probe_directory
    isdir(directory) || return nothing
    snapshots = Dict{String,Any}()
    for name in ("heart-owner-status.json", "command-1-CORRECT.log", "command-1-CORRECT.log.stderr", "heart-1.log")
        source = joinpath(options.heart_native_runtime, name)
        isfile(source) || continue
        content = bounded_text(source)
        destination = joinpath(directory, "startup-" * name)
        write(destination, content.text)
        snapshots[name] = (; path=destination, bytes=ncodeunits(content.text), truncated=content.truncated,
            sha256=bytes2hex(sha256(content.text)))
    end
    Protocol.write_json_atomic(joinpath(directory, "owner-failure.json"),
        (; version=1, phase="before_owner_admission", failure=sprint(showerror, exception),
            native_controller_held=session === nothing ? nothing : session.native_controller_held,
            admitted_frames=session === nothing ? nothing : Acquisition.cursor(session).sequence,
            native_runtime=options.heart_native_runtime, snapshots))
    return nothing
end

function startup_enable_proof(options, status)
    get(status, :generation, nothing) === 1 && get(status, :sequence, nothing) === 0 &&
        get(status, :state, nothing) == "paused" && get(status, :error, "missing") === nothing &&
        get(status, :child_returncode, "missing") === nothing ||
        error("endpoint enable proof requires successful fresh native owner startup")
    source = joinpath(options.heart_native_runtime, "command-1-CORRECT.log")
    isfile(source) && isfile(source * ".stderr") || error("native startup CORRECT reply is absent")
    stdout = bounded_text(source)
    stderr = bounded_text(source * ".stderr", MAX_COMMAND_REPLY_BYTES - ncodeunits(stdout.text))
    output = stdout.text * stderr.text
    !stdout.truncated && !stderr.truncated && occursin("ack<0><ACCEPTED>", output) &&
        occursin("status<0><SUCCESS>", output) || error("native startup CORRECT did not acknowledge SUCCESS")
    # HeartOwner.start requires command exit zero and both ACK markers before
    # publishing this successful generation's status. CORRECT enables endpoints
    # through its scoped helper; RUN preserves enables and holds integration.
    write(joinpath(options.heart_probe_directory, "startup-CORRECT.log"), stdout.text)
    write(joinpath(options.heart_probe_directory, "startup-CORRECT.log.stderr"), stderr.text)
    Protocol.write_json_atomic(joinpath(options.heart_probe_directory, "startup-owner-status.json"), status)
    return bytes2hex(sha256(output))
end

const NATIVE_TELEMETRY_TAGS = ("cbHoPixelsRaw0", "cbHoPixelsCalib0", "cbHoGrad0", "cbDmCmd0")
recording_arguments() = ["-configTelemEnable", "1", "-configTelemCbNames", join(NATIVE_TELEMETRY_TAGS, ',')]

function telemetry_paths(runtime, tag)
    tag in NATIVE_TELEMETRY_TAGS || error("unsupported native telemetry tag")
    # hrtTelemetry_canonicalBaseFileName prefixes date/time; startFile appends
    # block state and an ISO time. The decoder checks the header tag separately.
    pattern = Regex("^\\d{4}-\\d{2}-\\d{2}_\\d{2}-\\d{2}-\\d{2}_" * tag * "_.+\\.tel\$" )
    return filter(path -> occursin(pattern, basename(path)), readdir(runtime; join=true))
end

function validate_ingress_status(status, mode)
    mode in ("streaming", "deferred") || throw(ArgumentError("invalid native calibration ingress mode"))
    ingress = get(status, :native_ingress, nothing)
    ingress !== nothing && get(ingress, :mode, nothing) == mode &&
        get(ingress, :environment_key, nothing) == "HRT_DEFER_WFS_INGRESS" &&
        get(ingress, :observed_environment, nothing) == (mode == "deferred" ? "1" : "0") ||
        error("native supervised ingress mode or actual environment differs")
    return String(ingress.observed_environment)
end

function hold_native!(session; timeout_ns::UInt64)
    until = Acquisition.deadline(timeout_ns)
    status_path = joinpath(session.options.heart_native_runtime, "heart-owner-status.json")
    filesize(status_path) <= 64 * 1024 || error("native owner status exceeds its bound")
    status = Protocol.JSON3.read(read(status_path, String))
    get(status, :generation, nothing) === 1 && get(status, :sequence, nothing) === 0 &&
        get(status, :error, "missing") === nothing || error("calibration requires a fresh supervised HEART child")
    pid = get(status, :child_pid, nothing)
    pid isa Integer && pid > 0 && isdir("/proc/$pid") || error("native HEART child is absent")
    Acquisition.cursor(session).sequence == 0 &&
        pipewire_calibration_status(session.plant).pending_exposure === nothing ||
        error("native hold must precede every admitted exposure")
    ingress_mode = session.options.heart_native_ingress_mode
    observed_environment = validate_ingress_status(status, ingress_mode)
    enable_reply_sha256 = startup_enable_proof(session.options, status)
    native_command!(session, "RUN", String[], until)
    # In native RUN, WFS input/proc have f_running processing; TFC f_running
    # is NULL and CLWC f_running performs state changes without integration.
    session.native_controller_held = NativeHold(Int(pid), 1, true, true, "startup CORRECT", enable_reply_sha256, 0, ingress_mode, observed_environment)
    native_command!(session, "SET_TELM_RECORD", recording_arguments(), until)
    session.state.held = true
    return nothing
end

function read_native!(session, tag, datatype, shape, until)
    reader = get(session.readers, tag, nothing)
    while reader === nothing
        Acquisition.remaining(until)
        session.service()
        paths = telemetry_paths(session.options.heart_native_runtime, tag)
        length(paths) <= 1 || error("multiple native telemetry files for $tag; fresh instance required")
        if length(paths) == 1 && filesize(only(paths)) >= 1024
            reader = Telemetry.TelemetryReader(only(paths); tag, datatype, shape,
                maximum_bytes=session.options.heart_telemetry_max_bytes)
            session.readers[tag] = reader
        else
            sleep(0.001)
        end
    end
    return Telemetry.await_frame!(reader; timeout_ns=Acquisition.remaining(until), service=session.service)
end

function prepare_session(plant, driver, options; active, adc_bits, service)
    source = sink = nothing
    try
        rate = plant.configuration.rate
        format = NdArrayFormat(NdArray.F32_LE, (277,); rate, layout=NdArray.ROW_MAJOR)
        source = NdArraySource(plant.core, "heart-calibration-probe", zeros(Float32, 277), format;
            schema="org.heart.std-dm.actuator-command/1")
        sink = NdArraySink(plant.core, "heart-calibration-command", zeros(Float32, 277), format;
            schema="org.heart.std-dm.actuator-command/1")
        extent = options.profile === :classic ? 352 : 64
        locations = options.profile === :copper ? read_pupil_locations(options.heart_native_runtime) : Tuple{Int,Int}[]
        return Session(plant, driver, source, sink, options,
            pipewire_calibration_status(plant).acquisition_domain, Acquisition.AcquisitionState(), active,
            Acquisition.ExposureDiagnostics(adc_bits), nothing, Dict{String,Telemetry.TelemetryReader}(), nothing,
            Telemetry.FrameAssociation(), UInt64(0), nothing, service, zeros(UInt16, extent^2),
            zeros(Float32, options.profile === :classic ? 376 : 3600), zeros(Float32, 188), fill(false, 188),
            zeros(Float32, 1), locations, 0.0f0, UInt64(0), UInt64(0))
    catch
        Acquisition.close_endpoints((sink, source))
        rethrow()
    end
end

function read_pupil_locations(runtime)
    path = joinpath(runtime, "config", "pwfsRoiOffsets_64.csv")
    filesize(path) <= 4096 || error("native pupil location declaration exceeds its bound")
    lines = split(chomp(read(path, String)), '\n')
    length(lines) == 5 && split(lines[1]) == ["4", "2", "1", "uint"] || error("unsupported native pupil location CSV")
    locations = map(lines[2:end]) do line
        values = parse.(Int, split(strip(line), ','))
        length(values) == 2 && all(value -> 0 <= value <= 34, values) || error("native pupil extent escapes the detector")
        (values[1], values[2])
    end
    config_path = joinpath(runtime, "config", "heart.yaml")
    filesize(config_path) <= 1024 * 1024 || error("native configuration exceeds its bound")
    config = read(config_path, String)
    occursin(r"PWFS_QUAD_SIZE:\s*\[\s*\{[^}]*ROWS:\s*30,\s*COLS:\s*30"s, config) &&
        occursin(r"(?m)^\s*PWFS_GRAD_TYPE:\s*1\s*$", config) &&
        occursin(r"(?m)^\s*PWFS_QUAD_PIXEL_MASK_FILE:\s*\[\s*\{\s*WFS_NUM:\s*0,\s*FILE:\s*\"\"\s*\}\s*\]", config) &&
        occursin(r"(?m)^\s*PWFS_QUAD_LOCATION_FILE:\s*\[\s*\{\s*WFS_NUM:\s*0,\s*FILE:\s*\"\./config/pwfsRoiOffsets_64.csv\"\s*\}\s*\]", config) ||
        error("unsupported native Copper pupil/frontend declaration")
    return locations
end

function record_evidence!(session, record)
    bytes = Vector{UInt8}(Protocol.JSON3.write(record) * "\n")
    next_bytes = Base.checked_add(session.evidence_bytes, UInt64(length(bytes)))
    next_bytes <= session.options.heart_telemetry_max_bytes || error("native evidence exceeds its byte budget")
    path = joinpath(session.options.heart_probe_directory, "native-evidence.jsonl")
    islink(path) && error("native evidence path became a symlink")
    if session.evidence_count == 0
        ispath(path) && error("native evidence already exists")
    else
        filesize(path) == session.evidence_bytes || error("native evidence file changed")
    end
    open(path, "a") do io
        write(io, bytes)
    end
    session.evidence_count = Base.checked_add(session.evidence_count, UInt64(1))
    session.evidence_bytes = next_bytes
    return nothing
end

function endpoint_status(endpoint)
    try
        return (; node_id=node_id(endpoint), state=stream_state(endpoint.stream))
    catch exception
        return (; failure=sprint(showerror, exception))
    end
end

function stage_event!(session, sequence, stage, disposition; detail=nothing, kind="adoption_stage")
    record_evidence!(session, (; kind, sequence, stage, disposition,
        observed_monotonic_ns=time_ns(), detail,
        native_sink=hasproperty(session, :dm_sink) ? endpoint_status(session.dm_sink) : nothing,
        relay_source=hasproperty(session, :source) ? endpoint_status(session.source) : nothing,
        scope="transport progress only; does not establish scientific freshness"))
end

function adoption_stage(f, session, sequence, stage)
    stage_event!(session, sequence, stage, "entered")
    try
        value = f()
        stage_event!(session, sequence, stage, "completed")
        return value
    catch exception
        stage_event!(session, sequence, stage, "failed"; detail=sprint(showerror, exception))
        rethrow()
    end
end

function telemetry_status(session)
    map(NATIVE_TELEMETRY_TAGS) do tag
        paths = telemetry_paths(session.options.heart_native_runtime, tag)
        files = map(paths) do path
            islink(path) && error("native telemetry status path is a symlink")
            bytes = filesize(path)
            bytes <= session.options.heart_telemetry_max_bytes || error("native telemetry status exceeds its byte budget")
            committed = bytes >= Telemetry.FILE_HEADER_BYTES ? open(path) do io
                header = read(io, Telemetry.FILE_HEADER_BYTES)
                length(header) == Telemetry.FILE_HEADER_BYTES || error("native telemetry status header shrank")
                Telemetry.value_at(UInt64, header, 144)
            end : nothing
            (; name=basename(path), bytes, committed)
        end
        (; tag, files)
    end
end

function retain_primary_failure!(session, sequence, stage, exception)
    path = joinpath(session.options.heart_probe_directory, "primary-failure.json")
    ispath(path) && return nothing
    message = sprint(showerror, exception)
    Protocol.write_json_atomic(path, (; version=1, sequence, stage,
        failure=first(message, min(length(message), 8192))))
    return nothing
end

function primary_failure(options, fallback)
    path = joinpath(options.heart_probe_directory, "primary-failure.json")
    isfile(path) || return fallback
    !islink(path) && filesize(path) <= 64 * 1024 || error("primary native failure exceeds its bound")
    return String(Protocol.JSON3.read(read(path, String)).failure)
end

function exposure_stage(f, session, sequence, stage)
    stage_event!(session, sequence, stage, "entered"; kind="exposure_stage")
    try
        value = f()
        detail = value isa Telemetry.TelemetryFrame ? (; bucket=value.bucket, sync=value.sync,
            native_timestamp_us=value.timestamp_us) : nothing
        stage_event!(session, sequence, stage, "completed"; kind="exposure_stage", detail)
        return value
    catch exception
        retain_primary_failure!(session, sequence, stage, exception)
        snapshot = try telemetry_status(session) catch diagnostic_error
            (; failure=sprint(showerror, diagnostic_error))
        end
        stage_event!(session, sequence, stage, "failed"; kind="exposure_stage",
            detail=(; failure=sprint(showerror, exception), telemetry=snapshot))
        rethrow()
    end
end

struct RelayProbe{Session,Figure}
    session::Session
    figure::Figure
    sequence::UInt64
    until::UInt64
end

function (submit::RelayProbe)()
    session = submit.session
    token = submit_array!(session.source, submit.figure,
        BufferHeader(UInt32(0), UInt32(0), Int64(0), Int64(0), submit.sequence))
    stage_event!(session, submit.sequence, "relay_submit", "completed"; detail=(; token))
    session.state.publication = @async begin
        path = joinpath(session.options.heart_probe_directory, "relay-$(submit.sequence)-source-ack.json")
        try
            wait_array_source!(session.source, token; timeout_ns=Acquisition.remaining(submit.until))
            # Dedicated immutable publication witness avoids concurrent updates
            # to the owner's sequential JSONL evidence counters.
            Protocol.write_json_atomic(path, (; sequence=submit.sequence, token, state="completed",
                observed_monotonic_ns=time_ns(), scope="source queue publication only"))
            Acquisition.drive_until_receipt!(session, session.source.stream, submit.until)
        catch exception
            Protocol.write_json_atomic(path, (; sequence=submit.sequence, token, state="failed",
                failure=sprint(showerror, exception), observed_monotonic_ns=time_ns()))
            rethrow()
        end
    end
    return nothing
end

function retain_native_telemetry(options)
    root = joinpath(options.heart_probe_directory, "native-telemetry")
    ispath(root) && error("native telemetry snapshot already exists")
    mkdir(root; mode=0o700)
    records = NamedTuple[]
    for tag in NATIVE_TELEMETRY_TAGS
        paths = telemetry_paths(options.heart_native_runtime, tag)
        length(paths) <= 1 || error("multiple native telemetry files while retaining evidence")
        for source in paths
            islink(source) && error("native telemetry file is a symlink")
            bytes = filesize(source)
            0 <= bytes <= options.heart_telemetry_max_bytes || error("native telemetry snapshot exceeds its byte budget")
            destination = joinpath(root, basename(source))
            open(source, "r") do input
                open(destination, "w") do output
                    remaining = bytes
                    while remaining > 0
                        block = read(input, min(remaining, 64 * 1024))
                        isempty(block) && error("native telemetry shrank while retaining evidence")
                        write(output, block)
                        remaining -= length(block)
                    end
                end
            end
            push!(records, (; name=basename(source), bytes, sha256=bytes2hex(open(sha256, destination))))
        end
    end
    Protocol.write_json_atomic(joinpath(root, "snapshot.json"), (; version=1,
        scope="bounded file snapshot before owner close; partial final publication is preserved", records))
    return records
end

function retain_native_logs(options)
    root = joinpath(options.heart_probe_directory, "native-logs")
    ispath(root) && error("native log snapshot already exists")
    mkdir(root; mode=0o700)
    records = NamedTuple[]
    for name in ("heart-1.log", "heart-owner-status.json")
        source = joinpath(options.heart_native_runtime, name)
        isfile(source) || continue
        islink(source) && error("native log snapshot path is a symlink")
        content = bounded_text(source)
        destination = joinpath(root, name)
        write(destination, content.text)
        push!(records, (; name, bytes=ncodeunits(content.text), source_bytes=filesize(source),
            truncated=content.truncated, sha256=bytes2hex(sha256(content.text))))
    end
    Protocol.write_json_atomic(joinpath(root, "snapshot.json"), (; version=1, records,
        scope="bounded visible native log prefix before owner close; buffered unwritten output is unavailable"))
    return records
end

function start_session!(session)
    start!(session.source)
    start!(session.dm_sink)
    start!(session.plant)
    return session
end

function wait_native_receipt!(session, until)
    session.receive_task = @async wait_array_sink!(session.dm_sink; timeout_ns=Acquisition.remaining(until))
    while !istaskdone(session.receive_task)
        Acquisition.remaining(until)
        session.service()
        with_thread_loop_lock(main_loop(session.plant.frame_stream)) do _
            trigger_process!(session.plant.frame_stream)
        end
        sleep(0.001)
    end
    receipt = fetch(session.receive_task)
    session.receive_task = nothing
    receipt.header.sequence == 0 || error("native probe receipt is not the held zero-ID profile")
    return copy(array_values(session.dm_sink))
end

const MAX_NATIVE_PROBE_PATH_BYTES = 127

function native_probe_path(directory, sequence::UInt64)
    path = joinpath(directory, "probe-$sequence.csv")
    ncodeunits(path) <= MAX_NATIVE_PROBE_PATH_BYTES ||
        throw(ArgumentError("native DM probe path exceeds the 127-byte public client limit"))
    return path
end

function Acquisition.adopt_probe!(session::Session, figure::Vector{Float32}; timeout_ns::UInt64)
    require_usable(session)
    session.state.held || error("native calibration command ownership is not held")
    session.association.pending === nothing || error("native exposure is outstanding")
    length(figure) == 277 && all(isfinite, figure) || error("invalid physical command figure")
    until = Acquisition.deadline(timeout_ns)
    sequence = Base.checked_add(session.state.probe_sequence, UInt64(1))
    path = native_probe_path(session.options.heart_probe_directory, sequence)
    (ispath(path) || islink(path)) && error("native probe file already exists")
    try
        open(path, "w") do io
            println(io, "277 1 1 float")
            foreach(value -> println(io, value), figure)
        end
        arm_array_sink!(session.dm_sink, UInt64(0); allow_zero_sequence=true)
        native_command!(session, "DM_SHAPE", ["-configDmSelect", "0", "-configDmShape", "1",
            "-configDmFilename", path], until)
        received = adoption_stage(session, sequence, "native_std_dm_receipt") do
            wait_native_receipt!(session, until)
        end
        native = adoption_stage(session, sequence, "native_dm_bucket") do
            read_native!(session, "cbDmCmd0", 20, (277, 1), until)
        end
        native.bucket == Telemetry.next_bucket(session.native_dm_bucket) && native.sync == 0 ||
            error("native DM command bucket differs from the serialized held probe")
        Telemetry.confirm_probe(native, figure, received)
        submit = RelayProbe(session, received, sequence, until)
        session.state.progressing[] = true
        adoption_stage(session, sequence, "plant_probe_adoption") do
            adopt_pipewire_probe!(session.plant, sequence; submit, timeout_ns=Acquisition.remaining(until))
        end
        Acquisition.finish_progress!(session)
        adopted = copy(pipewire_probe_values(session.plant))
        reinterpret(UInt32, adopted) == reinterpret(UInt32, received) || error("adopted plant figure differs from the native receipt")
        final = Telemetry.confirm_probe(native, figure, adopted)
        Acquisition.remaining(until)
        session.state.probe_sequence = sequence
        session.native_dm_bucket = native.bucket
        stage_event!(session, sequence, "plant_figure_verified", "completed")
        record_evidence!(session, (; kind="adopted", sequence, native_bucket=native.bucket,
            native_sync=native.sync, native_timestamp_us=native.timestamp_us,
            requested_sha256=bytes2hex(sha256(reinterpret(UInt8, figure))),
            adopted_sha256=bytes2hex(sha256(reinterpret(UInt8, final.figure))), clipped=final.clipped))
        return (; cursor=Acquisition.cursor(session), figure=final.figure, clipped=final.clipped)
    catch exception
        session.state.progressing[] = false
        stage_event!(session, sequence, "adoption", "failed"; detail=sprint(showerror, exception))
        Acquisition.fault!(session)
        rethrow()
    end
end

function arm_native_exposure!(session, exposure)
    frame = hil_frame_buffer(session.plant.boundary)
    extent = session.options.profile === :classic ? 352 : 64
    size(frame) == (extent, extent) || error("native detector extent differs")
    index = 1
    for row in axes(frame, 1), column in axes(frame, 2)
        value = frame[row, column]
        isfinite(value) && 0 <= value <= typemax(UInt16) || error("invalid normal ADC code")
        session.raw[index] = round(UInt16, value)
        index += 1
    end
    start = model_nanoseconds(exposure.timestamp)
    start >= 0 || error("negative model exposure timestamp")
    record = (; domain=UInt64(1), generation=exposure.identity.generation,
        sequence=exposure.identity.sequence, start_model_ns=UInt64(start),
        duration_ns=exposure.exposure_duration_nanoseconds)
    Telemetry.arm_exposure!(session.association, record, session.raw)
    stage_event!(session, record.sequence, "normal_detector_staged", "completed"; kind="exposure_stage",
        detail=(; record..., raw_sha256=bytes2hex(sha256(reinterpret(UInt8, session.raw)))))
    return nothing
end

function pupil_intensity(frame, locations)
    # Native WfsInput finalizeFrame sets calibrated duration before advancing,
    # so advanceWriter may preserve a zero usecTime. This auxiliary ROI mean
    # relies on READY/progress and the caller's exact raw bucket/sync fence.
    frame.spec.tag == "cbHoPixelsCalib0" && frame.spec.datatype == 8 &&
        (frame.spec.rows, frame.spec.columns) == (64, 64) && frame.state == 2 &&
        frame.progress == frame.required && frame.timestamp_us >= 0 ||
        error("native calibrated pupil frame is incomplete or differs from the declared contract")
    total = 0.0
    for (row, column) in locations, dy in 0:29, dx in 0:29
        value = Telemetry.value_at(Float32, frame.payload, 4((row + dy) * 64 + column + dx))
        isfinite(value) || error("nonfinite native calibrated pupil pixel")
        total += value
    end
    result = Float32(total / 3600)
    isfinite(result) || error("nonfinite native pupil mean")
    return result
end

function Acquisition.acquire_exposure!(session::Session; timeout_ns::UInt64, require_valid=true)
    require_usable(session)
    session.state.held || error("native calibration command ownership is not held")
    until = Acquisition.deadline(timeout_ns)
    sequence = Base.checked_add(session.state.cursor_sequence, UInt64(1))
    try
        exposure = exposure_stage(session, sequence, "plant_frame_publication") do
            step_pipewire_exposure!(session.plant, session.driver;
                before_publish=exposure -> arm_native_exposure!(session, exposure), timeout_ns=Acquisition.remaining(until))
        end
        session.state.progressing[] = true
        session.state.publication = @async Acquisition.drive_until_receipt!(session, session.plant.frame_stream, until)
        extent = session.options.profile === :classic ? 352 : 64
        raw = exposure_stage(session, sequence, "native_raw_bucket") do
            read_native!(session, "cbHoPixelsRaw0", 7, (extent, extent), until)
        end
        calibrated = if session.options.profile === :copper
            exposure_stage(session, sequence, "native_calibrated_bucket") do
                frame = read_native!(session, "cbHoPixelsCalib0", 8, (64, 64), until)
                frame.bucket == raw.bucket && frame.sync == raw.sync || error("native calibrated frame association differs")
                frame
            end
        else
            nothing
        end
        datatype, shape = session.options.profile === :classic ? (13, (188, 1)) : (8, (3600, 1))
        measurement = exposure_stage(session, sequence, "native_measurement_bucket") do
            read_native!(session, "cbHoGrad0", datatype, shape, until)
        end
        witness = exposure_stage(session, sequence, "native_frame_association") do
            Telemetry.associate!(session.association, raw, measurement)
        end
        valid = exposure_stage(session, sequence, "native_response_decode") do
            if session.options.profile === :classic
                response = Telemetry.classic_response(measurement; order=session.options.heart_classic_order,
                    scale=session.options.heart_slope_scale, active=session.active)
                copyto!(session.values, response.slopes)
                copyto!(session.flux, response.flux)
                copyto!(session.validity, response.validity)
                response.valid
            else
                response = Telemetry.copper_response(measurement)
                copyto!(session.values, response.pixels)
                session.intensity[1] = pupil_intensity(calibrated, session.pupil_locations)
                response_valid = response.valid && session.previous_intensity > 0 && session.intensity[1] > 0
                session.previous_intensity = session.intensity[1]
                response_valid
            end
        end
        exposure_stage(session, sequence, "native_response_validity") do
            require_valid && !valid && error("invalid native WFS response")
            valid
        end
        exposure_stage(session, sequence, "plant_frame_receipt") do
            Acquisition.finish_progress!(session)
        end
        exposure_stage(session, sequence, "plant_exposure_completion") do
            complete_pipewire_exposure!(session.plant, exposure.identity)
        end
        session.state.cursor_sequence = exposure.identity.sequence
        session.state.cursor_model_ns = session.association.model_end_ns
        Acquisition.record_exposure!(session.diagnostics, session.raw, valid)
        record_evidence!(session, (; kind="exposure", probe_sequence=exposure.probe_sequence, witness..., valid,
            measurement_sha256=bytes2hex(sha256(measurement.payload)),
            calibrated_sha256=calibrated === nothing ? nothing : bytes2hex(sha256(calibrated.payload))))
        Acquisition.remaining(until)
        return (; exposure, valid)
    catch
        session.state.progressing[] = false
        Acquisition.fault!(session)
        rethrow()
    end
end

function Acquisition.hold!(session::Session)
    require_usable(session)
    session.native_controller_held !== nothing || error("native integration hold is absent")
    session.state.held = true
    return Acquisition.cursor(session)
end
function Acquisition.release!(session::Session)
    require_usable(session)
    session.association.pending === nothing && session.receive_task === nothing || error("native work remains outstanding")
    pipewire_calibration_status(session.plant).pending_exposure === nothing || error("plant exposure remains outstanding")
    session.state.publication === nothing || error("probe publication remains outstanding")
    # This initial-calibration session finishes in native RUN and shuts down.
    # Ordinary correction is a separately prepared fresh deployment.
    session.state.held = false
    return nothing
end

function Acquisition.close_session!(session::Session)
    session.state.closed && return nothing
    session.state.closed = true
    session.state.progressing[] = false
    try
        Acquisition.close_endpoints((session.dm_sink, session.source))
    finally
        try
            for task in (session.receive_task, session.state.publication)
                task === nothing || try fetch(task) catch end
            end
            foreach(close, values(session.readers))
        finally
            close(session.plant)
        end
    end
    return nothing
end

CalibrationServer.session_profile(session::Session) = Val(session.options.profile)
CalibrationServer.session_response_values(session::Session) = session.values
CalibrationServer.session_capture_values(session::Session, ::Val{:classic}) =
    (; raw=session.raw, slopes=session.values, flux=session.flux, validity=session.validity)
CalibrationServer.session_capture_values(session::Session, ::Val{:copper}) =
    (; raw=session.raw, pixels=session.values, intensity=session.intensity)

function CalibrationServer.Owner(session::Session; measurement_count::Int,
    maximum_timeout_ns::UInt64, capture=nothing, native_controller_held::Bool,
)
    proof = session.native_controller_held
    native_controller_held && proof !== nothing && proof.generation == 1 &&
        proof.run_acknowledged && proof.endpoints_acknowledged &&
        proof.endpoint_enable_command == "startup CORRECT" && occursin(r"^[0-9a-f]{64}$", proof.endpoint_reply_sha256) &&
        proof.admitted_frames == 0 && proof.ingress_mode in ("streaming", "deferred") &&
        proof.ingress_environment == (proof.ingress_mode == "deferred" ? "1" : "0") &&
        session.state.held && Acquisition.cursor(session).sequence == 0 ||
        throw(ArgumentError("native initial calibration requires an established fresh-child hold"))
    profile = CalibrationServer.session_profile(session)
    CalibrationServer.validate_session_measurements(profile, measurement_count)
    CalibrationServer.validate_capture(profile, capture, measurement_count)
    0 < maximum_timeout_ns <= UInt64(typemax(Int64)) || throw(ArgumentError("invalid native owner timeout"))
    return CalibrationServer.Owner(session, session.domain, 277, measurement_count, maximum_timeout_ns,
        UInt64(0), UInt64(0), nothing, :initial, false, false, false, false, capture, profile, UInt64(0))
end

function options(arguments)
    iseven(length(arguments)) || throw(ArgumentError("each option requires one value"))
    native = Dict{String,String}()
    ordinary = String[]
    names = ("heart-client", "heart-native-runtime", "heart-probe-directory", "heart-telemetry-max-bytes",
        "heart-slope-scale-x", "heart-slope-scale-y", "heart-classic-order", "heart-native-ingress-mode")
    for index in 1:2:length(arguments)
        name, value = arguments[index], arguments[index + 1]
        key = startswith(name, "--") ? name[3:end] : ""
        if key in names
            haskey(native, key) && throw(ArgumentError("duplicate $name"))
            isempty(value) && throw(ArgumentError("empty $name"))
            native[key] = value
        else
            append!(ordinary, [name, value])
        end
    end
    all(name -> haskey(native, name), names[1:4]) || throw(ArgumentError("missing native HEART owner options"))
    prepared = Main.calibration_options(ordinary; required_transport=:heart)
    ingress_mode = get(native, "heart-native-ingress-mode", "streaming")
    ingress_mode in ("streaming", "deferred") || throw(ArgumentError("invalid native calibration ingress mode"))
    ingress_mode == "deferred" && prepared.profile !== :copper && throw(ArgumentError("deferred native ingress requires Copper"))
    client, runtime, directory = abspath.([native[name] for name in names[1:3]])
    native_probe_path(directory, typemax(UInt64)) # Reserve every serialized probe filename before any child command.
    isfile(client) && stat(client).mode & 0o111 != 0 || throw(ArgumentError("native HEART client is absent or not executable"))
    !ispath(directory) && !islink(directory) && isdir(dirname(directory)) ||
        throw(ArgumentError("native probe directory must be fresh"))
    budget = tryparse(UInt64, native["heart-telemetry-max-bytes"])
    budget !== nothing && 1024 <= budget <= UInt64(typemax(Int64)) || throw(ArgumentError("invalid native telemetry budget"))
    scales = Tuple(parse(Float64, get(native, name, "1.0")) for name in names[5:6])
    all(isfinite, scales) && all(!iszero, scales) || throw(ArgumentError("native Classic scales must be finite and nonzero"))
    order = if haskey(native, "heart-classic-order")
        path = abspath(native["heart-classic-order"])
        filesize(path) == 188 * 4 || throw(ArgumentError("native Classic order requires 188 U32_LE indices"))
        bytes = read(path)
        length(bytes) == 188 * 4 || throw(ArgumentError("native Classic order requires 188 U32_LE indices"))
        Int.(ltoh.(reinterpret(UInt32, bytes)))
    else
        collect(1:188)
    end
    sort(order) == collect(1:188) || throw(ArgumentError("native Classic order is not a permutation"))
    return merge(prepared, (; heart_client=client, heart_native_runtime=runtime,
        heart_probe_directory=directory, heart_telemetry_max_bytes=budget,
        heart_slope_scale=scales, heart_classic_order=order, heart_native_ingress_mode=ingress_mode))
end

function report(options, science, state, owner; failure=nothing)
    base = Main.calibration_report(options, science, state, owner; failure=primary_failure(options, failure))
    session = owner.session
    return merge(base, (; engine="heart", native_controller_held=session.native_controller_held,
        command_transport_units="native micrometre OPD; relayed metre OPD", plant_command_units="metre OPD",
        native_classic_order=options.heart_classic_order, native_classic_scale=options.heart_slope_scale,
        native_copper_normalization="previous completed native pupil mean; cbHoGrad0 preserved",
        native_evidence=(; path=joinpath(options.heart_probe_directory, "native-evidence.jsonl"),
            records=session.evidence_count, bytes=session.evidence_bytes,
            sha256=session.evidence_count == 0 ? nothing : bytes2hex(open(sha256,
                joinpath(options.heart_probe_directory, "native-evidence.jsonl")))),
        qualification="native operational calibration evidence; scientific agreement and rate require separate acceptance"))
end

function run_owner(options, plant_module, target)
    mkdir(options.heart_probe_directory; mode=0o700)
    science = Acquisition.prepare_science(options.graph, plant_module, target, options.profile;
        period_ns=options.period_ns, illumination=options.illumination)
    Acquisition.validate_exposure_duration(science.detector_config, options.exposure_ns)
    active = Main.calibration_active(options)
    active = Acquisition.prepare_active(Val(options.profile), active)
    Protocol.write_json_atomic(options.prepared_event, (; version=1, state="prepared", sequence=0))
    Main.wait_for_connect(options) || return nothing
    configuration = PipeWireHILConfiguration(remote=options.remote, frame_node_name="simulator-wfs",
        command_node_name="simulator-command", frame_schema="org.heart.std-wfs.raw-pixels/1",
        command_schema="org.heart.std-dm.actuator-command/1", rate=SPA.Fraction(UInt32(options.rate), UInt32(1)),
        exposure_duration_ns=options.exposure_ns, frame_encoding=:uint16, command_scale=1.0f0,
        timeout_ns=30_000_000_000)
    plant = prepare_pipewire_calibration(science.boundary, configuration)
    session = owner = listener = nothing
    state = Protocol.OwnerState()
    failure = nothing
    last_payload = Ref{Union{Nothing,String}}(nothing)
    service_control = () -> begin
        isfile(options.control_request) || return nothing
        payload = open(options.control_request) do io
            String(read(io, Protocol.MAX_REQUEST_BYTES + 1))
        end
        payload == last_payload[] && return nothing
        last_payload[] = payload
        state.sequence = Acquisition.cursor(session).sequence
        reply = try
            Protocol.control!(state, payload, time_ns(), options.period_ns,
                () -> error("native calibration reset requires a fresh instance"))
        catch exception
            Protocol.response(state, state.last_request_id, "reset"; error=sprint(showerror, exception))
        end
        Protocol.write_json_atomic(options.control_reply, reply)
        Protocol.write_json_atomic(options.output, report(options, science, state, owner))
        nothing
    end
    service = () -> begin
        isfile(options.quit_request) && error("native calibration interrupted by shutdown")
        owner === nothing || service_control()
        nothing
    end
    try
        session = prepare_session(plant, science.driver, options; active, adc_bits=science.detector_config["bits"], service)
        start_session!(session)
        hold_native!(session; timeout_ns=UInt64(30_000_000_000))
        capture = options.capture_directory === nothing ? nothing : CalibrationServer.CaptureStore(
            options.capture_directory; maximum_bytes=options.capture_max_bytes, profile=options.profile,
            stage=options.calibration_stage, illumination=options.illumination,
            settings=(; detector_config=science.detector_config,
                graph_sha256=bytes2hex(open(sha256, options.graph)),
                wfs_active_sha256=active === nothing ? nothing : bytes2hex(sha256(UInt8.(active)))))
        owner = CalibrationServer.Owner(session; native_controller_held=true,
            measurement_count=options.profile === :classic ? 376 : 3600,
            maximum_timeout_ns=UInt64(30_000_000_000), capture)
        mkpath(dirname(options.calibration_socket))
        listener = listen(options.calibration_socket)
        Protocol.write_json_atomic(options.output, report(options, science, state, owner))
        Protocol.write_json_atomic(options.connect_reply, (; version=1, state="connected", sequence=0))
        CalibrationServer.serve!(owner, listener; accept_timeout_ns=UInt64(30_000_000_000),
            should_stop=() -> isfile(options.quit_request), service_control, admission_enabled=() -> state.running)
        state.running = false
        state.completed = true
        state.sequence = Acquisition.cursor(session).sequence
        Protocol.write_json_atomic(options.output, report(options, science, state, owner))
        while !isfile(options.quit_request)
            service_control()
            sleep(0.005)
        end
    catch exception
        failure = sprint(showerror, exception)
        owner === nothing || CalibrationServer.fault!(owner)
        owner === nothing && retain_startup_failure(options, exception; session)
        rethrow()
    finally
        state.running = false
        try
            try
                retain_native_telemetry(options)
                retain_native_logs(options)
            catch exception
                Protocol.write_json_atomic(joinpath(options.heart_probe_directory, "telemetry-retention-failure.json"),
                    (; failure=sprint(showerror, exception)))
            end
            if owner !== nothing
                final_report = report(options, science, state, owner; failure)
                Protocol.write_json_atomic(options.output, final_report)
                Protocol.write_json_atomic(joinpath(options.heart_probe_directory, "owner-report.json"), final_report)
            end
        finally
            listener === nothing || close(listener)
            ispath(options.calibration_socket) && rm(options.calibration_socket)
            session === nothing ? close(plant) : Acquisition.close_session!(session)
        end
    end
    return nothing
end

function main(arguments=ARGS)
    prepared = options(arguments)
    Protocol.require_fresh_instance(prepared)
    return Base.invokelatest(run_owner, prepared, Main.load_plant(prepared.profile), Main.load_target(prepared.backend))
end

end

abspath(PROGRAM_FILE) == (@__FILE__) && HeartCalibrationOwner.main()
