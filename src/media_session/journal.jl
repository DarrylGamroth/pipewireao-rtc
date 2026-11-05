import Agent, SQLite, DBInterface

"""One native operation record. `submit!` copies bytes before admission returns.

`operation_key` is the ingress's session/header identity key, shared by the
requested and terminal records. A duplicate key/event is an error, never a retry.
"""
struct JournalRequest
    token::UInt64
    session_id::String
    event::Symbol
    bytes::Vector{UInt8}
    client_name::String
    client_pid::UInt32
    operation_key::String
    function JournalRequest(token::UInt64, session_id::String, event::Symbol,
            bytes::Vector{UInt8}, client_name::String, client_pid::UInt32, operation_key::String)
        token > 0 && client_pid > 0 || throw(ArgumentError("invalid journal token or client PID"))
        event in (:requested,:completed,:unknown) || throw(ArgumentError("invalid journal event"))
        for (value, minimum, maximum) in ((session_id,1,128),(client_name,0,1024),(operation_key,1,512))
            minimum <= ncodeunits(value) <= maximum && isvalid(value) && !occursin('\0',value) ||
                throw(ArgumentError("invalid journal text field"))
        end
        limit = event === :requested ? 16384 : 65536
        8 <= length(bytes) <= limit && reinterpret(UInt32,@view(bytes[1:4]))[1] == length(bytes)-8 ||
            throw(ArgumentError("invalid native journal record extent"))
        return new(token,session_id,event,bytes,client_name,client_pid,operation_key)
    end
end

"""Durable append receipt. A failed SQLite write may have an unknown outcome."""
struct JournalResult
    token::UInt64
    success::Bool
    message::String
    unknown::Bool
end

"""Bounded single-writer journal. SQLite stays private to its default-pool task.

Construct on an interactive policy thread, with a separate default thread pool.
Construction waits for READY and reports path/schema failures before admission.
Capacity includes jobs and retained receipts, so neither direction can overflow.
"""
mutable struct Journal
    const path::String
    const capacity::Int
    const lock::ReentrantLock
    const jobs::Vector{JournalRequest}
    const results::Vector{JournalResult}
    outstanding::Int
    accepting::Bool
    closing::Bool
    done::Bool
    failure::Union{Nothing,String}
    task::Union{Nothing,Task}
    const ready::Channel{Union{Nothing,String}}
    const owner_thread::UInt
    worker_thread::UInt
end

mutable struct JournalWorker
    journal::Journal
    owner::Task
    database::Union{Nothing,SQLite.DB}
    active::Union{Nothing,JournalRequest}
end

function _journal_path(path::String)
    directory = dirname(path)
    mkpath(directory;mode=0o700)
    metadata = lstat(directory)
    uid = ccall(:getuid,Cuint,())
    isdir(metadata) && metadata.uid == uid && (filemode(metadata) & 0o077) == 0 ||
        throw(ArgumentError("journal requires a private owned directory"))
    flags = Base.Filesystem.JL_O_WRONLY | Base.Filesystem.JL_O_CREAT |
        Base.Filesystem.JL_O_NOFOLLOW | Base.Filesystem.JL_O_CLOEXEC
    file = Base.Filesystem.open(path,flags,0o600)
    try
        metadata = stat(file)
        isfile(metadata) && metadata.uid == uid && (filemode(metadata) & 0o077) == 0 && metadata.nlink == 1 ||
            throw(ArgumentError("journal requires a private owned regular database file"))
    finally
        close(file)
    end
    return nothing
end

# Finalize even row-returning PRAGMAs before a transaction may commit.
function _journal_execute(db::SQLite.DB,sql::String,parameters=())
    statement = DBInterface.prepare(db,sql)
    try
        query = DBInterface.execute(statement,parameters)
        for _ in query end
    finally
        DBInterface.close!(statement)
    end
    return nothing
end

function _journal_schema(db::SQLite.DB)
    _journal_execute(db,"PRAGMA busy_timeout=1000")
    _journal_execute(db,"PRAGMA journal_mode=WAL")
    _journal_execute(db,"PRAGMA synchronous=FULL")
    _journal_execute(db,"BEGIN IMMEDIATE")
    try
        _journal_execute(db,"""
        CREATE TABLE IF NOT EXISTS operation_events(
         sequence INTEGER PRIMARY KEY AUTOINCREMENT,
         session_id TEXT NOT NULL,
         event TEXT NOT NULL CHECK(event IN ('requested','completed','unknown')),
         record BLOB NOT NULL,
         operation_key TEXT NOT NULL,
         client_name TEXT NOT NULL DEFAULT '',
         client_pid INTEGER NOT NULL DEFAULT 0,
         recorded_at TEXT NOT NULL DEFAULT(strftime('%Y-%m-%dT%H:%M:%fZ','now')))
        """)
        columns = DBInterface.execute(db,"PRAGMA table_info(operation_events)") do rows
            Set(String(row.name) for row in rows)
        end
        "client_name" in columns || _journal_execute(db,"ALTER TABLE operation_events ADD COLUMN client_name TEXT NOT NULL DEFAULT ''")
        "client_pid" in columns || _journal_execute(db,"ALTER TABLE operation_events ADD COLUMN client_pid INTEGER NOT NULL DEFAULT 0")
        if !("operation_key" in columns)
            _journal_execute(db,"ALTER TABLE operation_events ADD COLUMN operation_key TEXT NOT NULL DEFAULT ''")
            _journal_execute(db,"UPDATE operation_events SET operation_key='legacy:' || sequence WHERE operation_key=''")
        end
        _journal_execute(db,"CREATE UNIQUE INDEX IF NOT EXISTS operation_events_key_event ON operation_events(operation_key,event)")
        _journal_execute(db,"CREATE INDEX IF NOT EXISTS operation_events_event_sequence ON operation_events(event,sequence)")
        _journal_execute(db,"CREATE INDEX IF NOT EXISTS operation_events_session_event_sequence ON operation_events(session_id,event,sequence)")
        _journal_execute(db,"COMMIT")
    catch
        try _journal_execute(db,"ROLLBACK") catch end
        rethrow()
    end
    return nothing
end

function Agent.on_start(worker::JournalWorker)
    journal = worker.journal
    current_task() === worker.owner || error("journal task ownership changed")
    thread = ccall(:uv_thread_self,UInt,())
    thread != journal.owner_thread && Threads.threadpool() === :default ||
        error("journal I/O requires a separate default-pool OS thread")
    _journal_path(journal.path)
    worker.database = SQLite.DB(journal.path)
    _journal_schema(something(worker.database))
    lock(journal.lock) do
        journal.worker_thread = thread
        journal.accepting = !journal.closing
    end
    put!(journal.ready,nothing)
    return nothing
end

function _journal_append(db::SQLite.DB,request::JournalRequest,path::String)
    try
        _journal_path(path)
    catch error
        return JournalResult(request.token,false,"journal path rejected: "*sprint(showerror,error),false)
    end
    try
        _journal_execute(db,"BEGIN IMMEDIATE")
        _journal_execute(db,"""
            INSERT INTO operation_events(session_id,event,record,client_name,client_pid,operation_key)
            VALUES (?,?,?,?,?,?)
            """,(request.session_id,String(request.event),request.bytes,request.client_name,
                Int64(request.client_pid),request.operation_key))
        _journal_execute(db,"COMMIT")
        return JournalResult(request.token,true,"",false)
    catch error
        # Native journal semantics: do not infer rollback or retry from a write
        # error, including busy/commit failures whose outcome may be ambiguous.
        try _journal_execute(db,"ROLLBACK") catch end
        return JournalResult(request.token,false,"journal append failed: "*sprint(showerror,error),true)
    end
end

function Agent.do_work(worker::JournalWorker)
    current_task() === worker.owner || error("journal task ownership changed")
    journal = worker.journal
    request = lock(journal.lock) do
        isempty(journal.jobs) ? nothing : popfirst!(journal.jobs)
    end
    request === nothing && return 0
    worker.active = request
    result = _journal_append(something(worker.database),request,journal.path)
    lock(journal.lock) do
        push!(journal.results,result)
    end
    worker.active = nothing
    return 1
end

Agent.on_error(::JournalWorker,error) = throw(error)
function Agent.on_close(worker::JournalWorker)
    worker.database === nothing || close(something(worker.database))
    worker.database = nothing
    return nothing
end

function _journal_serve(journal::Journal)
    current_task().sticky = true
    worker = JournalWorker(journal,current_task(),nothing,nothing)
    invoker = Agent.AgentInvoker(worker)
    try
        Agent.start(invoker)
        while true
            finished = lock(journal.lock) do
                !journal.accepting && isempty(journal.jobs)
            end
            finished && break
            Agent.invoke_unchecked(invoker) == 0 && sleep(0.001)
        end
    catch error
        message = "journal worker failed: "*sprint(showerror,error)
        lock(journal.lock) do
            journal.failure = message
            journal.accepting = false
            if worker.active !== nothing
                push!(journal.results,JournalResult(something(worker.active).token,false,message,true))
                worker.active = nothing
            end
            for request in journal.jobs
                push!(journal.results,JournalResult(request.token,false,message,false))
            end
            empty!(journal.jobs)
        end
        isready(journal.ready) || put!(journal.ready,message)
    finally
        try
            close(invoker)
        catch error
            lock(journal.lock) do
                journal.failure = "journal close failed: "*sprint(showerror,error)
            end
        end
        lock(journal.lock) do
            journal.accepting = false
            journal.done = true
        end
    end
    return nothing
end

function _journal_wait(predicate,timeout::Float64)
    clock = Clocks.SystemNanoClock()
    duration = ceil(Int64,timeout * 1_000_000_000)
    deadline = Base.Checked.checked_add(Clocks.time_nanos(clock),duration)
    while !predicate()
        Clocks.time_nanos(clock) >= deadline && return false
        sleep(0.001)
    end
    return true
end

function Journal(path::AbstractString;capacity::Integer=8,timeout::Real=5.0)
    isabspath(path) && !occursin('\0',path) || throw(ArgumentError("journal requires an absolute path"))
    1 <= capacity <= 8 || throw(ArgumentError("journal capacity must be in 1:8"))
    isfinite(timeout) && timeout > 0 || throw(ArgumentError("invalid journal startup timeout"))
    Threads.threadpool() === :interactive && Threads.nthreads(:default) >= 1 ||
        throw(ArgumentError("journal requires an interactive policy thread and a separate default pool"))
    journal = Journal(String(path),Int(capacity),ReentrantLock(),JournalRequest[],JournalResult[],0,
        false,false,false,nothing,nothing,Channel{Union{Nothing,String}}(1),ccall(:uv_thread_self,UInt,()),0)
    journal.task = Threads.@spawn :default _journal_serve(journal)
    if !_journal_wait(() -> isready(journal.ready),Float64(timeout))
        lock(journal.lock) do
            journal.accepting = false
            journal.closing = true
        end
        throw(ErrorException("journal startup outcome unknown: READY deadline expired"))
    end
    failure = Base.take!(journal.ready)
    failure === nothing || throw(ErrorException(failure))
    return journal
end

"""Admit an owned record without blocking, I/O or spinning; false means refused."""
function submit!(journal::Journal,request::JournalRequest)::Bool
    trylock(journal.lock) || return false
    try
        journal.accepting && journal.outstanding < journal.capacity || return false
        owned = JournalRequest(request.token,request.session_id,request.event,copy(request.bytes),
            request.client_name,request.client_pid,request.operation_key)
        push!(journal.jobs,owned)
        journal.outstanding += 1
        return true
    finally
        unlock(journal.lock)
    end
end

"""Take the oldest durable receipt without waiting; receipts remain after close."""
function take_result!(journal::Journal)::Union{Nothing,JournalResult}
    trylock(journal.lock) || return nothing
    try
        isempty(journal.results) && return nothing
        journal.outstanding -= 1
        return popfirst!(journal.results)
    finally
        unlock(journal.lock)
    end
end

"""Fence admission, drain accepted jobs and close storage on its worker.

Receipts remain available through `take_result!`. A timeout or worker/storage
failure throws; the writer is never interrupted or its in-flight outcome guessed.
"""
function Base.close(journal::Journal;timeout::Real=5.0)
    isfinite(timeout) && timeout > 0 || throw(ArgumentError("invalid journal close timeout"))
    lock(journal.lock) do
        journal.accepting = false
        journal.closing = true
    end
    finished = _journal_wait(() -> lock(() -> journal.done,journal.lock),Float64(timeout))
    finished || throw(ErrorException("journal close outcome unknown: drain deadline expired"))
    wait(something(journal.task))
    failure = lock(() -> journal.failure,journal.lock)
    failure === nothing || throw(ErrorException(failure))
    return nothing
end
