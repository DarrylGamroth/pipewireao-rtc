using PipeWireAO, PipeWireAORTC
include("/home/dgamroth/workspaces/codex/rtc-gpi2-integration/test/integration/managed_session_lifecycle.jl")
const M = ManagedSessionLifecycle
const C = PipeWireAORTC.Common
const D = PipeWireAORTC.DeploymentConfiguration
const A = PipeWireAORTC.Artifacts
const ROOT = "/home/dgamroth/.local/state/pipewireao/gpi2-annular-live-20261025b"
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
        Tuple(dimensions[i] for i in entry.source.axes)
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
function main()
    receipt=Dict{String,Any}("completed"=>false,"driver_sha256"=>C.sha256_file(@__FILE__),
        "scope"=>"Read-only finite native stream observation; no timing, optical performance or hardware claim",
        "owned_observers_closed"=>false)
    try
        deadline=time()+900
        marker=joinpath(ROOT,"live-identity.json")
        while !isfile(marker)
            time()<deadline || error("new Running identity did not appear within 900 seconds")
            sleep(0.25)
        end
        identity=C.read_json(marker)
        identity["stage"]==joinpath(ROOT,"session") || error("unexpected stage identity")
        application=joinpath(identity["stage"],"installed")
        remote=identity["remote"]
        startswith(remote,identity["runtime_root"]*"/") || error("remote outside recorded runtime")
        receipt["live_identity"]=identity
        receipt["unit_before"]=unit_snapshot(identity["unit"])
        receipt["unit_before"]["ActiveState"]=="active" || error("new session is not active")
        parse(Int,receipt["unit_before"]["MainPID"])==identity["pid"] || error("new session main PID changed")
        profile=D.profile(joinpath(application,"deployment.conf"),PREFIX)
        ledger=C.read_json(joinpath(dirname(remote),"launch.json"))
        ledger["unit"]==identity["unit"] && ledger["remote"]==remote || error("launch ledger differs from Running identity")
        session=D.decode(D.relative_asset(application,profile["session"]),PREFIX)
        specs=M.observation_specs(application,PREFIX)
        for mirror in ("woofer","tweeter"), product in ("applied","correction-role","constraint-feedback")
            name=mirror*"-"*product
            specs=(specs...,M.observation_spec(application,session,"rtc-"*name*"-queue-input",name,PREFIX))
        end
        length(specs)==10 || error("expected ten native streams")
        receipt["application_hashes"]=Dict(file=>C.sha256_file(joinpath(application,file)) for file in
            ("deployment.conf","Manifest.toml","instrument.json","rtc/graph.conf","rtc/parameters.conf","rtc/session.conf.in"))
        role_expected=Dict{String,Vector{UInt8}}()
        receipt["role_calibration"]=Dict{String,Any}()
        for mirror in ("woofer","tweeter")
            role_expected[mirror],receipt["role_calibration"][mirror]=expected_roles(application,mirror)
        end
        receipt["role_calibration"]["tweeter"]["counts"]==Dict("0"=>588,"1"=>1412,"2"=>304,"3"=>0) || error("unexpected actual-calibration tweeter role partition")
        before=graph_dump(remote)
        receipt["source_before"]=source_snapshot(before,profile,ledger)
        receipt["source_before"]["snapshot"]["running"] || error("recorded source is not Running")
        generation=receipt["source_before"]["snapshot"]["generation"]
        first_sequence=receipt["source_before"]["snapshot"]["sequence"]
        samples=Any[]
        paired=Dict{String,Vector{UInt64}}()
        common=Ref{Union{Nothing,AcquisitionIdentity}}(nothing)
        receipt["observations"]=M.Observation.observe_classic(remote;timeout=180,stream_specs=specs,
            drive_interval=0.01,process_capture=c -> begin
                s=Samples(c);push!(samples,s);s
            end,
            finished=captures -> begin
                all(s -> s.count>=32,samples) || return false
                for mirror in ("woofer","tweeter")
                    role=samples[findfirst(s -> s.name==mirror*"-correction-role",specs)]
                    for slot in findall(!iszero,role.sequences)
                        view(role.values,:,slot)==role_expected[mirror] || error("native role assignment differs from actual calibration C")
                    end
                    demanded=samples[findfirst(s -> s.name==mirror,specs)]
                    applied=samples[findfirst(s -> s.name==mirror*"-applied",specs)]
                    paired[mirror]=sort!(collect(intersect(available(demanded),available(applied))))
                    length(paired[mirror])>=16 || return false
                end
                coherent=filter(c -> c.identity!==nothing,captures)
                length(coherent)==8 || error("expected acquisition identities on camera, commands and role/constraint outputs only")
                common[]=M.common_identity(coherent)
                common[]!==nothing || return false
                common[].generation==generation || error("observation generation differs from current source")
                common[].sequence>first_sequence
            end)
        receipt["owned_observers_closed"]=true # helper returns only after deterministic retirement/finally
        receipt["coherent_identity"]=M.Observation._classic_identity_record(common[])
        receipt["applied_comparisons"]=Dict{String,Any}()
        for mirror in ("woofer","tweeter")
            demanded=samples[findfirst(s -> s.name==mirror,specs)]
            applied=samples[findfirst(s -> s.name==mirror*"-applied",specs)]
            maxerror=0f0
            for sequence in paired[mirror]
                d=view(demanded.values,:,findfirst(==(sequence),demanded.sequences))
                a=view(applied.values,:,findfirst(==(sequence),applied.sequences))
                expected=d ./ 1f-6
                maxerror=max(maxerror,maximum(abs.(a.-expected)))
                a==expected || error("same-sequence adopted Applied µm differs from demanded m / 1e-6")
            end
            receipt["applied_comparisons"][mirror]=Dict("paired_sequences"=>paired[mirror],
                "maximum_absolute_error_um"=>maxerror,"exact_float32_scaling_match"=>true,
                "demanded_units"=>"m OPD","applied_units"=>"µm OPD","header_sequence_lag"=>0,
                "semantics"=>"Applied publishes command adopted after frame n for next optical frame n+1; no AcquisitionMetadata is published on Applied")
        end
        after=graph_dump(remote)
        receipt["source_after"]=source_snapshot(after,profile,ledger)
        receipt["source_after"]["instance"]==receipt["source_before"]["instance"] &&
            receipt["source_after"]["snapshot"]["generation"]==generation &&
            receipt["source_after"]["snapshot"]["running"] &&
            receipt["source_after"]["snapshot"]["sequence"]>=first_sequence || error("source incarnation/run cursor changed")
        receipt["source_control_cursor_semantics"]="Snapshot is published on control/query completion; current frame progression is established by stream acquisition identities."
        receipt["unit_after"]=unit_snapshot(identity["unit"])
        receipt["unit_after"]==receipt["unit_before"] || error("session process identity/state changed")
        C.read_json(marker)==identity || error("live identity changed during observation")
        observer_prefix="classic-integration-observer-$(getpid())-"
        residual=filter(o -> startswith(get(props(o),"node.name",""),observer_prefix),after)
        isempty(residual) || error("owned observer nodes remain")
        receipt["owned_observer_nodes_remaining"]=length(residual)
        receipt["completed"]=true
    catch error
        receipt["failure"]=sprint(showerror,error,catch_backtrace())
        rethrow()
    finally
        C.write_json(joinpath(ROOT,"native-stream-verification.json"),receipt)
        println("native stream verification completed=",receipt["completed"]);flush(stdout)
    end
end
if abspath(PROGRAM_FILE) == (@__FILE__)
    main()
end
