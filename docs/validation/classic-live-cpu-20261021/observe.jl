using PipeWireAORTC, Test

length(ARGS) == 3 || error("usage: observe.jl STAGE OUTPUT EXPECTED_STATE")
stage, output, expected = ARGS
R = PipeWireAORTC
W, C, D = R.SessionRuntime, R.Common, R.DeploymentConfiguration
handle = W.attach(stage)
ledger = W._ledger(handle)
status = W.control!(handle, R.RunnerCommands.parse(["status"]); deadline=W.monotonic()+20)
@test status["ok"] === true && status["state"] == expected
prefix = "/home/dgamroth/.local/opt/pipewireao-classic-headless-20261021"
paths = D.installed_paths(prefix)
environment = merge(Dict(ENV), Dict("LD_LIBRARY_PATH"=>paths["library"],
    "PIPEWIREAO_CONFIG_DIR"=>joinpath(ledger["runtime"],"session"),
    "PIPEWIREAO_MODULE_DIR"=>paths["modules"],
    "PIPEWIREAO_SPA_PLUGIN_DIR"=>paths["spa"]))
dump = C.run_checked([joinpath(prefix,"bin/pwao-dump"),"-N","-r",ledger["remote"]];
    env=environment, timeout=20, maximum_output_bytes=16*1024*1024)
@test dump.returncode == 0
dump.returncode == 0 || error(dump.stderr)
graph_path = output * "-graph.json"
write(graph_path,dump.stdout)
graph = C.read_json(graph_path;maximum=16*1024*1024)
node = only(filter(graph) do object
    get(get(get(object,"info",Dict()),"props",Dict()),"node.name",nothing)=="simulator-wfs"
end)
props = node["info"]["props"]
@test props["aos.simulation.backend"] == "cpu"
records = node["info"]["params"]["Props"]
fields = only(filter(records) do record
    params = get(record,"params",Any[])
    !isempty(params) && first(params)=="pipewireao.source-snapshot.version"
end)["params"]
snapshot = Dict(replace(fields[i],"pipewireao.source-snapshot."=>"")=>fields[i+1]
    for i in 1:2:length(fields))
@test snapshot["running"] == (expected=="Running")
@test snapshot["sequence"] > 0
owners = Dict{String,Any}()
for (role,item) in ledger["owners"]
    pid = item["pid"]
    gpu = filter(line -> occursin(r"(?i)(libcuda|libcudart|libcublas|libcufft|libamdhip|libhsa-runtime)",line),
        split(read("/proc/$pid/maps",String),'\n'))
    @test isempty(gpu)
    owners[role] = Dict("pid"=>pid,"gpu_libraries"=>gpu)
end
C.write_json(output*".json",Dict("result"=>"passed","status"=>status,
    "source_snapshot"=>snapshot,"source_properties"=>props,"owners"=>owners,
    "unit"=>handle.unit,"invocation"=>handle.invocation,"remote"=>ledger["remote"]))
println("Verified native ",expected," with CPU source sequence ",snapshot["sequence"])
