using PipeWireAORTC, TOML
const C=PipeWireAORTC.Common
const rtc="/home/dgamroth/workspaces/codex/pipewire/pipewireao-rtc-series"
const app="/home/dgamroth/workspaces/codex/pipewire/revolt-classic-rtc"
const evidence=joinpath(rtc,"docs/validation/wavefront-series-20261022")
const live="/home/dgamroth/.local/state/pipewireao/classic-cpu-wavefront-series-live-20261022"
const raw="/home/dgamroth/workspaces/codex/worktrees/wavefront-series-20261022"
const prefix="/home/dgamroth/.local/opt/pipewireao-classic-headless-20261021"
spec=C.read_json(joinpath(app,"deployment.conf"))
all(C.sha256_file(joinpath(app,name))==hash for (name,hash) in spec["artifacts"]) || error("unsealed app")
science=["simulation.conf","graph.conf","parameters.conf","calibration-result.toml"]
append!(science,filter(n->startswith(n,"artifacts/"),split(read(`git -C $app ls-files`,String),'\n')))
for name in science
    read(joinpath(app,name))==read(Cmd(["git","-C",app,"show","4c8cf50:"*name])) || error("scientific input changed: $name")
end
production=["ext/aos/optical_observation.jl","ext/PipeWireAORTCAOSExt.jl","Project.toml"]
hashes=Dict(name=>C.sha256_file(joinpath(rtc,name)) for name in production)
all(hash==C.sha256_file(joinpath(pkgdir(PipeWireAORTC),name)) for (name,hash) in hashes) || error("registered source mismatch")
manifest=TOML.parsefile(joinpath(app,"Manifest.toml"))
dependency=only(manifest["deps"]["PipeWireAORTC"])
@assert dependency["version"]=="0.2.4" && dependency["git-tree-sha1"]=="742ec6818dcaf3d241bdd1d17f788997dfc9638f"
mkpath(joinpath(evidence,"live"));mkpath(joinpath(evidence,"scripts"))
for file in ("live-identity.json","live-graphics-audit.json","live-observation.json","live-rms-check.json","live-gpu-audit.json","status-verified.json","start.json","previous-session-final.json")
    cp(joinpath(live,file),joinpath(evidence,"live",file);force=true)
end
for file in ("launch-live.jl","check-live.jl","record-provenance.jl")
    cp(joinpath(raw,file),joinpath(evidence,"scripts",file);force=true)
end
for file in ("launch-live.log","check-live-glow-mesa.log","check-live-glow.log","check-live-gpu-failed.log")
    cp(joinpath(raw,file),joinpath(evidence,"logs",file);force=true)
end
tests=["test/aos_optical_observation.jl","test/integration/classic_wavefront.jl","test/integration/classic_observation.jl","test/integration/classic_managed_replay.jl","test/integration/prefix_capture.jl"]
C.write_json(joinpath(evidence,"integration.json"),Dict(
    "complete"=>true,"application_commit"=>strip(read(`git -C $app rev-parse HEAD`,String)),
    "package_commit"=>"ea5bd18b5a9e7097085ea452733ebabc78aaddff",
    "package_version"=>dependency["version"],"package_tree"=>dependency["git-tree-sha1"],
    "private_registry_only"=>true,"scientific_files_unchanged"=>science,
    "sealed_artifact_count"=>length(spec["artifacts"]),"production_sha256"=>hashes,
    "test_sha256"=>Dict(n=>C.sha256_file(joinpath(rtc,n)) for n in tests),
    "native_prefix"=>prefix,"native_endpoint_sha256"=>C.sha256_file(joinpath(prefix,"lib/pipewireao-rtc/modules/libwireplumber-module-ao-control-endpoint.so")),
    "gui_commit"=>"630198f88fd07cdba5c0c316f1c0307b4f58c2f2","gui_binary_sha256"=>C.sha256_file("/home/dgamroth/.local/opt/pipewireao-classic-headless-20261021/bin/pipewireao-gui-630198f-glow"),
    "scope"=>"Private package pin, unchanged science/calibration, finite CPU replay/reset and live GUI subscription; no GPU, cadence or hardware qualification"))
println("Provenance matches immutable registered source; all ",length(spec["artifacts"])," deployment artifacts sealed; scientific files unchanged")
