using PipeWireAORTC, Statistics
C=PipeWireAORTC.Common;R=PipeWireAORTC.SessionRuntime
root=@__DIR__;handle=R.attach(joinpath(root,"session"));ledger=R._ledger(handle)
status=R.control!(handle,PipeWireAORTC.RunnerCommands.parse(["status"]);deadline=R.monotonic()+20)
status["ok"]===true && status["state"]=="Running" || error("RTC is not running")
C.write_json(joinpath(root,"status-verified.json"),status)
source=read("/home/dgamroth/workspaces/codex/pipewire/pipewireao-rtc/test/integration/classic_observation.jl",String)
extra="""
    (name="feedback", node="rtc-constraint-feedback-queue-output", media="dm-constraint-feedback",
        type=Float32, wire=NdArray.F32_LE, shape=(277,),
        schema="org.calculon.ao.pdm-constraint-feedback/1", rate=nothing),
    (name="roles", node="rtc-correction-role-queue-output", media="dm-correction-role",
        type=UInt8, wire=NdArray.U8, shape=(277,),
        schema="org.calculon.ao.pdm-correction-role/1", rate=nothing),
"""
source=replace(source,"\n)\n\nmutable struct ClassicObservationCapture"=>"\n"*extra*")\n\nmutable struct ClassicObservationCapture";count=1)
include_string(Main,source,"classic_observation_live.jl")
mutable struct Samples{T}
    capture::T
    samples::Matrix{Float32}
    sequences::Vector{UInt64}
    count::Int
end
function (s::Samples)(stream)
    s.capture(stream);c=s.capture
    c.error===nothing && c.header!==nothing || return nothing
    if s.count<size(s.samples,2) && (s.count==0 || s.sequences[s.count]!=c.header.sequence)
        s.count+=1;copyto!(@view(s.samples[:,s.count]),c.values)
        s.sequences[s.count]=c.header.sequence
    end
    nothing
end
records=Samples[]
factory=c->begin
    s=Samples(c,zeros(Float32,277,60),zeros(UInt64,60),0);push!(records,s);s
end
names=("demanded","applied","offset","feedback","roles")
receipt=observe_classic(ledger["remote"];timeout=75,selected_streams=names,
    process_capture=factory,drive_interval=0.02,finished=_ -> all(s.count==60 for s in records))
central=[119,120,121,138,139,140,157,158,159]
metrics=Dict{String,Any}()
for (name,s) in zip(names,records)
    s.count==60 || error("incomplete live capture")
    values=s.samples
    write(joinpath(root,"live-"*name*"-f32.bin"),values)
    metrics[name]=Dict("samples"=>s.count,"sequence_first"=>first(s.sequences),"sequence_last"=>last(s.sequences),"maximum_magnitude"=>maximum(abs,values),"nonzero_values"=>count(!iszero,values),"near_bound_samples"=>count(x->abs(x)>=0.79999f0,values),"central_maximum_magnitude"=>maximum(abs,values[central,:]),"central_roles"=>unique(vec(values[central,:])))
end
all(iszero,records[4].samples) || error("live clipping observed")
all(==(2f0),records[5].samples[central,:]) || error("central correction role is not extrapolated")
any(!iszero,records[1].samples[central,:]) || error("central commands unexpectedly zero")
common=intersect(records[1].sequences,records[2].sequences)
length(common)>=50 || error("insufficient matching live demanded/applied sequences")
for seq in common
    (records[1].samples[:,findfirst(==(seq),records[1].sequences)] .* 1f-6) ./ 1f-6==records[2].samples[:,findfirst(==(seq),records[2].sequences)] || error("live demanded/applied mismatch")
end
paths=PipeWireAORTC.DeploymentConfiguration.installed_paths("/home/dgamroth/.local/opt/pipewireao-classic-headless-20261021")
environment=merge(Dict(ENV),Dict("LD_LIBRARY_PATH"=>paths["library"],"PIPEWIREAO_CONFIG_DIR"=>joinpath(ledger["runtime"],"session"),"PIPEWIREAO_MODULE_DIR"=>paths["modules"],"PIPEWIREAO_SPA_PLUGIN_DIR"=>paths["spa"]))
dump=C.run_checked(["/home/dgamroth/.local/opt/pipewireao-classic-headless-20261021/bin/pwao-dump","-N","-r",ledger["remote"]];env=environment,timeout=20,maximum_output_bytes=16*1024*1024)
dump.returncode==0 || error(dump.stderr)
write(joinpath(root,"live-graph.json"),dump.stdout)
graph=C.read_json(joinpath(root,"live-graph.json");maximum=16*1024*1024)
props(o)=get(get(o,"info",Dict()),"props",Dict())
node=only(filter(o->get(props(o),"node.name",nothing)=="simulator-wfs",graph))
props(node)["aos.simulation.backend"]=="cpu" || error("live backend mismatch")
calibration=props(node)["aos.simulation.calibration-identity"]
calibration==C.read_json(joinpath(root,"application/simulation.conf"))["calibration_identity"] || error("live calibration mismatch")
guiprops=[props(o) for o in graph if startswith(get(props(o),"node.name",""),"pipewireao-gui-")]
length(guiprops)>=3 || error("GUI observation nodes missing")
gui_pid=parse(Int,strip(read(`systemctl --user show pipewireao-classic-cpu-extrapolation-gui-20261022.service -p MainPID --value`,String)))
pids=Dict(role=>owner["pid"] for (role,owner) in ledger["owners"]);pids["rtc"]=handle.main_pid;pids["gui"]=gui_pid
audit=Dict()
for (role,pid) in pids
    mappings=filter(line->occursin(r"(?i)(libcuda|libcudart|libcublas|libcufft|libamdhip|libhsa-runtime)",line),readlines("/proc/$pid/maps"))
    devices=String[]
    for name in readdir("/proc/$pid/fd";join=true)
        target=try readlink(name) catch;continue end
        occursin(r"/dev/(nvidia|dri/|kfd)",target) && push!(devices,target)
    end
    isempty(mappings) && isempty(devices) || error("GPU use by $role")
    audit[role]=Dict("pid"=>pid,"gpu_mappings"=>mappings,"gpu_device_handles"=>devices)
end
C.write_json(joinpath(root,"live-observation.json"),receipt)
C.write_json(joinpath(root,"live-gpu-audit.json"),audit)
C.write_json(joinpath(root,"live-command-check.json"),Dict("complete"=>true,"backend"=>"cpu","calibration_identity"=>calibration,"central_actuator_ids"=>central,"central_all_extrapolated"=>true,"central_commands_nonzero"=>true,"all_physical_feedback_zero"=>true,"matching_demanded_applied_sequences"=>length(common),"streams"=>metrics,"gui_node_count"=>length(guiprops),"gui_pid"=>gui_pid,"scope"=>"60 live samples per product; read-only observation, not a global stability or performance guarantee"))
println("Live CPU commands verified: 60 samples per product; zero clipping; central roles extrapolated; GUI connected; no GPU libraries or handles")
