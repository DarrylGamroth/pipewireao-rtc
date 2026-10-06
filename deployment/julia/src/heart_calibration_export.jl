module HeartCalibrationExport

using TOML
using ..Common, ..Deployment, ..ScienceExport, ..HILExport, ..HeartConfiguration, ..HeartExport
using ..CalibrationExport, ..CalibrationCampaign

export export_package, run_pilot, run_plan, reduce_plan, plan_limits, main

const TELEMETRY_TAGS = ("cbHoPixelsRaw#", "cbHoPixelsCalib#", "cbHoGrad#", "cbDmCmd#")
const HELPERS = ("simulator.jl", "owner_protocol.jl", "correction_truth.jl",
    "native_heart_control.jl", "native_acquisition_lifecycle.jl", "native_calibration_actions.jl",
    "calibration_acquisition.jl", "calibration_server.jl", "calibration_owner.jl",
    "heart_calibration_owner.jl", "heart_calibration_telemetry.jl", "heart_calibration_verify.jl", "heart_calibration_method.jl", "heart_calibration_evidence.jl", "calibration_client.jl")
option(args, name, default=nothing) = HeartExport.option(args, name, default)

function calibration_name(name, profile)
    if profile == "classic"
        startswith(name,"revolt-classic-heart-hil-") || throw(ArgumentError("unexpected native Classic base name"))
        return replace(name,"-heart-hil-"=>"-heart-cal-"; count=1)
    end
    profile == "copper" || throw(ArgumentError("unsupported native calibration name profile"))
    return name * "-calibration"
end

function calibration_session(rate::Integer; profile="copper")
    profile in ("classic", "copper") || throw(ArgumentError("unsupported native calibration profile"))
    session = HeartExport.bridge_session(profile, rate)
    command = deepcopy(only(filter(node -> node["node.name"] == "heart-dm-source", session["sources"])))
    command["node.name"] = "heart-calibration-probe"
    command["ports"][1]["name"] = "output_1"
    push!(session["sources"], command)
    sink = deepcopy(only(filter(node -> node["node.name"] == "simulator-command", session["sinks"])))
    sink["node.name"] = "heart-calibration-command"
    push!(session["sinks"], sink)
    session["links"] = [
        Dict("output"=>"simulator-wfs:output_1", "input"=>"heart-wfs-sink:frame", "passive"=>false),
        Dict("output"=>"heart-dm-source:command", "input"=>"heart-calibration-command:input_1", "passive"=>false),
        Dict("output"=>"heart-calibration-probe:output_1", "input"=>"simulator-command:input_1", "passive"=>false)]
    return session
end

function full_rate_telemetry!(sections)
    sections["CB"]["TELEMETRY_FILE_STREAMS"] = [
        Dict("tagName"=>tag, "decimate"=>0, "pollPeriod"=>0.001) for tag in TELEMETRY_TAGS]
    pop!(sections["CB"], "TELEMETRY_SOCKET_STREAMS", nothing)
    return nothing
end

function freeze_detector!(path; seed=700, profile="copper")
    profile == "classic" && return freeze_classic_detector!(path; seed)
    profile == "copper" || throw(ArgumentError("unsupported native detector profile"))
    CalibrationCampaign.isint(seed) && 0 <= seed <= typemax(UInt32) || throw(ArgumentError("detector seed must be UInt32"))
    graph = TOML.parsefile(path)
    detectors = filter(node -> get(node, "type", nothing) == "emccd_detector_acquisition_f32", graph["nodes"])
    length(detectors) == 1 || throw(ArgumentError("pilot requires one normal EMCCD acquisition node"))
    detector = only(detectors)["config"]
    get(detector, "photon_noise", nothing) === true && get(detector, "readout_noise", nothing) === true ||
        throw(ArgumentError("pilot requires normal photon and readout noise"))
    pupils = filter(node -> get(node, "name", nothing) == "pwfs", graph["nodes"])
    length(pupils) == 1 && get(only(pupils)["config"], "source_magnitude", nothing) == 0.752574989159953 ||
        throw(ArgumentError("pilot requires the selected 100× lamp base"))
    before = ScienceExport.sha256(path)
    original_seed = detector["rng_seed"]
    detector["rng_seed"] = seed
    open(path, "w") do io
        TOML.print(io, graph; sorted=true)
    end
    TOML.parsefile(path) == graph || throw(ArgumentError("pilot graph serialization changed values"))
    return Dict("graph_before_sha256"=>before, "graph_sha256"=>ScienceExport.sha256(path),
        "original_detector_seed"=>original_seed, "detector_seed"=>seed, "lamp_factor"=>100,
        "photon_noise"=>true, "readout_noise"=>true)
end

function owner_arguments(argv; stage, illumination, capture_max_bytes, telemetry_max_bytes, evidence_directory, ingress_mode="streaming", profile="copper")
    result = copy(argv)
    positions = findall(arg -> endswith(arg, "/hil/simulator.jl"), result)
    length(positions) == 1 || throw(ArgumentError("HEART base requires the maintained simulator owner"))
    result[only(positions)] = "@PACKAGE@/hil/heart_calibration_owner.jl"
    append!(result, ["--calibration-socket", "@RUNTIME@/calibration.sock", "--calibration-stage", stage,
        "--illumination", illumination, "--capture-directory", "@RUNTIME@/captured",
        "--capture-max-bytes", string(capture_max_bytes),
        "--heart-client", "@PACKAGE@/heart/bin/scaoTemplateCmdClient",
        "--heart-native-runtime", "@RUNTIME@/heart/native",
        "--heart-probe-directory", evidence_directory,
        "--heart-telemetry-max-bytes", string(telemetry_max_bytes), "--heart-native-ingress-mode", ingress_mode])
    if profile == "classic"
        append!(result, ["--wfs-active", "@PACKAGE@/heart/classic-active.u8",
            "--heart-classic-order", "@PACKAGE@/heart/classic-order.u32le",
            "--heart-slope-scale-x", "1.0", "--heart-slope-scale-y", "1.0"])
    elseif profile != "copper"
        throw(ArgumentError("unsupported native owner profile"))
    end
    return result
end

include("heart_classic_calibration.jl")

"""Validate a frozen Copper public plan and derive finite completion/retention bounds.

This consumes absolute physical figures exactly as written by CalibrationClient.
The estimator and chronological order remain in the owning frozen plan.
"""
function plan_limits(plan; profile="copper")
    profile in ("classic", "copper") || throw(ArgumentError("unsupported native plan profile"))
    CalibrationCampaign.fields(plan, ("version", "run", "reference", "probes", "measurements",
        "frames_per_probe", "settling", "timeouts_ns"), "native calibration plan")
    CalibrationCampaign.isint(plan["version"]) && plan["version"] == 1 || throw(ArgumentError("invalid plan version"))
    CalibrationCampaign.positive_integer(plan["run"], "plan run", typemax(UInt64))
    plan["measurements"] == (profile == "classic" ? 376 : 3600) && CalibrationCampaign.isint(plan["measurements"]) ||
        throw(ArgumentError("native plan measurement extent differs from selected profile"))
    figures = plan["probes"]
    figures isa AbstractVector || throw(ArgumentError("plan probes must be an array"))
    batches = CalibrationCampaign.positive_integer(length(figures), "native probe batches", 16384)
    for figure in Iterators.flatten(((plan["reference"],), figures))
        figure isa AbstractVector && length(figure) == 277 || throw(ArgumentError("native figures require 277 physical coordinates"))
        CalibrationCampaign.wire_float32.(figure)
    end
    accepted_per_probe = CalibrationCampaign.positive_integer(plan["frames_per_probe"], "frames per probe", 64; minimum=2)
    rule = CalibrationCampaign.validate_settling(plan["settling"]; copper=true)
    rule["kind"] == "discard_exposures" || throw(ArgumentError("count-bounded native plans require discard_exposures settling"))
    discarded = rule["frames"]
    timeouts = CalibrationCampaign.fields(plan["timeouts_ns"], ("ownership", "adoption", "settling", "collection", "restoration"), "plan timeouts")
    foreach(value -> CalibrationCampaign.positive_integer(value, "native operation timeout", 30_000_000_000), values(timeouts))
    accepted = Base.checked_mul(batches, accepted_per_probe)
    frames = Base.checked_add(Base.checked_mul(batches, Base.checked_add(discarded, accepted_per_probe)), discarded)
    frames <= typemax(UInt32) || throw(ArgumentError("native frame sync exceeds UInt32"))
    commands = Base.checked_add(batches, 1)
    sizes = Dict("cbHoPixelsRaw0"=>Base.checked_add(1024, Base.checked_mul(frames, 8256)),
        "cbHoPixelsCalib0"=>Base.checked_add(1024, Base.checked_mul(frames, 16448)),
        "cbHoGrad0"=>Base.checked_add(1024, Base.checked_mul(frames, 14464)),
        "cbDmCmd0"=>Base.checked_add(1024, Base.checked_mul(commands, 1216)))
    if profile == "classic"
        sizes = Dict("cbHoPixelsRaw0"=>Base.checked_add(1024, Base.checked_mul(frames, 247872)),
            "cbHoPixelsCalib0"=>Base.checked_add(1024, Base.checked_mul(frames, 495680)),
            "cbHoGrad0"=>Base.checked_add(1024, Base.checked_mul(frames, 3072)),
            "cbDmCmd0"=>Base.checked_add(1024, Base.checked_mul(commands, 1216)))
    end
    # The same owner limit bounds its stage evidence, including bounded command replies.
    evidence = Base.checked_add(Base.checked_mul(frames, 16384), Base.checked_mul(commands, 131072))
    native_budget = max(maximum(values(sizes)), evidence)
    native_budget <= 1024^3 || throw(ArgumentError("native plan exceeds the 1 GiB per-file evidence bound"))
    capture = Base.checked_mul(accepted, profile == "classic" ? 250252 : 22596)
    capture <= 1024^3 || throw(ArgumentError("native plan capture payload exceeds 1 GiB"))
    output = CalibrationCampaign.interaction_result_output_limit_bytes(batches, profile == "classic" ? 376 : 3600, accepted_per_probe)
    return Dict("probe_batches"=>batches, "accepted_frames"=>accepted, "completed_exposures"=>frames,
        "native_dm_records"=>commands, "native_file_bytes"=>sizes, "telemetry_max_bytes_per_file"=>native_budget,
        "capture_max_payload_bytes"=>capture, "result_max_output_bytes"=>output)
end

const METHOD_INPUT_FILES = ("recipe.json", "method.json", "prepared-specification.json",
    "canonical-order.json", "canonical-plan.json", "interaction-plan.json", "base-identity.json")

function frozen_method_inputs(directory, plan_path, seed)
    directory = realpath(directory)
    identity_path = joinpath(directory, "prepared-identity.json")
    identity = Common.read_json(identity_path; maximum=16 * 1024 * 1024)
    files = Dict{String,String}()
    for name in METHOD_INPUT_FILES
        path = joinpath(directory, name)
        !islink(path) && filesize(path) <= 16 * 1024 * 1024 || throw(ArgumentError("frozen method input is linked or too large"))
        hash = ScienceExport.sha256(path)
        hash == identity["files"][name] || throw(ArgumentError("frozen method input differs from its prepared identity: $name"))
        files[name] = hash
    end
    plan_path !== nothing && ScienceExport.sha256(plan_path) == files["interaction-plan.json"] ||
        throw(ArgumentError("frozen method plan differs from selected native plan"))
    recipe = Common.read_json(joinpath(directory, "recipe.json"))
    recipe["seeds"]["interaction"] == seed || throw(ArgumentError("native detector seed differs from frozen method interaction seed"))
    plan = Common.read_json(plan_path; maximum=16 * 1024 * 1024)
    plan_limits(plan)
    recipe["frames_per_probe"] == plan["frames_per_probe"] && recipe["settling"] == plan["settling"] ||
        throw(ArgumentError("frozen method recipe frames or settling differ from its sealed plan"))
    recipe["lamp_magnitude"] == 0.752574989159953 || throw(ArgumentError("frozen method lamp differs from selected native calibration lamp"))
    aoc = Dict(name=>hash for (name, hash) in identity["package_files"] if startswith(name, "hil/packages/AdaptiveOpticsCalibration/"))
    isempty(aoc) && throw(ArgumentError("frozen method identity has no public AOC package"))
    aoc["hil/calibration_client.jl"] = identity["package_files"]["hil/calibration_client.jl"]
    return Dict("source"=>directory, "source_prepared_identity_sha256"=>ScienceExport.sha256(identity_path),
        "files"=>files, "aoc_package_files"=>aoc, "interaction_seed"=>seed)
end

const DEFERRED_SOURCE_REVISION = "6a5c06b11a8b934effeb6328a73a70895b2af94a"

function ingress_contract(mode, profile, properties, executable; source_revision)
    mode in ("streaming", "deferred") || throw(ArgumentError("native ingress mode must be streaming or deferred"))
    profile == "classic" && return classic_ingress_contract(mode, properties, executable; source_revision)
    expected = Dict("api.heart.std-wfs.width"=>64, "api.heart.std-wfs.height"=>64,
        "api.heart.std-wfs.pixels-per-datagram"=>2048, "api.heart.std-wfs.rows-per-datagram"=>true)
    profile == "copper" && all(get(properties, key, nothing) === value for (key, value) in expected) ||
        throw(ArgumentError("native completion ingress requires Copper 64×64 and exactly two 32-row datagrams"))
    if mode == "deferred"
        source_revision == DEFERRED_SOURCE_REVISION || throw(ArgumentError("deferred ingress requires the reviewed unchanged comparison source revision"))
        !islink(executable) && isfile(executable) && filesize(executable) <= 128 * 1024 * 1024 ||
            throw(ArgumentError("native deferred executable is absent, linked or too large"))
        bytes = read(executable, String)
        all(marker -> occursin(marker, bytes), ("HRT_DEFER_WFS_INGRESS",
            "WFS Proc did not snapshot first 32 rows", "HO Recon did not snapshot first 1800 inputs")) ||
            throw(ArgumentError("selected native binary lacks the existing deferred comparison ingress"))
    end
    return Dict("mode"=>mode, "environment_key"=>"HRT_DEFER_WFS_INGRESS", "environment_value"=>mode == "deferred" ? "1" : "0",
        "shape"=>[64,64], "packet_rows"=>32, "datagrams_per_frame"=>2,
        "source_revision"=>source_revision, "executable_sha256"=>ScienceExport.sha256(executable),
        "qualification"=>mode == "deferred" ? "existing comparison fixture; completion calibration only; ordinary streaming and cadence unqualified" : "ordinary streaming; completion qualification separate")
end

function export_package(args)
    base = realpath(args.base_package)
    provenance = Common.read_json(joinpath(base, "provenance.json"))
    profile = get(provenance, "profile", nothing)
    profile in ("classic", "copper") || throw(ArgumentError("unsupported native calibration profile"))
    profile == "classic" && option(args, :classic_transfer) === nothing &&
        throw(ArgumentError("Classic calibration requires an explicitly bound frozen transfer corpus"))
    output = abspath(args.output)
    !ispath(output) && !islink(output) || throw(ArgumentError("export output must be new"))
    evidence_directory = abspath(option(args, :owner_evidence_directory, output * "-owner-evidence"))
    !ispath(evidence_directory) && !islink(evidence_directory) && isdir(dirname(evidence_directory)) ||
        throw(ArgumentError("owner evidence directory must be fresh with an existing parent"))
    (evidence_directory == output || startswith(evidence_directory, output * "/")) &&
        throw(ArgumentError("owner evidence must be outside the immutable package"))
    ncodeunits(joinpath(evidence_directory, "probe-$(typemax(UInt64)).csv")) <= 127 ||
        throw(ArgumentError("owner evidence path must leave every native probe filename within the 127-byte client limit"))
    stage = option(args, :calibration_stage, "nativepilot")
    occursin(r"^[A-Za-z][A-Za-z0-9_-]{0,63}$", stage) || throw(ArgumentError("invalid calibration stage"))
    illumination = option(args, :illumination, "lamp")
    illumination in ("lamp", "dark") || throw(ArgumentError("illumination must be lamp or dark"))
    plan_path = option(args, :plan)
    plan_path = plan_path === nothing ? nothing : realpath(plan_path)
    seed = option(args, :detector_seed, 700)
    method_directory = option(args, :frozen_method)
    method_inputs = method_directory === nothing ? nothing : frozen_method_inputs(method_directory, plan_path, seed)
    limits = plan_path === nothing ? nothing : plan_limits(Common.read_json(plan_path; maximum=16 * 1024 * 1024); profile)
    classic = profile == "classic" ? classic_transfer_inputs(args, base, provenance, plan_path, seed) : nothing
    profile == "classic" && method_inputs !== nothing && throw(ArgumentError("Classic transfer is not a native fit/reduction"))
    capture_budget = option(args, :capture_max_bytes, limits === nothing ? 4096 * 22596 : limits["capture_max_payload_bytes"])
    capture_budget isa Int && !(capture_budget isa Bool) && 1 <= capture_budget <= 1024^3 ||
        throw(ArgumentError("native capture payload budget must be in 1:1073741824"))
    telemetry_budget = option(args, :telemetry_max_bytes, limits === nothing ? 64 * 1024 * 1024 : limits["telemetry_max_bytes_per_file"])
    limits === nothing || (capture_budget >= limits["capture_max_payload_bytes"] &&
        telemetry_budget >= limits["telemetry_max_bytes_per_file"] || throw(ArgumentError("explicit budgets cannot be smaller than frozen plan bounds")))
    telemetry_budget isa Int && !(telemetry_budget isa Bool) && 1024 <= telemetry_budget <= 1024 * 1024 * 1024 ||
        throw(ArgumentError("native telemetry byte budget must be in 1024:1073741824"))
    ingress_mode = option(args, :native_ingress_mode, "streaming")
    ingress_mode in ("streaming", "deferred") || throw(ArgumentError("native ingress mode must be streaming or deferred"))
    native_debug = option(args, :native_wfs_proc_debug, false)
    native_debug isa Bool || throw(ArgumentError("native WFS processing debug must be Boolean"))
    line_buffering = option(args, :native_debug_line_buffering, false)
    line_buffering isa Bool || throw(ArgumentError("native diagnostic line buffering must be Boolean"))
    line_buffering && !native_debug && throw(ArgumentError("native line buffering requires explicit diagnostic mode"))
    wrapper = line_buffering ? Sys.which("stdbuf") : nothing
    line_buffering && wrapper === nothing && throw(ArgumentError("native diagnostic stdbuf wrapper is unavailable"))
    wrapper = wrapper === nothing ? nothing : realpath(wrapper)
    override = realpath(args.pipewireao_jl_root)
    original_project = joinpath(base, "hil/packages/PipeWireAO/Project.toml")
    read(joinpath(override, "Project.toml")) == read(original_project) ||
        throw(ArgumentError("PipeWireAO override requires the base dependency declaration"))
    occursin("allow_zero_sequence::Bool=false", read(joinpath(override, "src/ndarray_exchange.jl"), String)) ||
        throw(ArgumentError("PipeWireAO override lacks the explicit exact-zero receive contract"))
    mkpath(dirname(output))
    return mktempdir(dirname(output); prefix=".rtc-heart-calibration-") do temporary
        package = joinpath(temporary, "package")
        HeartExport.export_package(merge(args, (; output=package, readout_us=option(args, :readout_us, 0)));
            simulator_backend=option(args, :simulator_backend, "cpu"))
        specification = Deployment.profile(joinpath(package, "deployment.conf"), args.pipewire_prefix)
        staged_provenance = Common.read_json(joinpath(package, "provenance.json"))
        selected_helpers = profile == "classic" ? (HELPERS..., "heart_classic_calibration_verify.jl", "heart_classic_calibration_evidence.jl") : HELPERS
        for name in selected_helpers
            source = joinpath(ScienceExport.resource_root(), "hil", name)
            target = joinpath(package, "hil", name)
            ispath(target) && rm(target)
            ScienceExport.copy_file(source, target)
        end
        HILExport.replace_staged_package(override, package, "PipeWireAO")
        document, sections = HeartConfiguration.load_config(joinpath(package, "heart/config.yaml.in"))
        full_rate_telemetry!(sections)
        write(joinpath(package, "heart/config.yaml.in"), HeartConfiguration.serialize_config(document, args.heart_source_config))
        plant = freeze_detector!(joinpath(package, "hil/plant.toml"); seed, profile)
        if classic !== nothing
            stage_classic_inputs!(package, classic)
        end
        if plan_path !== nothing
            ScienceExport.copy_file(plan_path, joinpath(package, "heart-calibration-plan.json"))
            ScienceExport.sha256(plan_path) == ScienceExport.sha256(joinpath(package, "heart-calibration-plan.json")) ||
                throw(ArgumentError("frozen native plan changed while copying"))
        end
        if method_inputs !== nothing
            frozen_directory = joinpath(package, "heart-method")
            mkdir(frozen_directory)
            for name in METHOD_INPUT_FILES
                ScienceExport.copy_file(joinpath(method_inputs["source"], name), joinpath(frozen_directory, name))
                ScienceExport.sha256(joinpath(frozen_directory, name)) == method_inputs["files"][name] ||
                    throw(ArgumentError("frozen method input changed while copying"))
            end
            for (name, hash) in method_inputs["aoc_package_files"]
                ScienceExport.sha256(joinpath(package, name)) == hash || throw(ArgumentError("native public AOC differs from frozen method: $name"))
            end
            Common.write_json(joinpath(package, "heart-method/identity.json"), method_inputs)
        end
        rate = staged_provenance["hil"]["wall_rate_hz"]
        Common.write_json(joinpath(package, "session.conf.in"), calibration_session(rate; profile))
        source = only(filter(owner -> owner["role"] == specification["source-owner"], specification["owners"]))
        CalibrationExport.calibration_source_control!(source, profile)
        source["argv"] = owner_arguments(source["argv"]; stage, illumination,
            capture_max_bytes=capture_budget, telemetry_max_bytes=telemetry_budget, evidence_directory, ingress_mode, profile)
        native_owner = only(filter(owner -> owner["role"] == "heart", specification["owners"]))
        core = Deployment.decode(joinpath(package, specification["core"]), args.pipewire_prefix)
        wfs = only(filter(item -> get(get(item, "args", Dict()), "factory.name", nothing) == "api.heart.std-wfs.sink", core["context.objects"]))["args"]
        ingress = ingress_contract(ingress_mode, staged_provenance["profile"], wfs,
            joinpath(package, "heart/bin/scaoTemplate"); source_revision=staged_provenance["heart"]["revision"])
        native_owner["environment"]["HRT_DEFER_WFS_INGRESS"] = ingress["environment_value"]
        append!(native_owner["argv"], ["--native-ingress-mode", ingress_mode])
        native_debug && append!(native_owner["argv"], ["--native-wfs-proc-debug", "true"])
        wrapper === nothing || append!(native_owner["argv"], ["--native-debug-stdio-wrapper", wrapper])
        specification["name"] = calibration_name(specification["name"], profile)
        calibration_binary = option(args, :calibration_binary)
        if calibration_binary !== nothing
            CalibrationExport.copy_calibration_binary(package, realpath(calibration_binary))
        end
        staged_provenance["heart_calibration"] = Dict(
            "version"=>1, "stage"=>stage, "illumination"=>illumination, "plant"=>plant,
            "frozen_method"=>method_inputs === nothing ? nothing : Dict("path"=>"heart-method",
                "identity_sha256"=>ScienceExport.sha256(joinpath(package, "heart-method/identity.json"))),
            "frozen_plan"=>plan_path === nothing ? nothing : Dict("sha256"=>ScienceExport.sha256(plan_path),
                "path"=>"heart-calibration-plan.json", "limits"=>limits),
            "native_ingress"=>ingress,
            "native_wfs_proc_debug"=>native_debug,
            "native_debug_stdio_wrapper"=>wrapper === nothing ? nothing : Dict("path"=>wrapper,
                "sha256"=>ScienceExport.sha256(wrapper), "argv_prefix"=>[wrapper, "-oL", "-eL"]),
            "native_debug_scope"=>native_debug ? "diagnostic only; cadence and science qualification excluded" : "disabled",
            "owner_evidence_directory"=>evidence_directory,
            "native_hold"=>"strict fresh startup CORRECT endpoint-enable ACK, followed by RUN hold ACK before any admitted exposure",
            "telemetry"=>[Dict("tag"=>tag, "decimate"=>0, "poll_period_s"=>0.001) for tag in TELEMETRY_TAGS],
            "telemetry_max_bytes_per_file"=>telemetry_budget, "capture_max_payload_bytes"=>capture_budget,
            "pipewireao_source"=>override, "pipewireao_revision"=>ScienceExport.revision(override),
            "pipewireao_exchange_sha256"=>ScienceExport.sha256(joinpath(package, "hil/packages/PipeWireAO/src/ndarray_exchange.jl")),
            "native_config_sha256"=>ScienceExport.sha256(joinpath(package, "heart/config.yaml.in")),
            "helper_sha256"=>Dict(name=>ScienceExport.sha256(joinpath(package, "hil", name)) for name in selected_helpers),
            "qualification"=>"finite native completion pilot; scientific matrix, correction and rate acceptance pending")
        if classic !== nothing
            staged_provenance["heart_calibration"]["classic_transfer"] = classic["record"]
        end
        staged_provenance["hil"]["pipewireao_jl_revision"] = ScienceExport.revision(override)
        Common.write_json(joinpath(package, "provenance.json"), staged_provenance)
        specification["artifacts"] = HeartExport._artifacts(package)
        Common.write_json(joinpath(package, "deployment.conf"), specification)
        Deployment.profile(joinpath(package, "deployment.conf"), args.pipewire_prefix)
        mv(package, output)
        return joinpath(output, "deployment.conf")
    end
end

function retain_pilot(instance, output, maximum_bytes)
    total = UInt64(0)
    for name in ("captured", "heart-probes", "heart/native", "simulator-result.json", "heart.log", "simulator.log")
        source = joinpath(instance, name)
        ispath(source) || continue
        islink(source) && throw(ArgumentError("pilot evidence contains a symlink"))
        # Native config contains owner-created symlinks to immutable package
        # artifacts. Retain native output files explicitly; do not traverse it.
        paths = if name == "heart/native"
            filter(path -> isfile(path) &&
                (endswith(path, ".tel") || basename(path) == "heart-owner-status.json" ||
                    startswith(basename(path), "command-") || occursin(r"^heart-[0-9]+\.log$", basename(path))),
                readdir(source; join=true))
        elseif isdir(source)
            [joinpath(directory, file) for (directory, _, files) in walkdir(source) for file in files]
        else
            [source]
        end
        for path in paths
            islink(path) && throw(ArgumentError("pilot evidence contains a symlink"))
            total = Base.checked_add(total, UInt64(filesize(path)))
            total <= maximum_bytes || throw(ArgumentError("pilot retained evidence exceeds its budget"))
            target = joinpath(output, name == "heart/native" ? joinpath(name, basename(path)) : relpath(path, instance))
            mkpath(dirname(target))
            ScienceExport.copy_file(path, target)
        end
    end
    return total
end

"""Run three finite native probe batches on an already admitted supervised deployment.

Retain final reports and native/capture evidence before public shutdown removes
the runtime instance. This demonstrates protocol completion only.
"""
function run_pilot(runtime::AbstractString, output::AbstractString; frames::Int=2,
    request_timeout_ns::Int=30_000_000_000, stage_timeout_seconds::Int=300,
    maximum_evidence_bytes::UInt64=UInt64(512 * 1024 * 1024),
)
    2 <= frames <= 64 || throw(ArgumentError("pilot requires 2:64 accepted frames per probe"))
    0 < request_timeout_ns <= 30_000_000_000 && 0 < stage_timeout_seconds <= 3600 || throw(ArgumentError("invalid pilot deadline"))
    output = abspath(output)
    !ispath(output) && !islink(output) && isdir(dirname(output)) || throw(ArgumentError("pilot evidence output must be fresh"))
    ready = Deployment.wait_state(runtime, state -> get(state, "admitted", false); timeout=30)
    instance = ready["private_runtime"]
    mkdir(output; mode=0o700)
    deadline = Base.checked_add(time_ns(), UInt64(stage_timeout_seconds) * UInt64(1_000_000_000))
    endpoint = CalibrationCampaign.endpoint_connect(CalibrationCampaign.endpoint_binding(ready), 1, request_timeout_ns)
    request = (action, expected) -> begin
        endpoint.timeout_ns = max(1, Int(floor(CalibrationCampaign.stage_remaining(deadline, request_timeout_ns / 1e9) * 1e9)))
        CalibrationCampaign.request!(endpoint, action, expected)
    end
    reference = zeros(Float32, 277)
    positive = copy(reference); positive[139] = 0.04f0
    negative = copy(reference); negative[139] = -0.04f0
    rule = Dict("kind"=>"discard_exposures", "frames"=>1)
    result = Dict{String,Any}("version"=>1, "profile"=>"copper", "engine"=>"heart", "ready"=>ready,
        "frames_per_probe"=>frames, "restoration_confirmed"=>false, "release_confirmed"=>false,
        "qualification"=>"finite native completion evidence; scientific and rate acceptance pending")
    result["startup_owner_report"] = Common.read_json(joinpath(instance, "simulator-result.json"))
    try
        held = request(Dict("kind"=>"hold"), "held")
        previous = held["cursor"]
        for (index, figure) in enumerate((reference, positive, negative))
            adopted = request(Dict("kind"=>"adopt", "probe"=>index-1, "figure"=>figure), "adopted")
            !adopted["clipped"] && CalibrationCampaign.same_figure(adopted["figure"], figure) && adopted["cursor"] == previous ||
                throw(ArgumentError("native pilot adoption clipped, changed figure or moved cursor"))
            settled = request(Dict("kind"=>"settle", "probe"=>index-1, "after"=>adopted["cursor"], "rule"=>rule), "settled")
            captured = request(Dict("kind"=>"capture", "probe"=>index-1, "after"=>settled["cursor"], "frames"=>frames), "captured")
            CalibrationCampaign.verify_capture(joinpath(instance, "captured"), captured; run=1,
                serial=endpoint.serial, stage=result["startup_owner_report"]["calibration_stage"], frames,
                after=settled["cursor"], startup=result["startup_owner_report"], profile="copper", probe=index-1)
            previous = captured["cursor"]
        end
        restored = request(Dict("kind"=>"restore", "figure"=>reference, "rule"=>rule), "restored")
        !restored["clipped"] && CalibrationCampaign.same_figure(restored["figure"], reference) || throw(ArgumentError("native restoration differs"))
        result["restoration_confirmed"] = true
        request(Dict("kind"=>"release"), "released")
        result["release_confirmed"] = true
        # Release flushes its native terminal reply and revokes action ingress.
        # Close our controller before waiting for the final owner report.
        close(endpoint)
        # The source reports completion after handling Release; wait for that
        # bounded publication before copying its final diagnostic report.
        report_path = joinpath(instance, "simulator-result.json")
        source = CalibrationCampaign.wait_completed_source(ready["control_locator"];
            deadline=Float64(deadline)/1e9)
        result["final_owner_report"] = CalibrationCampaign.completed_owner_report(
            report_path,source,result["startup_owner_report"])
    catch exception
        result["failure"] = sprint(showerror, exception)
        rethrow()
    finally
        close(endpoint)
        result["requests"] = endpoint.records
        try
            result["retained_bytes"] = retain_pilot(instance, output, maximum_evidence_bytes)
        catch exception
            result["retention_failure"] = sprint(showerror, exception)
            haskey(result, "failure") || rethrow()
        finally
            Common.write_json(joinpath(output, "pilot-result.json"), result)
        end
    end
    return joinpath(output, "pilot-result.json")
end

"""Collect a sealed public plan on an already admitted native deployment.

The caller owns launch/shutdown. Evidence is retained before shutdown and the
public CalibrationClient validates the actual means and exposure identities.
Estimators and installation policy remain with the frozen method pipeline.
"""
function run_plan(package::AbstractString, runtime::AbstractString, output::AbstractString;
    stage_timeout_seconds::Int=3600,
)
    total_start = time_ns()
    0 < stage_timeout_seconds <= 3600 || throw(ArgumentError("invalid native plan deadline"))
    package = realpath(package)
    specification = Deployment.profile(joinpath(package, "deployment.conf"), "/opt/pipewireao")
    descriptor_sha256 = ScienceExport.sha256(joinpath(package, "deployment.conf"))
    provenance = Common.read_json(joinpath(package, "provenance.json"))
    calibration = provenance["heart_calibration"]
    calibration["native_wfs_proc_debug"] === false || throw(ArgumentError("full native plans require nondebug science configuration"))
    frozen = calibration["frozen_plan"]
    frozen === nothing && throw(ArgumentError("native package has no frozen plan"))
    plan_path = joinpath(package, frozen["path"])
    ScienceExport.sha256(plan_path) == frozen["sha256"] || throw(ArgumentError("native frozen plan hash differs"))
    limits = plan_limits(Common.read_json(plan_path; maximum=16 * 1024 * 1024); profile=provenance["profile"])
    limits == frozen["limits"] || throw(ArgumentError("native frozen plan limits differ"))
    output = abspath(output)
    !ispath(output) && !islink(output) && isdir(dirname(output)) || throw(ArgumentError("native plan evidence must be fresh"))
    ready = Deployment.wait_state(runtime, state -> get(state, "admitted", false); timeout=30)
    instance = ready["private_runtime"]
    startup = Common.read_json(joinpath(instance, "simulator-result.json"))
    if provenance["profile"] == "classic"
        startup["profile"] == "classic" && startup["backend"] == provenance["hil"]["backend"] ||
            throw(ArgumentError("Classic runtime profile or backend differs from selected package"))
    end
    startup["graph_sha256"] == calibration["plant"]["graph_sha256"] &&
        startup["calibration_stage"] == calibration["stage"] && startup["sequence"] == 0 ||
        throw(ArgumentError("native runtime source differs from the frozen fresh package"))
    mkdir(output; mode=0o700)
    deadline = Base.checked_add(time_ns(), UInt64(stage_timeout_seconds) * UInt64(1_000_000_000))
    result = Dict{String,Any}("version"=>1, "plan_sha256"=>frozen["sha256"], "limits"=>limits,
        "runtime_identity"=>Dict("runtime"=>abspath(runtime), "instance"=>ready["instance"], "launcher_pid"=>ready["pid"],
            "ready_session_id"=>ready["ready"]["session_id"], "processes"=>ready["processes"],
            "source_owner"=>specification["source-owner"], "deployment_sha256"=>descriptor_sha256,
            "acquisition_generation"=>startup["acquisition_generation"],
            "acquisition_domain_mapping"=>startup["acquisition_domain_mapping"],
            "native_child_pid"=>startup["native_controller_held"]["child_pid"]),
        "startup_owner_report"=>startup, "qualification"=>"native completion and public means; scientific acceptance requires frozen method reduction",
        "phase_elapsed_ns"=>Dict{String,UInt64}("preflight"=>time_ns()-total_start))
    phase_started = time_ns()
    phase_name = "acquisition_including_first_call"
    try
        response_path = joinpath(output, "calibration-result.json")
        binding = CalibrationCampaign.endpoint_binding(ready)
        response = Common.run_checked([joinpath(package, "bin/rtc-calibrate"), "--remote", binding.remote,
            "--node", binding.node, "--owner-pid", string(binding.owner_pid),
            "--owner-instance", string(binding.instance), "--plan", plan_path];
            timeout=CalibrationCampaign.stage_remaining(deadline, stage_timeout_seconds),
            stdout_path=response_path, stderr_path=joinpath(output, "calibration.stderr"),
            maximum_output_bytes=limits["result_max_output_bytes"])
        response.returncode == 0 || throw(ArgumentError("public native calibration client failed: $(response.returncode)"))
        result["cli_result_sha256"] = ScienceExport.sha256(response_path)
        report_path = joinpath(instance, "simulator-result.json")
        source = CalibrationCampaign.wait_completed_source(ready["control_locator"];
            deadline=Float64(deadline)/1e9)
        final = CalibrationCampaign.completed_owner_report(report_path,source,startup)
        final["sequence"] == limits["completed_exposures"] &&
            final["detector_diagnostics"]["frames"] == limits["completed_exposures"] ||
            throw(ArgumentError("native completed owner count differs from frozen plan"))
        result["final_owner_report"] = final
        result["phase_elapsed_ns"][phase_name] = time_ns()-phase_started
        phase_name = "public_means_and_native_count_validation"
        phase_started = time_ns()
        verifier = joinpath(package, "hil", provenance["profile"] == "classic" ? "heart_classic_calibration_verify.jl" : "heart_calibration_verify.jl")
        prefix = [Base.julia_cmd().exec[1], "--startup-file=no", "--project=" * joinpath(package, "hil"), verifier]
        mean_check = Common.run_checked([prefix; "result"; plan_path; response_path;
            joinpath(output, "public-result-validation.json")]; timeout=CalibrationCampaign.stage_remaining(deadline, 120))
        mean_check.returncode == 0 || throw(ArgumentError("public CalibrationClient rejected native means: $(mean_check.stderr)"))
        count_check = Common.run_checked([prefix; "counts"; joinpath(instance, "heart/native");
            string(limits["completed_exposures"]); string(limits["native_dm_records"]);
            string(calibration["telemetry_max_bytes_per_file"]); joinpath(output, "native-record-counts.json")];
            timeout=CalibrationCampaign.stage_remaining(deadline, 120))
        count_check.returncode == 0 || throw(ArgumentError("native held-controller counts differ: $(count_check.stderr)"))
        result["restoration_confirmed"] = true
        result["release_confirmed"] = true
        result["native_counts_confirmed"] = true
        result["native_record_counts_sha256"] = ScienceExport.sha256(joinpath(output, "native-record-counts.json"))
    catch exception
        result["failure"] = sprint(showerror, exception)
        rethrow()
    finally
        result["phase_elapsed_ns"][phase_name] = time_ns()-phase_started
        phase_started = time_ns()
        maximum_bytes = UInt64(calibration["capture_max_payload_bytes"]) +
            UInt64(4 * calibration["telemetry_max_bytes_per_file"]) + UInt64(64 * 1024 * 1024)
        try
            result["retained_bytes"] = retain_pilot(instance, output, maximum_bytes)
            association_path = joinpath(calibration["owner_evidence_directory"], "native-evidence.jsonl")
            filesize(association_path) <= calibration["telemetry_max_bytes_per_file"] ||
                throw(ArgumentError("native association evidence exceeds its bound"))
            ScienceExport.copy_file(association_path, joinpath(output, "native-association.jsonl"))
            control_directory = joinpath(output, "native-control")
            mkdir(control_directory)
            control_total = UInt64(0)
            for path in readdir(calibration["owner_evidence_directory"]; join=true)
                name = basename(path)
                occursin(r"^(command-[0-9]+\.log(?:\.json|\.stderr)?|probe-[0-9]+\.csv|relay-[0-9]+-source-ack\.json|startup-CORRECT\.log(?:\.stderr)?|startup-owner-status\.json)$", name) || continue
                !islink(path) && filesize(path) <= 512 * 1024 || throw(ArgumentError("native control evidence exceeds its per-file bound"))
                control_total += UInt64(filesize(path))
                control_total <= UInt64(limits["native_dm_records"] + 2) * UInt64(640 * 1024) ||
                    throw(ArgumentError("native control evidence exceeds count-derived bound"))
                ScienceExport.copy_file(path, joinpath(control_directory, name))
            end
            Common.write_json(joinpath(output, "native-runtime-identity.json"), result["runtime_identity"])
            if !haskey(result, "failure")
                Common.read_json(joinpath(output, "simulator-result.json")) == result["final_owner_report"] ||
                    throw(ArgumentError("final native owner changed during evidence retention"))
                ScienceExport.sha256(joinpath(output, "native-association.jsonl")) ==
                    result["final_owner_report"]["native_evidence"]["sha256"] ||
                    throw(ArgumentError("native association evidence changed during retention"))
                Common.write_json(joinpath(output, "native-plan-result.json"), result)
                checked = Common.run_checked([Base.julia_cmd().exec[1], "--startup-file=no", "--project=" * joinpath(package, "hil"),
                    joinpath(package, "hil", provenance["profile"] == "classic" ? "heart_classic_calibration_evidence.jl" : "heart_calibration_evidence.jl"), package, output]; timeout=120,
                    stdout_path=joinpath(output, "native-evidence-verification.json"),
                    stderr_path=joinpath(output, "native-evidence-verification.stderr"))
                checked.returncode == 0 || throw(ArgumentError("retained native evidence failed verification: $(checked.stderr)"))
                files = Dict{String,String}()
                for (directory, _, names) in walkdir(output), name in names
                    path = joinpath(directory, name)
                    name == "native-plan-result.json" && continue
                    islink(path) && throw(ArgumentError("linked native evidence"))
                    files[relpath(path, output)] = ScienceExport.sha256(path)
                end
                Common.write_json(joinpath(output, "native-evidence-manifest.json"), files)
                result["evidence_manifest_sha256"] = ScienceExport.sha256(joinpath(output, "native-evidence-manifest.json"))
            end
        catch exception
            result["retention_failure"] = sprint(showerror, exception)
            haskey(result, "failure") || rethrow()
        finally
            result["phase_elapsed_ns"]["evidence_retention_and_payload_revalidation"] = time_ns()-phase_started
            result["phase_elapsed_ns"]["run_plan_total"] = time_ns()-total_start
            Common.write_json(joinpath(output, "native-plan-result.json"), result)
        end
    end
    return joinpath(output, "native-plan-result.json")
end

"""Reduce a completed, publicly stopped native plan through its sealed public AOC method."""
function validate_stopped_runtime(state, identity, runtime, descriptor_sha256, exposures)
    identity isa AbstractDict && all(name -> haskey(identity, name),
        ("runtime", "deployment_sha256", "launcher_pid", "instance", "ready_session_id", "processes", "source_owner")) ||
        throw(ArgumentError("missing actual native runtime identity"))
    all(name -> haskey(state, name), ("pid", "instance", "ready", "processes", "source-owner", "source", "phase", "admitted")) ||
        throw(ArgumentError("missing completed native runtime state"))
    identity["runtime"] == abspath(runtime) && identity["deployment_sha256"] == descriptor_sha256 &&
        state["pid"] == identity["launcher_pid"] && state["instance"] == identity["instance"] &&
        state["ready"]["session_id"] == identity["ready_session_id"] && state["processes"] == identity["processes"] &&
        state["source-owner"] == identity["source_owner"] && state["source"]["sequence"] == exposures &&
        state["phase"] == "stopped" && state["admitted"] === false && get(state, "error", nothing) === nothing &&
        isempty(get(state, "cleanup_errors", [])) && !ispath(joinpath(runtime, identity["instance"])) ||
        throw(ArgumentError("native reduction requires the same captured runtime and successful public shutdown"))
    return nothing
end

function reduce_plan(package, evidence, runtime, output; expected_deployment_sha256::String,
    timeout_seconds::Int=300,
)
    package = realpath(package)
    ScienceExport.sha256(joinpath(package, "deployment.conf")) == expected_deployment_sha256 ||
        throw(ArgumentError("native deployment differs from the pre-acquisition descriptor"))
    Deployment.profile(joinpath(package, "deployment.conf"), "/opt/pipewireao")
    provenance = Common.read_json(joinpath(package, "provenance.json"))
    method = provenance["heart_calibration"]["frozen_method"]
    method === nothing && throw(ArgumentError("native reduction requires sealed method inputs"))
    completion_path = joinpath(evidence, "native-plan-result.json")
    completion = Common.read_json(completion_path)
    identity = get(completion, "runtime_identity", nothing)
    state = Common.read_json(joinpath(runtime, "state.json"))
    validate_stopped_runtime(state, identity, runtime, expected_deployment_sha256,
        get(get(completion, "limits", Dict()), "completed_exposures", nothing))
    manifest_path = joinpath(evidence, "native-evidence-manifest.json")
    ScienceExport.sha256(manifest_path) == completion["evidence_manifest_sha256"] ||
        throw(ArgumentError("native evidence manifest changed"))
    for (name, hash) in Common.read_json(manifest_path; maximum=16 * 1024 * 1024)
        path = abspath(joinpath(evidence, name))
        startswith(path, abspath(evidence) * "/") && !islink(path) && ScienceExport.sha256(path) == hash ||
            throw(ArgumentError("retained native evidence changed: $name"))
    end
    all(name -> get(completion, name, false) === true,
        ("restoration_confirmed", "release_confirmed", "native_counts_confirmed")) &&
        get(completion, "failure", nothing) === nothing && get(completion, "retention_failure", nothing) === nothing ||
        throw(ArgumentError("native completion evidence is incomplete"))
    completion["plan_sha256"] == provenance["heart_calibration"]["frozen_plan"]["sha256"] &&
        ScienceExport.sha256(joinpath(evidence, "calibration-result.json")) == completion["cli_result_sha256"] &&
        ScienceExport.sha256(joinpath(evidence, "native-record-counts.json")) == completion["native_record_counts_sha256"] ||
        throw(ArgumentError("native frozen result or record verification changed before reduction"))
    0 < timeout_seconds <= 3600 || throw(ArgumentError("invalid native reduction deadline"))
    verified = Common.run_checked([Base.julia_cmd().exec[1], "--startup-file=no", "--project=" * joinpath(package, "hil"),
        joinpath(package, "hil/heart_calibration_evidence.jl"), package, abspath(evidence)]; timeout=timeout_seconds)
    verified.returncode == 0 || throw(ArgumentError("native captured evidence revalidation failed: $(verified.stderr)"))
    response = Common.run_checked([Base.julia_cmd().exec[1], "--startup-file=no", "--project=" * joinpath(package, "hil"),
        joinpath(package, "hil/heart_calibration_method.jl"), joinpath(package, method["path"]),
        method["identity_sha256"], joinpath(evidence, "calibration-result.json"), abspath(output),
        expected_deployment_sha256, ScienceExport.sha256(completion_path)]; timeout=timeout_seconds,
        env=Dict("OPENBLAS_NUM_THREADS"=>"1"))
    response.returncode == 0 || throw(ArgumentError("native public AOC reduction failed: $(response.stderr)"))
    return joinpath(abspath(output), "candidate-response.json")
end

function main(argv=ARGS)
    installed_binary = joinpath(dirname(ScienceExport.package_root()), "bin", "pipewireao-rtc")
    default_binary = isfile(installed_binary) ? installed_binary :
        normpath(joinpath(ScienceExport.resource_root(), "..", "target", "release", "pipewireao-rtc"))
    options = Common.cli_arguments(argv; required=["base-package", "output", "heart-root", "heart-source-config", "calibration-root", "pipewireao-jl-root"],
        allowed=["adapter-root", "readout-us", "calibration-stage", "illumination", "capture-max-bytes", "telemetry-max-bytes", "calibration-binary", "owner-evidence-directory", "native-wfs-proc-debug", "native-debug-line-buffering", "plan", "simulator-backend", "detector-seed", "frozen-method", "native-ingress-mode", "classic-transfer", "classic-transfer-sha256"],
        defaults=(rtc_binary=default_binary, pipewire_prefix="/opt/pipewireao"))
    debug_option = option(options, :native_wfs_proc_debug, "false")
    debug_option in ("true", "false") || throw(ArgumentError("native WFS processing debug must be true or false"))
    line_option = option(options, :native_debug_line_buffering, "false")
    line_option in ("true", "false") || throw(ArgumentError("native diagnostic line buffering must be true or false"))
    args = merge(options, (; native_wfs_proc_debug=debug_option == "true",
        native_debug_line_buffering=line_option == "true", readout_us=parse(Int, option(options, :readout_us, "0")),
        simulator_backend=option(options, :simulator_backend, "cpu"),
        detector_seed=parse(Int, option(options, :detector_seed, "700"))))
    hasproperty(options, :capture_max_bytes) && (args = merge(args, (; capture_max_bytes=parse(Int, options.capture_max_bytes))))
    hasproperty(options, :telemetry_max_bytes) && (args = merge(args, (; telemetry_max_bytes=parse(Int, options.telemetry_max_bytes))))
    println(export_package(args))
    return 0
end

end
