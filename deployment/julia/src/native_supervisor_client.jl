"""Typed public supervisor discovery and local CLI rendering; no socket fallback."""
module NativeSupervisorClient
using PipeWireAO
import ..Common
import ..NativeControlClient
import ..NativeControlCodec
import ..NativeSupervisorCodec
import ..NativeRunnerCodec
import ..NativeSourceClient
import ..NativeAcquisitionLifecycleCodec
import ..RunnerCommands

const PROFILE = NativeSupervisorCodec.PROFILE
const Client = NativeControlClient.Client
const UnknownOutcome = NativeControlClient.UnknownOutcome
const Codec = NativeSupervisorCodec
const Runner = NativeRunnerCodec
function connect(args...;expected_uuid=nothing,kwargs...)
    expected_uuid===nothing || Codec.validate_uuid(expected_uuid)
    client=NativeControlClient.connect(PROFILE,args...;kwargs...)
    try
        expected_uuid===nothing || live_uuid(client)==expected_uuid ||
            throw(UnknownOutcome("supervisor UUID differs from intended binding"))
        return client
    catch
        close(client);rethrow()
    end
end
function live_uuid(client::Client)
    return with_thread_loop_lock(client.loop) do _
        NativeControlClient.healthy(client)
        Codec.validate_uuid(client.observation.node_identity)
    end
end
request!(args...; kwargs...) = NativeControlClient.request!(args...; kwargs...)
export Client, UnknownOutcome, connect, request!, connect_locator, render, live_uuid

"The persisted locator supplies hints; exact bound metadata and fresh Status supply authority."
function connect_locator(path::AbstractString; deadline::Float64, check=()->nothing, expected_uuid=nothing)
    NativeControlClient.deadline_check(deadline, check)
    islink(path) && throw(ArgumentError("native control locator must not be a symlink"))
    hints = Common.read_json(path; maximum=4096)
    Set(keys(hints)) == Set(["version", "profile", "remote", "node", "owner_pid", "instance"]) &&
        get(hints,"version",nothing) === 1 && get(hints,"profile",nothing) == NativeControlClient.profile_name(PROFILE) ||
        throw(ArgumentError("unsupported native supervisor locator"))
    hints["remote"] isa String && hints["node"] isa String &&
        typeof(hints["owner_pid"]) === Int && 0 < hints["owner_pid"] <= typemax(UInt32) &&
        typeof(hints["instance"]) === Int && hints["instance"] > 0 ||
        throw(ArgumentError("invalid native supervisor locator identity"))
    # connect checks the actual private remote, actual registry/NodeInfo metadata,
    # owner PID/incarnation/profile and this client's actual controller marker.
    return connect(hints["remote"], hints["node"], hints["owner_pid"], hints["instance"]; deadline, check, expected_uuid)
end

function source_render(source::Codec.SourceObservation)
    snapshot = source.snapshot
    if snapshot isa Codec.SimulatorSnapshot
        values = (snapshot.version, snapshot.instance, snapshot.kind, snapshot.token,
            snapshot.result, snapshot.generation, snapshot.sequence, snapshot.running,
            snapshot.completed, snapshot.report_generation, snapshot.report_sequence)
        return NativeSourceClient.reply("status", source.token, values)
    end
    return Dict{String,Any}("version"=>1, "id"=>source.token, "operation"=>"status",
        "native_token"=>source.token, "endpoint_instance"=>source.binding.instance,
        "ok"=>true, "error"=>nothing, "state"=>snapshot.running ? "running" : "paused",
        "sequence"=>snapshot.cursor === nothing ? nothing : snapshot.cursor.sequence,
        "completed"=>snapshot.completed, "cursor"=>snapshot.cursor,
        "report_cursor"=>snapshot.report_cursor, "phase"=>snapshot.phase,
        "held"=>snapshot.held, "restored"=>snapshot.restored, "window"=>snapshot.window,
        "lifecycle"=>string(source.lifecycle),"instrument"=>lowercase(string(snapshot.instrument)))
end
function binding_render(binding::Codec.Binding)
    return Dict("node"=>binding.name,"profile"=>binding.profile,"owner_pid"=>binding.pid,
        "global_id"=>binding.global_id,"serial"=>binding.serial,"instance"=>binding.instance)
end

"Render a verified native result to the existing operator/report field names locally."
function render(completion; request_id=nothing, owner_pid=nothing)
    header = completion.header
    id = request_id === nothing ? string(header.token) : String(request_id)
    snapshot = completion isa Codec.Completion ? completion.snapshot : nothing
    record=completion isa Codec.Completion && completion.result!==nothing ? completion.result :
        snapshot!==nothing&&snapshot.runner!==nothing ? snapshot.runner.status : nothing
    if record!==nothing
        inner_header=NativeControlCodec.ReplyHeader(header.controller,header.endpoint_instance,header.token,header.operation,Int32(0))
        backend = Runner.Completion(inner_header, record.lifecycle, record.result, nothing)
        reply = RunnerCommands.render(backend; request_id=id)
        reply["session_id"] = snapshot!==nothing&&snapshot.runner!==nothing ? snapshot.runner.session_id : nothing
        reply["ok"]=header.result==0
        reply["error"]=header.result==0 ? nothing : Dict("field"=>completion.error.field,"message"=>completion.error.message)
    else
        reply = Dict{String,Any}("version"=>1,"id"=>id,"session_id"=>nothing,
            "state"=>nothing,"result"=>nothing,"ok"=>header.result==0,
            "error"=>header.result==0 ? nothing : Dict("field"=>completion.error.field,"message"=>completion.error.message))
    end
    phase = lowercase(string(completion.lifecycle))
    # Retain the existing admitted "running" phase name for wait/CLI callers;
    # the new supervisor_phase carries the exact coherent-admission domain.
    reply["phase"] = completion.admitted ? "running" : phase
    reply["supervisor_phase"] = phase
    reply["admitted"] = completion.admitted
    reply["endpoint_instance"] = header.endpoint_instance
    reply["native_token"] = header.token
    owner_pid === nothing || (reply["pid"] = owner_pid)
    reply["processes"] = snapshot === nothing ? Dict{String,Any}() :
        Dict{String,Any}(process.role=>Dict("pid"=>process.pid) for process in snapshot.processes)
    if snapshot !== nothing
        snapshot.source === nothing || (reply["source"] = source_render(snapshot.source))
        snapshot.runner === nothing || (reply["runner_endpoint"] = binding_render(snapshot.runner.binding))
        if snapshot.source !== nothing
            reply["source_endpoint"] = binding_render(snapshot.source.binding)
            if snapshot.source.snapshot isa NativeAcquisitionLifecycleCodec.Snapshot
                reply["source_endpoint"]["instrument"] = lowercase(string(snapshot.source.snapshot.instrument))
            end
        end
        snapshot.heart === nothing || (reply["heart_endpoint"] = binding_render(snapshot.heart.binding))
        header.operation == 1 && (reply["snapshot_order"] = "before_quit_effect")
    end
    return reply
end
end
