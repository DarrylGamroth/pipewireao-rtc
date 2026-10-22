using PipeWireAORTC, PipeWireAO, AdaptiveOpticsSim, AdaptiveOpticsSimPipeWireHIL, Statistics
include("/home/dgamroth/workspaces/codex/pipewire/pipewireao-rtc-series/test/integration/classic_wavefront.jl")
const M=ClassicWavefront.M;const R=PipeWireAORTC.SessionRuntime;const C=PipeWireAORTC.Common
const O=ClassicWavefront.O
const root="/home/dgamroth/.local/state/pipewireao/classic-cpu-wavefront-series-live-20261022"
const prefix="/home/dgamroth/.local/opt/pipewireao-classic-headless-20261021"
handle=R.attach(joinpath(root,"session"));ledger=R._ledger(handle)
status=M.request(handle,root,"status-before",["status"])
status["state"]=="Running" || error("RTC is not running")
science=ClassicWavefront.prepare_replay(joinpath(root,"application"))
config=only(filter(!isnothing,map(n->O.sensor_configuration(n.config),science.definition.nodes)))
telescope=AdaptiveOpticsSim.Optics.prepare_telescope(config.telescope,science.target)
pupil=AdaptiveOpticsSim.Optics.pupil_mask(telescope)
_,snapshot=M.source_snapshot(M.dump_graph(handle,root,prefix,"live-graph-before"))
mutable struct Samples{T}
    capture::T
    values::Matrix{Float32}
    identities::Vector{Union{Nothing,AcquisitionIdentity}}
    pts::Vector{Int64}
    count::Int
end
function (s::Samples)(stream)
    s.capture(stream);c=s.capture
    c.error===nothing && c.header!==nothing || return nothing
    if s.count<size(s.values,2) && (s.count==0 || something(s.identities[s.count]).sequence!=c.header.sequence)
        s.count+=1;copyto!(@view(s.values[:,s.count]),c.values)
        s.identities[s.count]=something(c.identity);s.pts[s.count]=c.header.pts
    end
    nothing
end
records=Samples[]
factory=c->begin
    s=Samples(c,zeros(Float32,prod(c.format.shape),32),
        Union{Nothing,AcquisitionIdentity}[nothing for _ in 1:32],zeros(Int64,32),0)
    push!(records,s);s
end
receipt=M.observe_classic(ledger["remote"];timeout=60,
    stream_specs=(ClassicWavefront.WAVEFRONT,ClassicWavefront.RMS),
    expected_generation=UInt64(snapshot["generation"]),process_capture=factory,
    valid_payload=c->c.schema==O.WAVEFRONT_SCHEMA ? all(x->isfinite(x)||isnan(x),c.values) : c.finite,
    drive_interval=0.01,finished=_ -> all(s->s.count==32,records))
image,meter=records
image_ids=something.(image.identities);meter_ids=something.(meter.identities)
common=intersect(image_ids,meter_ids);length(common)>=8 || error("insufficient matched image/RMS samples")
errors=Float64[];pistons=Float64[]
for identity in common
    a=findfirst(==(identity),image_ids);b=findfirst(==(identity),meter_ids)
    image.pts[a]==meter.pts[b] || error("matched sample PTS mismatch")
    values=permutedims(reshape(image.values[:,a],reverse(ClassicWavefront.WAVEFRONT.shape)))
    all(isfinite,values[pupil]) && all(isnan,values[.!pupil]) || error("pupil mask mismatch")
    finite=Float64.(values[pupil]);push!(pistons,mean(finite))
    push!(errors,abs(sqrt(mean(abs2,finite))-meter.values[2,b]))
end
maximum(errors)<1e-4 && maximum(abs,pistons)<1e-4 || error("RMS image comparison failed")
all(>(0),meter.values) || error("invalid RMS values")
sequences=getproperty.(meter_ids,:sequence)
all(>(0),diff(sequences)) && all(>(0),diff(meter.pts)) || error("non-increasing samples")
graph=M.dump_graph(handle,root,prefix,"live-graph")
props(o)=get(get(o,"info",Dict()),"props",Dict())
node=only(filter(o->get(props(o),"node.name",nothing)=="simulator-wfs",graph))
props(node)["aos.simulation.backend"]=="cpu" || error("backend mismatch")
simulation=C.read_json(joinpath(root,"application/simulation.conf"))
props(node)["aos.simulation.calibration-identity"]==simulation["calibration_identity"] || error("calibration mismatch")
gui_pid=parse(Int,strip(read(`systemctl --user show pipewireao-classic-cpu-wavefront-series-gui-20261022.service -p MainPID --value`,String)))
gui_pid>0 || error("GUI stopped")
gui_nodes=filter(o->startswith(get(props(o),"node.name",""),"pipewireao-gui-"),graph)
gui_ids=Set(o["id"] for o in gui_nodes)
queue=only(filter(o->get(props(o),"node.name",nothing)==ClassicWavefront.RMS.node,graph))
links=filter(graph) do object
    info=get(object,"info",Dict())
    get(info,"output-node-id",nothing)==queue["id"] && get(info,"input-node-id",nothing) in gui_ids
end
isempty(links) && error("GUI RMS consumer missing")
all(o->o["info"]["state"]=="active",links) || error("GUI RMS link inactive")
pids=Dict(role=>owner["pid"] for (role,owner) in ledger["owners"])
pids["rtc"]=handle.main_pid;pids["gui"]=gui_pid;audit=Dict()
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
status=M.request(handle,root,"status-verified",["status"])
status["state"]=="Running" || error("RTC stopped after observation")
write(joinpath(root,"live-wavefront.bin"),image.values);write(joinpath(root,"live-rms.bin"),meter.values)
C.write_json(joinpath(root,"live-observation.json"),receipt)
C.write_json(joinpath(root,"live-gpu-audit.json"),audit)
uncorrected=Float64.(meter.values[1,:]);corrected=Float64.(meter.values[2,:])
C.write_json(joinpath(root,"live-rms-check.json"),Dict("complete"=>true,"backend"=>"cpu",
    "calibration_identity"=>simulation["calibration_identity"],"schema"=>O.RMS_SCHEMA,
    "samples"=>meter.count,"sequences"=>sequences,"pts_ns"=>meter.pts,
    "generation"=>snapshot["generation"],"uncorrected_rms_nm"=>uncorrected,"corrected_rms_nm"=>corrected,
    "matched_image_samples"=>length(common),"max_image_rms_error_nm"=>maximum(errors),
    "pupil_mask_matches"=>true,"mean_uncorrected_rms_nm"=>mean(uncorrected),
    "mean_corrected_rms_nm"=>mean(corrected),"mean_sample_rms_reduction"=>mean(1 .- corrected./uncorrected),
    "gui_pid"=>gui_pid,"gui_rms_links"=>length(links),
    "model_period_seconds"=>0.002,"scope"=>"Read-only live CPU sampling and active generic GUI subscription; no rendered screenshot, cadence or hardware qualification"))
println("Live CPU RMS and GUI verified; means nm: ",mean(uncorrected)," → ",mean(corrected),"; no GPU use")
