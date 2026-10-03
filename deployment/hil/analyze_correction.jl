#!/usr/bin/env julia
"""
Cold Classic CPU correction diagnostic. Run with the exact installed HIL project:

    julia --project=PACKAGE/hil analyze_correction.jl \
        --package PACKAGE --report simulator-result.json --output NEW.json

No transport is started. Commands are the retained, adopted metre-OPD commands;
command n affects frame n+1. Ideal pupil products are diagnostics only and must
never become calibration/reconstructor inputs. Ratios are published only after
the zero-command replay checks pass and either legacy ADC payloads match exactly
or a new direct live OPD witness matches exactly. A present witness must match;
ADC equality cannot override a witness failure. This checks source payloads, not independent sink receipt.
The declared windows are 17:128 and 129:256, truncated to available frames for
shorter recordings; recordings of at most 16 frames use their full prefix.

The deployment artifact manifest validates the current installed sources. The
legacy simulator report binds its graph and payloads but does not bind historical
helper sources; current manifest equality cannot establish their acquisition-time
hash. A new direct witness records helper identities, assuming the installation
remains unchanged during acquisition.
"""
module CorrectionAnalysis

using JSON3
using SHA
using TOML

include("correction_truth.jl")
using .CorrectionTruth: telescope_config, pupil_variance, opd_hash

const ZERO_RTOL = 8 * Float64(eps(Float32))
const ZERO_ATOL_M = 0.0

require(condition, message) = condition || throw(ArgumentError(message))
file_hash(path) = bytes2hex(open(sha256, path))
positive_integer(x) = x isa Integer && !(x isa Bool) && 0 < x <= typemax(Int)
nonnegative_integer(x) = x isa Integer && !(x isa Bool) && x >= 0

"""Resolve a new output through its nearest existing parent before any write.
Dangling links are occupied paths. Return the resolved path so subsequent mkdir
and writes do not follow the caller's parent alias back into the installation.
"""
function diagnostic_output(package, output)
    package = realpath(package)
    output = abspath(output)
    for path in (output, output * ".replayed.frames.u16le")
        require(!ispath(path) && !islink(path), "diagnostic outputs must be new")
    end
    parent = dirname(output)
    missing = String[]
    while !ispath(parent)
        require(!islink(parent), "diagnostic parent is a dangling symlink")
        pushfirst!(missing, basename(parent))
        parent = dirname(parent)
    end
    require(isdir(parent), "diagnostic parent must be a directory")
    resolved = joinpath(realpath(parent), missing..., basename(output))
    require(!startswith(resolved, package * "/"), "diagnostic output must be outside the installed package")
    for path in (resolved, resolved * ".replayed.frames.u16le")
        require(!ispath(path) && !islink(path), "diagnostic outputs must be new")
    end
    return resolved
end

function checked_artifact(package, relative, expected)
    require(relative isa AbstractString && !isabspath(relative), "artifact path must be relative")
    path = normpath(joinpath(package, relative))
    require(startswith(path, package * "/") && isfile(path), "missing or escaping artifact: $relative")
    require(startswith(realpath(path), realpath(package) * "/"), "artifact symlink escapes package: $relative")
    require(expected isa AbstractString && occursin(r"^[0-9a-f]{64}$", expected), "invalid artifact hash: $relative")
    actual = file_hash(path)
    require(actual == expected, "artifact hash mismatch: $relative")
    return (; path, sha256=actual)
end

function validate_package(package)
    package = realpath(package)
    descriptor = joinpath(package, "deployment.conf")
    deployment = JSON3.read(read(descriptor, String))
    require(deployment.version == 1, "unsupported deployment version")
    artifacts = deployment.artifacts
    for (relative, expected) in pairs(artifacts)
        checked_artifact(package, String(relative), expected)
    end
    for relative in ("hil/simulator.jl", "hil/owner_protocol.jl", "hil/plant.toml", "hil/Project.toml", "hil/Manifest.toml")
        require(haskey(artifacts, relative), "required installed source is not hash-bound: $relative")
    end
    for (directory, _, files) in walkdir(joinpath(package, "hil"))
        for name in files
            if endswith(name, ".jl") || name in ("Project.toml", "Manifest.toml")
                relative = relpath(joinpath(directory, name), package)
                require(haskey(artifacts, relative), "installed source is not hash-bound: $relative")
            end
        end
    end
    return (; package, deployment_sha256=file_hash(descriptor), artifact_count=length(artifacts),
        simulator_sha256=file_hash(joinpath(package, "hil/simulator.jl")),
        project_sha256=file_hash(joinpath(package, "hil/Project.toml")),
        manifest_sha256=file_hash(joinpath(package, "hil/Manifest.toml")))
end

function payload_path(report_path, descriptor)
    # Preserved check_hil reports normally carry rewritten absolute paths. A
    # relative path is resolved against that preserved report, never the cwd.
    path = String(descriptor.file)
    return isabspath(path) ? path : joinpath(dirname(report_path), path)
end

function checked_payload(report_path, descriptor, expected_bytes)
    path = payload_path(report_path, descriptor)
    require(isfile(path) && filesize(path) == expected_bytes, "payload byte count mismatch: $path")
    actual = file_hash(path)
    require(actual == descriptor.sha256, "payload hash mismatch: $path")
    return read(path)
end

function validate_recording(package, report_path)
    report = JSON3.read(read(report_path, String))
    require(report.version == 1 && report.profile == "classic" && report.backend == "cpu", "requires a version-1 Classic CPU report")
    require(report.completed === true && report.failure === nothing, "simulator run did not complete successfully")
    n = report.completed_frames
    require(positive_integer(n) && n <= 256, "completed frame count must be in 1:256")
    n = Int(n)
    require(all(positive_integer, (report.completed_commands, report.requested_frames, report.sequence)) && report.completed_commands == n && report.requested_frames == n && report.sequence == n, "inconsistent completed counts")
    require(all(positive_integer, report.sequences) && report.sequences == collect(1:n), "recorded sequences must be 1:N")
    period = report.model_period_ns
    require(positive_integer(period), "invalid model period")
    period = Int(period)
    require(positive_integer(report.exposure_ns) && report.exposure_ns <= period, "invalid exposure")
    expected_times = [Base.Checked.checked_mul(i - 1, period) for i in 1:n]
    require(all(nonnegative_integer, report.model_timestamps_ns) && report.model_timestamps_ns == expected_times, "model timestamps do not match the fixed-step chronology")
    require(length(report.source_published_ns) == length(report.command_received_ns) == length(report.source_to_command_latency_ns) == n, "timing count mismatch")
    for i in 1:n
        source, received, latency = report.source_published_ns[i], report.command_received_ns[i], report.source_to_command_latency_ns[i]
        require(all(nonnegative_integer, (source, received, latency)) && source <= received && received - source == latency, "invalid exchange timing")
        i == 1 || require(source > report.source_published_ns[i - 1], "non-monotonic publication chronology")
    end
    graph = joinpath(package, "hil/plant.toml")
    require(file_hash(graph) == report.graph_sha256, "installed plant differs from recorded graph hash")
    f, c = report.frame, report.command
    require(f.element_type == "U16_LE" && f.layout == "ROW_MAJOR" && f.shape == [352, 352] && f.units == "raw detector ADC code" && f.encoding == "nearest ties to even", "unsupported detector contract")
    require(c.recorded_element_type == "F32_LE" && c.shape == [277] && c.recorded_units == "metre OPD" && c.plant_units == "metre OPD" && c.layout == "frame followed by 277 actuator values", "unsupported adopted command contract")
    transport = get(report, :transport, "scientific")
    require(transport in ("scientific", "heart"), "unsupported transport contract")
    frame_schema, command_schema, units, scale = transport == "heart" ?
        ("org.heart.std-wfs.raw-pixels/1", "org.heart.std-dm.actuator-command/1", "metre OPD", 1.0f0) :
        ("org.calculon.ao.raw-detector-pixels/1", "org.calculon.ao.demanded-pdm-command/1", "micrometre OPD", 1.0f-6)
    require(f.schema == frame_schema && c.schema == command_schema && c.transport_element_type == "F32_LE" && c.transport_units == units && isfinite(c.transport_to_plant_scale) && Float32(c.transport_to_plant_scale) == scale, "inconsistent wire contract")
    frames = checked_payload(report_path, f, Base.Checked.checked_mul(2 * 352 * 352, n))
    command_bytes = checked_payload(report_path, c, Base.Checked.checked_mul(4 * 277, n))
    command_words = ltoh.(copy(reinterpret(UInt32, command_bytes)))
    commands = reshape(copy(reinterpret(Float32, command_words)), 277, n)
    require(all(isfinite, commands), "non-finite adopted command")
    require(isfinite(report.command_limit_um) && report.command_limit_um > 0 && isfinite(report.command_limit_tolerance_um) && report.command_limit_tolerance_um >= 0, "invalid retained command limit diagnostic")
    truth = validate_live_truth(package, report, graph, n)
    return (; report, graph, n, period, frames, commands, truth,
        report_sha256=file_hash(report_path))
end

"""Validate a new direct live OPD witness independently of ADC reproducibility.
Legacy reports have no witness and retain the exact ADC promotion gate. A
witness must bind the actual acquisition helpers and all retained payloads;
mere agreement with a newly simulated wavefront cannot qualify old reports.
"""
function validate_live_truth(package, report, graph, n)
    truth = get(report, :correction_truth, nothing)
    truth === nothing && return nothing
    require(truth.version == 1 && truth.complete_prefix === true, "incomplete live OPD witness")
    require(positive_integer(truth.observed_frames) && positive_integer(truth.recorded_frames) && truth.observed_frames == truth.recorded_frames == n, "live OPD count mismatch")
    for (field, expected) in ((:graph_sha256, report.graph_sha256), (:frame_sha256, report.frame.sha256),
            (:command_sha256, report.command.sha256), (:simulator_sha256, file_hash(joinpath(package, "hil/simulator.jl"))),
            (:helper_sha256, file_hash(joinpath(package, "hil/correction_truth.jl"))))
        require(getproperty(truth, field) == expected, "live OPD source/payload binding differs: $field")
    end
    require(truth.outputs.atmosphere == "atmosphere_opd" && truth.outputs.pupil == "pupil_opd" && truth.outputs.surface == "pdm_surface_opd", "unsupported live OPD outputs")
    cfg = telescope_config(graph)
    require(truth.opd.units == "metre OPD" && truth.opd.element_type == "F32_LE" && truth.opd.layout == "ROW_MAJOR" && truth.opd.shape == [cfg.resolution, cfg.resolution], "unsupported live OPD representation")
    for name in keys(cfg)
        require(getproperty(truth.pupil, name) == getproperty(cfg, name), "live pupil configuration differs: $name")
    end
    require(positive_integer(truth.pupil.support_pixels) && truth.pupil.support_pixels <= cfg.resolution^2, "invalid live pupil support count")
    require(truth.pupil.mask_encoding == "row-major UInt8, zero outside support and one inside" &&
        truth.pupil.weighting == "uniform public annular pupil support" &&
        truth.pupil.variance == "population spatial variance after piston removal, metre OPD squared", "unsupported live pupil statistic")
    require(valid_hash(truth.pupil.mask_sha256), "invalid live pupil support hash")
    require(length(truth.per_frame) == n, "live OPD sample count mismatch")
    for (i, sample) in enumerate(truth.per_frame)
        require(positive_integer(sample.sequence) && sample.sequence == i && nonnegative_integer(sample.model_timestamp_ns) && sample.model_timestamp_ns == report.model_timestamps_ns[i], "live OPD chronology differs")
        require(all(valid_hash, (sample.atmosphere_sha256, sample.pupil_sha256, sample.surface_sha256)), "invalid live OPD hash")
        require(all(v -> v isa Real && !(v isa Bool) && isfinite(v) && v >= 0,
            (sample.residual_variance_m2, sample.atmosphere_variance_m2)), "invalid live OPD variance")
    end
    return truth
end

valid_hash(value) = value isa AbstractString && occursin(r"^[0-9a-f]{64}$", value)

function live_truth_matches(truth, per_frame, mask)
    truth === nothing && return false
    mask_hash = bytes2hex(sha256(UInt8[mask[r,c] for r in axes(mask,1) for c in axes(mask,2)]))
    truth.pupil.mask_sha256 == mask_hash && truth.pupil.support_pixels == count(mask) || return false
    length(truth.per_frame) == length(per_frame) || return false
    return all(zip(truth.per_frame, per_frame)) do (live, replay)
        live.sequence == replay.sequence && live.model_timestamp_ns == replay.model_timestamp_ns &&
            live.atmosphere_sha256 == replay.atmosphere_sha256 && live.pupil_sha256 == replay.pupil_sha256 &&
            live.surface_sha256 == replay.surface_sha256 && live.residual_variance_m2 == replay.residual_variance_m2 &&
            live.atmosphere_variance_m2 == replay.atmosphere_variance_m2
    end
end

verification_gate(adc_exact, live_truth, live_exact, baseline_verified) =
    baseline_verified && (live_truth === nothing ? adc_exact : live_exact)

function adc_bytes(frame::AbstractMatrix{<:Real})
    Base.require_one_based_indexing(frame)
    require(size(frame) == (352, 352), "replay detector shape mismatch")
    require(all(v -> isfinite(v) && 0 <= v <= typemax(UInt16), frame), "replay detector cannot encode as UInt16")
    words = UInt16[htol(round(UInt16, frame[r, c])) for r in axes(frame, 1) for c in axes(frame, 2)]
    return copy(reinterpret(UInt8, words))
end

function adc_comparison(actual::AbstractVector{UInt8}, expected::AbstractVector{UInt8})
    require(length(actual) == length(expected) == 2 * 352 * 352, "ADC comparison byte count mismatch")
    a, e = ltoh.(reinterpret(UInt16, actual)), ltoh.(reinterpret(UInt16, expected))
    differences = findall(i -> a[i] != e[i], eachindex(a))
    first = isempty(differences) ? nothing : let i = differences[1]
        (; row=div(i - 1, 352) + 1, column=rem(i - 1, 352) + 1, replay=Int(a[i]), recorded=Int(e[i]))
    end
    return (; exact=isempty(differences), differing_pixels=length(differences),
        maximum_abs_adc_difference=maximum(i -> abs(Int(a[i]) - Int(e[i])), differences; init=0),
        first_difference=first, replay_sha256=bytes2hex(sha256(actual)), recorded_sha256=bytes2hex(sha256(expected)))
end

function window_ranges(n)
    require(positive_integer(n) && n <= 256, "window frame count must be in 1:256")
    n <= 16 && return [(; name="available_frames_1_to_N", first=1, last=Int(n), complete=true)]
    ranges = [(; name="frames_17_to_128", first=17, last=min(Int(n), 128), complete=n >= 128)]
    n >= 129 && push!(ranges, (; name="frames_129_to_256", first=129, last=Int(n), complete=n == 256))
    return ranges
end

function correction_windows(residual, atmosphere, verified)
    require(length(residual) == length(atmosphere), "window product counts differ")
    map(window_ranges(length(residual))) do w
        residual_mean = sum(@view residual[w.first:w.last]) / (w.last - w.first + 1)
        atmosphere_mean = sum(@view atmosphere[w.first:w.last]) / (w.last - w.first + 1)
        ratio = verified && atmosphere_mean > 0 ? residual_mean / atmosphere_mean : nothing
        (; w..., frames=w.last - w.first + 1, residual_mean_variance_m2=residual_mean,
            atmosphere_mean_variance_m2=atmosphere_mean, residual_to_atmosphere_variance_ratio=ratio)
    end
end

function replay(installed, recording, output)
    s = installed
    cfg = telescope_config(recording.graph)
    require(isapprox(cfg.exposure_seconds, recording.report.exposure_ns / 1e9; rtol=1e-12, atol=0), "plant/report exposure mismatch")
    options = (; profile=:classic, backend=:cpu, graph=recording.graph, period_ns=UInt64(recording.period))
    science = Base.invokelatest(s.prepare_science, options, s.load_plant(:classic), s.load_target(:cpu))
    optics = s.AdaptiveOpticsSim.Optics
    telescope = optics.prepare_telescope(optics.TelescopeDefinition(;
        resolution=cfg.resolution, diameter=cfg.diameter, central_obstruction=cfg.central_obstruction,
        pupil_reflectivity=cfg.pupil_reflectivity, revision=cfg.revision, T=Float32), science.target)
    mask = optics.pupil_mask(telescope)
    atmosphere_snapshots = Matrix{Float32}[]
    raw_path = output * ".replayed.frames.u16le"
    require(!ispath(raw_path) && !islink(raw_path), "replayed ADC output must be new")
    per_frame = open(raw_path, "w") do raw_io
        map(1:recording.n) do n
            step = s.step_hil_frame_at!(science.boundary, science.driver)
            require(step.sequence == n && s.model_nanoseconds(step.timestamp) == recording.report.model_timestamps_ns[n], "replay model chronology mismatch")
            adc = adc_bytes(s.hil_frame_buffer(science.boundary))
            write(raw_io, adc)
            width = length(adc)
            comparison = adc_comparison(adc, @view recording.frames[(n - 1) * width + 1:n * width])
            atmosphere = s.graph_output(science.graph, :atmosphere_opd)
            residual = s.graph_output(science.graph, :pupil_opd)
            surface = s.graph_output(science.graph, :pdm_surface_opd)
            require(size(surface) == size(mask) && all(isfinite, surface), "invalid public PDM surface")
            push!(atmosphere_snapshots, copy(atmosphere))
            measured = (; sequence=n, model_timestamp_ns=recording.report.model_timestamps_ns[n], adc=comparison,
                residual_variance_m2=pupil_variance(residual, mask), atmosphere_variance_m2=pupil_variance(atmosphere, mask),
                atmosphere_sha256=opd_hash(atmosphere), pupil_sha256=opd_hash(residual), surface_sha256=opd_hash(surface))
            copyto!(s.hil_command_buffer(science.boundary), @view recording.commands[:, n])
            s.adopt_hil_command!(science.boundary, step.sequence)
            measured
        end
    end
    s.reset_hil_boundary!(science.boundary, science.driver)
    baseline = map(1:recording.n) do n
        step = s.step_hil_frame_at!(science.boundary, science.driver)
        require(step.sequence == n && s.model_nanoseconds(step.timestamp) == recording.report.model_timestamps_ns[n], "baseline model chronology mismatch")
        atmosphere = s.graph_output(science.graph, :atmosphere_opd)
        pupil = s.graph_output(science.graph, :pupil_opd)
        surface = s.graph_output(science.graph, :pdm_surface_opd)
        reference = atmosphere_snapshots[n]
        require(size(atmosphere) == size(pupil) == size(reference) && all(isfinite, atmosphere) && all(isfinite, pupil), "invalid baseline public OPD products")
        # Elementwise tolerance in metre OPD. With atol=0 zero-valued reference
        # elements require exact equality; the chosen rtol is explicitly retained.
        atmosphere_same = all(i -> isapprox(atmosphere[i], reference[i]; rtol=ZERO_RTOL, atol=ZERO_ATOL_M), eachindex(atmosphere, reference))
        pupil_same = all(i -> isapprox(pupil[i], atmosphere[i]; rtol=ZERO_RTOL, atol=ZERO_ATOL_M), eachindex(pupil, atmosphere))
        measured = (; sequence=n, atmosphere_sha256=opd_hash(atmosphere), pupil_sha256=opd_hash(pupil),
            atmosphere_exact=opd_hash(atmosphere) == per_frame[n].atmosphere_sha256,
            atmosphere_matches=atmosphere_same, pupil_equals_atmosphere=pupil_same,
            surface_is_zero=all(iszero, surface),
            maximum_atmosphere_difference_m=maximum(i -> abs(Float64(atmosphere[i]) - reference[i]), eachindex(atmosphere)),
            maximum_pupil_difference_m=maximum(i -> abs(Float64(pupil[i]) - atmosphere[i]), eachindex(pupil)),
            pupil_variance_m2=pupil_variance(pupil, mask))
        fill!(s.hil_command_buffer(science.boundary), 0.0f0)
        s.adopt_hil_command!(science.boundary, step.sequence)
        measured
    end
    adc_verified = all(p -> p.adc.exact, per_frame)
    baseline_verified = all(p -> p.atmosphere_matches && p.pupil_equals_atmosphere && p.surface_is_zero, baseline)
    live_verified = live_truth_matches(recording.truth, per_frame, mask)
    verified = verification_gate(adc_verified, recording.truth, live_verified, baseline_verified)
    limit, tolerance = recording.report.command_limit_um, recording.report.command_limit_tolerance_um
    command_um = recording.commands ./ 1.0f-6
    qualified_frames = map(per_frame) do p
        (; p..., residual_to_atmosphere_variance_ratio=verified && p.atmosphere_variance_m2 > 0 ? p.residual_variance_m2 / p.atmosphere_variance_m2 : nothing)
    end
    return (; verified, failure=verified ? nothing : "source replay or zero-command baseline verification failed",
        verification_basis=recording.truth === nothing ? "exact source ADC replay and zero-command baseline" : "exact direct live public OPD witness and zero-command baseline",
        live_truth_present=recording.truth !== nothing, live_truth_verified=live_verified,
        adc_exact=adc_verified, adc_differing_frames=count(p -> !p.adc.exact, per_frame),
        adc_differing_pixels=sum(p -> p.adc.differing_pixels, per_frame),
        replayed_adc=(; path=raw_path, sha256=file_hash(raw_path), element_type="U16_LE", layout="ROW_MAJOR", shape=[352,352], frames=recording.n),
        baseline_verified, zero_comparison=(; rtol=ZERO_RTOL, atol_m=ZERO_ATOL_M, comparison="elementwise"),
        pupil=(; cfg..., support_pixels=count(mask),
            mask_sha256=bytes2hex(sha256(UInt8[mask[r,c] for r in axes(mask,1) for c in axes(mask,2)])),
            mask_encoding="row-major UInt8, zero outside support and one inside",
            weighting="uniform public annular pupil support", variance="population spatial variance after piston removal, metre OPD squared"),
        command=(; units="metre OPD", nonzero_components=count(!iszero, recording.commands),
            components_at_limit=count(v -> abs(v) >= limit - tolerance, command_um), limit_um=limit, tolerance_um=tolerance,
            max_abs_command_um=maximum(abs, command_um), final_command_effect_is_recorded=false,
            interpretation="rail proximity only; requested-minus-demanded clipping feedback is not recorded here"),
        per_frame=qualified_frames, baseline,
        windows=correction_windows([p.residual_variance_m2 for p in per_frame], [p.atmosphere_variance_m2 for p in per_frame], verified))
end

"""Load the exact installed script in isolation with ordinary relative includes.
Module(name) supplies Base imports but does not install the include binding that
a regular module declaration supplies. The script's PROGRAM_FILE guard keeps
its main owner inactive when included here.
"""
function load_installed_simulator(path)
    installed = Module(:InstalledCorrectionSimulator)
    Core.eval(installed, :(include(path) = Base.include(@__MODULE__, path)))
    Base.include(installed, path)
    return installed
end

function analyze(package, report_path, output)
    output = diagnostic_output(package, output)
    provenance = validate_package(package)
    require(realpath(Base.active_project()) == realpath(joinpath(provenance.package, "hil/Project.toml")), "run with --project=PACKAGE/hil")
    recording = validate_recording(provenance.package, report_path)
    mkpath(dirname(output))
    installed = load_installed_simulator(joinpath(provenance.package, "hil/simulator.jl"))
    result = Base.invokelatest(replay, installed, recording, output)
    return (; version=1, diagnostic="Classic CPU simulation truth correction replay", scope="diagnostic only; no calibration, reconstructor, physical, hardware-rate or complete scientific acceptance claim",
        chronology="frame 1 uses zero; command n is adopted after frame n and affects frame n+1",
        julia_version=string(VERSION), analyzer_sha256=file_hash(@__FILE__),
        analysis_helper_sha256=file_hash(joinpath(@__DIR__, "correction_truth.jl")), provenance, report=(; path=abspath(report_path), sha256=recording.report_sha256),
        historical_source_identity=recording.truth === nothing ?
            "legacy simulator report binds graph/payload hashes; acquisition-time helper/source hashes are not established by its format" :
            "direct live witness binds simulator/helper acquisition hashes, graph, source ADC and adopted command payload hashes",
        result...)
end

function main(arguments=ARGS)
    require(length(arguments) == 6, "expected --package PACKAGE --report REPORT --output NEW.json")
    options = Dict{String,String}()
    for i in 1:2:6
        require(arguments[i] in ("--package", "--report", "--output") && !haskey(options, arguments[i]), "unknown or duplicate option")
        options[arguments[i]] = arguments[i + 1]
    end
    package = realpath(options["--package"])
    output = diagnostic_output(package, options["--output"])
    result = try
        analyze(package, abspath(options["--report"]), output)
    catch error
        raw_path = output * ".replayed.frames.u16le"
        partial_adc = isfile(raw_path) ? (; path=raw_path, bytes=filesize(raw_path), sha256=file_hash(raw_path)) : nothing
        (; version=1, verified=false, failure=sprint(showerror, error),
            partial_replayed_adc=partial_adc,
            scope="simulation diagnostic failed; no correction score established")
    end
    mkpath(dirname(output))
    temporary, io = mktemp(dirname(output))
    try
        write(io, JSON3.write(result), '\n')
        close(io)
        mv(temporary, output)
    finally
        isopen(io) && close(io)
        ispath(temporary) && rm(temporary)
    end
    return result.verified ? 0 : 1
end

end # module

abspath(PROGRAM_FILE) == (@__FILE__) && exit(CorrectionAnalysis.main())
