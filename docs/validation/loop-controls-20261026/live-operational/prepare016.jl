using PipeWireAORTC, TOML
const R=PipeWireAORTC
const C=R.Common
const cache="/home/dgamroth/.cache/pipewireao/loop-operations-20261026"
const root="/home/dgamroth/.local/state/pipewireao/gpi2-loop-controls-live-20261026"
@assert pkgversion(R)==v"0.2.16"
manifest=joinpath(dirname(Base.active_project()),"Manifest.toml")
for entries in values(TOML.parsefile(manifest)["deps"]),entry in entries
    @assert !haskey(entry,"path") && !haskey(entry,"repo-url")
end
profile=C.read_yaml(joinpath(cache,"host-cuda.yaml"))
R.InstrumentExport.prepare(joinpath(cache,"instrument-source"),joinpath(root,"application");
    profile,manifest,prefix=ENV["PIPEWIREAO_PREFIX"])
for file in ("rtc/graph.conf","rtc/parameters.conf","simulation.conf","instrument.json",
        "calibration/result.yaml","gui/operator-views.yaml")
    @assert read(joinpath(root,"application",file))==read(joinpath(root,"failed-start-014-application",file))
end
C.write_json(joinpath(root,"preparation016.json"),Dict("rtc_version"=>"0.2.16",
    "manifest_sha256"=>C.sha256_file(manifest),"scientific_and_gui_bytes_unchanged"=>true,
    "registered_packages_only"=>true,"native_fix_commit"=>"10d969f"))
println("Prepared RTC 0.2.16; science/calibration/GUI bytes identical")
