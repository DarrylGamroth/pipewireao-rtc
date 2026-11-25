module MediaSessionEffectsTests
using Test, PipeWireAO, PipeWireAORTC
import Clocks
import PipeWireAORTC.MediaSession:
    node!,
    find_object,
    property,
    capture!,
    capture_owner,
    connect_owner!,
    shutdown_owner!,
    source,
    prepare_source!,
    source_operation!,
    shutdown_source!,
    node_operation!,
    discover_graphs!,
    create_links!,
    remove_links!,
    named_properties!,
    update_properties!,
    submit_parameter!,
    await_condition!,
    retire_owner!

import PipeWireAORTC.DeploymentConfiguration

const S = PipeWireAORTC.MediaSession
const R = PipeWireAORTC.RunnerCodec
const C = PipeWireAORTC.ControlCodec
const Client = PipeWireAORTC.ControlClient
const Bootstrap = PipeWireAORTC.OwnerBootstrapCodec
const Acquisition = PipeWireAORTC.AcquisitionLifecycleCodec
const SPA = PipeWireAO.SPA

mutable struct Runtime{D}
    configuration::D
    declared_links::Vector{DeploymentConfiguration.LinkDeclaration}
    owners::Vector{S.AbstractOwner}
    sources::Vector{S.AbstractSource}
    parameters::Union{Nothing,S.AbstractOwner}
    controller::Union{Nothing,C.ControllerIdentity}
    ingress::S.Ingress.Gate{Clocks.CachedNanoClock}
    core_info::Union{Nothing,CoreInfo}
    client_id::UInt32
    objects::Dict{UInt32,S.Object}
    pids::Dict{UInt64,UInt32}
    captured::Dict{UInt64,Union{Nothing,S.CoreIdentity}}
    retirement_proofs::Dict{UInt64,Bool}
    graphs::Dict{String,UInt64}
    groups::Dict{String,S.Group}
    links::Vector{UInt32}
    bindings::Dict{UInt64,S.AbstractSource}
    snapshots::Dict{UInt64,S.SourceSnapshot}
    overrides::Dict{Tuple{UInt64,Symbol},S.SourceSnapshot}
    failures::Set{UInt64}
    trace::Vector{Tuple{Symbol,UInt64}}
    properties::Dict{String,Pod}
end

function snapshot(;
    running = false, completed = false, generation = UInt64(1), sequence = UInt64(0)
)
    S.SourceSnapshot(
        running,
        completed,
        generation,
        sequence,
        generation,
        sequence,
        S.SourceControlDetails(Int32(0), Int64(0), Int32(0)),
    )
end
function owner(handle, profile, pid, instance)
    S.Owner(
        profile,
        Client.Observation(profile, Int64(instance), UInt32(pid)),
        UInt64(handle),
        UInt32(pid),
        Int64(instance),
        false,
    )
end
function object!(
    runtime,
    handle,
    name,
    pid;
    instance = Int64(handle),
    profile = Client.CONTROLLER_PROFILE,
)
    id = UInt32(handle)
    serial = UInt64(1000) + UInt64(handle)
    properties = Dict(
        "object.serial" => string(serial),
        "node.name" => name,
        "pipewireao.rtc-control.protocol" => Client.PROTOCOL,
        "pipewireao.rtc-control.profile" => profile,
        "pipewireao.rtc-control.instance" => string(instance),
        "pipewireao.rtc-control.owner-pid" => string(pid),
    )
    info = NodeInfo(
        id,
        UInt32(0),
        UInt32(0),
        UInt64(31),
        UInt32(0),
        UInt32(0),
        PipeWireAO.NODE_STATE_IDLE,
        nothing,
        copy(properties),
        ParamInfo[],
    )
    runtime.objects[id] = S.Object{Nothing,NodeInfo}(
        id, serial, properties, nothing, info, false
    )
    runtime.pids[UInt64(id)] = UInt32(pid)
    return runtime.objects[id]
end
function Runtime()
    processing = Dict(
        "role" => "processing",
        "pid" => 2001,
        "bootstrap-node" => "processing-bootstrap",
        "bootstrap-instance" => "110",
    )
    plant = Dict{String,Union{String,Int}}(
        "role" => "plant",
        "pid" => 2002,
        "bootstrap-node" => "plant-bootstrap",
        "bootstrap-instance" => "120",
        "control-node" => "plant-source",
        "control-instance" => "121",
        "control-protocol" => Client.profile_name(Acquisition.CALIBRATION_PROFILE),
    )
    parameters = Dict{String,Union{String,Int}}(
        "role" => "parameters",
        "pid" => 2003,
        "control-node" => "parameters",
        "control-instance" => "131",
        "control-protocol" => Client.profile_name(PipeWireAORTC.ParameterSource.PROFILE),
    )
    camera = Dict{String,Union{String,Int}}(
        "role" => "camera",
        "pid" => 2004,
        "bootstrap-node" => "camera-bootstrap",
        "bootstrap-instance" => "140",
        "control-node" => "camera-source",
        "control-instance" => "141",
        "control-protocol" => S.SOURCE_CONTROL_PROFILE,
    )
    configuration = Dict{String,Any}(
        "owners" => [processing, plant, parameters, camera],
        "source" => plant,
        "auxiliary-sources" => [camera],
        "core.owner" => Dict("pid" => 9001),
        "controller.node.name" => "session-controller",
        "controller.instance" => "17",
        "session" => Dict(
            "links" => [
                Dict("output" => "upstream:out", "input" => "left:in"),
                Dict("output" => "upstream:out", "input" => "right:in"),
            ],
        ),
    )
    controller = C.ControllerIdentity(UInt32(7), UInt64(1007), Int64(17))
    core = CoreInfo(
        UInt32(0),
        UInt32(19),
        "user",
        "host",
        "version",
        "private-core",
        UInt64(1),
        Dict("application.process.id" => "9001"),
    )
    runtime = Runtime(
        configuration,
        DeploymentConfiguration.session_links(get(configuration, "session", Dict())),
        S.AbstractOwner[],
        S.AbstractSource[],
        nothing,
        controller,
        S.Ingress.Gate(17; clock = Clocks.CachedNanoClock(0)),
        core,
        UInt32(9),
        Dict{UInt32,S.Object}(),
        Dict{UInt64,UInt32}(),
        Dict{UInt64,Union{Nothing,S.CoreIdentity}}(),
        Dict{UInt64,Bool}(),
        Dict(
            "upstream" => UInt64(101),
            "left" => UInt64(102),
            "right" => UInt64(103),
            "independent" => UInt64(104),
        ),
        Dict(
            "science" => S.Group(
                ["upstream", "left", "right"], ["upstream", "left", "right"], false
            ),
            "observer" => S.Group(["independent"], ["independent"], false),
        ),
        UInt32[],
        Dict{UInt64,S.AbstractSource}(),
        Dict{UInt64,S.SourceSnapshot}(),
        Dict{Tuple{UInt64,Symbol},S.SourceSnapshot}(),
        Set{UInt64}(),
        Tuple{Symbol,UInt64}[],
        Dict{String,Pod}(),
    )
    controller_node = object!(runtime, 7, "session-controller", getpid(); instance = Int64(17))
    controller_node.global_properties["client.id"] = "9"
    client_properties = Dict(
        "application.process.id" => string(getpid()), "object.serial" => "1009"
    )
    client = ClientInfo(UInt32(9), UInt64(1), client_properties)
    runtime.objects[client.id] = S.Object{Nothing,ClientInfo}(
        client.id, UInt64(1009), client_properties, nothing, client, false
    )
    S.Ingress.controllers!(runtime.ingress, [S.controller_fact(runtime, controller_node)])
    object!(
        runtime,
        11,
        "processing-bootstrap",
        2001;
        instance = Int64(110),
        profile = Client.profile_name(Bootstrap.PROFILE),
    )
    object!(
        runtime,
        21,
        "plant-bootstrap",
        2002;
        instance = Int64(120),
        profile = Client.profile_name(Bootstrap.PROFILE),
    )
    object!(
        runtime,
        22,
        "plant-source",
        2002;
        instance = Int64(121),
        profile = Client.profile_name(Acquisition.CALIBRATION_PROFILE),
    )
    object!(
        runtime,
        31,
        "parameters",
        2003;
        instance = Int64(131),
        profile = Client.profile_name(PipeWireAORTC.ParameterSource.PROFILE),
    )
    object!(
        runtime,
        41,
        "camera-bootstrap",
        2004;
        instance = Int64(140),
        profile = Client.profile_name(Bootstrap.PROFILE),
    )
    object!(
        runtime,
        42,
        "camera-source",
        2004;
        instance = Int64(141),
        profile = S.SOURCE_CONTROL_PROFILE,
    )
    cursor = Acquisition.AcquisitionCursor(UInt64(1), UInt64(1), UInt64(0), UInt64(0))
    runtime.bindings[UInt64(22)] = S.AcquisitionBinding(
        owner(22, Acquisition.CALIBRATION_PROFILE, 2002, 121), Acquisition.Classic, cursor
    )
    runtime.bindings[UInt64(42)] = S.SourceControlBinding(
        UInt64(42), UInt32(2004), Int64(141), snapshot()
    )
    runtime.snapshots[UInt64(22)] = snapshot()
    runtime.snapshots[UInt64(42)] = snapshot()
    return runtime
end
job(origin = S.ReadyOrigin()) = (; ticket = (; origin, deadline = Int64(5_000_000_000)))
function await_condition!(condition, runtime::Runtime, job)
    value = condition()
    value === nothing && throw(ArgumentError("controlled observation is not ready"))
    return value
end
function node!(runtime::Runtime, job, name::AbstractString, pid::Integer)
    matches = [
        object for object in values(runtime.objects) if
        get(S.object_properties(object), "node.name", nothing) == name
    ]
    length(matches) == 1 || throw(ArgumentError("node is missing or ambiguous"))
    handle = UInt64(only(matches).id)
    runtime.pids[handle] == pid || throw(ArgumentError("node PID differs"))
    push!(runtime.trace, (:node, handle))
    return handle
end
find_object(runtime::Runtime, id::Integer) = get(runtime.objects, UInt32(id), nothing)
S.registry_serial(runtime::Runtime, id) = runtime.objects[UInt32(id)].serial
property(runtime::Runtime, handle::UInt64, key::AbstractString) =
    get(S.object_properties(runtime.objects[UInt32(handle)]), key, nothing)
function capture!(runtime::Runtime, handle::UInt64; core = nothing)
    if !haskey(runtime.captured, handle)
        runtime.captured[handle] = core
        push!(runtime.trace, (:capture, handle))
    end
    return nothing
end
function capture_owner(
    runtime::Runtime,
    handle::UInt64,
    profile::Client.AbstractProfile,
    instance::Integer,
    pid::Integer,
)
    capture!(runtime, handle)
    push!(runtime.trace, (:capture_owner, handle))
    return owner(handle, profile, pid, instance)
end
S.check_job(::Runtime, job::S.Job) =
    job.cancelled ? throw(S.Cancelled()) : nothing
connect_owner!(runtime::Runtime, job, owner::S.Owner) =
    (push!(runtime.trace, (:connect, owner.handle)); nothing)
struct FailingConnectRuntime
    owners::Vector{S.AbstractOwner}
    sibling_started::Channel{Nothing}
    sibling_joined::Ref{Bool}
    failure::ArgumentError
end

S.check_job(::FailingConnectRuntime, job::S.Job) =
    job.cancelled ? throw(S.Cancelled()) : nothing

function connect_owner!(runtime::FailingConnectRuntime, job, owner::S.Owner)
    if owner === first(runtime.owners)
        timedwait(() -> isready(runtime.sibling_started), 5) === :ok ||
            error("second owner did not begin Connect")
        take!(runtime.sibling_started)
        throw(runtime.failure)
    end
    put!(runtime.sibling_started, nothing)
    try
        timedwait(() -> job.cancelled, 5) === :ok ||
            error("second owner did not receive cancellation")
        S.check_job(runtime, job)
    finally
        runtime.sibling_joined[] = true
    end
end

@testset "Failed Connect retires an in-flight sibling before returning" begin
    owners = S.AbstractOwner[
        owner(11, Bootstrap.PROFILE, 2001, 111),
        owner(21, Bootstrap.PROFILE, 2002, 121),
    ]
    rejection = ArgumentError("first owner rejected Connect")
    runtime = FailingConnectRuntime(owners, Channel{Nothing}(1), Ref(false), rejection)
    ticket = S.EffectTicket(
        UInt64(1), UInt64(1), UInt64(1), UInt32(0), S.ConfiguringOrigin(),
        Int64(5_000_000_000), S.ConnectOwners(), nothing,
    )
    job = S.Job(ticket, false)
    failure = try
        S.perform!(runtime, job, S.ConnectOwners())
        nothing
    catch error
        error
    end
    @test failure === rejection
    @test job.cancelled
    @test runtime.sibling_joined[]
end

function shutdown_owner!(runtime::Runtime, job, owner::S.Owner)
    push!(runtime.trace, (:shutdown_owner, owner.handle))
    owner.retired = true
    return nothing
end
function retire_owner!(quit::Function, runtime::Runtime, owner::S.Owner{Bootstrap.Profile})
    quit()
    owner.retired || error("retirement requires terminal acknowledgement")
    runtime.retirement_proofs[owner.handle] = owner.retired
    push!(runtime.trace, (:retire_owner, owner.handle))
    return nothing
end
source(runtime::Runtime, handle::UInt64, declaration) =
    (push!(runtime.trace, (:capture_source, handle)); runtime.bindings[handle])
handle(binding::S.AcquisitionBinding) = binding.owner.handle
handle(binding::S.SourceControlBinding) = binding.handle
prepare_source!(runtime::Runtime, job, binding::S.AcquisitionBinding) =
    (push!(runtime.trace, (:prepare, handle(binding))); runtime.snapshots[handle(binding)])
prepare_source!(runtime::Runtime, job, binding::S.SourceControlBinding) =
    (push!(runtime.trace, (:prepare, handle(binding))); runtime.snapshots[handle(binding)])
set_previous!(binding::S.AcquisitionBinding, value) = (
    binding.previous = Acquisition.AcquisitionCursor(
        UInt64(1), value.generation, value.sequence, UInt64(0)
    );
    nothing
)
set_previous!(binding::S.SourceControlBinding, value) = (binding.previous = value; nothing)
function source_operation!(
    runtime::Runtime, job, binding::S.AcquisitionBinding, kind::Symbol; running = false
)
    return operation!(runtime, binding, kind, running)
end
function source_operation!(
    runtime::Runtime, job, binding::S.SourceControlBinding, kind::Symbol; running = false
)
    return operation!(runtime, binding, kind, running)
end
function operation!(runtime, binding, kind, running)
    id = handle(binding)
    push!(runtime.trace, (kind === :run ? (running ? :release : :hold) : kind, id))
    before = runtime.snapshots[id]
    value = get(runtime.overrides, (id, kind), nothing)
    if value === nothing
        value = if kind === :query
            before
        elseif kind === :reset
            snapshot(; generation = before.generation + UInt64(1))
        else
            snapshot(; running, generation = before.generation, sequence = before.sequence)
        end
    end
    runtime.snapshots[id] = value
    set_previous!(binding, value)
    return value
end
function shutdown_source!(runtime::Runtime, job, binding::S.AcquisitionBinding)
    push!(runtime.trace, (:shutdown_source, handle(binding)))
    binding.owner.retired = true
    return snapshot()
end
shutdown_source!(runtime::Runtime, job, binding::S.SourceControlBinding) = nothing
function node_operation!(
    runtime::Runtime, job, handle::UInt64, kind::Symbol, argument = nothing
)
    push!(
        runtime.trace,
        (kind === :run ? (argument ? :run_graph : :hold_graph) : :reset_graph, handle),
    )
    handle in runtime.failures && throw(ArgumentError("controlled graph failure"))
    return nothing
end
discover_graphs!(runtime::Runtime, job) =
    (push!(runtime.trace, (:discover, UInt64(0))); nothing)
create_links!(runtime::Runtime, job) = (
    push!(runtime.trace, (:connect_links, UInt64(0)));
    push!(runtime.links, UInt32(50));
    nothing
)
remove_links!(runtime::Runtime, job) =
    (push!(runtime.trace, (:withdraw_links, UInt64(0))); empty!(runtime.links); nothing)
named_properties!(runtime::Runtime, job, handle) =
    (push!(runtime.trace, (:properties, handle)); copy(runtime.properties))
update_properties!(runtime::Runtime, job, ::S.ReadyOrigin, payload::Tuple) =
    (push!(runtime.trace, (:update_ready, UInt64(0))); SPA.Struct(Pod[Pod("updated")]))
update_properties!(runtime::Runtime, job, ::S.RunningOrigin, payload::Tuple) =
    (push!(runtime.trace, (:update_running, UInt64(0))); SPA.Struct(Pod[Pod("updated")]))
submit_parameter!(runtime::Runtime, job, payload::Tuple) =
    (push!(runtime.trace, (:parameter, UInt64(0))); SPA.Struct(Pod[Pod("submitted")]))

function capture_sources!(runtime)
    S.perform!(runtime, job(S.ConfiguringOrigin()), S.CaptureSources())
    empty!(runtime.trace)
    return runtime
end
function decode_details(operation, details; state = R.Ready)
    header = C.ReplyHeader(
        C.ControllerIdentity(UInt32(7), UInt64(17), Int64(27)),
        Int64(31),
        Int64(1),
        operation,
        Int32(0),
    )
    outcome =
        operation in (S.STOP_GROUP_OPERATION, S.START_GROUP_OPERATION) ? R.Requested :
        R.Observed
    payload = SPA.Struct(
        Pod[Pod(SPA.Id(UInt32(state))), Pod(SPA.Id(UInt32(outcome))), Pod(details)]
    )
    return R.decode_completion(C.encode_completion(header, payload; endpoint = :lifecycle)).result
end

@testset "Exact controller and declared bootstrap admission" begin
    runtime = Runtime()
    S.perform!(runtime, job(S.ConfiguringOrigin()), S.CaptureOwners())
    @test [owner.handle for owner in runtime.owners] == UInt64[11, 21, 41]
    @test all(
        value -> value == S.CoreIdentity(UInt32(9001), UInt32(19), "private-core"),
        values(runtime.captured),
    )
    empty!(runtime.trace)
    ticket = S.EffectTicket(
        UInt64(1), UInt64(1), UInt64(1), UInt32(0), S.ConfiguringOrigin(),
        Int64(5_000_000_000), S.ConnectOwners(), nothing
    )
    S.perform!(runtime, S.Job(ticket, false), S.ConnectOwners())
    @test runtime.trace ==
        [(:connect, UInt64(11)), (:connect, UInt64(21)), (:connect, UInt64(41))]
    @test_throws ArgumentError S.perform!(runtime, job(), S.CaptureOwners())
    runtime = Runtime()
    runtime.controller = C.ControllerIdentity(UInt32(7), UInt64(1008), Int64(17))
    @test_throws ArgumentError S.perform!(runtime, job(), S.CaptureOwners())
    @test isempty(runtime.owners)
    runtime = Runtime()
    runtime.objects[UInt32(9)].removed = true
    @test_throws ArgumentError S.perform!(runtime, job(), S.CaptureOwners())
    @test isempty(runtime.captured)
    runtime = Runtime()
    # The same observations can return after an incarnation has lost authority.
    fact = S.controller_fact(runtime, runtime.objects[UInt32(7)])
    S.Ingress.controllers!(runtime.ingress, S.Ingress.Controller[])
    S.Ingress.controllers!(runtime.ingress, [fact])
    @test_throws ArgumentError S.perform!(runtime, job(), S.CaptureOwners())
    @test isempty(runtime.captured)
    runtime = Runtime()
    runtime.client_id = UInt32(0)
    @test_throws ArgumentError S.perform!(runtime, job(), S.CaptureOwners())
    @test isempty(runtime.captured)
    runtime = Runtime()
    runtime.configuration["core.owner"]["pid"] = 9002
    @test_throws ArgumentError S.perform!(runtime, job(), S.CaptureOwners())
    runtime = Runtime()
    object = runtime.objects[UInt32(7)]
    before = object.info
    object.info = NodeInfo(
        before.id,
        before.max_input_ports,
        before.max_output_ports,
        UInt64(0),
        before.n_input_ports,
        before.n_output_ports,
        before.state,
        before.error,
        before.properties,
        before.params,
    )
    @test_throws ArgumentError S.perform!(runtime, job(), S.CaptureOwners())
    @test isempty(runtime.owners) && isempty(runtime.captured)
end

@testset "Quit retires independent graph owners ahead of Link withdrawal" begin
    runtime = Runtime()
    runtime.configuration["node.pids"] = Dict(
        "upstream" => 2002, "left" => 2001, "right" => 2001, "independent" => 2004
    )
    S.perform!(runtime, job(), S.CaptureOwners())
    capture_sources!(runtime)
    empty!(runtime.trace)
    S.perform!(runtime, job(), S.ShutdownGraphOwners())
    S.perform!(runtime, job(), S.WithdrawLinks())
    S.perform!(runtime, job(), S.ShutdownSources())
    S.perform!(runtime, job(), S.ShutdownOwners())
    @test runtime.trace == [
        (:shutdown_owner, UInt64(11)),
        (:retire_owner, UInt64(11)),
        (:withdraw_links, UInt64(0)),
        (:shutdown_source, UInt64(22)),
        (:shutdown_owner, UInt64(21)),
        (:retire_owner, UInt64(21)),
        (:shutdown_owner, UInt64(41)),
        (:retire_owner, UInt64(41)),
    ]
end

S.available_bootstrap!(runtime::Runtime, job, name, pid, instance) =
    node!(runtime, job, name, pid)

@testset "Persistent graph retirement requires this session's Connect acknowledgement" begin
    runtime = Runtime()
    runtime.configuration["node.pids"] = Dict("left" => 2001)
    # Runtime uses narrowed dictionaries for its ordinary owner fixtures.
    runtime.configuration["owners"] = [Dict{String,Any}(d) for d in runtime.configuration["owners"]]
    runtime.configuration["owners"][1]["persistent"] = true
    S.perform!(runtime, job(), S.CaptureOwners())
    empty!(runtime.trace)
    S.perform!(runtime, job(), S.ShutdownGraphOwners())
    S.perform!(runtime, job(), S.ShutdownOwners())
    @test (:shutdown_owner, UInt64(11)) ∉ runtime.trace
    @test !runtime.owners[1].retired

    runtime = Runtime()
    runtime.configuration["node.pids"] = Dict("left" => 2001)
    runtime.configuration["owners"] = [Dict{String,Any}(d) for d in runtime.configuration["owners"]]
    runtime.configuration["owners"][1]["persistent"] = true
    S.perform!(runtime, job(), S.CaptureOwners())
    ticket = S.EffectTicket(UInt64(1), UInt64(1), UInt64(1), UInt32(0),
        S.ConfiguringOrigin(), Int64(5_000_000_000), S.ConnectOwners(), nothing)
    S.perform!(runtime, S.Job(ticket, false), S.ConnectOwners())
    empty!(runtime.trace)
    S.perform!(runtime, job(), S.ShutdownGraphOwners())
    @test (:shutdown_owner, UInt64(11)) in runtime.trace
    @test runtime.owners[1].retired
end

function S.publish_parameter_source!(runtime::Runtime, _job, _handle, properties)
    push!(runtime.trace, (
        :parameter_source_id, parse(UInt64, properties["pipewireao.rtc-control.parameter-source.id"]),
    ))
    push!(runtime.trace, (
        :parameter_source_serial, parse(UInt64, properties["pipewireao.rtc-control.parameter-source.serial"]),
    ))
    return nothing
end

@testset "Publisher and source capture are bounded and do not duplicate bootstrap shutdown" begin
    runtime = Runtime()
    S.perform!(runtime, job(), S.CaptureOwners())
    S.perform!(runtime, job(), S.CaptureParameters())
    @test runtime.parameters.handle == 31
    @test runtime.trace[end-1:end] == [
        (:parameter_source_id, UInt64(31)),
        (:parameter_source_serial, runtime.objects[UInt32(31)].serial),
    ]
    empty!(runtime.trace)
    capture_sources!(runtime)
    @test handle.(runtime.sources) == UInt64[22, 42]
    S.perform!(runtime, job(), S.PrepareSources())
    @test runtime.trace == [(:prepare, UInt64(22)), (:prepare, UInt64(42))]
    empty!(runtime.trace)
    S.perform!(runtime, job(), S.ShutdownSources())
    S.perform!(runtime, job(), S.ShutdownOwners())
    @test runtime.trace == [
        (:shutdown_source, UInt64(22)),
        (:shutdown_owner, UInt64(21)),
        (:retire_owner, UInt64(21)),
        (:shutdown_owner, UInt64(11)),
        (:retire_owner, UInt64(11)),
        (:shutdown_owner, UInt64(41)),
        (:retire_owner, UInt64(41)),
    ]
    @test runtime.retirement_proofs ==
        Dict(UInt64(11) => true, UInt64(21) => true, UInt64(41) => true)
    empty!(runtime.trace)
    delete!(runtime.objects, UInt32(21))
    delete!(runtime.objects, UInt32(11))
    delete!(runtime.objects, UInt32(41))
    S.perform!(runtime, job(S.FaultOrigin()), S.ShutdownSources())
    S.perform!(runtime, job(S.FaultOrigin()), S.ShutdownOwners())
    @test isempty(runtime.trace)
    runtime = Runtime()
    push!(runtime.configuration["owners"], copy(runtime.configuration["owners"][3]))
    @test_throws ArgumentError S.perform!(runtime, job(), S.CaptureParameters())
    @test runtime.parameters === nothing
    runtime = Runtime()
    runtime.configuration["auxiliary-sources"][1]["role"] = "plant"
    @test_throws ArgumentError S.perform!(runtime, job(), S.CaptureSources())
    @test isempty(runtime.sources) && isempty(runtime.trace)
end

function external_stream_runtime()
    runtime = Runtime()
    configuration = runtime.configuration
    configuration["source"] = Dict("role" => "plant", "pid" => 2002,
        "control-protocol" => "external-stream")
    configuration["auxiliary-sources"] = []
    filter!(owner -> owner["role"] != "plant", configuration["owners"])
    configuration["node.pids"] = Dict("pupil" => 2002)
    configuration["session"] = Dict("sources" => [
        Dict("node.name" => "pupil", "ownership" => "external",
            "ports" => [Dict("name" => "out", "direction" => "output")]),
    ])
    empty!(runtime.declared_links)
    push!(runtime.declared_links, DeploymentConfiguration.link_declaration(
        Dict("output" => "pupil:out", "input" => "upstream:in"),
    ))
    return runtime
end

struct ExternalLinkRuntime{D,L}
    configuration::D
    links::Vector{L}
    captured::Set{UInt64}
end
function S.assert_identity!(runtime::ExternalLinkRuntime, id::UInt64)
    id in runtime.captured || throw(ArgumentError("required object is absent"))
    return nothing
end

@testset "External stream validation and lifecycle scope" begin
    runtime = external_stream_runtime()
    configuration = runtime.configuration
    @test S.validate_external_stream(configuration, runtime.declared_links) === nothing
    push!(configuration["owners"], configuration["source"])
    @test S.validate_external_stream(configuration, runtime.declared_links) === nothing
    for effect in (S.CaptureSources(), S.PrepareSources(), S.HoldSources(), S.RunSources(),
            S.ResetSources(), S.ShutdownSources())
        @test S.perform!(runtime, job(), effect) === nothing
    end
    @test isempty(runtime.sources) && isempty(runtime.trace)
    @test_throws ArgumentError S.perform!(runtime, job(), S.QuerySourceEnd())
    @test_throws ArgumentError S.perform!(runtime, job(), S.QueryStatus())

    output = (node = 10, port = 11, parent = 12)
    input = (node = 20, port = 21, parent = 22)
    linked = ExternalLinkRuntime(configuration, [(; output, input, failure = nothing)],
        Set{UInt64}((10, 11, 12, 20, 21, 22)))
    for (origin, state) in ((S.ReadyOrigin(), R.Ready), (S.RunningOrigin(), R.Running))
        details = S.perform!(linked, job(origin), S.QueryStatus())
        status = decode_details(S.STATUS_OPERATION, details; state)
        @test status.details.running == (state == R.Running)
        @test status.details.owned_links == 1
    end
    delete!(linked.captured, 11)
    @test_throws ArgumentError S.perform!(linked, job(), S.QueryStatus())

    links = runtime.declared_links
    @test_throws ArgumentError S.validate_external_stream(configuration, empty(links))
    for change! in (
        cfg -> cfg["source"]["pid"] = true,
        cfg -> cfg["source"]["control-instance"] = "99",
        cfg -> cfg["owners"][2]["pid"] = 2002,
        cfg -> cfg["owners"][end]["bootstrap-node"] = "plant-bootstrap",
        cfg -> cfg["core.owner"]["pid"] = 2002,
        cfg -> cfg["node.pids"]["pupil"] = 1000,
        cfg -> cfg["session"]["sources"][1]["ownership"] = "runner",
        cfg -> cfg["session"]["sources"][1]["ports"][1]["direction"] = "input",
        cfg -> push!(cfg["auxiliary-sources"], cfg["source"]),
    )
        invalid = deepcopy(configuration)
        change!(invalid)
        @test_throws ArgumentError S.validate_external_stream(invalid, links)
    end
end

@testset "Source chronology requires held and reset proofs" begin
    runtime = capture_sources!(Runtime())
    S.perform!(runtime, job(S.ConfiguringOrigin()), S.HoldSources())
    @test runtime.trace == [(:hold, UInt64(22)), (:hold, UInt64(42))]
    empty!(runtime.trace)
    S.perform!(runtime, job(S.ReadyOrigin()), S.RunSources())
    @test runtime.trace == [(:release, UInt64(42)), (:release, UInt64(22))]
    empty!(runtime.trace)
    S.perform!(runtime, job(S.RunningOrigin()), S.HoldSources())
    S.perform!(runtime, job(), S.ResetSources())
    @test runtime.trace == [
        (:hold, UInt64(22)), (:hold, UInt64(42)), (:reset, UInt64(22)), (:reset, UInt64(42))
    ]
    @test all(binding -> S._source_generation(binding) == UInt64(2), runtime.sources)
    runtime.overrides[(UInt64(22), :reset)] = snapshot(; generation = UInt64(2))
    empty!(runtime.trace)
    @test_throws ArgumentError S.perform!(runtime, job(), S.ResetSources())
    @test runtime.trace == [(:reset, UInt64(22))]
    runtime = capture_sources!(Runtime())
    runtime.overrides[(UInt64(22), :run)] = snapshot(; sequence = UInt64(1))
    @test_throws ArgumentError S.perform!(
        runtime, job(S.ConfiguringOrigin()), S.HoldSources()
    )
    @test runtime.trace == [(:hold, UInt64(22))]
    runtime = capture_sources!(Runtime())
    runtime.bindings[UInt64(22)].owner.retired = true
    S.perform!(runtime, job(S.FaultOrigin()), S.HoldSources())
    @test runtime.trace == [(:hold, UInt64(42))]
    @test_throws ArgumentError S.perform!(runtime, job(), S.RunSources())
end

@testset "Graph dependencies, selective groups and fault compensation" begin
    runtime = Runtime()
    S.perform!(runtime, job(), S.RunGraphs())
    @test runtime.trace == [
        (:run_graph, UInt64(104)),
        (:run_graph, UInt64(102)),
        (:run_graph, UInt64(103)),
        (:run_graph, UInt64(101)),
    ]
    @test all(group -> group.running, values(runtime.groups))
    empty!(runtime.trace)
    details = S.perform!(runtime, job(S.RunningOrigin()), S.RunGraphs("science", false))
    @test runtime.trace == [
        (:hold_graph, UInt64(101)), (:hold_graph, UInt64(102)), (:hold_graph, UInt64(103))
    ]
    @test !runtime.groups["science"].running && runtime.groups["observer"].running
    result = decode_details(S.STOP_GROUP_OPERATION, details; state = R.Running)
    @test result.details.group == "science" && result.details.observed == R.Stopped
    empty!(runtime.trace)
    push!(runtime.failures, UInt64(101))
    @test_throws ArgumentError S.perform!(runtime, job(S.RunningOrigin()), S.HoldGraphs())
    @test runtime.trace == [(:hold_graph, UInt64(101))]
    empty!(runtime.trace)
    @test_throws ArgumentError S.perform!(runtime, job(S.FaultOrigin()), S.HoldGraphs())
    @test runtime.trace == [
        (:hold_graph, UInt64(101)),
        (:hold_graph, UInt64(104)),
        (:hold_graph, UInt64(102)),
        (:hold_graph, UInt64(103)),
    ]
    @test runtime.groups["observer"].running
    empty!(runtime.trace)
    empty!(runtime.failures)
    S.perform!(runtime, job(), S.ResetGraphs())
    @test runtime.trace == [
        (:reset_graph, UInt64(104)),
        (:reset_graph, UInt64(102)),
        (:reset_graph, UInt64(103)),
        (:reset_graph, UInt64(101)),
    ]
    empty!(runtime.trace)
    @test_throws ArgumentError S.perform!(runtime, job(), S.RunGraphs("missing"))
    @test isempty(runtime.trace)
    push!(
        runtime.declared_links,
        DeploymentConfiguration.link_declaration(
            Dict("output" => "right:out", "input" => "upstream:in")
        ),
    )
    @test_throws ArgumentError S.perform!(runtime, job(), S.RunGraphs())
    @test isempty(runtime.trace)
end

@testset "Installed admission checks every managed source is held" begin
    runtime = capture_sources!(Runtime())
    details = S.perform!(runtime, job(S.ReadyOrigin()), S.CheckHeldStatus())
    @test !decode_details(S.STATUS_OPERATION, details).details.running
    for handle in UInt64[22, 42]
        runtime.snapshots[handle] = snapshot(; running = true)
        @test_throws "source is running" S.perform!(runtime, job(S.ReadyOrigin()), S.CheckHeldStatus())
        runtime.snapshots[handle] = snapshot(; running = false)
    end
end

@testset "Wire observations and public property adapters" begin
    runtime = capture_sources!(Runtime())
    push!(runtime.links, UInt32(50))
    details = S.groups_details(runtime)
    @test decode_details(S.GROUPS_OPERATION, details).details.groups ==
        Dict("science" => R.Stopped, "observer" => R.Stopped)
    @test decode_details(S.STATUS_OPERATION, S.status_details(runtime; running = false)).details.owned_links ==
        1
    runtime.snapshots[UInt64(22)] = snapshot(; running = true)
    runtime.snapshots[UInt64(42)] = snapshot(; running = true)
    result = decode_details(
        S.STATUS_OPERATION,
        S.perform!(runtime, job(S.RunningOrigin()), S.QueryStatus());
        state = R.Running,
    )
    @test result.details.running &&
        result.details.owned_nodes == 0 &&
        isempty(result.details.discarded_by_sink)
    @test runtime.trace == [(:query, UInt64(22)), (:query, UInt64(42))]
    runtime.snapshots[UInt64(22)] = snapshot(; completed = true, sequence = UInt64(3))
    evidence = S.perform!(runtime, job(S.RunningOrigin()), S.QuerySourceEnd())
    @test evidence === S.SourceEnd(true, false)
    runtime.overrides[(UInt64(22), :query)] = snapshot(; generation = UInt64(0))
    @test_throws ArgumentError S.perform!(runtime, job(S.RunningOrigin()), S.QueryStatus())
    runtime.properties = Dict(
        "controller:gain" => Pod(Float32(0.2)),
        "controller:requested-generation" => Pod(Int64(2)),
        "controller:active-generation" => Pod(nothing),
        "controller:requested-parameter-sequence" => Pod(Int64(3)),
        "controller:active-parameter-sequence" => Pod(Int64(3)),
        "not-scalar" => Pod(SPA.Struct(Pod[])),
    )
    result = decode_details(
        S.PROPERTIES_OPERATION, S.perform!(runtime, job(), S.QueryProperties(("left",)))
    )
    @test length(result.details.properties) == 4 &&
        !haskey(result.details.properties, "not-scalar")
    result = decode_details(
        S.PROPERTY_GENERATION_OPERATION,
        S.perform!(runtime, job(), S.QueryPropertyGeneration(("left", "controller"))),
    )
    @test result.details.requested == 2 && result.details.active === nothing
    result = decode_details(
        S.PARAMETER_GENERATION_OPERATION,
        S.perform!(runtime, job(), S.QueryParameterGeneration(("left", "controller"))),
    )
    @test result.details.requested == 3 && result.details.active == 3
    runtime.properties["controller:active-parameter-sequence"] = Pod(nothing)
    @test_throws ArgumentError S.perform!(
        runtime, job(), S.QueryParameterGeneration(("left", "controller"))
    )
    @test_throws ArgumentError S.perform!(
        runtime, job(), S.QueryProperties(("left", "unexpected"))
    )
    @test_throws ArgumentError S.perform!(
        runtime, job(), S.QueryPropertyGeneration(("left",))
    )
    @test S.perform!(
        runtime, job(), S.UpdateProperties(("left", Dict{String,R.RunnerScalar}()))
    ).values == Pod[Pod("updated")]
    @test last(runtime.trace) == (:update_ready, UInt64(0))
    @test S.perform!(
        runtime,
        job(S.RunningOrigin()),
        S.UpdateProperties(("left", Dict{String,R.RunnerScalar}())),
    ).values == Pod[Pod("updated")]
    @test last(runtime.trace) == (:update_running, UInt64(0))
    @test S.perform!(runtime, job(), S.SubmitParameter(("left", "matrix"))).values ==
        Pod[Pod("submitted")]
    empty!(runtime.trace)
    S.perform!(runtime, job(), S.DiscoverGraphs())
    S.perform!(runtime, job(), S.ConnectLinks())
    S.perform!(runtime, job(), S.WithdrawLinks())
    @test runtime.trace == [
        (:discover, UInt64(0)), (:connect_links, UInt64(0)), (:withdraw_links, UInt64(0))
    ]
end
end
