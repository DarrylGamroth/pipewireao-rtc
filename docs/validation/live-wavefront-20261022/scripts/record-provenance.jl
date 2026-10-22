using PipeWireAORTC, TOML
const C=PipeWireAORTC.Common
const rtc="/home/dgamroth/workspaces/codex/pipewire/pipewireao-rtc-wavefront"
const app="/home/dgamroth/workspaces/codex/pipewire/revolt-classic-rtc"
const evidence=joinpath(rtc,"docs/validation/live-wavefront-20261022")
const live="/home/dgamroth/.local/state/pipewireao/classic-cpu-wavefront-live-20261022"
const raw="/home/dgamroth/workspaces/codex/worktrees/live-wavefront-20261022"
const prefix="/home/dgamroth/.local/opt/pipewireao-classic-headless-20261021"
spec=C.read_json(joinpath(app,"deployment.conf"))
all(C.sha256_file(joinpath(app,name))==hash for (name,hash) in spec["artifacts"]) || error("unsealed app")
science=["simulation.conf","graph.conf","parameters.conf","calibration-result.toml"]
append!(science,filter(n->startswith(n,"artifacts/"),split(read(`git -C $app ls-files`,String),'\n')))
for name in science
    read(joinpath(app,name))==read(Cmd(["git","-C",app,"show","b0637ac3:"*name])) || error("scientific input changed: $name")
end
production=["ext/aos/optical_observation.jl","ext/PipeWireAORTCAOSExt.jl","Project.toml"]
hashes=Dict(name=>C.sha256_file(joinpath(rtc,name)) for name in production)
all(hash==C.sha256_file(joinpath(pkgdir(PipeWireAORTC),name)) for (name,hash) in hashes) || error("registered source mismatch")
manifest=TOML.parsefile(joinpath(app,"Manifest.toml"))
dependency=only(manifest["deps"]["PipeWireAORTC"])
@assert dependency["version"]=="0.2.3" && dependency["git-tree-sha1"]=="07c4146c0e62d318b369d2fc55fbdbfc022e310c"
mkpath(joinpath(evidence,"live"));mkpath(joinpath(evidence,"scripts"))
for file in ("live-identity.json","live-observation.json","live-wavefront-check.json","live-gpu-audit.json","status-verified.json","start.json","previous-session-final.json")
    cp(joinpath(live,file),joinpath(evidence,"live",file);force=true)
end
for file in ("launch-live.jl","check-live.jl","record-provenance.jl")
    cp(joinpath(raw,file),joinpath(evidence,"scripts",file);force=true)
end
for file in ("launch-live.log","check-live.log")
    cp(joinpath(raw,file),joinpath(evidence,"logs",file);force=true)
end
tests=["test/aos_optical_observation.jl","test/integration/classic_wavefront.jl","test/integration/classic_observation.jl","test/integration/classic_managed_replay.jl","test/integration/prefix_capture.jl"]
C.write_json(joinpath(evidence,"integration.json"),Dict(
    "complete"=>true,"application_commit"=>strip(read(`git -C $app rev-parse HEAD`,String)),
    "package_commit"=>"fc52a69983db6d985ec36d3b85f4411ece99bf21",
    "package_version"=>dependency["version"],"package_tree"=>dependency["git-tree-sha1"],
    "private_registry_only"=>true,"scientific_files_unchanged"=>science,
    "sealed_artifact_count"=>length(spec["artifacts"]),"production_sha256"=>hashes,
    "test_sha256"=>Dict(n=>C.sha256_file(joinpath(rtc,n)) for n in tests),
    "native_prefix"=>prefix,"native_endpoint_sha256"=>C.sha256_file(joinpath(prefix,"lib/pipewireao-rtc/modules/libwireplumber-module-ao-control-endpoint.so")),
    "gui_binary_sha256"=>C.sha256_file("/home/dgamroth/.local/opt/pipewireao-classic-journal-20261020/bin/pipewireao-gui-4a3d94e"),
    "scope"=>"Private package pin, unchanged science/calibration, finite CPU replay/reset and live GUI subscription; no GPU, cadence or hardware qualification"))
println("Provenance matches immutable registered source; all ",length(spec["artifacts"])," deployment artifacts sealed; scientific files unchanged")
