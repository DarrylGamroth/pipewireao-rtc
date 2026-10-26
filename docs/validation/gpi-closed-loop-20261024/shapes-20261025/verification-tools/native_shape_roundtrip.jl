# Prepared qualification driver. Run only on the explicitly authorized new session.
include(joinpath(@__DIR__,"native_observation_helpers.jl"))
const OFFSET_ROOT="/home/dgamroth/.local/state/pipewireao/gpi2-shape-live-20261025"
const GRAPH="gpi2-jfg-frame-graph"
const OFFSET_SCHEMA="pipewireao/requested-pdm-command-f32/1"
function offset_baseline(application,mirror,count;product="shape-offset")
    if product=="shape-offset"
        baseline=shape_baseline(application,mirror)
        size(baseline.data)==(count,) || error("typed shape parameter count differs")
        return baseline
    end
    entry=only(filter(e -> e.port==Symbol(mirror*"-"*product),
        PipeWireAORTC.GraphOwner.bindings(joinpath(application,"rtc/parameters.conf"))))
    A.prepare(entry.source,Float32,(count,))
end
function controlled_probe(application,mirror,count)
    instrument=C.read_json(joinpath(application,"instrument.json"))
    owner=instrument["deformable_mirrors"][mirror]
    owner["units"]=="m OPD" || error("shape parameter units must be m OPD")
    mask=owner["shape_control"]["controlled_actuators"]
    length(mask)==count && all(x -> x isa Bool,mask) || error("owner controlled actuator mask invalid")
    selected=findfirst(identity,mask)
    selected!==nothing || error("owner mask has no controlled actuator")
    expected=mirror=="woofer" ? 97 : 1412
    sum(mask)==expected || error("unexpected controlled actuator count")
    mirror=="tweeter" && mask[1] && error("tweeter physical index zero must be inactive")
    Dict("index_one_based"=>selected,"index_zero_based"=>selected-1,
        "controlled_count"=>sum(mask),"physical_count"=>count,
        "instrument_sha256"=>C.sha256_file(joinpath(application,"instrument.json")))
end
function checked_request(handle,name,fields,record;deadline_seconds=15,before_request=()->nothing)
    try
        reply=PipeWireAORTC.SessionRuntime.control!(handle,PipeWireAORTC.RunnerCommands.parse(fields);
            deadline=PipeWireAORTC.SessionRuntime.monotonic()+deadline_seconds,before_request)
        record[name]=reply
        reply["ok"]===true || error("native request rejected: "*name)
        return reply
    catch error
        record[name*"-failure"]=sprint(showerror,error)
        rethrow()
    end
end
function active_generation(handle,mirror,previous,record,name)
    W=PipeWireAORTC.SessionRuntime
    deadline=W.monotonic()+15
    while true
        reply=checked_request(handle,name,["parameter-generation",GRAPH,mirror*"-shape"],record)
        g=reply["result"]
        if g["requested"]>previous && g["active"]==g["requested"]
            return g["active"]
        end
        W.monotonic()<deadline || error("parameter adoption did not become active")
        sleep(0.05)
    end
end
function observe_offsets(handle,application,expected,record,name;action=nothing,after_sequence=0)
    profile=D.profile(joinpath(application,"deployment.conf"),PREFIX)
    session=D.decode(D.relative_asset(application,profile["session"]),PREFIX)
    specs=M.observation_specs(application,PREFIX)
    for mirror in ("woofer","tweeter"),product in ("shape-offset","offset")
        stream_name=mirror*"-"*product
        spec=M.observation_spec(application,session,"rtc-"*stream_name*"-queue-input",stream_name,PREFIX)
        spec.type===Float32 && spec.schema==OFFSET_SCHEMA && spec.shape==size(expected[stream_name]) ||
            error("$stream_name declaration differs from native parameter contract")
        specs=(specs...,spec)
    end
    length(specs)==8 || error("expected camera/three commands/two shape/two engineering readbacks")
    samples=Any[]
    coherent=Ref{Union{Nothing,AcquisitionIdentity}}(nothing)
    observation=M.Observation.observe_classic(PipeWireAORTC.SessionRuntime._ledger(handle)["remote"];timeout=90,stream_specs=specs,drive_interval=0.01,
        process_capture=c -> begin s=Samples(c);push!(samples,s);s end,on_ready=action,
        finished=captures -> begin
            all(s -> s.count>=2,samples) || return false
            groups=map(samples) do s;available(s);end
            common=reduce(intersect,groups)
            for seq in sort!(collect(filter(>(after_sequence),common));rev=true)
                matches=true
                for stream_name in keys(expected)
                    s=samples[findfirst(spec -> spec.name==stream_name,specs)]
                    slot=findfirst(==(seq),s.sequences)
                    reinterpret(UInt32,collect(view(s.values,:,slot)))==reinterpret(UInt32,expected[stream_name]) || (matches=false;break)
                end
                matches || continue
                identities=map(captures) do c
                    only(filter(i -> i!==nothing && i.sequence==seq,c.identities))
                end
                all(==(first(identities)),identities) || error("current-offset frame identities differ")
                coherent[]=first(identities)
                return true
            end
            false
        end)
    observation["coherent_identity"]=M.Observation._classic_identity_record(coherent[])
    observation["expected_offset_bits"]=Dict(m=>reinterpret(UInt32,v) for(m,v) in expected)
    record[name]=observation
    coherent[].sequence
end
function offset_main()
    W=PipeWireAORTC.SessionRuntime
    receipt=Dict{String,Any}("completed"=>false,"driver_sha256"=>C.sha256_file(@__FILE__),
        "scope"=>"Native bounded reversible controlled-channel pre-completion shape offset; unchanged engineering readbacks; no gain/limit/lifecycle changes",
        "transactions"=>Dict{String,Any}(),"baseline_restored"=>Dict{String,Bool}())
    mkpath(joinpath(OFFSET_ROOT,"offset-validation"))
    destination=joinpath(OFFSET_ROOT,"offset-validation")
    try
        marker=joinpath(OFFSET_ROOT,"live-identity.json")
        deadline=time()+1050
        while !isfile(marker)
            time()<deadline || error("authorized new session did not publish Running identity")
            sleep(0.25)
        end
        identity=C.read_json(marker)
        identity["stage"]==joinpath(OFFSET_ROOT,"session") || error("unexpected stage")
        handle=W.attach(identity["stage"];deadline=W.monotonic()+30)
        handle.unit==identity["unit"] && handle.main_pid==identity["pid"] &&
            W._ledger(handle)["remote"]==identity["remote"] || error("native session identity differs")
        application=joinpath(identity["stage"],"installed")
        receipt["live_identity"]=identity
        receipt["unit_before"]=unit_snapshot(identity["unit"])
        receipt["initial_baseline_native_readback_verified"]=false
        baseline=Dict(m*"-"*p=>offset_baseline(application,m,n;product=p) for(m,n) in (("woofer",97),("tweeter",2304)) for p in ("shape-offset","offset"))
        expected=Dict(m=>copy(a.data) for(m,a) in baseline)
        all(v -> all(iszero,v),values(expected)) || error("declared baseline is not zero")
        receipt["probe_selection"]=Dict{String,Any}()
        receipt["baseline_artifacts"]=Dict(m=>a.provenance for(m,a) in baseline)
        sequence=observe_offsets(handle,application,expected,receipt,"initial-baseline")
        receipt["initial_baseline_native_readback_verified"]=true
        for mirror in ("woofer","tweeter")
            transaction=Dict{String,Any}();receipt["transactions"][mirror]=transaction
            receipt["baseline_restored"][mirror]=false
            target=mirror*"-shape-offset"
            original=copy(expected[target]);probe=copy(original)
            selection=controlled_probe(application,mirror,length(original))
            receipt["probe_selection"][mirror]=selection
            transaction["parameter_alias"]=target
            transaction["generation_node"]=mirror*"-shape"
            probe[selection["index_one_based"]]+=4f-9
            reinterpret(UInt32,probe)!=reinterpret(UInt32,original) &&
                maximum(abs,Float64.(probe).-Float64.(original))<=5e-9 || error("probe must differ by at most5nm")
            file,io=mktemp(destination);close(io)
            dirty=false;restore_attempted=false
            function submit(values,name;restoring=false)
                before=checked_request(handle,name*"-generation-before",["parameter-generation",GRAPH,mirror*"-shape"],transaction)
                write(file,A.packed_bytes(values))
                # Each logical update is sent once. Submission is not adoption proof.
                try
                    checked_request(handle,name,["parameter",GRAPH,mirror*"-shape-offset","F32_LE",string(length(values)),OFFSET_SCHEMA,file],transaction;
                        before_request=()->begin
                            restoring && (restore_attempted=true)
                            nothing
                        end)
                    active_generation(handle,mirror,before["result"]["requested"],transaction,name*"-active")
                catch error
                    transaction[name*"-outcome-unknown-or-rejected"]=sprint(showerror,error)
                    # Reconcile with exact passive readout; never repeat this submission.
                end
            end
            try
                dirty=true;expected[target]=probe
                sequence=observe_offsets(handle,application,expected,transaction,"probe-readout";
                    after_sequence=sequence,action=()->submit(probe,"probe-submit"))
                expected[target]=original
                sequence=observe_offsets(handle,application,expected,transaction,"restore-readout";
                    after_sequence=sequence,action=()->submit(original,"restore-submit";restoring=true))
                dirty=false;receipt["baseline_restored"][mirror]=true
            finally
                # A compensating baseline update is distinct from retrying an unknown probe.
                # It is attempted at most once and still needs exact readout confirmation.
                if dirty && !restore_attempted
                    expected[target]=original
                    try
                        sequence=observe_offsets(handle,application,expected,transaction,"emergency-baseline-readout";
                            after_sequence=sequence,action=()->submit(original,"emergency-baseline-submit";restoring=true))
                        receipt["baseline_restored"][mirror]=true
                    catch error
                        receipt["baseline_restored"][mirror]=false
                        transaction["restoration-failure"]=sprint(showerror,error)
                    end
                end
                rm(file;force=true)
            end
        end
        receipt["unit_after"]=unit_snapshot(identity["unit"])
        receipt["unit_after"]==receipt["unit_before"] || error("session unit identity changed")
        graph=graph_dump(identity["remote"])
        prefix="classic-integration-observer-$(getpid())-"
        all(o -> !startswith(get(props(o),"node.name",""),prefix),graph) || error("owned observer remains")
        receipt["owned_observer_nodes_remaining"]=0
        receipt["completed"]=true
    catch error
        receipt["failure"]=sprint(showerror,error,catch_backtrace());rethrow()
    finally
        C.write_json(joinpath(destination,"result.json"),receipt)
        println("native offset roundtrip completed=",receipt["completed"]);flush(stdout)
    end
end
if abspath(PROGRAM_FILE)==(@__FILE__)
    offset_main()
end
