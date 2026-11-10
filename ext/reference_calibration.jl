# CPU simulator reference candidates. Acquisition remains in the existing native
# owner; AOC owns the numerical reductions. No activation or recording is implied.
const ReferenceFrames = AdaptiveOpticsCalibration.ReferenceFrames
const Preparation = PipeWireAORTC.CalibrationPreparation
const ReferenceClient = PipeWireAORTC.CalibrationActionClient

function reference_counts(recipe)
    spec = get(recipe, "references", nothing)
    validate_reference_stages(spec)
    IC.fields(
        spec,
        ("source", "dark", "lamp", "qualification"),
        ("source", "dark", "lamp", "qualification"),
        "reference procedure",
    )
    spec["source"] == "internal-source" ||
        throw(ArgumentError("reference source must be internal-source"))
    counts = map(("dark", "lamp", "qualification")) do name
        value = spec[name]
        validate_reference_stage(value, name)
        IC.fields(
            value, ("samples", "discard_exposures"), ("samples", "discard_exposures"), name
        )
        samples, discard = value["samples"], value["discard_exposures"]
        validate_reference_samples(samples, name)
        validate_reference_discard(discard, name)
        (; samples = Int(samples), discard = Int(discard))
    end
    counts[3].discard >= counts[2].discard + counts[2].samples || throw(
        ArgumentError(
            "qualification must exclude the reset simulator's complete training window"
        ),
    )
    return NamedTuple{(:dark, :lamp, :qualification)}(counts)
end

function reference_geometry(application, parameters)
    prefix = get(ENV, "PIPEWIREAO_PREFIX", "/opt/pipewireao")
    document = PipeWireAORTC.DeploymentConfiguration.decode(
        joinpath(application, "rtc", "graph.conf"), prefix
    )
    node = only(
        filter(node -> node["name"] == "shack-hartmann", document["filter.graph"]["nodes"])
    )
    node["label"] == "shack-hartmann-image-f32" || throw(
        ArgumentError("reference procedure requires the declared image centroid estimator"),
    )
    config = node["config"]
    config["coordinate_scale"] == 1 ||
        throw(ArgumentError("reference centroids require pixel coordinate scale one"))
    rows, columns = Tuple(config["image_size"])
    roi_rows, roi_columns = Tuple(config["subaperture_size"])
    count = config["subaperture_count"]
    size(parameters[:background]) == (rows, columns) &&
    size(parameters[Symbol("reference-slopes")]) == (count, 2) &&
    size(parameters[:active]) == (count,) &&
    size(parameters[:thresholds]) == (count, 2) || throw(
        DimensionMismatch(
            "reference parameters differ from declared detector/ROI geometry"
        ),
    )
    expected = Float32[
        (column - (roi_columns - 1) / 2) for row in 0:(roi_rows-1) for
        column in 0:(roi_columns-1)
    ]
    expected_y = Float32[
        (row - (roi_rows - 1) / 2) for row in 0:(roi_rows-1) for column in 0:(roi_columns-1)
    ]
    parameters[:coordinates] == hcat(expected, expected_y) || throw(
        ArgumentError(
            "centroid coordinates must be the declared centered detector-pixel axes"
        ),
    )
    return (; rows, columns, count)
end

function reference_source!(directory, name, values; artifacts = nothing)
    path = joinpath(directory, name * ".fits")
    Calibration.write_fits(path, values)
    if artifacts !== nothing
        artifacts[name] = Dict(
            "path" => basename(path),
            "hdu" => 1,
            "axes" => collect(ndims(values) == 1 ? (1,) : (2, 1)),
            "target_type" => string(eltype(values)),
            "target_shape" => collect(size(values)),
            "sha256" => Calibration.digest(path),
            "storage_order" => "row-major",
        )
    end
    return PipeWireAORTC.Artifacts.FITSArtifact(
        path; axes = ndims(values) == 1 ? nothing : (2, 1)
    )
end

reference_application_hashes(application) = Dict(
    relpath(joinpath(root, file), application) =>
        Calibration.digest(joinpath(root, file)) for
    (root, _, files) in walkdir(application) for file in files
)

function reference_product(plan, state)
    result = AdaptiveOpticsCalibration.allocate_result(plan)
    workspace = AdaptiveOpticsCalibration.allocate_workspace(plan)
    AdaptiveOpticsCalibration.process!(result, workspace, plan, state)
    return result
end

# Admitted samples are borrowed. One AOC update consumes exactly one exposure;
# no raw history or inactive-ROI data are retained by the reducer.
function reference_lamp_update!(state, plan, sample, indices, reference)
    arrays = sample.arrays
    centroids = reshape(
        vec(
            permutedims(
                Float64.(arrays.slopes[indices, :]) .+ Float64.(reference[indices, :])
            ),
        ),
        2length(indices),
        1,
    )
    input = ReferenceFrames.LampReferenceInputs(
        centroids,
        reshape(arrays.flux[indices], length(indices), 1),
        reshape(arrays.validity[indices], length(indices), 1),
        reshape(arrays.raw, size(arrays.raw)..., 1);
        centroids_are_absolute = true,
    )
    AdaptiveOpticsCalibration.process!(state, plan, input)
    return nothing
end

function reference_restoration!(client, reference, deadline::Int64)
    restored = ReferenceClient.complete!(
        client, Actions.Restore(reference, Actions.Immediate()); deadline, record = false
    )
    confirm_reference_restoration(restored, reference)
    released = ReferenceClient.complete!(
        client, Actions.Release(); deadline, record = false
    )
    confirm_reference_release(released)
    return nothing
end

function reference_stage(
    application,
    remote,
    sources,
    reference,
    run,
    serial,
    stage,
    condition,
    counts,
    timeout_s,
    cancelled,
    confirm,
    configuration,
    check_application,
    reduce;
    frontend_outputs = (:slopes, :flux, :validity),
    commands = nothing,
    probe_command = nothing,
    measurements::Union{Nothing,Symbol} = :slopes,
)
    cancelled() && throw(InterruptException())
    check_application()
    clock = Clocks.SystemNanoClock()
    start = Clocks.time_nanos(clock)
    duration = round(Int64, timeout_s * 1e9)
    deadline = Base.Checked.checked_add(start, duration)
    cleanup_deadline = Base.Checked.checked_add(deadline, duration)
    frontend = command = server = client = serving = nothing
    selected_reference =
        probe_command === nothing ? reference : getproperty(reference, probe_command)
    gate = nothing
    observed = Ref{Union{Nothing,Actions.Exposure}}(nothing)
    boundary = Ref{Union{Nothing,Actions.AcquisitionCursor}}(nothing)
    delivered = Ref(0)
    consumer_error = Ref{Any}(nothing)
    released = false
    report = nothing
    errors = Exception[]
    try
        frontend = Calibration.calibration_graph(
            application;
            inputs = (raw = "pixel-calibration:raw",),
            outputs = frontend_outputs,
            parameter_sources = sources,
        )
        measurement_count =
            measurements === nothing ? 0 :
            prod(
                getproperty(FilterGraphs.output_formats(frontend.graph), measurements).shape
            )
        Actions.preflight_collect_reply(measurement_count, counts.samples)
        command = if commands === nothing
            Calibration.calibration_graph(
                application;
                inputs = (requested = "pdm-command:requested",),
                outputs = (:demanded, Symbol("constraint-feedback")),
            )
        else
            # Names and endpoints come from the declared instrument graph. Each
            # projection keeps its own conditioner, units and physical shape.
            built = Any[]
            try
                for specification in values(commands)
                    push!(
                        built,
                        Calibration.calibration_graph(
                            application;
                            inputs = (requested = specification.requested,),
                            outputs = (
                                demanded = specification.demanded,
                                var"constraint-feedback" = specification.feedback,
                            ),
                        ),
                    )
                end
                NamedTuple{keys(commands)}(Tuple(built))
            catch primary
                failures = Exception[primary]
                for descriptor in reverse(built)
                    try
                        FilterGraphPipeWire.close_execution(descriptor.graph)
                    catch cleanup
                        push!(failures, cleanup)
                    end
                end
                length(failures) == 1 && rethrow()
                throw(CompositeException(failures))
            end
        end
        name = "rtc.reference.$(uuid4())"
        instance = Int64(serial)
        identity = bytes2hex(
            Calibration.sha256(
                codeunits(
                    join(
                        vcat(
                            [
                                frontend.source_graph_sha256,
                                condition,
                                configuration.application_sha256,
                                configuration.prescription_identity,
                                configuration.simulation_sha256,
                                configuration.reference_figure_sha256,
                            ],
                            [
                                "$(port):$(frontend.parameter_sha256[port])" for port in
                                sort!(collect(keys(frontend.parameter_sha256)); by = string)
                            ],
                        ),
                        "\n",
                    ),
                ),
            ),
        )
        request = Preparation.Request(;
            run,
            serial,
            stage,
            condition,
            configuration_identity = "sha256:" * identity,
            kind = :simulated,
            issued_at = start,
            deadline,
        )
        gate = Preparation.Procedure(request; clock)
        gate.state == :pending ||
            throw(ArgumentError("reference preparation deadline expired"))
        function consume(sample, exposure)
            try
                cancelled() && throw(InterruptException())
                Clocks.time_nanos(clock) < deadline ||
                    error("reference preparation expired during acquisition")
                previous = observed[]
                after = something(boundary[])
                exposure.domain == after.domain &&
                exposure.generation == after.generation &&
                exposure.sequence ==
                (previous === nothing ? after.sequence : previous.sequence) + 1 &&
                exposure.start_model_ns >= (
                    previous === nothing ? after.model_ns :
                    previous.start_model_ns + previous.duration_ns
                ) || error(
                    "reference exposure does not follow its correlated acquisition boundary",
                )
                delivered[] < counts.samples || error("reference sample count overrun")
                reduce(sample, exposure)
                observed[] = exposure
                delivered[] += 1
            catch error
                consumer_error[] = error
                rethrow()
            end
        end
        server = Calibration.prepare_initial_calibration(
            application,
            remote,
            frontend,
            command;
            reference,
            name,
            instance,
            deadline,
            clock,
            simulation_graph = condition,
            consume,
            probe_command,
            measurements,
        )
        hashes = copy(frontend.parameter_sha256)
        frontend = command = nothing # ownership transferred to the native endpoint
        serving = @async try
            Endpoint.serve!(server; deadline = cleanup_deadline)
            nothing
        catch error
            error
        end
        client = ReferenceClient.connect(
            ReferenceClient.Binding(remote, name, getpid(), instance),
            run,
            duration;
            command_count = length(selected_reference),
            deadline,
            clock,
        )
        action(value) = ReferenceClient.complete!(client, value; deadline, record = false)
        held = action(Actions.Hold())
        confirm_reference_hold(held)
        acquisition_domain = bytes2hex(collect(server.effects.acquisition_domain.bytes))
        witness = "$name/$instance/$acquisition_domain"
        evidence =
            confirm === nothing ?
            Preparation.Confirmation(
                request; observed_at = Clocks.time_nanos(clock), witness
            ) : confirm(request, witness)
        confirm_reference_witness(evidence, witness)
        Preparation.complete!(gate, evidence)
        cancelled() && throw(InterruptException())
        adopted = action(Actions.Adopt(UInt32(0), selected_reference))
        confirm_reference_adoption(adopted, selected_reference)
        rule =
            counts.discard == 0 ? Actions.Immediate() :
            Actions.DiscardExposures(UInt32(counts.discard))
        settled = action(Actions.Settle(UInt32(0), adopted.cursor, rule))
        confirm_reference_settling(settled)
        boundary[] = settled.cursor
        Preparation.check_current!(gate)
        cancelled() && throw(InterruptException())
        response = action(
            Actions.Collect(
                UInt32(0), settled.cursor, UInt32(measurement_count), UInt32(counts.samples)
            ),
        )
        # Dark/diagnostic lamp data may have false WFS validity. Their scientific
        # eligibility is determined separately by AOC, never by Responses.valid.
        confirm_reference_collection(response)
        consumer_error[] === nothing || throw(consumer_error[])
        delivered[] == counts.samples &&
        length(response.exposures) == counts.samples &&
        length(response.values) == measurement_count || error(
            "reference collection differs from its declared sample/measurement counts"
        )
        Preparation.check_current!(gate)
        cancelled() && throw(InterruptException())
        last = something(observed[])
        report = Dict{String,Any}(
            "stage" => stage,
            "condition" => condition,
            "run" => run,
            "serial" => serial,
            "samples" => delivered[],
            "discard_exposures" => counts.discard,
            "witness" => evidence.witness,
            "configuration_identity" => request.configuration_identity,
            "observed_at" => evidence.observed_at / 1e9,
            "deadline" => deadline / 1e9,
            "acquisition_domain" => acquisition_domain,
            "generation" => last.generation,
            "first_sequence" => first(response.exposures).sequence,
            "last_sequence" => last.sequence,
            "first_start_ns" => first(response.exposures).start_model_ns,
            "last_end_ns" => last.start_model_ns + last.duration_ns,
            "parameter_sha256" => Dict(string(port) => hash for (port, hash) in hashes),
        )
        reference_restoration!(client, selected_reference, cleanup_deadline)
        released = true
        report["restored"] = report["released"] = true
    catch error
        push!(errors, error)
        gate === nothing || Preparation.invalidate!(gate, "Reference stage aborted")
        if client !== nothing && client.can_restore && !released
            try
                reference_restoration!(client, selected_reference, cleanup_deadline)
                released = true
            catch cleanup
                push!(errors, cleanup)
            end
        end
    finally
        if client !== nothing
            try
                close(client)
            catch error
                push!(errors, error)
            end
        end
        # Release completion is retired by the exact client's disconnect. On
        # unknown outcomes close/fence first; no recovery command is fabricated.
        if server !== nothing && !released
            try
                close(server)
            catch error
                push!(errors, error)
            end
        end
        if serving !== nothing
            try
                result = fetch(serving)
                result === nothing || push!(errors, result)
            catch error
                push!(errors, error)
            end
        end
        if server !== nothing
            try
                close(server)
            catch error
                push!(errors, error)
            end
        end
        for descriptor in calibration_descriptors(frontend, command)
            descriptor === nothing && continue
            try
                FilterGraphPipeWire.close_execution(descriptor.graph)
            catch error
                push!(errors, error)
            end
        end
    end
    isempty(errors) ||
        (length(errors) == 1 ? throw(only(errors)) : throw(CompositeException(errors)))
    check_application()
    return report
end

reference_remotes(remote::AbstractString) =
    reference_remotes((; dark = remote, lamp = remote, qualification = remote))
function reference_remotes(remotes::NamedTuple)
    Set(keys(remotes)) == Set((:dark, :lamp, :qualification)) || throw(
        ArgumentError("remote must identify the private core for each reference stage")
    )
    return map(Control.private_remote, remotes)
end
reference_remotes(_) =
    throw(ArgumentError("remote must identify the private core for each reference stage"))

"""
    calibrate_references(application, output; remote, reference, run=1,
        timeout_s=300, cancelled=()->false, confirm=nothing)

Produce a fresh candidate directory from a built CPU application's declared
`references` recipe. The recipe's selected sensor determines the procedure.
Shack–Hartmann trains full-ROI centroid references and a frozen eligible mask.
Pyramid averages normalized pupil pixels and maps them through the frozen
reconstructor. Both compare an independent reset-simulator window against the
frozen training result.

`remote` is a private core path or `(dark=..., lamp=..., qualification=...)`.
The caller owns those cores. Supply the absolute Float32 command figure for
Shack–Hartmann or a named figure for each declared pyramid command Port.
Pyramid requires one thread per command projection plus the frontend and
control owner. Each stage completes restoration and release before the next.
Cancellation is checked at completed-action and sample boundaries.

`confirm(request,witness)` optionally supplies correlated simulator preparation
evidence after native hold/authority preparation. This endpoint supports the CPU
simulator. AOC numerical status and qualification diagnostics describe the
candidate produced by those simulator exposures.
"""
function Calibration.calibrate_references(
    application,
    output;
    remote,
    reference,
    run::Integer = 1,
    timeout_s::Real = 300,
    cancelled = () -> false,
    confirm = nothing,
)
    output = Calibration._calibration_output((application,), output)
    Threads.nthreads(:default) >= 3 ||
        throw(ArgumentError("reference acquisition requires at least three Julia threads"))
    0 < run <= typemax(UInt64) ||
        throw(ArgumentError("reference run must be nonzero UInt64"))
    isfinite(timeout_s) && 0 < timeout_s <= 3600 ||
        throw(ArgumentError("reference timeout must be in (0,3600] seconds"))
    timeout_s = Float64(timeout_s)
    timeout_s * 1e9 >= 1 ||
        throw(ArgumentError("reference timeout is below one nanosecond"))
    remotes = reference_remotes(remote)
    recipe = Calibration.read_recipe(application)
    counts = reference_counts(recipe)
    options = PipeWireAORTC.AOSOwner.configuration(joinpath(application, "simulation.conf"))
    options.backend === :cpu && options.frame_encoding === :uint16 ||
        throw(ArgumentError("reference acquisition requires a UInt16 CPU detector"))
    declaration = IC.load_simulation(options.plant.definition)
    kind = Calibration.recipe_sensor_kind(recipe, declaration)
    return _calibrate_references(
        kind, application, output, recipe, counts, options, declaration;
        remote = remotes, reference, run, timeout_s, cancelled, confirm,
    )
end

_calibrate_references(::Val{Kind}, args...; kwargs...) where {Kind} =
    throw(ArgumentError("unsupported reference calibration sensor procedure: $Kind"))

function _calibrate_references(
    ::Val{:shack_hartmann}, application, output, _recipe, counts, options, declaration;
    remote, reference, run, timeout_s, cancelled, confirm,
)
    validate_reference_figure(reference)
    parameters = Calibration.read_parameters(application)
    geometry = reference_geometry(application, parameters)
    length(reference) == options.command_count && all(isfinite, reference) ||
        throw(ArgumentError("reference figure differs from the declared physical command"))
    reference = collect(reference)
    configured = IC.settings(declaration, options.plant.settings)
    application_hashes = reference_application_hashes(application)
    function check_application()
        reference_application_hashes(application) == application_hashes ||
            error("built application changed during reference acquisition")
        return nothing
    end
    configuration = (;
        application_sha256 = bytes2hex(
            Calibration.sha256(
                codeunits(
                    join(
                        [
                            "$path:$(application_hashes[path])" for
                            path in sort!(collect(keys(application_hashes)))
                        ],
                        "\n",
                    ),
                ),
            ),
        ),
        prescription_identity = IC.prescription_identity(declaration, configured),
        simulation_sha256 = Calibration.digest(joinpath(application, "simulation.conf")),
        reference_figure_sha256 = bytes2hex(
            Calibration.sha256(PipeWireAORTC.Artifacts.packed_bytes(reference))
        ),
    )
    production = IC.graph_document(declaration, configured)
    detector = only(filter(node -> node["type"] == "detector", production["nodes"]))
    bits = detector["config"]["bits"]
    validate_reference_adc_bits(bits)
    rail = UInt32(1) << bits
    rail -= UInt32(1)
    thresholds = copy(parameters[:thresholds][:, 2])
    dark_plan = AdaptiveOpticsCalibration.prepare(
        ReferenceFrames.DarkFrameMoments(),
        ReferenceFrames.DarkFrameSpecification(
            geometry.rows, geometry.columns, counts.dark.samples
        ),
    )
    dark_state = ReferenceFrames.DarkFrameState(dark_plan)
    lamp_plan = AdaptiveOpticsCalibration.prepare(
        ReferenceFrames.LampReference(thresholds, rail),
        ReferenceFrames.LampReferenceSpecification(
            geometry.rows, geometry.columns, geometry.count, counts.lamp.samples
        ),
    )
    lamp_state = ReferenceFrames.LampReferenceState(lamp_plan)
    cancelled() && throw(InterruptException())
    mkpath(dirname(output))
    return mktempdir(dirname(output); prefix = ".reference-candidate-") do temporary
        reports = Any[]
        artifacts = Dict{String,Any}()
        write_candidate(name, values) =
            reference_source!(temporary, name, values; artifacts)
        push!(
            reports,
            reference_stage(
                application,
                remote.dark,
                Dict(),
                reference,
                UInt64(run),
                UInt64(1),
                "dark",
                "dark",
                counts.dark,
                timeout_s,
                cancelled,
                confirm,
                configuration,
                check_application,
                (sample, exposure) -> AdaptiveOpticsCalibration.process!(
                    dark_state, dark_plan, sample.arrays.raw
                ),
            ),
        )
        dark = reference_product(dark_plan, dark_state)
        dark.status == ReferenceFrames.Valid || error("dark reduction is invalid")
        background = Float32.(dark.mean)
        sources = Dict{Symbol,PipeWireAORTC.Artifacts.FITSArtifact}(
            :background => write_candidate("background", background),
            :active => write_candidate("training-active", fill(true, geometry.count)),
            Symbol("reference-slopes") => write_candidate(
                "training-reference-slopes", zeros(Float32, geometry.count, 2)
            ),
        )
        zero_reference = zeros(Float32, geometry.count, 2)
        universe = collect(1:geometry.count)
        push!(
            reports,
            reference_stage(
                application,
                remote.lamp,
                sources,
                reference,
                UInt64(run),
                UInt64(2),
                "lamp-training",
                "internal-source",
                counts.lamp,
                timeout_s,
                cancelled,
                confirm,
                configuration,
                check_application,
                (sample, exposure) -> reference_lamp_update!(
                    lamp_state, lamp_plan, sample, universe, zero_reference
                ),
            ),
        )
        lamp = reference_product(lamp_plan, lamp_state)
        active = copy(lamp.eligible)
        frozen_reference = permutedims(
            reshape(Float32.(lamp.reference_centroids), 2, geometry.count)
        )
        sources[:active] = write_candidate("active", active)
        sources[Symbol("reference-slopes")] = write_candidate(
            "reference-slopes", frozen_reference
        )
        indices = findall(active)
        qualification = nothing
        comparison_indices = Int[]
        difference = Float64[]
        if !isempty(indices)
            qualification_plan = AdaptiveOpticsCalibration.prepare(
                ReferenceFrames.LampReference(thresholds[indices], rail),
                ReferenceFrames.LampReferenceSpecification(
                    geometry.rows,
                    geometry.columns,
                    length(indices),
                    counts.qualification.samples,
                ),
            )
            qualification_state = ReferenceFrames.LampReferenceState(qualification_plan)
            push!(
                reports,
                reference_stage(
                    application,
                    remote.qualification,
                    sources,
                    reference,
                    UInt64(run),
                    UInt64(3),
                    "qualification",
                    "internal-source",
                    counts.qualification,
                    timeout_s,
                    cancelled,
                    confirm,
                    configuration,
                    check_application,
                    (sample, exposure) -> reference_lamp_update!(
                        qualification_state,
                        qualification_plan,
                        sample,
                        indices,
                        frozen_reference,
                    ),
                ),
            )
            qualification = reference_product(qualification_plan, qualification_state)
            write_candidate(
                "qualification-reference-centroids", qualification.reference_centroids
            )
            compared = findall(qualification.eligible)
            comparison_indices = indices[compared]
            for position in compared, coordinate in 1:2
                push!(
                    difference,
                    qualification.reference_centroids[2position-2+coordinate] -
                    frozen_reference[indices[position], coordinate],
                )
            end
            isempty(difference) ||
                write_candidate("qualification-reference-difference", difference)
        end
        cancelled() && throw(InterruptException())
        write_candidate("dark-mean", dark.mean)
        write_candidate("dark-variance", dark.variance)
        write_candidate("lamp-minimum-flux", lamp.minimum_flux)
        write_candidate("lamp-all-training-valid", lamp.all_training_valid)
        qualified =
            lamp.status == ReferenceFrames.Valid &&
            qualification !== nothing &&
            qualification.status == ReferenceFrames.Valid &&
            all(qualification.eligible)
        report = Dict{String,Any}(
            "version" => 1,
            "product" => "reference-candidate",
            "application_graph_sha256" =>
                Calibration.digest(joinpath(application, "rtc", "graph.conf")),
            "recipe_sha256" =>
                Calibration.digest(joinpath(application, "calibration", "recipe.conf")),
            "configuration" =>
                Dict(string(key) => value for (key, value) in pairs(configuration)),
            "application_files_sha256" => application_hashes,
            "aoc_version" => string(pkgversion(AdaptiveOpticsCalibration)),
            "run" => UInt64(run),
            "reference_figure" => reference,
            "detector" => detector,
            "adc_upper_rail" => rail,
            "dark_status" => string(dark.status),
            "lamp_status" => string(lamp.status),
            "declared_roi_count" => geometry.count,
            "eligible_roi_count" => length(indices),
            "active_roi_indices" => indices,
            "lamp_adc_maximum" => lamp.adc_maximum,
            "qualification_status" =>
                (qualification === nothing ? "NoEligible" : string(qualification.status)),
            "qualification_eligible" =>
                (qualification === nothing ? Bool[] : qualification.eligible),
            "qualification_minimum_flux" =>
                (qualification === nothing ? Float64[] : qualification.minimum_flux),
            "qualification_adc_maximum" =>
                (qualification === nothing ? 0.0 : qualification.adc_maximum),
            "qualification_eligibility_passed" => qualified,
            "qualification_centroid_comparison_roi_indices" => comparison_indices,
            "qualification_reference_difference_rms_pixels" => (
                isempty(difference) ? nothing :
                sqrt(sum(abs2, difference) / length(difference))
            ),
            "qualification_reference_difference_maximum_pixels" =>
                (isempty(difference) ? nothing : maximum(abs, difference)),
            "interaction_matrix_accepted" => false,
            "activation" => "candidate-only",
            "stages" => reports,
            "artifacts" => artifacts,
        )
        PipeWireAORTC.Common.write_yaml(
            joinpath(temporary, "result.yaml"),
            report;
            header = "Generated by InstrumentCalibration.calibrate_references; regenerate from the built application and declared reference recipe.",
        )
        check_application()
        mv(temporary, output)
        return report
    end
end

validate_reference_stages(spec::AbstractDict) = nothing
validate_reference_stages(spec) =
    throw(ArgumentError("recipe must declare reference stages"))

validate_reference_stage(value::AbstractDict, name) = nothing
validate_reference_stage(value, name) = throw(ArgumentError("$name must be a mapping"))

function validate_reference_samples(samples::Integer, name)
    (name == "dark" ? 2 : 1) <= samples <= 4096 ||
        throw(ArgumentError("invalid $name sample count"))
    return nothing
end
validate_reference_samples(samples, name) =
    throw(ArgumentError("invalid $name sample count"))

validate_reference_samples(samples::Bool, name) =
    throw(ArgumentError("invalid $name sample count"))

function validate_reference_discard(discard::Integer, name)
    0 <= discard <= 4096 || throw(ArgumentError("invalid $name discard count"))
    return nothing
end
validate_reference_discard(discard, name) =
    throw(ArgumentError("invalid $name discard count"))

validate_reference_discard(discard::Bool, name) =
    throw(ArgumentError("invalid $name discard count"))

function confirm_reference_restoration(restored::Actions.Restored, reference)
    restored.figure == reference && !restored.clipped ||
        error("reference stage restoration was not confirmed")
    return nothing
end
confirm_reference_restoration(restored, reference) =
    error("reference stage restoration was not confirmed")

confirm_reference_release(released::Actions.Released) = nothing
confirm_reference_release(released) = error("reference stage release was not confirmed")

confirm_reference_hold(held::Actions.Held) = nothing
confirm_reference_hold(held) = error("reference hold was not confirmed")

function confirm_reference_witness(evidence::Preparation.Confirmation, witness)
    evidence.witness == witness ||
        throw(ArgumentError("simulator preparation witness differs from the current owner"))
    return nothing
end
confirm_reference_witness(evidence, witness) =
    throw(ArgumentError("simulator preparation witness differs from the current owner"))

function confirm_reference_adoption(adopted::Actions.Adopted, reference)
    adopted.figure == reference && !adopted.clipped ||
        error("reference figure adoption was not confirmed")
    return nothing
end
confirm_reference_adoption(adopted, reference) =
    error("reference figure adoption was not confirmed")

confirm_reference_settling(settled::Actions.Settled) = nothing
confirm_reference_settling(settled) = error("reference settling boundary was not confirmed")

confirm_reference_collection(response::Actions.Responses) = nothing
confirm_reference_collection(response) = error("reference collection was not confirmed")

validate_reference_figure(reference::AbstractVector{Float32}) = nothing
validate_reference_figure(reference) =
    throw(ArgumentError("Shack–Hartmann references require one explicit Float32 command figure"))

function validate_reference_adc_bits(bits::Integer)
    1 <= bits <= 16 ||
        throw(ArgumentError("reference ADC rail requires a declared UInt16 bit depth"))
    return nothing
end
validate_reference_adc_bits(bits) =
    throw(ArgumentError("reference ADC rail requires a declared UInt16 bit depth"))
