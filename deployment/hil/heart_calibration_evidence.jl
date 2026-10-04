"""Revalidate retained native measurements against their actual public calibration result."""
module HeartCalibrationEvidence

using JSON3, SHA
include("heart_calibration_telemetry.jl")
include("calibration_client.jl")
const Telemetry = HeartCalibrationTelemetry

digest(path) = bytes2hex(open(sha256, path))
function document(path; maximum=16 * 1024 * 1024)
    !islink(path) && filesize(path) <= maximum || throw(ArgumentError("native evidence is linked or exceeds its bound"))
    return JSON3.read(read(path, String))
end
check(condition, message) = condition || throw(ArgumentError(message))
float_bits_equal(left, right) = length(left) == length(right) &&
    reinterpret(UInt32, Float32.(left)) == reinterpret(UInt32, Float32.(right))

function telemetry_path(directory, tag)
    paths = String[]
    for path in readdir(directory; join=true)
        endswith(path, ".tel") && isfile(path) || continue
        !islink(path) && filesize(path) >= 1024 || throw(ArgumentError("invalid retained native stream"))
        bytes = open(io -> read(io, 32), path)
        zero = findfirst(iszero, bytes)
        check(zero !== nothing, "unterminated native tag")
        String(bytes[1:zero-1]) == tag && push!(paths, path)
    end
    check(length(paths) == 1, "missing or repeated retained native $tag stream")
    return only(paths)
end

function read_associations(path, maximum)
    check(!islink(path) && filesize(path) <= maximum, "native associations exceed their bound")
    exposures = JSON3.Object[]
    adopted = JSON3.Object[]
    open(path) do io
        for line in eachline(io)
            check(ncodeunits(line) <= 1024 * 1024, "native association record exceeds its bound")
            row = JSON3.read(line)
            if row.kind == "exposure"
                check(row.probe_sequence == length(adopted), "native exposure preceded its declared DM adoption")
                push!(exposures, row)
            elseif row.kind == "adopted"
                push!(adopted, row)
            elseif hasproperty(row, :disposition)
                check(row.disposition != "failed", "native stage reports a failed gate")
            end
        end
    end
    return exposures, adopted
end

function pupil_mean(frame, locations)
    pixels = reinterpret(Float32, frame.payload)
    total = 0.0
    for (row, column) in locations, dy in 0:29, dx in 0:29
        value = pixels[(row + dy) * 64 + column + dx + 1]
        check(isfinite(value), "nonfinite native calibrated pupil")
        total += Float64(value)
    end
    return Float32(total / 3600)
end

function verify(package, evidence)
    provenance = document(joinpath(package, "provenance.json"))
    calibration = provenance.heart_calibration
    plan = document(joinpath(package, "heart-calibration-plan.json"))
    check(digest(joinpath(package, "heart-calibration-plan.json")) == calibration.frozen_plan.sha256,
        "retained native plan differs from sealed package")
    completed = document(joinpath(evidence, "native-plan-result.json"))
    identity = document(joinpath(evidence, "native-runtime-identity.json"))
    startup = completed.startup_owner_report
    final = document(joinpath(evidence, "simulator-result.json"))
    check(identity == completed.runtime_identity && final == completed.final_owner_report,
        "retained native runtime or final owner differs")
    check(identity.deployment_sha256 == digest(joinpath(package, "deployment.conf")), "native descriptor differs")
    check(identity.acquisition_generation == startup.acquisition_generation == final.acquisition_generation &&
        identity.acquisition_domain_mapping == startup.acquisition_domain_mapping == final.acquisition_domain_mapping,
        "native acquisition domain or generation differs")
    check(startup.engine == final.engine == "heart" && startup.profile == final.profile == "copper" &&
        startup.sequence == 0 && final.completed === true && final.restoration_confirmed === true &&
        final.ownership_held === false && final.failure === nothing, "native owner did not complete restored and released")
    check(startup.native_controller_held == final.native_controller_held &&
        identity.native_child_pid == final.native_controller_held.child_pid &&
        final.native_controller_held.generation == 1 && final.native_controller_held.admitted_frames == 0 &&
        final.native_controller_held.run_acknowledged === true && final.native_controller_held.endpoints_acknowledged === true,
        "native child hold proof changed")
    ingress = calibration.native_ingress
    check(ingress.mode in ("streaming", "deferred") && ingress.environment_key == "HRT_DEFER_WFS_INGRESS" &&
        ingress.environment_value == (ingress.mode == "deferred" ? "1" : "0") && ingress.shape == [64,64] &&
        ingress.packet_rows == 32 && ingress.datagrams_per_frame == 2 &&
        digest(joinpath(package, "heart/bin/scaoTemplate")) == ingress.executable_sha256 &&
        final.native_controller_held.ingress_mode == ingress.mode &&
        final.native_controller_held.ingress_environment == ingress.environment_value,
        "native ingress contract or hold environment differs")
    native_status = document(joinpath(evidence, "heart/native/heart-owner-status.json"); maximum=64 * 1024)
    check(native_status.child_pid == identity.native_child_pid && native_status.generation == 1 &&
        native_status.native_ingress.mode == ingress.mode &&
        native_status.native_ingress.environment_key == ingress.environment_key &&
        native_status.native_ingress.observed_environment == ingress.environment_value &&
        native_status.owner_pid == identity.processes.heart.pid && native_status.error === nothing &&
        native_status.source_config_sha256 == calibration.native_config_sha256 &&
        native_status.rendered_config == joinpath(identity.runtime, identity.instance, "heart/native/config/heart.yaml"),
        "retained native owner PID, generation or deployed configuration differs")
    correct_path = joinpath(evidence, "native-control/startup-CORRECT.log")
    correct = read(correct_path, String) * read(correct_path * ".stderr", String)
    check(ncodeunits(correct) <= 64 * 1024 && occursin("ack<0><ACCEPTED>", correct) &&
        occursin("status<0><SUCCESS>", correct) &&
        bytes2hex(sha256(correct)) == final.native_controller_held.endpoint_reply_sha256 &&
        final.native_controller_held.endpoint_enable_command == "startup CORRECT", "native endpoint enable ACK differs")
    check(startup.detector_config.rng_seed == calibration.plant.detector_seed &&
        startup.graph_sha256 == calibration.plant.graph_sha256, "native source graph or detector seed differs")
    batches, accepted, discarded = length(plan.probes), Int(plan.frames_per_probe), Int(plan.settling.frames)
    frames = batches * (accepted + discarded) + discarded
    commands = batches + 1
    check(completed.limits.completed_exposures == final.sequence == frames &&
        completed.limits.native_dm_records == commands, "native completed count differs from plan")
    directory = joinpath(evidence, "heart/native")
    maximum = UInt64(calibration.telemetry_max_bytes_per_file)
    for serial in 1:commands+2
        command = document(joinpath(evidence, "native-control/command-$serial.log.json"); maximum=512 * 1024)
        expected = serial == 1 ? "RUN" : serial == 2 ? "SET_TELM_RECORD" : "DM_SHAPE"
        text = command.stdout * command.stderr
        check(command.name == expected && command.exitcode == 0 && command.termsignal == 0 &&
            command.failure === nothing && command.truncated === false && ncodeunits(text) <= 64 * 1024 &&
            occursin("ack<0><ACCEPTED>", text) && occursin("status<0><SUCCESS>", text), "native public command ACK differs")
    end
    counts = Telemetry.verify_copper_counts(directory; frames, commands, maximum_bytes=maximum)
    association_path = joinpath(evidence, "native-association.jsonl")
    check(digest(association_path) == final.native_evidence.sha256, "native associations differ from final owner")
    exposures, adopted = read_associations(association_path, maximum)
    check(length(exposures) == frames && length(adopted) == commands, "native association/adoption count differs")
    raw = Telemetry.TelemetryReader(telemetry_path(directory, "cbHoPixelsRaw0"); tag="cbHoPixelsRaw0", datatype=7,
        shape=(64, 64), maximum_bytes=maximum)
    calibrated = Telemetry.TelemetryReader(telemetry_path(directory, "cbHoPixelsCalib0"); tag="cbHoPixelsCalib0", datatype=8,
        shape=(64, 64), maximum_bytes=maximum)
    gradient = Telemetry.TelemetryReader(telemetry_path(directory, "cbHoGrad0"); tag="cbHoGrad0", datatype=8,
        shape=(3600, 1), maximum_bytes=maximum)
    dm = Telemetry.TelemetryReader(telemetry_path(directory, "cbDmCmd0"); tag="cbDmCmd0", datatype=20,
        shape=(277, 1), maximum_bytes=maximum)
    result_path = joinpath(evidence, "calibration-result.json")
    check(digest(result_path) == completed.cli_result_sha256, "public native means changed")
    result = document(result_path; maximum=512 * 1024 * 1024)
    prepared = (; plan, figures=permutedims(hcat(plan.probes...)), measurements=3600, frames_per_probe=accepted)
    values = CalibrationClient.validate_result(result, prepared)
    locations_path = joinpath(package, "heart/calibration/pwfsRoiOffsets_64.csv")
    # The actual deployed configuration is retained in the immutable package.
    locations = [Tuple(parse.(Int, split(line, ','))) for line in split(chomp(read(locations_path, String)), '\n')[2:end]]
    check(length(locations) == 4 && all(location -> all(value -> 0 <= value <= 34, location), locations), "invalid native pupil locations")
    sums = zeros(Float64, 3600)
    previous_intensity = 0.0f0
    maximum_adc = UInt16(0)
    invalid_frames = 0
    duration = UInt64(round(Int, startup.detector_config.exposure_duration_s * 1e9))
    rail = UInt16(final.detector_diagnostics.adc_upper_rail)
    check(rail == (1 << startup.detector_config.bits) - 1, "native ADC rail differs from detector contract")
    if calibration.frozen_method !== nothing
        recipe = document(joinpath(package, calibration.frozen_method.path, "recipe.json"))
        check(recipe.adc_upper_rail == rail, "native ADC rail differs from frozen recipe")
    end
    rail_pixels = 0
    try
        for index in 1:commands
            command = Telemetry.next_frame!(dm)
            figure = Float32.(index <= batches ? plan.probes[index] : plan.reference)
            actual = collect(@view reinterpret(Float32, command.payload)[1:277])
            record = adopted[index]
            expected_sha = bytes2hex(sha256(reinterpret(UInt8, figure)))
            check(float_bits_equal(actual, figure) && record.sequence == index && record.native_bucket == index-1 &&
                record.native_sync == 0 && record.clipped === false && record.requested_sha256 == expected_sha &&
                record.adopted_sha256 == expected_sha, "native actual DM figure differs from public probe")
        end
        for index in 1:frames
            r, c, g = Telemetry.next_frame!(raw), Telemetry.next_frame!(calibrated), Telemetry.next_frame!(gradient)
            record = exposures[index]
            e = record.exposure
            expected_probe = index <= batches * (accepted + discarded) ? cld(index, accepted + discarded) : commands
            check(e.domain == identity.acquisition_domain_mapping.opaque_domain && e.generation == identity.acquisition_generation &&
                e.sequence == index && e.start_model_ns == UInt64(index-1) * duration && e.duration_ns == duration &&
                record.probe_sequence == expected_probe &&
                record.native_sync == r.sync == c.sync == g.sync == index && record.raw_bucket == r.bucket == index-1 &&
                record.measurement_bucket == g.bucket == index-1, "native association interval or frame identity differs")
            check(record.raw_sha256 == bytes2hex(sha256(r.payload)) &&
                record.measurement_sha256 == bytes2hex(sha256(g.payload)) &&
                record.calibrated_sha256 == bytes2hex(sha256(c.payload)), "native associated detector or measurement payload differs")
            pixels = reinterpret(Float32, g.payload)
            intensity = pupil_mean(c, locations)
            valid = all(isfinite, pixels) && any(!iszero, pixels) && previous_intensity > 0 && intensity > 0
            check(record.valid === valid, "native validity differs from retained measurements")
            previous_intensity = intensity
            invalid_frames += !valid
            adc = reinterpret(UInt16, r.payload)
            maximum_adc = max(maximum_adc, Base.maximum(adc))
            rail_pixels += count(==(rail), adc)
            check(all(value -> value <= rail, adc), "native ADC value exceeds declared rail")
            if index <= batches * (accepted + discarded)
                batch = cld(index, accepted + discarded)
                offset = mod(index-1, accepted + discarded) + 1
                if offset > discarded
                    check(valid, "accepted native frame is invalid")
                    sample = offset - discarded
                    receipt = result.responses[batch].exposures[sample]
                    check(all(name -> getproperty(receipt, name) == getproperty(e, name),
                        (:domain, :generation, :sequence, :start_model_ns, :duration_ns)), "public mean uses a different native exposure")
                    for measurement in eachindex(sums, pixels)
                        sums[measurement] += Float64(pixels[measurement])
                    end
                    if sample == accepted
                        check(float_bits_equal(Float32.(sums ./ accepted), @view(values[batch, :])),
                            "public means differ from retained native gradients")
                        fill!(sums, 0.0)
                    end
                end
            end
        end
        check(final.detector_diagnostics.frames == frames && final.detector_diagnostics.maximum_adc == maximum_adc &&
            final.detector_diagnostics.invalid_frames == invalid_frames && final.detector_diagnostics.upper_rail_pixels == rail_pixels &&
            final.detector_diagnostics.upper_rail_frames == 0 && rail_pixels == 0,
            "native ADC diagnostics differ or hit a rail")
    finally
        foreach(close, (raw, calibrated, gradient, dm))
    end
    return (; version=1, counts, accepted_frames=batches*accepted, maximum_adc, invalid_frames,
        public_means_match_native=true, scope="retained actual native payload/association/ADC/public mean verification")
end

function main(arguments=ARGS)
    length(arguments) == 2 || throw(ArgumentError("usage: heart_calibration_evidence.jl PACKAGE EVIDENCE"))
    println(JSON3.write(verify(arguments...)))
    return 0
end

end
abspath(PROGRAM_FILE) == (@__FILE__) && HeartCalibrationEvidence.main()
