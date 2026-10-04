#!/usr/bin/env julia
"""Cold public-AOC probe preparation and chronological method reduction."""
module CalibrationMethodAnalysis

using JSON3
using SHA
include("calibration_client.jl")
using .CalibrationClient

digest(path) = bytes2hex(open(sha256, path))
document(path) = JSON3.read(read(path, String))

function write_new(path, value)
    (ispath(path) || islink(path)) && throw(ArgumentError("output already exists: $path"))
    open(path, "w") do io
        JSON3.write(io, value)
        write(io, '\n')
    end
    return path
end

function prepared_specification(recipe, method; physical_count=277, measurements=376)
    length(recipe.reference) == physical_count && length(recipe.amplitudes) == physical_count ||
        throw(DimensionMismatch("recipe physical command dimension differs"))
    typeof(method.version) <: Integer && typeof(method.version) !== Bool && method.version == 1 ||
        throw(ArgumentError("unsupported method version"))
    typeof(method.run) <: Integer && typeof(method.run) !== Bool && 0 < method.run <= typemax(UInt64) ||
        throw(ArgumentError("method run must be a positive UInt64 integer"))
    method.order in ("forward", "reverse") || throw(ArgumentError("invalid method ordering"))
    timeout = recipe.request_timeout_ns
    specification = (; run=method.run, reference=recipe.reference, amplitudes=recipe.amplitudes,
        measurements, frames_per_probe=recipe.frames_per_probe, settling=recipe.settling,
        timeouts_ns=(; ownership=timeout, adoption=timeout, settling=timeout,
            collection=timeout, restoration=timeout))
    return hasproperty(method, :probe_basis) ? merge(specification, (; probe_basis=method.probe_basis)) : specification
end

function ordered_plan(canonical, order)
    count = size(canonical.figures, 1)
    permutation = order == "forward" ? collect(1:count) : order == "reverse" ? collect(count:-1:1) :
        throw(ArgumentError("invalid chronological order"))
    chronological = merge(canonical, (; plan=merge(canonical.plan, (; probes=canonical.plan.probes[permutation])),
        figures=canonical.figures[permutation, :]))
    return chronological, permutation
end

function canonical_responses(chronological_responses, permutation)
    count = size(chronological_responses, 1)
    length(permutation) == count && sort(collect(permutation)) == collect(1:count) ||
        throw(ArgumentError("invalid chronology-to-canonical permutation"))
    # Only numerical values are reordered, after chronological identity validation.
    return chronological_responses[invperm(collect(permutation)), :]
end

function basis_metadata(canonical)
    positive = canonical.figures[1:2:end, :] .- permutedims(canonical.reference)
    if hasproperty(canonical, :probe_basis)
        basis = canonical.probe_basis
        # The client owns basis construction and estimator selection. These public
        # prepared fields describe its actual physical deltas, not new estimator math.
        kind = basis.description.kind
        coordinates = kind in ("zonal_push_pull", "hadamard_push_pull") ? "physical_actuator" : "mode_direction"
        description = basis.description
    else
        kind, coordinates = "zonal_push_pull", "physical_actuator"
        description = (; ordering="positive/negative per physical coordinate")
    end
    return (; kind, coordinate_kind=coordinates, positive_commands=positive,
        positive_commands_shape=size(positive), positive_commands_layout="column_major",
        amplitudes=canonical.amplitudes, description)
end

"""Select the measurement contract from retained package provenance, never recipe dimensions."""
function selected_profile(output, package)
    identity = document(bound_path(output, "base-identity.json"))
    all(name -> hasproperty(identity, name), (:files, :selected_profile, :startup_snapshot)) ||
        throw(ArgumentError("missing selected base identities"))
    for relative in ("deployment.conf", "provenance.json")
        haskey(identity.files, relative) && identity.files[relative] isa AbstractString &&
            occursin(r"^[0-9a-f]{64}$", identity.files[relative]) ||
            throw(ArgumentError("missing base file identity: $relative"))
    end
    selected = identity.selected_profile
    all(name -> hasproperty(selected, name), (:profile, :engine, :mode, :backend)) ||
        throw(ArgumentError("incomplete selected profile identity"))
    selected.profile in ("classic", "copper") && selected.engine in ("fgn", "jfg") &&
        selected.mode == "frame" && selected.backend in ("cpu", "cuda", "amdgpu") ||
        throw(ArgumentError("method requires selected complete-frame Classic/Copper science backend"))
    provenance = document(bound_path(package, "provenance.json"))
    all(name -> hasproperty(provenance, name),
        (:profile, :engine, :mode, :calibration_stage, :illumination, :source_provenance)) ||
        throw(ArgumentError("missing acquisition package profile identity"))
    source = provenance.source_provenance
    all(name -> hasproperty(source, name), (:profile, :engine, :mode, :hil)) &&
        hasproperty(source.hil, :backend) || throw(ArgumentError("missing source profile identity"))
    provenance.profile == source.profile == selected.profile &&
        provenance.engine == source.engine == selected.engine &&
        provenance.mode == source.mode == selected.mode && source.hil.backend == selected.backend &&
        provenance.calibration_stage == "interaction" && provenance.illumination == "lamp" ||
        throw(ArgumentError("selected and acquisition package profile identities differ"))
    copper = selected.profile == "copper"
    return (; profile=selected.profile, backend=selected.backend, physical_count=277, measurements=copper ? 3600 : 376,
        command_units="micrometre OPD", measurement_units=copper ? "normalized pixel" : "detector pixel coordinate",
        response_units=copper ? "normalized pixel per micrometre OPD of estimated coordinate" :
            "detector pixel coordinate per micrometre OPD of estimated coordinate")
end

function profile_specification(recipe, method, selected)
    if selected.profile == "copper"
        hasproperty(recipe, :adc_upper_rail) && typeof(recipe.adc_upper_rail) <: Integer &&
            typeof(recipe.adc_upper_rail) !== Bool && recipe.adc_upper_rail == 16383 ||
            throw(ArgumentError("Copper method requires 14-bit ADC rail"))
        rule = recipe.settling
        Set(keys(rule)) == Set((:kind, :frames)) && rule.kind == "discard_exposures" &&
            typeof(rule.frames) <: Integer && typeof(rule.frames) !== Bool && 1 <= rule.frames <= 4096 ||
            throw(ArgumentError("Copper method requires discarded settling exposures"))
    end
    return prepared_specification(recipe, method; physical_count=selected.physical_count,
        measurements=selected.measurements)
end

function prepare_method(output, package)
    recipe = document(joinpath(output, "recipe.json"))
    method = document(joinpath(output, "method.json"))
    selected = selected_profile(output, package)
    specification = profile_specification(recipe, method, selected)
    canonical = prepare_plan(specification)
    chronological, permutation = ordered_plan(canonical, method.order)
    write_new(joinpath(output, "prepared-specification.json"), specification)
    write_new(joinpath(output, "canonical-order.json"), (; chronology_to_canonical=permutation,
        meaning="chronological probe i uses canonical row chronology_to_canonical[i]"))
    write_new(joinpath(output, "canonical-plan.json"), canonical.plan)
    (ispath(joinpath(output, "interaction-plan.json")) || islink(joinpath(output, "interaction-plan.json"))) &&
        throw(ArgumentError("interaction plan already exists"))
    write_plan(joinpath(output, "interaction-plan.json"), chronological)
    files = ("recipe.json", "method.json", "base-identity.json", "prepared-specification.json",
        "canonical-order.json", "canonical-plan.json", "interaction-plan.json",
        "analysis/calibration_method_analysis.jl", "analysis/calibration_client.jl")
    inputs = Dict(relative => digest(joinpath(output, relative)) for relative in files)
    inputs["package_provenance"] = digest(bound_path(package, "provenance.json"))
    inputs["installed_client"] = digest(joinpath(package, "hil/calibration_client.jl"))
    inputs["analysis/calibration_client.jl"] == inputs["installed_client"] ||
        throw(ArgumentError("frozen client differs from installed client"))
    return write_new(joinpath(output, "preparation.json"), (; version=1, status="prepared", profile=selected.profile, backend=selected.backend,
        signed_batches=size(canonical.figures, 1), measurements=canonical.measurements,
        frames_per_probe=canonical.frames_per_probe, physical_coordinates=length(canonical.reference),
        order=method.order, basis=basis_metadata(canonical), input_hashes=inputs))
end

function bound_path(root, relative)
    isabspath(relative) && throw(ArgumentError("absolute frozen path"))
    any(part -> part == "..", splitpath(relative)) && throw(ArgumentError("escaping frozen path"))
    path = joinpath(root, relative)
    isfile(path) && !islink(path) || throw(ArgumentError("missing or symlinked frozen file"))
    realpath(path) == abspath(path) || throw(ArgumentError("frozen path has a symlink parent"))
    return path
end

function check_seal(output, package, expected)
    sealpath = joinpath(output, "prepared-identity.json")
    digest(sealpath) == expected || throw(ArgumentError("prepared identity hash changed"))
    seal = document(sealpath)
    for relative in ("recipe.json", "method.json", "base-identity.json", "prepared-specification.json",
            "canonical-order.json", "canonical-plan.json", "interaction-plan.json",
            "analysis/calibration_method_analysis.jl", "analysis/calibration_client.jl")
        haskey(seal.files, relative) || throw(ArgumentError("missing frozen input identity: $relative"))
    end
    for relative in ("provenance.json", "hil/calibration_client.jl")
        haskey(seal.package_files, relative) || throw(ArgumentError("missing frozen package identity: $relative"))
    end
    for (root, files) in ((output, seal.files), (package, seal.package_files))
        for (relative, hash) in pairs(files)
            digest(bound_path(root, String(relative))) == hash || throw(ArgumentError("frozen input hash changed: $relative"))
        end
    end
    return seal
end

function validate_stage(stage)
    all(name -> hasproperty(stage, name) && getproperty(stage, name) === true,
        (:restoration_confirmed, :release_confirmed, :shutdown_confirmed)) ||
        throw(ArgumentError("stage lifecycle incomplete"))
    hasproperty(stage, :failure) && stage.failure !== nothing && throw(ArgumentError("stage reports failure"))
    hasproperty(stage, :recovery_failure) && stage.recovery_failure !== nothing && throw(ArgumentError("stage recovery failed"))
    stage.launcher_exit == 0 && typeof(stage.launcher_exit) !== Bool || throw(ArgumentError("launcher failed"))
    stage.final.phase == "stopped" || throw(ArgumentError("deployment did not stop"))
    hasproperty(stage.final, :error) && stage.final.error !== nothing && throw(ArgumentError("final deployment error"))
    hasproperty(stage.final, :cleanup_errors) && !isempty(stage.final.cleanup_errors) && throw(ArgumentError("cleanup incomplete"))
    return nothing
end

function reduce_method(output, package, expected_seal)
    Base.ENDIAN_BOM == 0x04030201 || throw(ArgumentError("F32_LE writer requires little-endian host"))
    evidence = joinpath(output, "evidence")
    stage = document(joinpath(evidence, "stage-result.json"))
    validate_stage(stage)
    # Admission precedes scientific consumption and rebinding. The expected seal
    # is passed by the owner from before acquisition, not read from a mutable file.
    seal = check_seal(output, package, expected_seal)
    recipe, method = document(joinpath(output, "recipe.json")), document(joinpath(output, "method.json"))
    selected = selected_profile(output, package)
    canonical = prepare_plan(profile_specification(recipe, method, selected))
    chronological, permutation = ordered_plan(canonical, method.order)
    retained = document(joinpath(output, "canonical-order.json"))
    collect(retained.chronology_to_canonical) == permutation || throw(ArgumentError("canonical ordering differs"))
    # Verify the reconstructed public CLI plan exactly matches the frozen JSON.
    JSON3.write(chronological.plan) * "\n" == read(joinpath(output, "interaction-plan.json"), String) ||
        throw(ArgumentError("prepared chronological plan differs"))
    cli_path = joinpath(evidence, "rtc-calibrate.json")
    values = validate_result(read(cli_path, String), chronological)
    responses = canonical_responses(values, permutation)
    started = time_ns()
    matrix = estimate_interaction_matrix(canonical, responses)
    estimation_ns = time_ns() - started
    destination = joinpath(output, "candidate-response.f32le")
    (ispath(destination) || islink(destination)) && throw(ArgumentError("candidate payload already exists"))
    open(destination, "w") do io
        # ROW_MAJOR measurement-by-estimated-coordinate, explicit cold conversion.
        write(io, reinterpret(UInt8, vec(permutedims(matrix))))
    end
    basis = basis_metadata(canonical)
    return write_new(joinpath(output, "candidate-response.json"), (; version=1,
        status="complete-unaccepted-candidate", profile=selected.profile, backend=selected.backend, shape=size(matrix), layout="ROW_MAJOR", element_type="F32_LE",
        path="candidate-response.f32le", sha256=digest(destination), coordinate_kind=basis.coordinate_kind,
        command_units=selected.command_units, measurement_units=selected.measurement_units,
        response_units=selected.response_units,
        basis, order=method.order, chronology_to_canonical=permutation,
        frames_per_signed_batch=canonical.frames_per_probe, signed_batches=size(canonical.figures, 1),
        source_hashes=seal.files, package_hashes=seal.package_files, prepared_identity_sha256=expected_seal,
        cli_result_sha256=digest(cli_path), stage_result_sha256=digest(joinpath(evidence, "stage-result.json")),
        cold_estimation_ns=estimation_ns,
        acceptance="none; no reconstructor selection, physical activation or scientific acceptance"))
end

function main(args)
    if length(args) == 3 && args[1] == "prepare"
        prepare_method(args[2], args[3])
    elseif length(args) == 4 && args[1] == "reduce"
        reduce_method(args[2], args[3], args[4])
    else
        throw(ArgumentError("usage: calibration_method_analysis.jl prepare OUTPUT PACKAGE | reduce OUTPUT PACKAGE EXPECTED_SEAL_SHA256"))
    end
end

end

if abspath(PROGRAM_FILE) == @__FILE__
    CalibrationMethodAnalysis.main(ARGS)
end
