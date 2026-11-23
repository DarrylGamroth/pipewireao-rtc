# Observe the declared queues of one installed RTC on an explicit private remote.
using PipeWireAORTC
using PipeWireAO
using PipeWireAO_jll

const RTC = PipeWireAORTC
include("classic_observation.jl")

function queue_spec(session, core, name, stem, media)
    sink = only(row for row in session["sinks"] if row["node.name"] == stem * "-queue-input")
    port = only(sink["ports"])
    output = stem * "-queue-output"
    modules = core["context.modules"]
    queue = only(
        row["args"] for row in modules if
        get(row, "name", "") == "libpipewire-module-queue" &&
        get(get(row["args"], "playback.props", Dict()), "node.name", "") == output
    )
    queue["queue.max-buffers"] == 1 &&
        queue["queue.storage"] == "copy" &&
        queue["queue.overflow"] == "drop-oldest" ||
        error("Unexpected queue storage policy for $output")
    queue["playback.props"]["media.name"] == media || error("Unexpected media name for $output")
    wire = getproperty(NdArray, Symbol(port["element-type"]))
    type = wire == NdArray.U16_LE ? UInt16 : Float32
    wire in (NdArray.U16_LE, NdArray.F32_LE) || error("Unsupported element type for $output")
    get(port, "layout", "ROW_MAJOR") == "ROW_MAJOR" || error("Unexpected layout for $output")
    rate = get(port, "rate", nothing)
    return (name = name, node = output, media = media, type, wire,
        shape = Tuple(Int.(port["shape"])), schema = port["schema"],
        rate = rate === nothing ? nothing : SPA.Fraction(parse.(Int, split(rate, '/'))...))
end

function probe_specs(profile, app)
    prefix = PipeWireAO_jll.artifact_dir
    deployment = RTC.Common.read_json(joinpath(app, "deployment.conf"))
    expected_name = get(Dict("spiders" => "spiders-fitted-dual",
        "spiders-single" => "spiders-fitted-exposure"), profile, profile)
    deployment["name"] == expected_name || error("Application profile mismatch")
    session = RTC.DeploymentConfiguration.decode(joinpath(app, deployment["session"]), prefix)
    core = RTC.DeploymentConfiguration.decode(joinpath(app, deployment["core"]), prefix)
    declarations = if profile == "gpi2"
        (("detector", "simulator-detector", "detector-image"),
            ("woofer", "rtc-woofer-command", "woofer-command"),
            ("tweeter", "rtc-tweeter-command", "tweeter-command"),
            ("tiptilt", "rtc-tiptilt-command", "tiptilt-command"))
    elseif profile == "spiders"
        (("demand", "spiders-scc-dm-command", "spiders-scc-dm-command"),
            ("applied", "spiders-dm-applied", "spiders-dm-applied"))
    elseif profile == "spiders-single"
        (("demand", "spiders-scc-dm-command", "spiders-scc-dm-command"),)
    elseif profile == "cal2"
        Tuple((name, "cal2-" * name, "cal2-" * name) for name in
            ("scc-image", "llowfs-image", "scc-physical-offset", "llowfs-physical-offset"))
    else
        error("Unsupported profile $profile")
    end
    return map(d -> queue_spec(session, core, d...), declarations), session
end

function write_record(directory, name, record)
    path = joinpath(directory, name * ".json")
    RTC.Common.write_json(path, record; atomic = true)
    return nothing
end

function phase!(directory, name)
    println(name)
    flush(stdout)
    touch(joinpath(directory, name))
    return nothing
end

function stream_progress(specs, captures)
    return Dict(
        spec.name => Dict(
            "first_header_sequence" => c.first_sequence,
            "last_header_sequence" => c.header === nothing ? nothing : c.header.sequence,
            "buffers_seen" => c.count,
            "distinct_header_sequences" => c.distinct_sequences,
            "header_sequence_gaps" => c.header === nothing ? nothing :
                c.header.sequence - c.first_sequence + 1 - c.distinct_sequences,
            "last_acquisition_identity" => _classic_identity_record(c.identity),
            "max_abs_payload" => maximum(abs, c.values),
        ) for (spec, c) in zip(specs, captures)
    )
end

function common_identities(captures)
    groups = map(captures) do capture
        Set(identity for identity in capture.identities if identity !== nothing)
    end
    return sort!(collect(reduce(intersect, groups)); by = id -> id.sequence)
end

mutable struct FlowHandshake
    cancelled::Bool
    running::Bool
    stopped::Bool
    progress::Union{Nothing,Dict{String,Any}}
    observed::Union{Nothing,Dict{String,Any}}
    quiet::Union{Nothing,Dict{String,Any}}
end

FlowHandshake() = FlowHandshake(false, false, false, nothing, nothing, nothing)

function watch_handshake!(handshake, directory)
    sent = false
    while !handshake.cancelled
        handshake.running = isfile(joinpath(directory, "running"))
        handshake.stopped = isfile(joinpath(directory, "stopped"))
        if handshake.progress !== nothing
            progress = handshake.progress
            handshake.progress = nothing
            println("progress ", join(("$name=$(fields["distinct_header_sequences"])" for
                (name, fields) in sort!(collect(progress); by = first)), " "))
            flush(stdout)
            write_record(directory, "progress", Dict("streams" => progress))
        end
        if !sent && handshake.observed !== nothing
            write_record(directory, "running", handshake.observed)
            sent = true
            phase!(directory, "observed")
        end
        sleep(0.01)
    end
    return nothing
end

function record_camera!(capture, metadata, cursor)
    identity = something(capture.identity)
    timing = something(exposure_timing(metadata))
    timing.has_duration && timing.duration_nanoseconds == 2_000_000 &&
        capture.header.pts == Int64((identity.sequence - 1) * 2_000_000) ||
        error("CAL2 LLOWFS exposure is outside the staged sequence window")
    identity.sequence >= cursor[] || error("CAL2 LLOWFS acquisition sequence regressed")
    cursor[] = identity.sequence
    return nothing
end

function record_chopping!(capture, metadata, phases, first_fringed, high_is_fringed, duration)
    identity = something(capture.identity)
    timing = something(exposure_timing(metadata))
    # HIL publishes the model exposure start in Header PTS and the duration
    # in the exposure metadata record.
    start = capture.header.pts
    timing.has_duration && timing.duration_nanoseconds == duration &&
        start >= 0 && start % duration == 0 ||
        error("CAL2 SCC exposure is outside a declared chopper window")
    fringed = iseven(div(start, duration)) == first_fringed
    optical = optical_classification(metadata)
    trigger = trigger_classification(metadata)
    optical == (fringed ? OPTICAL_FRINGED : OPTICAL_UNFRINGED) &&
        trigger == (fringed == high_is_fringed ? ACQUISITION_TRIGGER_HIGH : ACQUISITION_TRIGGER_LOW) ||
        error("CAL2 SCC optical or electrical classification differs from its chopper window")
    haskey(phases, optical) || (phases[optical] = Dict(
        "identity" => _classic_identity_record(identity),
        "start_ns" => start,
        "duration_ns" => timing.duration_nanoseconds,
        "trigger" => string(trigger),
    ))
    return nothing
end

function observe_flow(profile, app, remote, directory, specs; pupil_owner = nothing, pupil = nothing)
    timeout = parse(Float64, get(ENV, "RTC_FLOW_TIMEOUT", "300"))
    handshake = FlowHandshake()
    handshake_task = @async watch_handshake!(handshake, directory)
    quiet_since = Ref(0.0)
    quiet_sequences = Ref{Any}(nothing)
    next_log = Ref(0.0)
    baseline = Ref{Any}(nothing)
    cursor = Threads.Atomic{UInt64}(0)
    phases = Dict{OpticalClassification,Dict{String,Any}}()
    applied_timestamp = Ref{Union{Nothing,ReferenceTimestamp}}(nothing)
    injection = Ref{Union{Nothing,Dict{String,Any}}}(nothing)
    injection_error = Ref{Any}(nothing)
    cancelled = Threads.Atomic{Bool}(false)
    injection_task = if profile == "cal2"
        @async begin
            try
                while !handshake.running && !cancelled[]
                    sleep(0.01)
                end
                cancelled[] || (injection[] = inject_pupil!(pupil_owner, pupil, cursor, cancelled))
            catch err
                injection_error[] = err
                @error "CAL2 pupil injection failed" exception = (err, catch_backtrace())
                cancelled[] || touch(joinpath(directory, "probe_failed"))
            end
        end
    else
        nothing
    end
    process_capture = identity
    if profile == "cal2"
        simulation = RTC.Common.read_json(joinpath(app, "simulation.conf"))
        chopping = simulation["plant"]["chopping"]["scc"]
        first_fringed = chopping["initial_phase"] == "fringed"
        high_is_fringed = chopping["trigger_high_is_fringed"]
        camera_schema = only(s.schema for s in specs if s.name == "llowfs-image")
        scc_schema = only(s.schema for s in specs if s.name == "scc-image")
        duration = Int64(10_000_000)
        process_capture = capture -> begin
            if capture.schema == camera_schema
                on_metadata = (c, metadata) -> record_camera!(c, metadata, cursor)
                return stream -> capture(stream; on_metadata)
            elseif capture.schema == scc_schema
                on_metadata = (c, metadata) ->
                    record_chopping!(c, metadata, phases, first_fringed, high_is_fringed, duration)
                return stream -> capture(stream; on_metadata)
            end
            return capture
        end
    elseif profile == "spiders"
        applied_schema = only(s.schema for s in specs if s.name == "applied")
        process_capture = capture -> begin
            capture.schema == applied_schema || return capture
            on_metadata = (_, metadata) -> (applied_timestamp[] = reference_timestamp(metadata))
            return stream -> capture(stream; on_metadata)
        end
    end

    function finished(captures)
        injection_error[] === nothing || throw(injection_error[])
        handshake.running || return false
        if handshake.observed === nothing
            if baseline[] === nothing && profile != "cal2"
                baseline[] = map(c -> (count = c.distinct_sequences,
                    acquisition = c.identity === nothing ? UInt64(0) : c.identity.sequence), captures)
            end
            now = _classic_now()
            if now >= next_log[]
                handshake.progress = stream_progress(specs, captures)
                next_log[] = now + 5
            end
            first_counts = baseline[] === nothing ? map(_ -> 0, captures) :
                map(row -> row.count, baseline[])
            all(c.distinct_sequences >= first + 3 for (c, first) in zip(captures, first_counts)) ||
                return false
            record = Dict{String,Any}(
                "streams" => stream_progress(specs, captures),
                "first_running_observation_counts" =>
                    Dict(s.name => count for (s, count) in zip(specs, first_counts)),
            )
            if profile == "gpi2"
                first_identity = maximum(row -> row.acquisition, baseline[])
                matches = filter(id -> id.sequence > first_identity, common_identities(captures))
                length(matches) >= 2 || return false
                record["matching_detector_and_three_command_acquisitions"] =
                    map(_classic_identity_record, matches)
            elseif profile == "cal2"
                injection[] === nothing && return false
                length(phases) == 2 || return false
                record["synthetic_pupil"] = injection[]
                record["scc_chopper_exposures"] =
                    Dict(string(phase) => receipt for (phase, receipt) in phases)
            elseif profile == "spiders"
                stamp = applied_timestamp[]
                stamp === nothing && return false
                applied = only(c for (s, c) in zip(specs, captures) if s.name == "applied")
                applied.header.sequence > 0 || return false
                record["last_applied_reference_timestamp"] = Dict(
                    "clock" => string(stamp.clock), "timestamp_ns" => stamp.timestamp_nanoseconds,
                )
            end
            handshake.observed = record
        end
        handshake.stopped || return false
        sequences = map(c -> c.header.sequence, captures)
        now = _classic_now()
        # Buffered observations can drain after the Stop reply. Restart the
        # quiet interval if any delivered sequence advances.
        if quiet_sequences[] != sequences
            quiet_since[] = now
            quiet_sequences[] = sequences
        end
        now - quiet_since[] >= 2 || return false
        handshake.quiet = Dict(
            "quiet_window_s" => now - quiet_since[],
            "streams" => stream_progress(specs, captures),
        )
        return true
    end

    try
        result = observe_classic(
            remote; timeout, stream_specs = specs, drive_interval = 0.005,
            on_ready = () -> phase!(directory, "ready"), process_capture, finished,
        )
        write_record(directory, "stopped", handshake.quiet)
        write_record(directory, "observation", result)
    finally
        handshake.cancelled = true
        cancelled[] = true
        wait(handshake_task)
        injection_task === nothing || wait(injection_task)
    end
    return nothing
end

function run_probe(profile, app, remote, directory)
    isabspath(remote) && issocket(remote) ||
        error("Expected an existing absolute private PipeWire socket")
    ledger = RTC.Common.read_json(joinpath(dirname(remote), "launch.json"))
    ledger["remote"] == remote || error("PipeWire socket differs from the private launch record")
    isdir(directory) && isempty(readdir(directory)) || error("Expected an empty handshake directory")
    specs, session = probe_specs(profile, app)
    if profile == "cal2"
        with_pupil_source(app, session, remote) do owner, pupil
            observe_flow(profile, app, remote, directory, specs; pupil_owner = owner, pupil)
        end
    else
        observe_flow(profile, app, remote, directory, specs)
    end
    phase!(directory, "complete")
    return nothing
end

if abspath(PROGRAM_FILE) == @__FILE__
    length(ARGS) == 4 || error("usage: sealed_application_flow.jl PROFILE APPLICATION PRIVATE_SOCKET HANDSHAKE_DIR")
    first(ARGS) == "cal2" && include("sealed_cal2_pupil.jl")
    run_probe(ARGS...)
end
