
using Profile
function save_graph_update_allocations()
    samples = Profile.Allocs.fetch().allocs
    directory = ENV["RTC_GRAPH_UPDATE_TRACE_DIR"]
    mkpath(directory)
    # Aggregate after stop: never expand parameterized types or repeat entire
    # stacks per allocation. Include every sample; no task pointer is inspected.
    totals = Dict{Symbol,Tuple{Int,Int}}(:frame => (0,0))
    hot = Set((:_process_graph_callback!, :_process_graph_buffers!,
        :_process_feedback_buffers!, :_process_synchronized_buffers!,
        :_process_admitted!, :_adopt_pending_properties!,
        :_adopt_pending_parameters!, :GraphProcessCallback))
    properties = Set((:GraphGetPropertiesCallback, :GraphSetPropertiesCallback,
        :_graph_properties, :_stage_property_transaction!, :_prepare_property_update))
    sites = Dict{Tuple{Symbol,Symbol,Int},Tuple{Int,Int}}()
    first_timestamp = typemax(UInt64)
    last_timestamp = UInt64(0)
    for sample in samples
        first_timestamp = min(first_timestamp, sample.timestamp)
        last_timestamp = max(last_timestamp, sample.timestamp)
        category = :other
        if any(frame -> frame.func in hot, sample.stacktrace)
            category = :frame
        elseif any(frame -> frame.func == :_stage_parameter_transaction! ||
                frame.func == :_prepare_parameter_transaction, sample.stacktrace)
            category = :parameter_preparation
        elseif any(frame -> frame.func in properties, sample.stacktrace)
            category = :property_control
        elseif isempty(sample.stacktrace)
            category = :empty_stack
        end
        count, bytes = get(totals, category, (0,0))
        totals[category] = (count+1, bytes+sample.size)
        if category == :frame
            for frame in sample.stacktrace
                frame.from_c && continue
                key = (frame.func, frame.file, frame.line)
                count, bytes = get(sites, key, (0,0))
                sites[key] = (count+1, bytes+sample.size)
            end
        end
    end
    open(joinpath(directory, "allocation-summary.tsv"), "w") do io
        println(io, "category\tcount\tbytes")
        for category in sort!(collect(keys(totals)); by=string)
            count, bytes = totals[category]
            println(io, category, '\t', count, '\t', bytes)
        end
    end
    open(joinpath(directory, "allocation-frame-sites.tsv"), "w") do io
        println(io, "function\tfile\tline\tcount\tbytes")
        for (key, value) in sites
            println(io, join((key..., value...), '\t'))
        end
    end
    open(joinpath(directory, "allocation-capture.txt"), "w") do io
        println(io, "samples=", length(samples), " sample_rate=1.0 timestamp_raw_first=",
            isempty(samples) ? 0 : first_timestamp, " timestamp_raw_last=", last_timestamp)
    end
    return nothing
end

function _process_graph_callback!(out)
    push!(out, Vector{Float32}(undef,8))
end
function _stage_parameter_transaction!(out)
    push!(out, Vector{Float32}(undef,16))
end
out=Vector{Vector{Float32}}(); sizehint!(out,8)
_process_graph_callback!(out); _stage_parameter_transaction!(out)
Profile.Allocs.@profile sample_rate=1.0 begin
    _process_graph_callback!(out)
    _stage_parameter_transaction!(out)
end
ENV["RTC_GRAPH_UPDATE_TRACE_DIR"]=mktempdir()
save_graph_update_allocations()
s=read(joinpath(ENV["RTC_GRAPH_UPDATE_TRACE_DIR"],"allocation-summary.tsv"),String)
println(s)
@assert occursin(r"frame\t[1-9]",s)
@assert occursin(r"parameter_preparation\t[1-9]",s)
rm(ENV["RTC_GRAPH_UPDATE_TRACE_DIR"];recursive=true)
