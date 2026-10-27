using PipeWireAORTC, TOML
const R = PipeWireAORTC
const C = R.Common
const cache = "/home/dgamroth/.cache/pipewireao/loop-operations-20261026"
const repo = "/home/dgamroth/workspaces/codex/adaptive-optics-simulations"
const root = "/home/dgamroth/.local/state/pipewireao/gpi2-loop-controls-live-20261026"
mkpath(root)
manifest = joinpath(dirname(Base.active_project()), "Manifest.toml")
deps = TOML.parsefile(manifest)["deps"]
@assert only(deps["PipeWireAORTC"])["version"] == "0.2.14"
@assert only(deps["FilterGraphPipeWire"])["version"] == "0.1.9"
for entries in values(deps), entry in entries
    @assert !haskey(entry, "path") && !haskey(entry, "repo-url")
end
empty!(ARGS)
append!(ARGS, [joinpath(repo,"gpi2"),
    "/home/dgamroth/.cache/pipewireao/gpi2-yaml-release-20261026/calibration",
    joinpath(cache,"instrument-source")])
Base.include(Module(:CalibrationStaging),joinpath(repo,"tools/stage-modal-calibration.jl"))
profile = C.read_yaml("/home/dgamroth/.cache/pipewireao/gpi2-yaml-release-20261026/host-cuda.yaml")
for role in ("julia", "simulator", "session")
    profile["environment"][role]["JULIA_DEPOT_PATH"] = ENV["JULIA_DEPOT_PATH"]
end
C.write_yaml(joinpath(cache,"host-cuda.yaml"),profile)
R.InstrumentExport.prepare(joinpath(cache,"instrument-source"),joinpath(root,"application");
    profile,manifest,prefix=ENV["PIPEWIREAO_PREFIX"])
C.write_json(joinpath(root,"preparation.json"),Dict(
    "rtc_version"=>string(pkgversion(R)),
    "source_commit"=>strip(read(`git -C $repo rev-parse HEAD`,String)),
    "manifest_sha256"=>C.sha256_file(manifest),
    "previous_calibration_reused"=>true,
    "calibration_receipt_sha256"=>C.sha256_file(joinpath(root,"application/calibration/result.yaml"))))
println("Prepared registered RTC 0.2.14 with unchanged calibrated science")
