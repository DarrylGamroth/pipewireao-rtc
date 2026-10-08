# Included by HeartCalibrationExport. Classic admission is deliberately scoped
# to the reviewed four-direction transfer of the accepted CPU-selected inverse.
const CLASSIC_ACCEPTED_INVERSE_SHA256 = "bb9aa68345a3402445b65a350e796b212e048453bf917245cee7f36efa015813"

# Exact accepted projection resources proved by E_native*S == B and T=Sᵀ.
const CLASSIC_TRANSFER_MAPS = (
    ("controller-to-vdm",[221,221],"983d34d2a0b061ba1769f01b4b112e00b8a39f74f45bc9e7d7f01d21dc7ac772"),
    ("active-to-full",[277,221],"8c6c942d40ea6f2814db19c407ebba2d2159eaf29876ed08114967a1c96c0e81"),
    ("vdm-to-pdm",[277,277],"3b65fcfa047483b8f46a6129b86db1f990b0651487c6c5bf2418862ed093e136"),
    ("full-to-active",[221,277],"f8293d858992ae5acac10cc67dd6fd887cf72d5f3b489e6d42866b787d8dccaa"),
    ("pdm-to-vdm",[277,277],"3b65fcfa047483b8f46a6129b86db1f990b0651487c6c5bf2418862ed093e136"),
    ("vdm-to-controller",[221,221],"983d34d2a0b061ba1769f01b4b112e00b8a39f74f45bc9e7d7f01d21dc7ac772"))

function classic_selected_resources(base, provenance, specification, prefix)
    graph = DeploymentConfiguration.decode(joinpath(base,"graphs/graph.conf.in"),prefix)
    controller = only(filter(node->get(node,"label",nothing)=="closed-loop-correction-f32",graph["filter.graph"]["nodes"]))
    controller["props"]["gain"] == -0.3 && controller["props"]["pole"] == 0.99 &&
        controller["props"]["anti-windup-gain"] == 0.99 && controller["config"]["state_length"] == 221 ||
        throw(ArgumentError("Classic accepted controller settings differ"))
    files=Dict{String,String}()
    for (name,shape,expected) in CLASSIC_TRANSFER_MAPS
        binding=only(filter(row->row["name"]==name,provenance["parameters"]))
        binding["shape"] == shape && binding["element_type"] == "F32_LE" ||
            throw(ArgumentError("Classic accepted map extent differs: $name"))
        relative="calibration/"*binding["file"]
        specification["artifacts"][relative] == ScienceExport.sha256(joinpath(base,relative)) == expected ||
            throw(ArgumentError("Classic accepted map bytes differ: $name"))
        files[relative]=expected
    end
    return files
end

function classic_ingress_contract(mode, properties, executable; source_revision)
    mode == "streaming" || throw(ArgumentError("Classic supports ordinary native streaming only"))
    expected = Dict("api.heart.std-wfs.width"=>352, "api.heart.std-wfs.height"=>352,
        "api.heart.std-wfs.pixels-per-datagram"=>3872, "api.heart.std-wfs.rows-per-datagram"=>true)
    all(get(properties, key, nothing) === value for (key, value) in expected) ||
        throw(ArgumentError("Classic requires 352×352 and exactly 32 eleven-row datagrams"))
    return Dict("mode"=>mode, "environment_key"=>"HRT_DEFER_WFS_INGRESS", "environment_value"=>"0",
        "shape"=>[352,352], "packet_rows"=>11, "datagrams_per_frame"=>32,
        "source_revision"=>source_revision, "executable_sha256"=>ScienceExport.sha256(executable),
        "qualification"=>"ordinary Classic streaming; finite transfer and cadence qualification separate")
end

function freeze_classic_detector!(path; seed)
    seed == 98 && CalibrationCampaign.isint(seed) || throw(ArgumentError("Classic transfer requires frozen detector seed 98"))
    graph = TOML.parsefile(path)
    detectors = filter(node -> get(node, "name", nothing) == "detector", graph["nodes"])
    length(detectors) == 1 && only(detectors)["type"] == "cmos_detector_acquisition_f32" ||
        throw(ArgumentError("Classic transfer requires the normal CMOS detector"))
    detector = only(detectors)["config"]
    detector["photon_noise"] === true && detector["readout_noise"] === true && detector["bits"] == 12 ||
        throw(ArgumentError("Classic transfer requires normal noise and actual 12-bit ADC"))
    sensor = only(filter(node -> get(node, "name", nothing) == "shwfs", graph["nodes"]))
    sensor["type"] == "shack_hartmann_rate_f32" || throw(ArgumentError("unexpected Classic sensor"))
    before = ScienceExport.sha256(path)
    original_seed, original_magnitude = detector["rng_seed"], sensor["config"]["source_magnitude"]
    detector["rng_seed"] = seed
    sensor["config"]["source_magnitude"] = 0.5
    open(io -> TOML.print(io, graph; sorted=true), path, "w")
    TOML.parsefile(path) == graph || throw(ArgumentError("Classic graph serialization changed values"))
    return Dict("graph_before_sha256"=>before, "graph_sha256"=>ScienceExport.sha256(path),
        "original_detector_seed"=>original_seed, "detector_seed"=>seed,
        "original_lamp_magnitude"=>original_magnitude, "lamp_magnitude"=>0.5,
        "photon_noise"=>true, "readout_noise"=>true,
        "illumination_scope"=>"static calibration lamp selected by acquisition; normal atmosphere graph retained")
end

function classic_transfer_policy(directory, expected_sha256, plan_path, seed)
    directory = realpath(directory)
    policy_path = joinpath(directory, "policy.json")
    expected_sha256 isa AbstractString && occursin(r"^[0-9a-f]{64}$", expected_sha256) &&
        ScienceExport.sha256(policy_path) == expected_sha256 || throw(ArgumentError("Classic transfer policy SHA differs"))
    policy = Common.read_json(policy_path)
    get(policy, "version", nothing) == 1 && get(policy, "selected_direction_ids", nothing) == [1,8,9,16] &&
        get(policy, "groups", nothing) == Dict("sparse"=>[1,8], "mixed"=>[9,16]) &&
        get(policy, "accepted_inverse_sha256", nothing) == CLASSIC_ACCEPTED_INVERSE_SHA256 ||
        throw(ArgumentError("unsupported Classic transfer policy"))
    seed == 98 && get(policy, "detector_seed", nothing) == seed && get(policy, "lamp_magnitude", nothing) == 0.5 ||
        throw(ArgumentError("Classic transfer seed or lamp differs"))
    plan_path !== nothing || throw(ArgumentError("Classic transfer requires its frozen plan"))
    for name in ("interaction-plan.json", "directions.json", "probe-labels.json", "recipe.json")
        path = joinpath(directory, name)
        !islink(path) && filesize(path) <= 16 * 1024 * 1024 && ScienceExport.sha256(path) == policy["prepared_files"][name] ||
            throw(ArgumentError("Classic prepared transfer input differs: $name"))
    end
    ScienceExport.sha256(plan_path) == policy["prepared_files"]["interaction-plan.json"] ||
        throw(ArgumentError("Classic selected plan differs"))
    plan = Common.read_json(plan_path; maximum=16 * 1024 * 1024)
    limits = plan_limits(plan; profile="classic")
    plan["run"] == 98 && plan["frames_per_probe"] == 64 && plan["settling"] == Dict("kind"=>"discard_exposures", "frames"=>1) &&
        limits["probe_batches"] == 24 && limits["completed_exposures"] == 1561 && limits["native_dm_records"] == 25 ||
        throw(ArgumentError("Classic transfer counts differ from reviewed finite corpus"))
    recipe = Common.read_json(joinpath(directory, "recipe.json"))
    recipe["seeds"]["interaction"] == seed && recipe["lamp_magnitude"] == 0.5 && recipe["adc_upper_rail"] == 4095 &&
        recipe["frames_per_probe"] == 64 && recipe["settling"] == plan["settling"] && recipe["reference"] == plan["reference"] ||
        throw(ArgumentError("Classic recipe differs from frozen plan"))
    Set(keys(policy["source_files"])) == Set(("interaction-plan.json", "directions.json", "probe-labels.json", "policy.json")) ||
        throw(ArgumentError("Classic source corpus ledger is incomplete"))
    source = realpath(policy["source_corpus"])
    for (name, hash) in policy["source_files"]
        name in ("interaction-plan.json", "directions.json", "probe-labels.json", "policy.json") ||
            throw(ArgumentError("unexpected Classic source corpus file"))
        ScienceExport.sha256(joinpath(source, name)) == hash || throw(ArgumentError("Classic source corpus changed: $name"))
    end
    original = Common.read_json(joinpath(source, "interaction-plan.json"))
    labels = Common.read_json(joinpath(source, "probe-labels.json"))
    selected = findall(row -> row["direction"] in [1,8,9,16], labels)
    original["reference"] == plan["reference"] && original["probes"][selected] == plan["probes"] &&
        labels[selected] == Common.read_json(joinpath(directory, "probe-labels.json")) ||
        throw(ArgumentError("Classic transfer changed original figures or chronology"))
    original_directions = Common.read_json(joinpath(source, "directions.json"))
    filter(row -> row["direction"] in [1,8,9,16], original_directions) == Common.read_json(joinpath(directory, "directions.json")) ||
        throw(ArgumentError("Classic transfer changed original directions"))
    for (name, hash) in policy["source_files"]
        ScienceExport.sha256(joinpath(source,name)) == hash || throw(ArgumentError("Classic source corpus changed during validation"))
    end
    return policy
end

function classic_transfer_inputs(args, base, provenance, plan_path, seed)
    option(args, :native_ingress_mode, "streaming") == "streaming" && option(args, :illumination, "lamp") == "lamp" ||
        throw(ArgumentError("Classic transfer requires streaming lamp acquisition"))
    policy = classic_transfer_policy(args.classic_transfer, option(args, :classic_transfer_sha256), plan_path, seed)
    inputs = HeartConfiguration.calibration_inputs(base, provenance; pipewire_prefix=args.pipewire_prefix)
    inputs.mode == "operational" || throw(ArgumentError("Classic transfer requires accepted operational offsets"))
    specification = DeploymentConfiguration.profile(joinpath(base, "deployment.conf"), args.pipewire_prefix)
    CalibrationCampaign.validate_simulator_backend(base, specification, provenance; allowed_backends=("cpu", "cuda"))
    profile = provenance["prepared_profile"]
    profile["controlled_vdm_size"] == 221 && profile["full_vdm_size"] == 277 && profile["pdm_size"] == 277 ||
        throw(ArgumentError("Classic transfer requires selected 221/physical 277 coordinates"))
    binding = only(filter(row -> row["name"] == "reconstructor", provenance["parameters"]))
    binding["shape"] == [221,376] && binding["element_type"] == "F32_LE" || throw(ArgumentError("Classic selected inverse shape differs"))
    relative = "calibration/" * binding["file"]
    specification["artifacts"][relative] == ScienceExport.sha256(joinpath(base, relative)) == CLASSIC_ACCEPTED_INVERSE_SHA256 ||
        throw(ArgumentError("Classic transfer requires the accepted inverse bytes"))
    maps = classic_selected_resources(base, provenance, specification, args.pipewire_prefix)
    policy["physical_B_sha256"] == CLASSIC_TRANSFER_MAPS[2][3] || throw(ArgumentError("Classic frozen physical map differs"))
    active = read(inputs.active)
    active == UInt8[index in (86,87,102,103) ? 0 : 1 for index in 1:188] ||
        throw(ArgumentError("Classic transfer eligibility differs from accepted corpus"))
    return Dict("active"=>active, "directory"=>realpath(args.classic_transfer), "record"=>Dict(
        "policy_sha256"=>ScienceExport.sha256(joinpath(args.classic_transfer, "policy.json")),
        "accepted_inverse_sha256"=>CLASSIC_ACCEPTED_INVERSE_SHA256, "selected_inverse_path"=>relative, "map_files_sha256"=>maps,
        "controller"=>Dict("gain"=>-0.3,"pole"=>0.99,"anti_windup_gain"=>0.99),
        "inputs_sha256"=>Dict(name=>ScienceExport.sha256(joinpath(args.classic_transfer, name)) for name in
            ("policy.json", "interaction-plan.json", "directions.json", "probe-labels.json", "recipe.json")),
        "active_sha256"=>ScienceExport.sha256(inputs.active), "measurements"=>376,
        "physical_coordinates"=>277, "selected_coordinates"=>221,
        "native_measurement_scale"=>[1.0,1.0], "native_measurement_order"=>collect(1:188),
        "inactive_native_state"=>-1, "scope"=>policy["scope"]))
end

function stage_classic_inputs!(package, inputs)
    record = inputs["record"]
    ScienceExport.sha256(joinpath(package,record["selected_inverse_path"])) == record["accepted_inverse_sha256"] ||
        throw(ArgumentError("Classic accepted inverse changed while copying package"))
    for (relative,hash) in record["map_files_sha256"]
        ScienceExport.sha256(joinpath(package,relative)) == hash || throw(ArgumentError("Classic accepted map changed while copying"))
    end
    write(joinpath(package, "heart/classic-active.u8"), inputs["active"])
    write(joinpath(package, "heart/classic-order.u32le"), reinterpret(UInt8, htol.(UInt32.(1:188))))
    directory = joinpath(package, "heart/classic-transfer")
    mkdir(directory)
    for (name, hash) in inputs["record"]["inputs_sha256"]
        source = joinpath(inputs["directory"], name)
        ScienceExport.sha256(source) == hash || throw(ArgumentError("Classic transfer source changed before copy"))
        ScienceExport.copy_file(source, joinpath(directory, name))
        ScienceExport.sha256(joinpath(directory, name)) == hash || throw(ArgumentError("Classic copied transfer input differs"))
    end
end
