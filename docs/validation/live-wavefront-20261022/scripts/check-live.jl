using PipeWireAORTC, AdaptiveOpticsSim, AdaptiveOpticsSimPipeWireHIL, Statistics
include("/home/dgamroth/workspaces/codex/pipewire/pipewireao-rtc-wavefront/test/integration/classic_wavefront.jl")
const M=ClassicWavefront.M
const R=PipeWireAORTC.SessionRuntime
const C=PipeWireAORTC.Common
const O=ClassicWavefront.O
const root="/home/dgamroth/.local/state/pipewireao/classic-cpu-wavefront-live-20261022"
const prefix="/home/dgamroth/.local/opt/pipewireao-classic-headless-20261021"
handle=R.attach(joinpath(root,"session"));ledger=R._ledger(handle)
status=M.request(handle,root,"status-verified",["status"])
status["state"]=="Running" || error("RTC is not running")
science=ClassicWavefront.prepare_replay(joinpath(root,"application"))
config=only(filter(!isnothing,map(n->O.sensor_configuration(n.config),science.definition.nodes)))
telescope=AdaptiveOpticsSim.Optics.prepare_telescope(config.telescope,science.target)
pupil=AdaptiveOpticsSim.Optics.pupil_mask(telescope)
_,snapshot=M.source_snapshot(M.dump_graph(handle,root,prefix,"live-graph-before"))
mutable struct Samples{T}
    capture::T
    values::Matrix{Float32}
    sequences::Vector{UInt64}
    pts::Vector{Int64}
    count::Int
end
function (s::Samples)(stream)
    s.capture(stream);c=s.capture
    c.error===nothing && c.header!==nothing || return nothing
    if s.count<size(s.values,2) && (s.count==0 || s.sequences[s.count]!=c.header.sequence)
        s.count+=1;copyto!(@view(s.values[:,s.count]),c.values)
        s.sequences[s.count]=c.header.sequence;s.pts[s.count]=c.header.pts
    end
    nothing
end
records=Samples[]
factory=c->begin
    s=Samples(c,zeros(Float32,prod(ClassicWavefront.WAVEFRONT.shape),16),zeros(UInt64,16),zeros(Int64,16),0)
    push!(records,s);s
end
receipt=M.observe_classic(ledger["remote"];timeout=60,stream_specs=(ClassicWavefront.WAVEFRONT,),
    expected_generation=UInt64(snapshot["generation"]),process_capture=factory,
    valid_payload=c->all(x->isfinite(x)||isnan(x),c.values),drive_interval=0.01,
    finished=_ -> only(records).count==16)
s=only(records);rms=Float64[];pistons=Float64[]
for column in axes(s.values,2)
    image=permutedims(reshape(s.values[:,column],reverse(ClassicWavefront.WAVEFRONT.shape)))
    all(isfinite,image[pupil]) && all(isnan,image[.!pupil]) || error("pupil mask mismatch")
    values=Float64.(image[pupil]);push!(rms,sqrt(mean(abs2,values)));push!(pistons,mean(values))
end
all(>(0),diff(s.sequences)) && all(>(0),diff(s.pts)) || error("non-increasing samples")
all(isfinite,rms) && all(>(0),rms) && maximum(abs,pistons)<1e-4 || error("invalid OPD statistics")
graph=M.dump_graph(handle,root,prefix,"live-graph")
props(o)=get(get(o,"info",Dict()),"props",Dict())
node=only(filter(o->get(props(o),"node.name",nothing)=="simulator-wfs",graph))
props(node)["aos.simulation.backend"]=="cpu" || error("backend mismatch")
simulation=C.read_json(joinpath(root,"application/simulation.conf"))
props(node)["aos.simulation.calibration-identity"]==simulation["calibration_identity"] || error("calibration mismatch")
gui_pid=parse(Int,strip(read(`systemctl --user show pipewireao-classic-cpu-wavefront-gui-20261022.service -p MainPID --value`,String)))
gui_pid>0 || error("GUI stopped")
gui_nodes=filter(o->startswith(get(props(o),"node.name",""),"pipewireao-gui-"),graph)
isempty(gui_nodes) && error("GUI not attached")
queue=only(filter(o->get(props(o),"node.name",nothing)==ClassicWavefront.WAVEFRONT.node,graph))
gui_ids=Set(o["id"] for o in gui_nodes)
gui_wavefront_links=filter(graph) do object
    info=get(object,"info",Dict())
    get(info,"output-node-id",nothing)==queue["id"] && get(info,"input-node-id",nothing) in gui_ids
end
isempty(gui_wavefront_links) && error("GUI residual wavefront consumer missing")
pids=Dict(role=>owner["pid"] for (role,owner) in ledger["owners"])
pids["rtc"]=handle.main_pid;pids["gui"]=gui_pid
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
write(joinpath(root,"live-wavefront.bin"),s.values)
C.write_json(joinpath(root,"live-observation.json"),receipt)
C.write_json(joinpath(root,"live-gpu-audit.json"),audit)
C.write_json(joinpath(root,"live-wavefront-check.json"),Dict("complete"=>true,"backend"=>"cpu",
    "calibration_identity"=>simulation["calibration_identity"],"schema"=>O.WAVEFRONT_SCHEMA,
    "shape"=>[480,480],"samples"=>s.count,"sequences"=>s.sequences,"pts_ns"=>s.pts,
    "generation"=>snapshot["generation"],"rms_nm"=>rms,"piston_nm"=>pistons,
    "pupil_mask_matches"=>true,"gui_pid"=>gui_pid,"gui_wavefront_links"=>length(gui_wavefront_links),
    "scope"=>"Read-only live CPU sampling and GUI subscription; no rendered screenshot, cadence or hardware qualification"))
println("Live CPU wavefront and GUI subscription verified; RMS nm range ",extrema(rms),"; no GPU use")
