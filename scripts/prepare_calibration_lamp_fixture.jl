#!/usr/bin/env julia
# Development-only Classic lamp fixture preparation; this is not a qualification.
using PipeWireAODeployment, TOML

const C = PipeWireAODeployment.Common
const D = PipeWireAODeployment.Deployment
const H = PipeWireAODeployment.HILExport
const Campaign = PipeWireAODeployment.CalibrationCampaign
const GENERATED_UNIT = "systemd/pipewireao-rtc@.service"

function verify_seals(package, specification)
    for (relative, expected) in specification["artifacts"]
        path = joinpath(package, relative)
        isfile(path) && !islink(path) || error("sealed artifact is absent or linked: $path")
        C.sha256_file(path) == expected || error("sealed artifact changed: $path")
    end
end

function calibration_owner(specification)
    specification["source-owner"] == "simulator" || error("fixture requires simulator source owner")
    owner = only(filter(item -> item["role"] == specification["source-owner"], specification["owners"]))
    owner["control-protocol"] == "pipewireao.rtc.calibration-lifecycle/1" ||
        error("fixture requires the native calibration lifecycle owner")
    argv = owner["argv"]
    option(name) = begin
        positions = findall(==(name), argv)
        length(positions) == 1 && only(positions) < length(argv) || error("owner is missing one $name argument")
        argv[only(positions) + 1]
    end
    option("--profile") == "classic" || error("owner is not configured for Classic")
    option("--rate") == "500" || error("owner rate is not 500 Hz")
    option("--illumination") == "lamp" || error("owner is not configured for lamp illumination")
    option("--graph") == "@PACKAGE@/hil/plant.toml" || error("owner graph is not the sealed plant")
    return owner, argv
end

function read_plant(source)
    text = read(source, String)
    model = TOML.parse(text)
    wfs = only(filter(node -> node["name"] == "shwfs", model["nodes"]))
    detector = only(filter(node -> node["name"] == "detector", model["nodes"]))
    old_magnitude = wfs["config"]["source_magnitude"]
    seed = detector["config"]["rng_seed"]
    return text, model, old_magnitude, seed
end

function main(args)
    length(args) == 3 || error("usage: SOURCE FRESH_STAGE RECIPE")
    source, stage, recipe_path = abspath.(args)
    installed = stage * "-installed"
    proof_path = stage * "-coldproof.json"
    !ispath(stage) && !islink(stage) && !ispath(installed) && !islink(installed) &&
        !ispath(proof_path) && !islink(proof_path) || error("stage, installed package and coldproof paths must be fresh")

    source_descriptor_path = joinpath(source, "deployment.conf")
    source_provenance_path = joinpath(source, "provenance.json")
    source_plant_path = joinpath(source, "hil", "plant.toml")
    descriptor = C.read_json(source_descriptor_path)
    specification = D.profile(source_descriptor_path, "/opt/pipewireao")
    verify_seals(source, descriptor)
    owner, owner_argv = calibration_owner(specification)
    provenance = C.read_json(source_provenance_path)
    provenance["profile"] == "classic" && provenance["mode"] == "frame" &&
        provenance["engine"] == "fgn" && provenance["rate"] == "500/1" ||
        error("source provenance is not the sealed Classic FGN frame source at 500 Hz")

    recipe = C.read_json(recipe_path)
    magnitude = get(recipe, "lamp_magnitude", nothing)
    magnitude isa Real && !(magnitude isa Bool) && isfinite(magnitude) ||
        error("recipe lamp_magnitude must be finite")

    source_artifacts = H._package_artifacts(source)
    GENERATED_UNIT in keys(source_artifacts) || error("source generated unit is absent")
    GENERATED_UNIT ∉ keys(descriptor["artifacts"]) || error("source generated unit must remain installer-owned and unsealed")
    source_unit_path = joinpath(source, GENERATED_UNIT)
    isfile(source_unit_path) && !islink(source_unit_path) || error("source generated unit is linked or absent")
    old_unit_hash = C.sha256_file(source_unit_path)
    source_file_hashes = copy(source_artifacts)
    old_plant_hash = C.sha256_file(source_plant_path)
    old_descriptor_hash = C.sha256_file(source_descriptor_path)
    old_provenance_hash = C.sha256_file(source_provenance_path)
    source_text, source_model, old_magnitude, detector_seed = read_plant(source_plant_path)

    cp(source, stage)
    rm(joinpath(stage, GENERATED_UNIT))
    stage_plant_path = joinpath(stage, "hil", "plant.toml")
    updated_text = Campaign.set_model_setting(source_text, "shwfs", "source_magnitude", magnitude)
    write(stage_plant_path, updated_text)
    updated_model = TOML.parse(updated_text)
    updated_wfs = only(filter(node -> node["name"] == "shwfs", updated_model["nodes"]))
    updated_detector = only(filter(node -> node["name"] == "detector", updated_model["nodes"]))
    expected_model = deepcopy(source_model)
    only(filter(node -> node["name"] == "shwfs", expected_model["nodes"]))["config"]["source_magnitude"] = magnitude
    updated_model == expected_model || error("plant change was not limited to shwfs source_magnitude")
    updated_detector["config"]["rng_seed"] == detector_seed || error("detector RNG seed changed")
    updated_wfs["config"]["source_magnitude"] == magnitude || error("recipe lamp magnitude was not applied")

    changed_model_hash = C.sha256_file(stage_plant_path)
    changed_model_hash != old_plant_hash || error("recipe did not change the plant bytes")
    staged_artifacts = H._package_artifacts(stage)
    protected_files = Dict(path => hash for (path, hash) in source_file_hashes
        if path ∉ ("hil/plant.toml", "provenance.json", GENERATED_UNIT))
    all(get(staged_artifacts, path, nothing) == hash for (path, hash) in protected_files) ||
        error("a protected package file changed during fixture preparation")
    Set(keys(staged_artifacts)) == setdiff(Set(keys(source_artifacts)), Set([GENERATED_UNIT])) ||
        error("package file inventory changed beyond the installer-owned generated unit")

    fixture_receipt = Dict{String,Any}(
        "scope" => "historical development-only illumination fixture; no qualification claim",
        "preparation_helper_sha256" => C.sha256_file(@__FILE__),
        "source_package" => source,
        "source_descriptor_sha256" => old_descriptor_hash,
        "source_provenance_sha256" => old_provenance_hash,
        "recipe_path" => recipe_path,
        "recipe_sha256" => C.sha256_file(recipe_path),
        "source_owner_role" => owner["role"],
        "source_owner_argv" => owner_argv,
        "source_provenance_profile" => provenance["profile"],
        "source_provenance_mode" => provenance["mode"],
        "source_provenance_rate" => provenance["rate"],
        "source_plant_sha256" => old_plant_hash,
        "fixture_plant_sha256" => changed_model_hash,
        "installer_owned_unit_path" => GENERATED_UNIT,
        "source_generated_unit_sha256" => old_unit_hash,
        "staged_generated_unit_omitted" => true,
        "source_magnitude" => old_magnitude,
        "recipe_lamp_magnitude" => magnitude,
        "detector_rng_seed" => detector_seed,
        "protected_files" => protected_files,
        "protected_files_unchanged" => true,
        "descriptor_updates" => ["name", "artifacts"],
        "provenance_artifact_map_excludes" => ["deployment.conf", "provenance.json"])

    staged_provenance = C.read_json(joinpath(stage, "provenance.json"))
    staged_provenance["calibration_illumination_fixture"] = fixture_receipt
    staged_provenance["artifacts"] = Dict(path => hash for (path, hash) in staged_artifacts
        if path ∉ ("deployment.conf", "provenance.json"))
    C.write_json(joinpath(stage, "provenance.json"), staged_provenance)

    final_artifacts = H._package_artifacts(stage)
    removed_files = sort!(collect(setdiff(Set(keys(source_artifacts)), Set(keys(final_artifacts)))))
    removed_files == [GENERATED_UNIT] || error("unexpected package files removed: $removed_files")
    changed_files = sort!([path for path in keys(final_artifacts)
        if get(source_artifacts, path, nothing) != final_artifacts[path]])
    changed_files == ["hil/plant.toml", "provenance.json"] || error("unexpected package file changes: $changed_files")
    descriptor["name"] = basename(stage)
    descriptor["artifacts"] = final_artifacts
    C.write_json(joinpath(stage, "deployment.conf"), descriptor)
    D.profile(joinpath(stage, "deployment.conf"), "/opt/pipewireao")
    verify_seals(stage, descriptor)
    H._package_artifacts(stage)["provenance.json"] == C.sha256_file(joinpath(stage, "provenance.json")) ||
        error("updated provenance is not included in the descriptor seal")

    installed_package = D.install((; package=stage, destination=installed, pipewire_prefix="/opt/pipewireao"))
    installed_descriptor = C.read_json(joinpath(installed_package, "deployment.conf"))
    D.profile(joinpath(installed_package, "deployment.conf"), "/opt/pipewireao")
    verify_seals(installed_package, installed_descriptor)
    installed_unit_path = joinpath(installed_package, GENERATED_UNIT)
    isfile(installed_unit_path) && !islink(installed_unit_path) || error("installer did not generate its unit")
    all(C.sha256_file(joinpath(installed_package, path)) == hash for (path, hash) in protected_files) ||
        error("installed protected file differs from the source")
    verify_seals(source, C.read_json(source_descriptor_path))
    source_provenance_hash_after = C.sha256_file(source_provenance_path)
    source_provenance_hash_after == old_provenance_hash || error("source provenance changed")
    C.sha256_file(source_descriptor_path) == old_descriptor_hash || error("source descriptor changed")
    H._package_artifacts(source) == source_artifacts || error("source package changed")

    fixture_receipt["installed_package"] = installed_package
    fixture_receipt["installed_descriptor_sha256"] = C.sha256_file(joinpath(installed_package, "deployment.conf"))
    fixture_receipt["installed_provenance_sha256"] = C.sha256_file(joinpath(installed_package, "provenance.json"))
    fixture_receipt["installed_seal_count"] = length(installed_descriptor["artifacts"])
    fixture_receipt["installed_generated_unit_sha256"] = C.sha256_file(installed_unit_path)
    C.write_json(proof_path, fixture_receipt)
    println(installed_package)
end

abspath(PROGRAM_FILE) == (@__FILE__) && main(ARGS)
