#!/usr/bin/env julia
"""Cold Copper amplitude pilot; descriptive products, without calibration acceptance."""
module CalibrationQualityAnalysis

include("calibration_reference_analysis.jl")
using .CalibrationReferenceAnalysis: AOC, Diagnostics, JSON3, digest, digest_string,
    require, integer, finite_number, exact_keys, checked_file, read_json,
    validate_settling, cursor, read_packed, fresh_target, publish, packed, artifact,
    CHANNELS, EXPOSURE_BYTES, MEASUREMENT_ORDER
using LinearAlgebra
const IM = AOC.InteractionMatrices
const SCOPE = "descriptive one-direction candidate; no interaction-matrix, inverse, correction or rate acceptance"
const ORDER_SCOPE = "amplitude traversal and sign order reverse together; repeat/order discrepancy does not identify time, normalization history, noise or nonlinearity"

# Integer guards apply to parsed values: JSON3 normalizes integral decimal
# numbers to integers. The acquisition owner separately checks metadata types.

function represented(value, name)
    finite_number(value, name)
    result = Float32(value)
    require(isfinite(result) && (iszero(value) || !iszero(result)), "$name is not representable as Float32")
    return result
end

function figure(values, expected)
    require(values isa AbstractVector && length(values) == 277, "figure must have 277 physical coordinates")
    require(all(i -> represented(values[i], "figure") == expected[i], 1:277), "changed adopted/restored figure")
end

function shape(values, expected)
    require(values isa AbstractVector && length(values) == length(expected), "wrong payload dimensions")
    for (value,extent) in zip(values,expected)
        integer(value,"shape extent",extent,extent)
    end
end

function validate_recipe(recipe)
    exact_keys(recipe, ("version","actuator","amplitudes","repeats","frames_per_batch",
        "reference","seed","lamp_magnitude","settling","adc_upper_rail",
        "request_timeout_ns","stage_timeout_seconds"))
    integer(recipe["version"], "version", 1, 1)
    integer(recipe["actuator"], "actuator", 1, 277)
    integer(recipe["repeats"], "repeats", 2, 4)
    integer(recipe["frames_per_batch"], "frames", 2, 16)
    integer(recipe["seed"], "seed", 0, typemax(UInt32))
    finite_number(recipe["lamp_magnitude"], "lamp magnitude")
    integer(recipe["adc_upper_rail"], "ADC rail", 16383, 16383)
    integer(recipe["request_timeout_ns"], "request timeout", 1, 30_000_000_000)
    integer(recipe["stage_timeout_seconds"], "stage timeout", 1, 1800)
    validate_settling(recipe["settling"])
    require(recipe["reference"] isa AbstractVector && length(recipe["reference"]) == 277, "reference must have 277 physical coordinates")
    reference = [represented(x,"reference") for x in recipe["reference"]]
    require(recipe["amplitudes"] isa AbstractVector && 1 <= length(recipe["amplitudes"]) <= 3, "one to three amplitudes required")
    amplitudes = [represented(x,"amplitude") for x in recipe["amplitudes"]]
    require(all(>(0),amplitudes) && issorted(amplitudes) && allunique(amplitudes), "amplitudes must be positive and strictly ascending")
    return (;reference,amplitudes)
end

function expected_schedule(recipe)
    values = validate_recipe(recipe)
    batches = NamedTuple[]
    for repeat in 0:Int(recipe["repeats"])-1
        push!(batches,(;label="null_start",repeat,amplitude=nothing,sign=0,figure=copy(values.reference),frames=Int(recipe["frames_per_batch"])))
        amplitudes = iseven(repeat) ? values.amplitudes : reverse(values.amplitudes)
        signs = iseven(repeat) ? (1,-1) : (-1,1)
        for amplitude in amplitudes, sign in signs
            command = copy(values.reference)
            command[Int(recipe["actuator"])] += sign*amplitude
            require(all(isfinite,command), "probe figure overflows Float32")
            require(sign*(Float64(command[Int(recipe["actuator"])])-Float64(values.reference[Int(recipe["actuator"])])) > 0,
                "represented probe does not straddle reference")
            push!(batches,(;label=sign==1 ? "positive" : "negative",repeat,amplitude,sign,figure=command,frames=Int(recipe["frames_per_batch"])))
        end
        push!(batches,(;label="null_end",repeat,amplitude=nothing,sign=0,figure=copy(values.reference),frames=Int(recipe["frames_per_batch"])))
    end
    return batches
end

function validate_schedule(schedule, recipe)
    expected = expected_schedule(recipe)
    require(length(schedule) == length(expected), "schedule batch count mismatch")
    for (batch, declared) in zip(schedule,expected)
        exact_keys(batch,("label","repeat","amplitude","sign","figure","frames"))
        require(batch["label"] == declared.label, "schedule label/order mismatch")
        integer(batch["repeat"],"repeat",declared.repeat,declared.repeat)
        integer(batch["sign"],"sign",declared.sign,declared.sign)
        integer(batch["frames"],"frames",declared.frames,declared.frames)
        require(declared.amplitude === nothing ? batch["amplitude"] === nothing :
            represented(batch["amplitude"],"amplitude") == declared.amplitude, "schedule amplitude mismatch")
        figure(batch["figure"],declared.figure)
    end
    return expected
end

function frozen_inputs(output)
    seal, path = read_json(output,"quality-inputs.json",2^22)
    exact_keys(seal,("version","files"))
    integer(seal["version"],"seal version",1,1)
    require(1 <= length(seal["files"]) <= 4096,"input seal file count out of range")
    for (relative,sha) in pairs(seal["files"])
        checked_file(output,String(relative),2^30;sha)
    end
    for relative in ("recipe.json","schedule.json","measured-reference-pixels.f32le",
        "reference-candidate/recipe.json","reference-candidate/training-evidence/analysis.json",
        "reference-candidate/training-evidence/stage-result.json",
        "training-package/hil/calibration_quality_analysis.jl","training-package/hil/calibration_reference_analysis.jl")
        require(haskey(seal["files"],relative),"unsealed required input: $relative")
    end
    reference_helper = joinpath(@__DIR__,"calibration_reference_analysis.jl")
    require(seal["files"]["training-package/hil/calibration_quality_analysis.jl"] == digest(@__FILE__) &&
        seal["files"]["training-package/hil/calibration_reference_analysis.jl"] == digest(reference_helper),
        "executed analysis helpers differ from frozen package")
    training, producer = read_json(output,"reference-candidate/training-evidence/analysis.json",2^21;
        sha=seal["files"]["reference-candidate/training-evidence/analysis.json"])
    integer(training["version"],"producing report version",1,1)
    require(training["version"] == 1 && training["profile"] == "copper" && training["stage"] == "training" &&
        training["status"] == "valid-candidate" && training["public_method"] == "Diagnostics.RepeatedResponseMoments" &&
        training["public_status"] == "ResponseMomentsValid", "invalid producing reference report")
    require(training["analysis_source_sha256"] == digest(reference_helper) &&
        training["measurement_order"] == MEASUREMENT_ORDER && training["variance_normalization"] == "N-1" &&
        training["variance_scope"] == CalibrationReferenceAnalysis.VARIANCE_SCOPE &&
        training["qualification"] == CalibrationReferenceAnalysis.QUALIFICATION_SCOPE,
        "producing reference method/source/scope mismatch")
    descriptors = filter(a -> a["path"] == "measured-reference-pixels.f32le",training["artifacts"])
    require(length(descriptors) == 1,"missing/duplicate producing reference descriptor")
    descriptor = only(descriptors)
    exact_keys(descriptor,("path","sha256","bytes","shape","element_type","layout","units"))
    integer(descriptor["bytes"],"reference bytes",14400,14400)
    shape(descriptor["shape"],[3600])
    require(descriptor["element_type"] == "F32_LE" &&
        descriptor["layout"] == "ROW_MAJOR" && descriptor["units"] == "normalized pixel", "wrong frozen reference contract")
    reference_path = checked_file(output,"measured-reference-pixels.f32le",14400;
        expected_bytes=14400,sha=descriptor["sha256"])
    reference = read_packed(reference_path,Float32,3600)
    require(all(isfinite,reference),"nonfinite frozen reference")
    identities = training["input_identities"]
    producer_recipe, _ = read_json(output,"reference-candidate/recipe.json",65536;sha=identities["recipe_sha256"])
    CalibrationReferenceAnalysis.validate_recipe(producer_recipe)
    checked_file(output,"reference-candidate/training-evidence/stage-result.json",2^21;sha=identities["stage_result_sha256"])
    return (;seal,path,reference,producer,producer_recipe)
end

function receipt(record, serial, kind, result, recipe)
    exact_keys(record,("request","reply"))
    request, reply = record["request"], record["reply"]
    exact_keys(request,("version","run","serial","timeout_ns","action"))
    exact_keys(reply,("version","run","serial","result"))
    for envelope in (request,reply)
        integer(envelope["version"],"protocol version",1,1)
        integer(envelope["run"],"run",1,1)
        integer(envelope["serial"],"serial",serial,serial)
    end
    integer(request["timeout_ns"],"timeout",1,recipe["request_timeout_ns"])
    require(request["action"]["kind"] == kind && reply["result"]["kind"] == result,"lifecycle receipt order mismatch")
    return request["action"],reply["result"]
end

"""Validate all receipts, descriptors and payload hashes before numerical reduction."""
function read_batches(evidence, recipe, schedule)
    count, batches = Int(recipe["frames_per_batch"]), length(schedule)
    stage, path = read_json(evidence,"stage-result.json",2^22)
    require(stage["stage"] == "training","quality acquisition must use training stage")
    for name in ("restoration_confirmed","release_confirmed","shutdown_confirmed")
        require(stage[name] === true,"incomplete lifecycle: $name")
    end
    integer(stage["launcher_exit"],"launcher exit",0,0)
    require(get(stage,"failure",nothing) === nothing && get(stage,"recovery_failure",nothing) === nothing,"failed quality stage")
    final, startup = stage["final"], stage["startup_report"]
    require(final["phase"] == "stopped" && get(final,"error",nothing) === nothing && isempty(get(final,"cleanup_errors",())),"incomplete public shutdown")
    integer(startup["version"],"startup version",1,1)
    require(startup["profile"] == "copper" && startup["backend"] == "cpu" && startup["illumination"] == "lamp" &&
        startup["calibration_stage"] == "training" && startup["failure"] === nothing,"wrong startup profile")
    require(startup["command_transport_units"] == "micrometre OPD" && startup["plant_command_units"] == "metre OPD","command units mismatch")
    detector = startup["detector_config"]
    integer(detector["rows"],"rows",64,64); integer(detector["columns"],"columns",64,64)
    integer(detector["bits"],"ADC bits",14,14); integer(detector["rng_seed"],"seed",recipe["seed"],recipe["seed"])
    seconds = finite_number(detector["exposure_duration_s"],"exposure duration")
    require(0 < seconds <= typemax(Int64)/1e9,"invalid exposure duration")
    duration = round(Int64,seconds*1e9); require(duration > 0,"zero exposure duration")
    mapping = startup["acquisition_domain_mapping"]
    exact_keys(mapping,("opaque_domain","complete_domain")); integer(mapping["opaque_domain"],"opaque domain",1,1)
    require(length(mapping["complete_domain"]) == 16,"wrong complete domain")
    foreach(x -> integer(x,"domain byte",0,255),mapping["complete_domain"])
    require(any(!iszero,mapping["complete_domain"]),"zero acquisition domain")
    generation = integer(startup["acquisition_generation"],"generation",1,typemax(UInt64))
    integer(startup["sequence"],"startup sequence",0,typemax(UInt64)-1)
    integer(startup["cursor_model_ns"],"startup model time",0,typemax(UInt64)-1)
    digest_string(startup["graph_sha256"]); digest_string(startup["capture_settings_sha256"])
    require(startup["wfs_active"] === nothing && startup["wfs_active_sha256"] === nothing,"unexpected Classic ROI snapshot")
    integer(startup["capture_max_bytes"],"capture budget",count*batches*EXPOSURE_BYTES,typemax(Int64))
    records, captures = stage["requests"],stage["captures"]
    require(length(records) == 3*batches+3 && length(captures) == batches,"incomplete quality lifecycle")
    action, held = receipt(records[1],1,"hold","held",recipe)
    exact_keys(action,("kind",)); exact_keys(held,("kind","cursor"))
    previous = cursor(held["cursor"],generation)
    require(previous["sequence"] == startup["sequence"] && previous["model_ns"] == startup["cursor_model_ns"],"hold/startup cursor mismatch")
    manifests, manifest_paths = Any[], String[]
    for (i,batch) in enumerate(schedule)
        probe, adopt_serial = i-1, 3*i-1
        action, adopted = receipt(records[adopt_serial],adopt_serial,"adopt","adopted",recipe)
        exact_keys(action,("kind","probe","figure")); exact_keys(adopted,("kind","cursor","figure","clipped"))
        integer(action["probe"],"probe",probe,probe)
        figure(action["figure"],batch.figure); figure(adopted["figure"],batch.figure)
        require(adopted["clipped"] === false && cursor(adopted["cursor"],generation) == previous,"clipped/uncorrelated adoption")
        action, settled_reply = receipt(records[adopt_serial+1],adopt_serial+1,"settle","settled",recipe)
        exact_keys(action,("kind","probe","after","rule")); exact_keys(settled_reply,("kind","cursor"))
        integer(action["probe"],"probe",probe,probe)
        cursor(action["after"],generation)
        validate_settling(action["rule"])
        require(action["after"] == previous && action["rule"] == recipe["settling"],"settling request mismatch")
        settled = cursor(settled_reply["cursor"],generation)
        require(settled["sequence"] > previous["sequence"] && settled["model_ns"] > previous["model_ns"],"no normalization exposure")
        rule = recipe["settling"]
        require(rule["kind"] == "discard_exposures" ? settled["sequence"]-previous["sequence"] == rule["frames"] :
            settled["model_ns"]-previous["model_ns"] >= rule["duration_ns"],"settling boundary mismatch")
        serial = adopt_serial+2
        action, completion = receipt(records[serial],serial,"capture","captured",recipe)
        exact_keys(action,("kind","probe","after","frames"))
        exact_keys(completion,("kind","cursor","manifest","sha256","frames","bytes","metadata_bytes"))
        integer(action["probe"],"probe",probe,probe)
        integer(action["frames"],"frames",count,count)
        cursor(action["after"],generation)
        require(action["after"] == settled,"capture before settling")
        capture = captures[i]
        exact_keys(capture,("probe","serial","figure","settled_cursor","completion"))
        integer(capture["probe"],"capture probe",probe,probe); integer(capture["serial"],"capture serial",serial,serial)
        figure(capture["figure"],batch.figure)
        cursor(capture["settled_cursor"],generation)
        require(capture["settled_cursor"] == settled && capture["completion"] == completion,"capture receipt association mismatch")
        require(completion["manifest"] == "$serial/manifest.json","noncanonical manifest path")
        integer(completion["frames"],"completed frames",count,count)
        integer(completion["bytes"],"completed bytes",count*EXPOSURE_BYTES,count*EXPOSURE_BYTES)
        metadata = integer(completion["metadata_bytes"],"metadata bytes",1,16384+4096*count)
        manifest, manifest_path = read_json(evidence,"captured/$serial/manifest.json",16384+4096*count;
            expected_bytes=metadata,sha=completion["sha256"])
        for (name,value) in (("version",1),("run",1),("serial",serial),("probe",probe),("frames",count),("bytes",count*EXPOSURE_BYTES))
            integer(manifest[name],name,value,value)
        end
        require(manifest["stage"] == "training" && manifest["profile"] == "copper" && manifest["illumination"] == "lamp","manifest profile mismatch")
        require(manifest["acquisition_domain_mapping"] == mapping && manifest["settings_sha256"] == startup["capture_settings_sha256"],"manifest settings/domain mismatch")
        exact_keys(manifest["settings"],("detector_config","graph_sha256","wfs_active_sha256"))
        require(all(k -> manifest["settings"][k] == startup[k],keys(manifest["settings"])),"startup settings mismatch")
        require(length(manifest["exposures"]) == count,"exposure count mismatch")
        previous_end = settled["model_ns"]
        for (frame,exposure) in enumerate(manifest["exposures"])
            require(exposure["directory"] == string(frame),"noncanonical exposure directory")
            integer(exposure["domain"],"domain",1,1); integer(exposure["generation"],"generation",generation,generation)
            integer(exposure["sequence"],"sequence",settled["sequence"]+frame,settled["sequence"]+frame)
            start = integer(exposure["start_model_ns"],"model start",0,typemax(UInt64)-duration)
            integer(exposure["duration_ns"],"duration",duration,duration)
            require(start >= previous_end,"overlapping/nonchronological exposures")
            require(exposure["valid"] === true,"invalid lamp response")
            exact_keys(exposure["files"],(c.name for c in CHANNELS))
            for c in CHANNELS
                descriptor = exposure["files"][c.name]
                exact_keys(descriptor,("path","element_type","shape","layout","bytes","sha256"))
                shape(descriptor["shape"],c.shape)
                require(descriptor["path"] == c.filename && descriptor["element_type"] == c.element && descriptor["layout"] == "ROW_MAJOR","wrong payload contract")
                integer(descriptor["bytes"],"payload bytes",c.bytes,c.bytes)
                checked_file(evidence,"captured/$serial/$frame/$(c.filename)",c.bytes;expected_bytes=c.bytes,sha=descriptor["sha256"])
            end
            previous_end = start+duration
        end
        previous = cursor(completion["cursor"],generation)
        require(previous["sequence"] == manifest["exposures"][end]["sequence"] && previous["model_ns"] == previous_end,"capture completion cursor mismatch")
        push!(manifests,manifest); push!(manifest_paths,manifest_path)
    end
    serial = 3*batches+2
    action, restored = receipt(records[serial],serial,"restore","restored",recipe)
    exact_keys(action,("kind","figure","rule")); exact_keys(restored,("kind","figure","clipped"))
    reference = Float32.(recipe["reference"])
    figure(action["figure"],reference); figure(restored["figure"],reference)
    validate_settling(action["rule"])
    require(action["rule"] == recipe["settling"] && restored["clipped"] === false,"restoration not confirmed")
    action, released = receipt(records[serial+1],serial+1,"release","released",recipe)
    exact_keys(action,("kind",)); exact_keys(released,("kind",))
    source = final["source"]
    require(source["operation"] == "pause" && source["state"] == "paused" && source["completed"] === true && source["ok"] === true && source["error"] === nothing,"source public pause incomplete")
    minimum_restored = recipe["settling"]["kind"] == "discard_exposures" ? recipe["settling"]["frames"] : 1
    integer(source["sequence"],"restored sequence",previous["sequence"]+minimum_restored,typemax(UInt64))
    windows = map(enumerate(manifests)) do (i,manifest)
        serial = 3*i+1
        pixels = Matrix{Float32}(undef,3600,count); intensity = Vector{Float32}(undef,count)
        adc_maximum = UInt16(0)
        for frame in 1:count
            base = joinpath(evidence,"captured",string(serial),string(frame))
            adc_maximum = max(adc_maximum,maximum(read_packed(joinpath(base,"raw.u16le"),UInt16,4096)))
            pixels[:,frame] .= read_packed(joinpath(base,"pixels.f32le"),Float32,3600)
            intensity[frame] = only(read_packed(joinpath(base,"intensity.f32le"),Float32,1))
        end
        require(adc_maximum < recipe["adc_upper_rail"],"ADC rail rejects whole pilot")
        require(all(isfinite,pixels) && all(isfinite,intensity) && all(>(0),intensity),"nonfinite/nonpositive lamp response")
        (;pixels,intensity,adc_maximum,manifest)
    end
    return (;windows,stage,path,manifest_paths)
end

function moments(responses)
    product = AOC.process(AOC.prepare(Diagnostics.RepeatedResponseMoments(),
        Diagnostics.RepeatedResponseSpecification(size(responses,1),size(responses,2))),responses)
    require(product.status === Diagnostics.ResponseMomentsValid,"invalid public response moments")
    return product
end

ratio(numerator,denominator) = iszero(denominator) ? nothing : numerator/denominator
function comparison(first, second)
    difference, a, b = second-first,norm(first),norm(second)
    return (;difference_l2=norm(difference),difference_rms=norm(difference)/sqrt(length(first)),
        relative_difference=ratio(norm(difference),a),cosine=ratio(dot(first,second),a*b))
end

function main(output, evidence)
    Base.ENDIAN_BOM == 0x04030201 || throw(ArgumentError("packed data requires little-endian host"))
    output,evidence = abspath(output),abspath(evidence)
    binding = frozen_inputs(output)
    recipe,recipe_path = read_json(output,"recipe.json",65536)
    validate_recipe(recipe)
    figure(binding.producer_recipe["reference"],Float32.(recipe["reference"]))
    schedule,schedule_path = read_json(output,"schedule.json",2^20)
    declared = validate_schedule(schedule,recipe)
    filenames = ("batch-means.f64le","batch-variances.f64le","derivative-repeats.f64le","derivative-means.f64le")
    targets = [fresh_target(output,name) for name in filenames]
    report_path = fresh_target(evidence,"analysis.json")
    inputs = read_batches(evidence,recipe,declared)
    batches,repeats,amplitudes = length(declared),Int(recipe["repeats"]),Float32.(recipe["amplitudes"])
    means,variances = zeros(3600,batches),zeros(3600,batches)
    batch_reports = NamedTuple[]
    for (i,window) in enumerate(inputs.windows)
        product = moments(window.pixels)
        means[:,i] .= product.mean; variances[:,i] .= product.sample_variance
        rest_mean = vec(sum(Float64.(window.pixels[:,2:end]);dims=2))/(size(window.pixels,2)-1)
        first = Float64.(window.pixels[:,1])
        intensity = Float64.(window.intensity)
        push!(batch_reports,(;probe=i-1,label=declared[i].label,repeat=declared[i].repeat,
            amplitude=declared[i].amplitude,sign=declared[i].sign,adc_maximum=window.adc_maximum,
            frozen_reference=comparison(Float64.(binding.reference),product.mean),
            first_frame=(;pixel_l2=norm(first),remaining_mean_l2=norm(rest_mean),
                pixels_vs_remaining=comparison(rest_mean,first),current_intensity=intensity[1],
                remaining_current_intensity_mean=sum(intensity[2:end])/(length(intensity)-1)),
            intensity=(;minimum=minimum(intensity),maximum=maximum(intensity),mean=sum(intensity)/length(intensity))))
    end
    derivatives = zeros(3600,repeats,length(amplitudes)); derivative_means = zeros(3600,length(amplitudes))
    amplitude_reports = NamedTuple[]
    find_batch(repeat,label,amplitude=nothing) = only(findall(b -> b.repeat == repeat && b.label == label && b.amplitude == amplitude,declared))
    for (a,amplitude) in enumerate(amplitudes)
        midpoint_reports,intervals = NamedTuple[],Float64[]
        for repeat in 0:repeats-1
            positive,negative = find_batch(repeat,"positive",amplitude),find_batch(repeat,"negative",amplitude)
            actuator = Int(recipe["actuator"])
            interval = Float64(declared[positive].figure[actuator])-Float64(declared[negative].figure[actuator])
            require(isfinite(interval) && interval > 0,"unrepresented command interval")
            response = permutedims(hcat(means[:,positive],means[:,negative]))
            product = AOC.process(AOC.prepare(IM.ZonalPushPull([interval/2]),IM.ResponseSpecification(3600)),response)
            require(product.status === IM.StructuredValid,"invalid public zonal estimate")
            derivatives[:,repeat+1,a] .= vec(IM.interaction_matrix(product))
            push!(intervals,interval)
            first_null,last_null = find_batch(repeat,"null_start"),find_batch(repeat,"null_end")
            midpoint = (means[:,positive]+means[:,negative])/2
            push!(midpoint_reports,(;repeat,positive_probe=positive-1,negative_probe=negative-1,
                actual_positive_coordinate=Float64(declared[positive].figure[actuator]),
                actual_negative_coordinate=Float64(declared[negative].figure[actuator]),
                actual_half_interval=interval/2,
                command_pair_midpoint_reference_offset=(Float64(declared[positive].figure[actuator])+Float64(declared[negative].figure[actuator]))/2-Float64(Float32(recipe["reference"][actuator])),
                versus_null_start=comparison(means[:,first_null],midpoint),
                versus_null_end=comparison(means[:,last_null],midpoint),
                versus_bracketing_null_mean=comparison((means[:,first_null]+means[:,last_null])/2,midpoint)))
        end
        product = moments(derivatives[:,:,a]); derivative_means[:,a] .= product.mean
        repeats_report = [(;repeat=r-1,l2=norm(derivatives[:,r,a]),rms=norm(derivatives[:,r,a])/sqrt(3600)) for r in 1:repeats]
        pairs = [(;first_repeat=i-1,second_repeat=j-1,comparison=comparison(derivatives[:,i,a],derivatives[:,j,a])) for i in 1:repeats for j in i+1:repeats]
        push!(amplitude_reports,(;amplitude=Float64(amplitude),actual_intervals=intervals,
            mean_l2=norm(product.mean),mean_rms=norm(product.mean)/sqrt(3600),repeats=repeats_report,
            repeat_order_comparisons=pairs,pair_midpoints=midpoint_reports,
            versus_lowest_amplitude=comparison(derivative_means[:,1],product.mean)))
    end
    nulls = findall(b -> b.sign == 0,declared)
    null_comparisons = [(;first_probe=i-1,second_probe=j-1,comparison=comparison(means[:,i],means[:,j])) for (position,i) in enumerate(nulls) for j in nulls[position+1:end]]
    # Julia's first axis is measurement; its packed columns are the declared
    # ROW_MAJOR batch/measurement and amplitude/repeat/measurement wire arrays.
    artifacts = [artifact(targets[1],packed(means),[batches,3600],"F64_LE","normalized pixel"),
        artifact(targets[2],packed(variances),[batches,3600],"F64_LE","normalized pixel squared"),
        artifact(targets[3],packed(derivatives),[length(amplitudes),repeats,3600],"F64_LE","normalized pixel per micrometre OPD"),
        artifact(targets[4],packed(derivative_means),[length(amplitudes),3600],"F64_LE","normalized pixel per micrometre OPD")]
    report = (;version=1,profile="copper",status="characterized-candidate",
        public_methods=["Diagnostics.RepeatedResponseMoments","InteractionMatrices.ZonalPushPull"],
        analysis_source_sha256=digest(@__FILE__),measurement_order=MEASUREMENT_ORDER,
        variance_normalization="N-1",variance_scope="descriptive; no standard error or confidence interval",
        command_units="micrometre OPD",actuator=recipe["actuator"],samples_per_batch=recipe["frames_per_batch"],
        relative_difference_definition="norm(second-first)/norm(first); null for zero denominator",
        cosine_definition="dot(first,second)/(norm(first)*norm(second)); null for zero denominator",
        batches=batch_reports,amplitudes=amplitude_reports,null_comparisons,artifacts,
        inputhashes=(;quality_inputs_sha256=digest(binding.path),recipe_sha256=digest(recipe_path),
            schedule_sha256=digest(schedule_path),stage_result_sha256=digest(inputs.path),
            producing_reference_analysis_sha256=digest(binding.producer),
            measured_reference_sha256=binding.seal["files"]["measured-reference-pixels.f32le"],
            capture_manifest_sha256=digest.(inputs.manifest_paths)),order_scope=ORDER_SCOPE,scope=SCOPE)
    publish(report_path,Vector{UInt8}(codeunits(JSON3.write(report)*"\n")))
    return report
end
end

if abspath(PROGRAM_FILE) == @__FILE__
    length(ARGS) == 2 || throw(ArgumentError("usage: calibration_quality_analysis.jl output training-evidence"))
    println(CalibrationQualityAnalysis.JSON3.write(CalibrationQualityAnalysis.main(ARGS...)))
end
