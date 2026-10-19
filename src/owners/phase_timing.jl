module PhaseTiming

import ..Common
using Base.Threads: threadid

export COLUMNS, Row, Capture, wants_sample, record!, reset!, save!

const COLUMNS = (
    :generation,
    :sequence,
    :deadline_ns,
    :started_ns,
    :ready_ns,
    :step_started_ns,
    :step_finished_ns,
    :staged_ns,
    :published_ns,
    :received_ns,
    :adoption_started_ns,
    :finished_ns,
    :optical_finished_ns,
    :next_deadline_ns,
    :missed_periods,
    :process_gc_time_ns,
    :process_allocated_bytes,
)

const Row = NTuple{17,UInt64}

mutable struct Capture
    directory::String
    warmup::Int
    rows::Vector{Row}
    period_ns::UInt64
    bootstrap_instance::Int64
    owner_thread::Int
    seen::Int
    used::Int
    generation::UInt64
    saved_count::Int
end

function Capture(directory::AbstractString, warmup::Integer, capacity::Integer,
        period_ns::Integer, bootstrap_instance::Integer)
    isabspath(directory) || throw(ArgumentError("phase timing directory must be absolute"))
    warmup isa Bool && throw(ArgumentError("warmup must be a nonnegative integer"))
    0 <= warmup || throw(ArgumentError("warmup must be a nonnegative integer"))
    capacity isa Bool && throw(ArgumentError("capacity must be in 1:65536"))
    1 <= capacity <= 65_536 || throw(ArgumentError("capacity must be in 1:65536"))
    period_ns isa Bool && throw(ArgumentError("period_ns must be nonnegative"))
    0 <= period_ns <= typemax(UInt64) ||
        throw(ArgumentError("period_ns must be nonnegative"))
    bootstrap_instance isa Bool && throw(ArgumentError("bootstrap_instance must be positive"))
    0 < bootstrap_instance <= typemax(Int64) ||
        throw(ArgumentError("bootstrap_instance must be positive"))
    return Capture(String(directory), Int(warmup), fill(ntuple(_ -> UInt64(0), Val(17)), Int(capacity)),
        UInt64(period_ns), Int64(bootstrap_instance), threadid(), 0, 0, 0, -1)
end

wants_sample(::Nothing) = false
wants_sample(capture::Capture) = capture.used < length(capture.rows)
record!(::Nothing, row) = nothing

function record!(capture::Capture, row::Row)
    threadid() == capture.owner_thread ||
        throw(ArgumentError("phase timing capture must be recorded by its owner thread"))
    generation = row[1]
    if capture.generation == 0
        generation > 0 || throw(ArgumentError("phase timing generation must be positive"))
        capture.generation = generation
    elseif generation != capture.generation
        throw(ArgumentError("phase timing row generation differs from active capture"))
    end
    capture.seen += 1
    capture.seen <= capture.warmup && return nothing
    capture.used == length(capture.rows) && return nothing
    capture.used += 1
    capture.rows[capture.used] = row
    return nothing
end

reset!(::Nothing, generation) = nothing
function reset!(capture::Capture, generation::Integer)
    0 < generation <= typemax(UInt64) ||
        throw(ArgumentError("phase timing generation must be positive"))
    (capture.used == 0 || capture.used == capture.saved_count) ||
        throw(ArgumentError("cannot reset phase timing capture with unsaved rows"))
    capture.seen = 0
    capture.used = 0
    capture.generation = UInt64(generation)
    capture.saved_count = -1
    return nothing
end

save!(::Nothing) = nothing
function save!(capture::Capture)
    (capture.used == 0 || capture.used == capture.saved_count) && return nothing
    generation = capture.generation
    path = joinpath(capture.directory, "phase-timing-$generation.json")
    _check_output_path(path)
    mkpath(capture.directory)
    temporary, io = mktemp(capture.directory)
    try
        close(io)
        rows = [collect(capture.rows[index]) for index in 1:capture.used]
        document = (
            version=1,
            owner_pid=getpid(),
            bootstrap_instance=capture.bootstrap_instance,
            generation,
            period_ns=capture.period_ns,
            pacing=capture.period_ns == 0 ? "unpaced" : "periodic",
            warmup_frames=capture.warmup,
            capacity=length(capture.rows),
            record_count=capture.used,
            capture_complete=capture.used == length(capture.rows),
            columns=collect(String.(COLUMNS)),
            rows,
        )
        Common.write_json(temporary, document)
        _check_output_path(path)
        Base.rename(temporary, path)
        capture.saved_count = capture.used
    finally
        isopen(io) && close(io)
        ispath(temporary) && rm(temporary)
    end
    return nothing
end

function _check_output_path(path)
    if (ispath(path) || islink(path)) && !(isfile(path) && !islink(path))
        throw(ArgumentError("phase timing report conflicts with a non-file path: $path"))
    end
    return nothing
end

end
