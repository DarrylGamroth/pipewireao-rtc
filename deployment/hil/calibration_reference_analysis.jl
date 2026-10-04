#!/usr/bin/env julia
"""
Cold Copper candidate reduction through public AdaptiveOpticsCalibration methods.
Inputs are complete, restored, released and stopped deployed capture windows.
Pixels are individual absolute outputs normalized by the deployed previous-frame
normalizer. Sample variance is descriptive; independence-dependent standard error
and confidence intervals are not used. No reference is adopted in a science graph.
"""
module CalibrationReferenceAnalysis

using AdaptiveOpticsCalibration
using JSON3
using SHA
using LinearAlgebra

const AOC = AdaptiveOpticsCalibration
const RF = AOC.ReferenceFrames
const Diagnostics = AOC.Diagnostics
const STAGES = ("dark", "training", "qualification")
const CHANNELS = (
    (; name="raw", filename="raw.u16le", element="U16_LE", shape=[64,64], bytes=8192),
    (; name="pixels", filename="pixels.f32le", element="F32_LE", shape=[4,900], bytes=14400),
    (; name="intensity", filename="intensity.f32le", element="F32_LE", shape=[1], bytes=4),
)
const EXPOSURE_BYTES = 22596
const MEASUREMENT_ORDER = "pupil block then row/column wire order; intensity excluded"
const VARIANCE_SCOPE = "descriptive sample variance; previous-frame normalization can correlate samples; no confidence interval"
const QUALIFICATION_SCOPE = "non-actuating measured candidates; no interaction, inverse, correction or rate acceptance"

require(condition, message) = condition || throw(ArgumentError(message))
integer(::Bool, name, lower, upper) = throw(ArgumentError("$name must be an integer"))
function integer(value::Integer, name, lower, upper)
    require(lower <= value <= upper, "$name is out of range")
    return value
end
integer(value, name, lower, upper) = throw(ArgumentError("$name must be an integer"))
finite_number(::Bool, name) = throw(ArgumentError("$name must be a finite number"))
function finite_number(value::Real, name)
    require(isfinite(value), "$name must be finite")
    return value
end
finite_number(value, name) = throw(ArgumentError("$name must be a finite number"))
function exact_keys(value, names)
    require(Set(String.(keys(value))) == Set(names), "unexpected or missing fields")
end
function digest_string(value)
    require(value == lowercase(value) && occursin(r"^[0-9a-f]{64}$", value), "invalid SHA256")
    return value
end
digest(path) = bytes2hex(open(sha256, path))
function checked_file(root, relative, maximum; expected_bytes=nothing, sha=nothing)
    require(!isabspath(relative), "input path must be relative")
    path = abspath(joinpath(root, relative))
    canonical_root = realpath(root)
    require(startswith(path, canonical_root * "/"), "input path escapes evidence")
    require(isfile(path) && !islink(path) && realpath(path) == path, "input must be a regular unaliased file")
    size = filesize(path)
    require(size <= maximum && (expected_bytes === nothing || size == expected_bytes), "wrong input length")
    sha === nothing || require(digest(path) == digest_string(sha), "input digest mismatch")
    return path
end
function read_json(root, relative, maximum; kwargs...)
    path = checked_file(root, relative, maximum; kwargs...)
    return JSON3.read(read(path, String)), path
end

function validate_recipe(recipe)
    exact_keys(recipe, ("version","dark_frames","training_frames","qualification_frames",
        "seeds","lamp_magnitude","reference","settling","adc_upper_rail",
        "request_timeout_ns","stage_timeout_seconds"))
    integer(recipe["version"], "version", 1, 1)
    for stage in STAGES
        integer(recipe[stage * "_frames"], "samples", 2, 64)
    end
    exact_keys(recipe["seeds"], STAGES)
    seeds = [integer(recipe["seeds"][s], "seed", 0, typemax(UInt32)) for s in STAGES]
    require(length(unique(seeds)) == 3, "detector seeds must be distinct")
    finite_number(recipe["lamp_magnitude"], "lamp magnitude")
    require(length(recipe["reference"]) == 277, "reference must have 277 physical coordinates")
    for value in recipe["reference"]
        finite_number(value, "reference")
        require(isfinite(Float32(value)), "reference is not representable as Float32")
        require(iszero(value) || !iszero(Float32(value)), "nonzero reference underflows Float32")
    end
    validate_settling(recipe["settling"])
    integer(recipe["adc_upper_rail"], "ADC rail", 1, 65535)
    integer(recipe["request_timeout_ns"], "request timeout", 1, 30_000_000_000)
    integer(recipe["stage_timeout_seconds"], "stage timeout", 1, 3600)
    return recipe
end
function validate_settling(rule)
    if rule["kind"] == "discard_exposures"
        exact_keys(rule, ("kind","frames"))
        integer(rule["frames"], "discard count", 1, 4096)
    elseif rule["kind"] == "model_time"
        exact_keys(rule, ("kind","duration_ns"))
        integer(rule["duration_ns"], "settling duration", 1, typemax(Int64))
    else
        throw(ArgumentError("Copper requires completed exposure settling"))
    end
    return rule
end
function cursor(value, generation)
    exact_keys(value, ("domain","generation","sequence","model_ns"))
    integer(value["domain"], "domain", 1, 1)
    integer(value["generation"], "generation", generation, generation)
    integer(value["sequence"], "sequence", 0, typemax(UInt64)-1)
    integer(value["model_ns"], "model time", 0, typemax(UInt64)-1)
    return value
end
function same_figure(values, reference)
    require(length(values) == 277, "wrong adopted/restored figure dimensions")
    require(all(i -> finite_number(values[i], "figure") == Float32(reference[i]), 1:277),
        "adopted/restored figure differs from reference")
end

"""Validate provenance and chronology before reading any numerical payload."""
function read_window(stage_name, output, evidence, recipe)
    require(stage_name in STAGES, "unknown stage")
    count = Int(recipe[stage_name * "_frames"])
    stage, stage_path = read_json(evidence, "stage-result.json", 2^21)
    require(stage["stage"] == stage_name, "stage identity mismatch")
    for name in ("restoration_confirmed","release_confirmed","shutdown_confirmed")
        require(stage[name] === true, "incomplete lifecycle: $name")
    end
    integer(stage["launcher_exit"], "launcher exit", 0, 0)
    require(get(stage, "failure", nothing) === nothing && get(stage, "recovery_failure", nothing) === nothing,
        "failed stage")
    final = stage["final"]
    require(final["phase"] == "stopped" && get(final,"error",nothing) === nothing &&
        isempty(get(final,"cleanup_errors", ())), "shutdown/cleanup incomplete")
    startup = stage["startup_report"]
    integer(startup["version"], "startup version", 1, 1)
    require(startup["profile"] == "copper" && startup["backend"] == "cpu",
        "expected Copper CPU startup")
    require(startup["calibration_stage"] == stage_name && startup["failure"] === nothing,
        "startup stage mismatch")
    illumination = stage_name == "dark" ? "dark" : "lamp"
    require(startup["illumination"] == illumination, "illumination mismatch")
    require(startup["command_transport_units"] == "micrometre OPD" &&
        startup["plant_command_units"] == "metre OPD", "command units mismatch")
    detector = startup["detector_config"]
    integer(detector["rows"], "detector rows", 64, 64)
    integer(detector["columns"], "detector columns", 64, 64)
    integer(detector["bits"], "ADC bits", 14, 14)
    integer(detector["rng_seed"], "stage seed", recipe["seeds"][stage_name], recipe["seeds"][stage_name])
    require(recipe["adc_upper_rail"] == 2^14-1, "ADC upper rail differs from detector")
    duration_seconds = finite_number(detector["exposure_duration_s"], "exposure duration")
    require(0 < duration_seconds <= typemax(Int64)/1e9, "invalid detector duration")
    duration = round(Int64, duration_seconds*1e9)
    require(duration > 0, "zero exposure duration")
    mapping = startup["acquisition_domain_mapping"]
    exact_keys(mapping, ("opaque_domain","complete_domain"))
    integer(mapping["opaque_domain"], "opaque domain", 1, 1)
    require(length(mapping["complete_domain"]) == 16, "missing full acquisition domain")
    for byte in mapping["complete_domain"]
        integer(byte, "domain byte", 0, 255)
    end
    require(any(!iszero, mapping["complete_domain"]), "zero acquisition domain")
    generation = integer(startup["acquisition_generation"], "generation", 1, typemax(UInt64))
    integer(startup["sequence"], "startup sequence", 0, typemax(UInt64)-1)
    integer(startup["cursor_model_ns"], "startup model time", 0, typemax(UInt64)-1)
    digest_string(startup["graph_sha256"])
    digest_string(startup["capture_settings_sha256"])
    require(startup["wfs_active"] === nothing && startup["wfs_active_sha256"] === nothing,
        "unexpected Classic active ROI snapshot")

    records = stage["requests"]
    require(length(records) == 6, "expected complete six-operation capture lifecycle")
    kinds = ("hold","adopt","settle","capture","restore","release")
    results = ("held","adopted","settled","captured","restored","released")
    for i in 1:6
        request, reply = records[i]["request"], records[i]["reply"]
        integer(request["version"], "request version", 1, 1)
        integer(request["run"], "run", 1, 1)
        integer(request["serial"], "serial", i, i)
        integer(request["timeout_ns"], "timeout", recipe["request_timeout_ns"], recipe["request_timeout_ns"])
        integer(reply["version"], "reply version", 1, 1)
        integer(reply["run"], "reply run", 1, 1)
        integer(reply["serial"], "reply serial", i, i)
        require(request["action"]["kind"] == kinds[i] && reply["result"]["kind"] == results[i],
            "request/reply lifecycle order mismatch")
    end
    actions = [r["request"]["action"] for r in records]
    replies = [r["reply"]["result"] for r in records]
    held = cursor(replies[1]["cursor"], generation)
    require(held["sequence"] == startup["sequence"] && held["model_ns"] == startup["cursor_model_ns"],
        "hold/startup cursor mismatch")
    for i in (2,3,4)
        integer(actions[i]["probe"], "probe", 0, 0)
    end
    same_figure(actions[2]["figure"], recipe["reference"])
    same_figure(replies[2]["figure"], recipe["reference"])
    cursor(replies[2]["cursor"], generation)
    require(replies[2]["clipped"] === false && replies[2]["cursor"] == held, "adoption failed")
    cursor(actions[3]["after"], generation)
    require(actions[3]["after"] == held && actions[3]["rule"] == recipe["settling"], "settling request mismatch")
    settled = cursor(replies[3]["cursor"], generation)
    require(settled["sequence"] > held["sequence"] && settled["model_ns"] > held["model_ns"],
        "no discarded normalization exposure")
    rule = recipe["settling"]
    if rule["kind"] == "discard_exposures"
        require(settled["sequence"] - held["sequence"] == rule["frames"], "discard count mismatch")
    else
        require(settled["model_ns"] - held["model_ns"] >= rule["duration_ns"], "settling duration mismatch")
    end
    cursor(actions[4]["after"], generation)
    require(actions[4]["after"] == settled, "capture did not follow settled cursor")
    integer(actions[4]["frames"], "requested frames", count, count)
    completion = replies[4]
    require(stage["capture"] == completion, "capture completion differs from lifecycle receipt")
    same_figure(actions[5]["figure"], recipe["reference"])
    same_figure(replies[5]["figure"], recipe["reference"])
    require(actions[5]["rule"] == recipe["settling"] && replies[5]["clipped"] === false, "restoration failed")
    source = final["source"]
    require(source["operation"] == "pause" && source["state"] == "paused" &&
        source["completed"] === true && source["ok"] === true && source["error"] === nothing,
        "source did not complete public pause")

    require(completion["manifest"] == "4/manifest.json", "noncanonical manifest path")
    integer(completion["frames"], "completed frames", count, count)
    integer(completion["bytes"], "completed bytes", count*EXPOSURE_BYTES, count*EXPOSURE_BYTES)
    metadata_bytes = integer(completion["metadata_bytes"], "metadata bytes", 1, 16384+4096*count)
    manifest, manifest_path = read_json(evidence, "captured/4/manifest.json", 16384+4096*count;
        expected_bytes=metadata_bytes, sha=completion["sha256"])
    for (name,value) in (("version",1),("run",1),("serial",4),("probe",0),("frames",count),
                        ("bytes",count*EXPOSURE_BYTES))
        integer(manifest[name], name, value, value)
    end
    require(manifest["stage"] == stage_name && manifest["profile"] == "copper" &&
        manifest["illumination"] == illumination, "manifest profile/stage mismatch")
    require(manifest["acquisition_domain_mapping"] == mapping, "full domain mapping mismatch")
    require(manifest["settings_sha256"] == startup["capture_settings_sha256"], "settings digest mismatch")
    settings = manifest["settings"]
    exact_keys(settings, ("detector_config","graph_sha256","wfs_active_sha256"))
    require(all(name -> settings[name] == startup[name], keys(settings)), "startup settings mismatch")
    integer(startup["capture_max_bytes"], "capture budget", count*EXPOSURE_BYTES, typemax(Int64))
    require(length(manifest["exposures"]) == count, "exposure count mismatch")

    # All identities/descriptors/hashes are checked before numerical products.
    for (i, exposure) in enumerate(manifest["exposures"])
        require(exposure["directory"] == string(i), "noncanonical exposure directory")
        integer(exposure["domain"], "exposure domain", 1, 1)
        integer(exposure["generation"], "exposure generation", generation, generation)
        integer(exposure["sequence"], "exposure sequence", settled["sequence"]+i, settled["sequence"]+i)
        start = integer(exposure["start_model_ns"], "exposure start", 0, typemax(UInt64)-duration)
        integer(exposure["duration_ns"], "exposure duration", duration, duration)
        require(exposure["valid"] === true || exposure["valid"] === false, "intrinsic validity must be Boolean")
        previous_end = i == 1 ? settled["model_ns"] :
            manifest["exposures"][i-1]["start_model_ns"] + duration
        require(start >= previous_end, "overlapping/nonchronological exposures")
        exact_keys(exposure["files"], (c.name for c in CHANNELS))
        for c in CHANNELS
            record = exposure["files"][c.name]
            require(record["path"] == c.filename && record["element_type"] == c.element &&
                record["shape"] == c.shape && record["layout"] == "ROW_MAJOR", "payload contract mismatch")
            integer(record["bytes"], "channel bytes", c.bytes, c.bytes)
            checked_file(evidence, joinpath("captured","4",string(i),c.filename), c.bytes;
                expected_bytes=c.bytes, sha=record["sha256"])
        end
    end
    last_exposure = manifest["exposures"][end]
    completed_cursor = cursor(completion["cursor"], generation)
    require(completed_cursor["sequence"] == last_exposure["sequence"] &&
        completed_cursor["model_ns"] == last_exposure["start_model_ns"]+duration, "completion cursor mismatch")
    minimum_restored = rule["kind"] == "discard_exposures" ? rule["frames"] : 1
    integer(source["sequence"], "restored final sequence", completed_cursor["sequence"]+minimum_restored, typemax(UInt64))
    raw = Array{UInt16}(undef,64,64,count)
    pixels = Matrix{Float32}(undef,3600,count)
    intensity = Vector{Float32}(undef,count)
    validity = BitVector(undef,count)
    for i in 1:count
        root = joinpath(evidence,"captured","4",string(i))
        # Explicit ROW_MAJOR conversion. Pixels remain pupil-block wire order.
        raw[:,:,i] .= transpose(reshape(read_packed(joinpath(root,"raw.u16le"),UInt16,4096),64,64))
        pixels[:,i] .= read_packed(joinpath(root,"pixels.f32le"),Float32,3600)
        intensity[i] = only(read_packed(joinpath(root,"intensity.f32le"),Float32,1))
        validity[i] = manifest["exposures"][i]["valid"]
    end
    return (;raw,pixels,intensity,validity,manifest,stage,stage_path,manifest_path)
end

function read_packed(path, ::Type{T}, count) where {T}
    require(filesize(path) == sizeof(T)*count, "wrong packed length")
    return collect(reinterpret(T, read(path)))
end
function fresh_target(root, filename)
    require(isdir(root) && realpath(root) == abspath(root), "output directory must be unaliased")
    path = joinpath(root,filename)
    require(!ispath(path) && !islink(path), "output already exists: $path")
    return path
end
function publish(path, bytes)
    require(!ispath(path) && !islink(path), "output already exists")
    temporary, io = mktemp(dirname(path))
    try
        write(io,bytes)
        close(io)
        mv(temporary,path; force=false)
    finally
        isopen(io) && close(io)
        ispath(temporary) && rm(temporary)
    end
    return digest(path)
end
packed(values) = collect(reinterpret(UInt8,vec(values)))
function artifact(path, bytes, shape, element, units)
    return (;path=basename(path),sha256=publish(path,bytes),bytes=length(bytes),
        shape,element_type=element,layout="ROW_MAJOR",units)
end

"""Bind qualification to the successful prior training report and its candidate bytes.

The orchestration owner freezes this report's identity immediately after training
and checks it again before qualification. This local check validates its method,
source, recipe and precise artifact contract; it does not invent a trust anchor.
"""
function frozen_reference(output, recipe, recipe_path)
    training, training_path = read_json(output,"training-evidence/analysis.json",2^21)
    require(training["version"] == 1 && training["profile"] == "copper" &&
        training["stage"] == "training" && training["status"] == "valid-candidate" &&
        training["public_method"] == "Diagnostics.RepeatedResponseMoments" &&
        training["public_status"] == "ResponseMomentsValid", "missing successful public training analysis")
    integer(training["version"], "training version", 1, 1)
    integer(training["samples"], "training samples", recipe["training_frames"], recipe["training_frames"])
    require(training["variance_normalization"] == "N-1" &&
        training["measurement_order"] == MEASUREMENT_ORDER &&
        training["variance_scope"] == VARIANCE_SCOPE &&
        training["qualification"] == QUALIFICATION_SCOPE &&
        training["analysis_source_sha256"] == digest(@__FILE__), "training source/scope mismatch")
    identities = training["input_identities"]
    require(identities["recipe_sha256"] == digest(recipe_path), "training recipe identity mismatch")
    checked_file(output,"training-evidence/stage-result.json",2^21;sha=identities["stage_result_sha256"])
    checked_file(output,"training-evidence/captured/4/manifest.json",16384+4096*Int(recipe["training_frames"]);
        sha=identities["capture_manifest_sha256"])
    descriptors = filter(a -> a["path"] == "measured-reference-pixels.f32le",training["artifacts"])
    require(length(descriptors) == 1, "missing/duplicate frozen reference descriptor")
    reference = only(descriptors)
    exact_keys(reference,("path","sha256","bytes","shape","element_type","layout","units"))
    integer(reference["bytes"], "frozen reference bytes",14400,14400)
    require(reference["shape"] == [3600] && reference["element_type"] == "F32_LE" &&
        reference["layout"] == "ROW_MAJOR" && reference["units"] == "normalized pixel",
        "wrong frozen reference artifact contract")
    path = checked_file(output,"measured-reference-pixels.f32le",14400;
        expected_bytes=14400,sha=reference["sha256"])
    values = read_packed(path,Float32,3600)
    require(all(isfinite,values), "nonfinite frozen reference")
    return (;values,reference_sha256=digest(path),training_analysis_sha256=digest(training_path))
end

function main(stage, output, evidence)
    Base.ENDIAN_BOM == 0x04030201 || throw(ArgumentError("packed data requires little-endian host"))
    require(stage in STAGES, "unknown reference stage")
    output, evidence = abspath(output), abspath(evidence)
    recipe, recipe_path = read_json(output,"recipe.json",65536)
    validate_recipe(recipe)
    filenames = stage == "dark" ? ("measured-background.f32le","measured-dark-variance.f64le") :
        stage == "training" ? ("measured-reference-pixels.f32le","measured-reference-variance.f64le") :
        ("qualification-mean.f64le",)
    targets = [fresh_target(output,f) for f in filenames]
    report_path = fresh_target(evidence,"analysis.json")
    window = read_window(stage,output,evidence,recipe)
    require(maximum(window.raw) < recipe["adc_upper_rail"], "ADC rail equality/overflow invalidates whole candidate")
    all(isfinite,window.pixels) && all(isfinite,window.intensity) ||
        throw(ArgumentError("nonfinite deployed response"))
    stage == "dark" || require(all(window.validity) && all(>(0),window.intensity),
        "lamp requires true intrinsic validity and positive current intensity")
    count = size(window.raw,3)
    frozen_binding = stage == "qualification" ? frozen_reference(output,recipe,recipe_path) : nothing
    frozen = frozen_binding === nothing ? Float32[] : frozen_binding.values
    numerical_started = time_ns()
    if stage == "dark"
        product = AOC.process(AOC.prepare(RF.DarkFrameMoments(),RF.DarkFrameSpecification(64,64,count)),window.raw)
        require(product.status === RF.Valid, "invalid public dark moments")
        mean_values, variance = product.mean, product.variance
        method = "ReferenceFrames.DarkFrameMoments"
    else
        product = AOC.process(AOC.prepare(Diagnostics.RepeatedResponseMoments(),
            Diagnostics.RepeatedResponseSpecification(3600,count)),window.pixels)
        require(product.status === Diagnostics.ResponseMomentsValid, "invalid public response moments")
        mean_values, variance = product.mean, product.sample_variance
        method = "Diagnostics.RepeatedResponseMoments"
    end
    numerical_ns = time_ns()-numerical_started
    rounded = Float32.(mean_values)
    require(all(isfinite,rounded) && all(isfinite,variance), "candidate computation/Float32 representation nonfinite")
    residual = stage == "qualification" ? mean_values-Float64.(frozen) : Float64[]
    frozen_norm = norm(Float64.(frozen))
    comparison = stage == "qualification" ?
        (;max_abs=maximum(abs,residual),rms=norm(residual)/sqrt(3600),
          relative_norm=frozen_norm > 0 ? norm(residual)/frozen_norm : nothing,
          relative_norm_definition="norm(mean - frozen F32 reference) / norm(frozen F32 reference); null for zero denominator",
          units="normalized pixel",reference_sha256=frozen_binding.reference_sha256,
          training_analysis_sha256=frozen_binding.training_analysis_sha256,
          acceptance="descriptive independent-seed comparison; no acceptance tolerance") : nothing
    artifacts = if stage == "dark"
        [artifact(targets[1],packed(permutedims(rounded)),[64,64],"F32_LE","ADC"),
         artifact(targets[2],packed(permutedims(variance)),[64,64],"F64_LE","ADC squared")]
    elseif stage == "training"
        [artifact(targets[1],packed(rounded),[3600],"F32_LE","normalized pixel"),
         artifact(targets[2],packed(variance),[3600],"F64_LE","normalized pixel squared")]
    else
        [artifact(targets[1],packed(mean_values),[3600],"F64_LE","normalized pixel")]
    end
    report = (;version=1,profile="copper",stage,status="valid-candidate",public_method=method,
        public_status=string(product.status),samples=count,variance_normalization="N-1",
        measurement_order=MEASUREMENT_ORDER,
        variance_scope=VARIANCE_SCOPE,
        adc_maximum=maximum(window.raw),intrinsic_valid=collect(window.validity),
        mean_range=(;minimum=minimum(mean_values),maximum=maximum(mean_values)),
        current_intensity_range=(;minimum=minimum(window.intensity),maximum=maximum(window.intensity)),
        current_intensity_mean=sum(Float64,window.intensity)/count,
        comparison,artifacts,numerical_wall_ns=numerical_ns,
        input_identities=(;recipe_sha256=digest(recipe_path),stage_result_sha256=digest(window.stage_path),
            capture_manifest_sha256=digest(window.manifest_path),
            settings_sha256=window.manifest["settings_sha256"],
            acquisition_domain_mapping=window.manifest["acquisition_domain_mapping"],
            exposures=window.manifest["exposures"]),
        analysis_source_sha256=digest(@__FILE__),
        qualification=QUALIFICATION_SCOPE)
    publish(report_path,Vector{UInt8}(codeunits(JSON3.write(report)*"\n")))
    return report
end

end # module

if abspath(PROGRAM_FILE) == @__FILE__
    length(ARGS) == 3 || throw(ArgumentError("usage: calibration_reference_analysis.jl stage output evidence"))
    println(CalibrationReferenceAnalysis.JSON3.write(CalibrationReferenceAnalysis.main(ARGS...)))
end
