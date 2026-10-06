# EXPERIMENT ONLY: sampled process-wide Julia allocations, no acceptance claim.
module SourceAllocationDiagnostic
using Profile
using ..HILOwnerProtocol
const SAMPLE_RATE = 0.005
const GROUP_LIMIT = 32
const STACK_LIMIT = 8
const ACTIVE = Ref(false)
const OUTPUT_DIRECTORY = "/tmp/gui-source-allocation-diagnostic-20261006/profiles-attempt-2"

function warm!()
    Profile.Allocs.clear()
    Profile.Allocs.start(;sample_rate=SAMPLE_RATE)
    Profile.Allocs.stop()
    Profile.Allocs.fetch()
    Profile.Allocs.clear()
    return nothing
end
function begin!()
    Profile.Allocs.clear()
    Profile.Allocs.start(;sample_rate=SAMPLE_RATE)
    ACTIVE[]=true
    return nothing
end
function stop!()
    ACTIVE[] && Profile.Allocs.stop()
    ACTIVE[]=false
    return nothing
end
bounded(value,limit=128)=first(string(value),limit)
function save!(output,generation,allocation=nothing)
    # Stop precedes fetch, stringification, aggregation and filesystem IO.
    stop!()
    sampled=Profile.Allocs.fetch()
    groups=Dict{String,Dict{String,Any}}()
    types=Dict{String,Dict{String,Any}}()
    dropped_groups=0
    total_bytes=0
    tasks=Set{UInt}()
    for sample in sampled.allocs
        total_bytes+=sample.size
        push!(tasks,UInt(sample.task)) # opaque sampled identity only; never dereference
        type=bounded(sample.type,160)
        if haskey(types,type) || length(types)<GROUP_LIMIT
            row=get!(types,type) do
                Dict{String,Any}("type"=>type,"samples"=>0,"sampled_bytes"=>0)
            end
            row["samples"]+=1;row["sampled_bytes"]+=sample.size
        end
        frames=[bounded(frame) for frame in Iterators.take(sample.stacktrace,STACK_LIMIT)]
        # Keep owner/SDK and compiler frames even when deeper than the head.
        relevant=[bounded(frame) for frame in sample.stacktrace if
            occursin("source_control",string(frame.file)) || occursin("PipeWireAO",string(frame.file)) ||
            occursin("simulator_owner",string(frame.file)) || occursin("compiler",string(frame.file))]
        resize!(relevant,min(length(relevant),STACK_LIMIT))
        key=type*":"*join(frames,";")
        if haskey(groups,key) || length(groups)<GROUP_LIMIT
            row=get!(groups,key) do
                Dict{String,Any}("type"=>type,"frames"=>frames,"relevant_frames"=>relevant,
                    "samples"=>0,"sampled_bytes"=>0)
            end
            row["samples"]+=1;row["sampled_bytes"]+=sample.size
        else
            dropped_groups+=1
        end
    end
    payload=Dict("scope"=>"diagnostic sampled process-wide Julia allocations after prefix; fetch/aggregation/reporting excluded; native C malloc coverage not claimed",
        "sample_rate"=>SAMPLE_RATE,"generation"=>generation,"owner_pid"=>getpid(),"inclusive_allocation"=>allocation,"samples"=>length(sampled.allocs),
        "sampled_bytes"=>total_bytes,"distinct_opaque_tasks"=>length(tasks),
        "group_limit"=>GROUP_LIMIT,"stack_limit"=>STACK_LIMIT,"samples_outside_retained_groups"=>dropped_groups,
        "types"=>sort!(collect(values(types));by=row -> -row["sampled_bytes"]),
        "stacks"=>sort!(collect(values(groups));by=row -> -row["samples"]))
    HILOwnerProtocol.write_json_atomic(joinpath(OUTPUT_DIRECTORY,"source-"*string(getpid())*"-generation-"*string(generation)*".json"),payload;maximum=256*1024)
    Profile.Allocs.clear()
    return nothing
end
end
