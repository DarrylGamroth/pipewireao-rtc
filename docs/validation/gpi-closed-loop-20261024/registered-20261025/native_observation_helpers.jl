using PipeWireAO, PipeWireAORTC
include("/home/dgamroth/workspaces/codex/rtc-gpi2-integration/test/integration/managed_session_lifecycle.jl")
const M = ManagedSessionLifecycle
const C = PipeWireAORTC.Common
const D = PipeWireAORTC.DeploymentConfiguration
const A = PipeWireAORTC.Artifacts
const ROOT = "/home/dgamroth/.local/state/pipewireao/gpi2-registered-live-20261025"
const PREFIX = "/home/dgamroth/.local/opt/pipewireao-classic-headless-20261021"
const CAPACITY = 128

mutable struct Samples{C,T}
    capture::C
    sequences::Vector{UInt64}
    values::Matrix{T}
    count::Int
end
Samples(c) = Samples(c, zeros(UInt64,CAPACITY), zeros(eltype(c.values),length(c.values),CAPACITY),0)
function (s::Samples)(stream)
    before = s.capture.distinct_sequences
    s.capture(stream)
    if s.capture.error === nothing && s.capture.distinct_sequences > before
        s.count += 1
        slot = mod1(s.count,CAPACITY)
        s.sequences[slot] = s.capture.header.sequence
        copyto!(view(s.values,:,slot),s.capture.values)
    end
    nothing
end
available(s) = Set(filter(!iszero,s.sequences))
function read_parameter(application,name)
    file = joinpath(application,"rtc/parameters.conf")
    entry = only(filter(e -> e.port == Symbol(name),PipeWireAORTC.GraphOwner.bindings(file)))
    shape = A.FITSIO.FITS(entry.source.path,"r") do f
        dimensions = size(f[entry.source.hdu])
        entry.source.axes === nothing ? dimensions : Tuple(dimensions[i] for i in entry.source.axes)
    end
    A.prepare(entry.source,Float32,shape)
end
function expected_roles(application,mirror)
    completion = read_parameter(application,mirror*"-active-to-full")
    projection = read_parameter(application,mirror*"-vdm-to-pdm")
    c,p = completion.data,projection.data
    size(p,2)==size(c,1) || error("completion/projection dimensions differ")
    # Independently infer each controlled coordinate's first unit row from C.
    primary = zeros(Int,size(c,2))
    roles = zeros(UInt8,size(c,1))
    for row in axes(c,1)
        support = findall(!iszero,view(c,row,:))
        isempty(support) && continue
        roles[row] = 2
        if length(support)==1 && c[row,only(support)]==1f0 && primary[only(support)]==0
            primary[only(support)] = row
            roles[row] = 1
        end
    end
    all(!iszero,primary) || error("completion does not establish every controlled coordinate")
    physical_roles=fill(UInt8(3),size(p,1))
    for row in axes(p,1)
        support=findall(!iszero,view(p,row,:))
        isempty(support) && (physical_roles[row]=0;continue)
        if length(support)==1 && p[row,only(support)]==1f0
            physical_roles[row]=roles[only(support)]
        end # A mixed physical projection has unknown correction provenance (3).
    end
    physical_roles,Dict("completion"=>completion.provenance,"projection"=>projection.provenance,
        "counts"=>Dict(string(code)=>count(==(code),physical_roles) for code in UInt8(0):UInt8(3)))
end
function graph_dump(remote)
    result = C.run_checked([joinpath(PREFIX,"bin/pwao-dump"),"-N","-r",remote];timeout=20,
        maximum_output_bytes=16*1024*1024)
    result.returncode==0 || error("exact new-session graph inspection failed: "*result.stderr)
    C.parse_json(result.stdout)
end
props(object) = get(get(object,"info",Dict()),"props",Dict())
function source_snapshot(graph,profile,ledger)
    node = only(filter(o -> get(props(o),"node.name",nothing)=="simulator-wfs",graph))
    identity=(id=UInt32(node["id"]),serial=parse(UInt64,string(props(node)["object.serial"])))
    M.Faults.decode_aos_source(graph,M.Faults.qualification_source(profile),
        ledger["owners"][profile["source-owner"]],identity)
end
function unit_snapshot(unit)
    result=C.run_checked(["systemctl","--user","show",unit,"--property=ActiveState,SubState,MainPID,InvocationID"];timeout=10)
    result.returncode==0 || error("cannot inspect exact recorded session unit")
    Dict(first(split(line,'=';limit=2))=>last(split(line,'=';limit=2)) for line in split(strip(result.stdout),'\n'))
end
# Explicit algorithm default, sized from the exported typed parameter contract.
# Its actual live adoption is verified by exact native readout before any control.
function shape_baseline(application,mirror)
    graph_name="gpi2-jfg-frame-graph"
    session=D.decode(joinpath(application,"rtc/session.conf.in"),PREFIX)
    declaration=only(filter(g -> g["node.name"]==graph_name,session["graphs"]))
    alias=mirror*"-shape-offset"
    port=only(filter(p -> p["name"]==alias,declaration["ports"]))
    port["parameter"]===true && port["direction"]=="input" &&
        port["element-type"]=="F32_LE" && port["layout"]=="ROW_MAJOR" &&
        port["schema"]=="pipewireao/requested-pdm-command-f32/1" || error("shape parameter contract differs")
    shape=Tuple(Int.(port["shape"]))
    length(shape)==1 && only(shape)>0 || error("shape parameter must have one physical dimension")
    graph=D.decode(joinpath(application,"rtc/graph.conf"),PREFIX)["filter.graph"]
    external=only(filter(p -> p["name"]==alias,graph["inputs"]))
    external["endpoint"]==mirror*"-shape:shape-offset" || error("shape alias endpoint differs")
    node=only(filter(p -> p["name"]==mirror*"-shape",graph["nodes"]))
    node["label"]=="vdm-shape-offset-f32" && node["config"]["physical_actuator_count"]==only(shape) ||
        error("shape alias does not address declared physical VdmShapeOffsetF32 parameter")
    (data=zeros(Float32,shape),provenance=Dict("origin"=>"VdmShapeOffsetF32 declared zero initialization",
        "verification"=>"Exact native same-identity readout required before probing",
        "parameter_alias"=>alias,"generation_node"=>mirror*"-shape",
        "element_type"=>"Float32","shape"=>collect(shape),"units"=>"m OPD"))
end
