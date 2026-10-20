#!/usr/bin/env julia
# Optional observer client. The caller owns the already Running cohort.
include("classic_observation.jl")
import PipeWireAORTC
using Test

function _classic_observation_successor(previous, current)
    previous["remote"]==current["remote"] || error("Classic observation remote changed")
    names=Set(spec.name for spec in CLASSIC_OBSERVATION_STREAMS)
    Set(keys(previous["streams"]))==Set(keys(current["streams"]))==names ||
        error("Classic lifecycle observation must include all eight products")
    gaps=Dict{String,Any}()
    for name in names
        old, new=previous["streams"][name], current["streams"][name]
        for key in ("output_node_id", "output_node_serial", "output_port_id", "output_port_serial")
            old[key]==new[key] || error("Classic $name producer incarnation changed")
        end
        (old["observer_node_id"], old["observer_node_serial"]) !=
            (new["observer_node_id"], new["observer_node_serial"]) ||
            error("Classic $name observer incarnation was reused")
        new["finite"] && new["canonical_boolean"] && new["distinct_sequences"]>=2 &&
            new["first_sequence"]>=old["last_sequence"] &&
            new["last_sequence"]>new["first_sequence"] ||
            error("Classic $name did not advance monotonically after reattachment")
        for (a,b) in ((old["last_identity"],new["first_identity"]),
                (new["first_identity"],new["last_identity"]))
            if a===nothing || b===nothing
                a===b || error("Classic $name acquisition metadata presence changed")
            else
                a["domain"]==b["domain"] && a["generation"]==b["generation"] ||
                    error("Classic $name acquisition incarnation changed")
            end
        end
        span=new["last_sequence"]-new["first_sequence"]+1
        span>=new["distinct_sequences"] || error("Classic $name sequence accounting is inconsistent")
        gaps[name]=Dict("first_sequence_gap"=>new["first_sequence"]-old["last_sequence"],
            "last_sequence_advance"=>new["last_sequence"]-old["last_sequence"],
            "unobserved_sequences"=>span-new["distinct_sequences"])
    end
    old, new=previous["matching_wfs_identity"], current["matching_wfs_identity"]
    old!==nothing && new!==nothing && old["domain"]==new["domain"] &&
        old["generation"]==new["generation"] && new["sequence"]>old["sequence"] ||
        error("Classic common WFS acquisition identity did not advance in the same incarnation")
    return gaps
end

"""
    observe_classic_lifecycle(remote; timeout=45, slow_interval=0.1,
        slow_duration=1.0, detached_duration=1.0, on_phase=record->nothing)

Attach normal observers, retire them, attach observers with driver requests spaced
by `slow_interval`, retire them, wait with no owned observers, then attach fresh
normal observers. Every attachment checks all eight existing queue outputs and a
common WFS acquisition identity. Producer incarnations and acquisition domain /
generation must remain unchanged; per-product sequences and common WFS identities
must advance across attachments. Each observe_classic call retires its resources
in finally before the next phase begins. Sleeps occur outside native loop locks.

The caller owns source/session controls. This helper never starts, stops, resets
or changes that cohort. It makes no stochastic sample-equality or cadence claim.
Sequence gaps show progress across the detached interval; they do not establish
uninterrupted progress at every instant without an independent source counter.
`unobserved_sequences` is derived from delivered labels, not a native drop counter.
`on_phase` receives partial receipts after retirement and on failure.
"""
function observe_classic_lifecycle(remote::AbstractString; timeout::Real=45.0,
        slow_interval::Real=0.1, slow_duration::Real=1.0, detached_duration::Real=1.0,
        on_phase=record->nothing, _observe=observe_classic, _pause=sleep, _clock=_classic_now)
    _classic_observation_timing(timeout, slow_interval, slow_duration)
    slow_interval>0.02 || throw(ArgumentError("slow_interval must exceed the normal 20 ms drive interval"))
    isfinite(detached_duration) && detached_duration>0 ||
        throw(ArgumentError("detached_duration must be positive and finite"))
    record=Dict{String,Any}("remote"=>String(remote), "completed"=>false,
        "test_sha256"=>PipeWireAORTC.Common.sha256_file(@__FILE__),
        "observation_client_sha256"=>PipeWireAORTC.Common.sha256_file(joinpath(@__DIR__,"classic_observation.jl")),
        "scope"=>"observer attachment/slow driving/detachment/reattachment; no source controls")
    try
        record["attached"]=_observe(remote; timeout)
        on_phase(record)
        record["slow"]=_observe(remote; timeout, drive_interval=slow_interval, minimum_duration=slow_duration)
        record["attached_to_slow"]=_classic_observation_successor(record["attached"],record["slow"])
        record["detached_started_s"]=_clock()
        on_phase(record)
        _pause(Float64(detached_duration))
        record["detached_ended_s"]=_clock()
        record["detached_ended_s"]-record["detached_started_s"]>=detached_duration ||
            error("Classic detached observation interval ended early")
        record["reattached"]=_observe(remote; timeout)
        record["slow_to_reattached"]=_classic_observation_successor(record["slow"],record["reattached"])
        record["completed"]=true
        on_phase(record)
        return record
    catch err
        record["failure"]=sprint(showerror,err)
        on_phase(record)
        rethrow()
    end
end

function classic_observation_lifecycle_selftest()
    # Construct complete records without opening a native loop or scientific plant.
    function observation(phase)
        acquisition(sequence)=Dict("domain"=>"a000", "generation"=>2, "sequence"=>sequence)
        streams=Dict{String,Any}()
        for (index,spec) in enumerate(CLASSIC_OBSERVATION_STREAMS)
            first=UInt64(100phase)
            streams[spec.name]=Dict{String,Any}("output_node_id"=>index, "output_node_serial"=>index+10,
                "output_port_id"=>index+20, "output_port_serial"=>index+30,
                "observer_node_id"=>index+40, "observer_node_serial"=>phase*100+index,
                "first_sequence"=>first, "last_sequence"=>first+10,
                "distinct_sequences"=>2, "finite"=>true, "canonical_boolean"=>true,
                "first_identity"=>spec.name=="applied" ? nothing : acquisition(first),
                "last_identity"=>spec.name=="applied" ? nothing : acquisition(first+10))
        end
        return Dict("remote"=>"unused-cold-remote", "streams"=>streams,
            "matching_wfs_identity"=>acquisition(100phase+10))
    end
    @testset "Classic observer lifecycle cold contracts" begin
        for spec in CLASSIC_OBSERVATION_STREAMS
            capture=ClassicObservationCapture(spec)
            @test capture.first_identity===nothing
            @test capture.first_sequence===nothing
        end
        domain=AcquisitionDomain(ntuple(index->index==1 ? UInt8(1) : UInt8(0),16))
        identity=AcquisitionIdentity(domain,UInt64(2),UInt64(1))
        @test _classic_same_acquisition(identity,AcquisitionIdentity(domain,UInt64(2),UInt64(2)))===nothing
        @test _classic_same_acquisition(nothing,nothing)===nothing
        @test_throws ErrorException _classic_same_acquisition(identity,nothing)
        @test_throws ErrorException _classic_same_acquisition(identity,AcquisitionIdentity(domain,UInt64(3),UInt64(2)))
        @test _classic_observation_timing(45.0,0.1,1.0)===nothing
        for settings in ((0.0,0.1,1.0),(45.0,0.0,1.0),(45.0,Inf,1.0),
                (45.0,0.1,-1.0),(45.0,0.1,45.0),(45.0,0.1,NaN))
            @test_throws ArgumentError _classic_observation_timing(settings...)
        end
        a,b=observation(1),observation(2)
        gaps=_classic_observation_successor(a,b)
        @test length(gaps)==8
        @test gaps["detector"]["unobserved_sequences"]==9
        for mutate in (
            x->(x["streams"]["detector"]["output_node_serial"]+=1),
            x->(x["streams"]["flux"]["observer_node_serial"]=a["streams"]["flux"]["observer_node_serial"]),
            x->(x["streams"]["slopes"]["first_sequence"]=0),
            x->(x["streams"]["focal"]["finite"]=false),
            x->(x["streams"]["validity"]["canonical_boolean"]=false),
            x->(x["streams"]["offset"]["last_identity"]["generation"]+=1),
            x->(x["streams"]["applied"]["last_identity"]=Dict()),
            x->(x["matching_wfs_identity"]["sequence"]=100),
            x->pop!(x["streams"],"focal"),
        )
            bad=deepcopy(b); mutate(bad)
            @test_throws ErrorException _classic_observation_successor(a,bad)
        end
        calls, phases=Any[],Any[]
        ticks=Ref(1.0)
        fake_observe(remote; kwargs...)=begin
            push!(calls,(;remote,kwargs=(;kwargs...)))
            observation(length(calls))
        end
        record=observe_classic_lifecycle("unused-cold-remote"; _observe=fake_observe,
            _pause=seconds->(ticks[]+=seconds), _clock=()->ticks[],
            on_phase=value->push!(phases,deepcopy(value)))
        @test record["completed"]
        @test length(calls)==3
        @test calls[2].kwargs.drive_interval==0.1
        @test calls[2].kwargs.minimum_duration==1.0
        @test record["detached_ended_s"]-record["detached_started_s"]==1.0
        @test all(!value["completed"] for value in phases[1:end-1])
        @test last(phases)["completed"]
        empty!(phases)
        @test_throws ErrorException observe_classic_lifecycle("unused-cold-remote";
            _observe=(args...;kwargs...)->error("controlled observer failure"),
            on_phase=value->push!(phases,deepcopy(value)))
        @test only(phases)["completed"]===false
        @test only(phases)["failure"]=="controlled observer failure"
    end
end

if abspath(PROGRAM_FILE)==(@__FILE__) && ARGS==["--self-test"]
    classic_observation_lifecycle_selftest()
elseif abspath(PROGRAM_FILE)==(@__FILE__)
    length(ARGS)==2 || error("usage: classic_observation_lifecycle.jl REMOTE FRESH_OUTPUT_JSON | --self-test")
    remote,output=ARGS
    !ispath(output) && !islink(output) || error("observation output must be fresh")
    observe_classic_lifecycle(remote;
        on_phase=record->PipeWireAORTC.Common.write_json(output,record;atomic=true))
end
