using Test, PipeWireAO, PipeWireAORTC

module MediaSessionObjectsTests
using Test, PipeWireAO
import Clocks
import PipeWireAORTC.MediaSession: policy_id, policy_text, Owner
import PipeWireAORTC:
    OwnerBootstrapCodec, ControlClient, AcquisitionLifecycleCodec, DeploymentConfiguration
const PolicySPA = PipeWireAO.SPA
const PolicyPod = PipeWireAO.Pod
const SECOND = Int64(1_000_000_000)
const CLOCK = Clocks.SystemNanoClock()
abstract type AbstractEvent end
mutable struct Machine
    losses::Vector{String}
end
required_lost!(machine::Machine, message) = push!(machine.losses, String(message))
stage!(queue::Vector{AbstractEvent}, event::AbstractEvent) =
    (length(queue) < 256 || error("test event queue full"); push!(queue, event); nothing)
struct ParameterReceived <: AbstractEvent
    object::UInt32
    sequence::Cint
    parameter::UInt32
    pod::Union{Nothing,Pod}
end
param_callback(queue, id) =
    (_, sequence, param, index, next, pod)->stage!(
        queue,
        ParameterReceived(id, sequence, param, pod),
    )
parameter_error!(runtime, id, sequence, message) = false
include(joinpath(@__DIR__, "..", "src", "media_session", "objects.jl"))

mutable struct TestProxy
    closed::Bool
end
Base.close(proxy::TestProxy) = (proxy.closed = true; nothing)
mutable struct TestRuntime{C,R,L,F}
    core::C
    registry::R
    loop::L
    configuration::F
    objects::Dict{UInt32,Object}
    captured::Dict{UInt32,Captured}
    retired::Dict{UInt32,UInt64}
    graphs::Dict{String,UInt64}
    groups::Dict{String,Group}
    links::Vector{LinkRecord}
    queue::Vector{AbstractEvent}
    machine::Machine
    core_info::Union{Nothing,CoreInfo}
    client_id::UInt32
    withdrawing::Bool
    done::Set{Cint}
    cancel_creation::Bool
end
function TestRuntime(
    core = nothing,
    registry = nothing,
    loop = nothing;
    configuration = Dict{String,String}(),
    queue = AbstractEvent[],
)
    return TestRuntime(
        core,
        registry,
        loop,
        configuration,
        Dict{UInt32,Object}(),
        Dict{UInt32,Captured}(),
        Dict{UInt32,UInt64}(),
        Dict{String,UInt64}(),
        Dict{String,Group}(),
        LinkRecord[],
        queue,
        Machine(String[]),
        nothing,
        UInt32(0),
        false,
        Set{Cint}(),
        false,
    )
end
const SPA = PolicySPA
const CONTRACT = PortContract(
    "F32_LE",
    Int32[2],
    "org.pipewireao.test.media-session/1",
    "ROW_MAJOR",
    SPA.Fraction(100, 1),
)
const FORMAT = NdArrayFormat(
    NdArray.F32_LE,
    (2,);
    layout = NdArray.ROW_MAJOR,
    rate = SPA.Fraction(100, 1),
)
native_format() = ndarray_format(FORMAT; schema = CONTRACT.schema)
function link_record(sequence = UInt64(1))
    output = Endpoint(UInt32(11), UInt32(12), UInt32(10), CONTRACT)
    input = Endpoint(UInt32(21), UInt32(22), UInt32(20), CONTRACT)
    return LinkRecord(
        sequence,
        "pipewireao/session/test/1",
        output,
        input,
        false,
        nothing,
        nothing,
        nothing,
        nothing,
        nothing,
        false,
        true,
        false,
        false,
        false,
        nothing,
    )
end
function link_info(
    record;
    id = UInt32(31),
    state = PipeWireAO.LINK_STATE_PAUSED,
    format = native_format(),
    mask = UInt64(7),
)
    properties = Dict(
        "client.id"=>"7",
        "object.path"=>record.path,
        "object.linger"=>"false",
        "link.passive"=>"false",
    )
    return LinkInfo(
        id,
        record.output.node,
        record.output.port,
        record.input.node,
        record.input.port,
        mask,
        state,
        nothing,
        format,
        properties,
    )
end

@testset "Exact ndarray Format contract and selected fixed choices" begin
    @test validate_format(native_format(), CONTRACT) === nothing
    @test_throws ArgumentError validate_format(
        native_format(),
        PortContract("F64_LE", Int32[2], CONTRACT.schema, "ROW_MAJOR", CONTRACT.rate),
    )
    @test_throws ArgumentError validate_format(
        native_format(),
        PortContract("F32_LE", Int32[3], CONTRACT.schema, "ROW_MAJOR", CONTRACT.rate),
    )
    @test_throws ArgumentError validate_format(
        native_format(),
        PortContract("F32_LE", Int32[2], "different/1", "ROW_MAJOR", CONTRACT.rate),
    )
    @test_throws ArgumentError validate_format(
        native_format(),
        PortContract("F32_LE", Int32[2], CONTRACT.schema, "COLUMN_MAJOR", CONTRACT.rate),
    )
    @test_throws ArgumentError validate_format(
        native_format(),
        PortContract(
            "F32_LE",
            Int32[2],
            CONTRACT.schema,
            "ROW_MAJOR",
            SPA.Fraction(101, 1),
        ),
    )
    @test validate_format(
        native_format(),
        PortContract(
            "F32_LE",
            Int32[2],
            CONTRACT.schema,
            "ROW_MAJOR",
            SPA.Fraction(200, 2),
        ),
    ) === nothing
    object = pod_value(SPA.Object, native_format())
    properties = copy(object.properties)
    duplicate = Pod(
        SPA.Parameter(
            SPA.Object(object.type, object.id, vcat(properties, properties[1:1])),
        ),
    )
    @test_throws ArgumentError validate_format(duplicate, CONTRACT)
    index = findfirst(property->property.key == SPA.FORMAT_NDARRAY_ELEMENT_TYPE, properties)
    choices = Pod(
        SPA.Choice(
            SPA.CHOICE_ENUM,
            [SPA.Id(UInt32(NdArray.F32_LE)), SPA.Id(UInt32(NdArray.F64_LE))],
        ),
    )
    properties[index] = SPA.Property(SPA.FORMAT_NDARRAY_ELEMENT_TYPE, choices)
    @test_throws ArgumentError validate_format(
        Pod(SPA.Parameter(SPA.Object(object.type, object.id, properties))),
        CONTRACT,
    )
    # Wire fixed None can retain alternatives. Only its complete default is
    # selected; the original native record remains byte-for-byte unchanged.
    choices.data[9:12] .= reinterpret(UInt8, UInt32[UInt32(SPA.CHOICE_NONE)])
    properties[index] = SPA.Property(SPA.FORMAT_NDARRAY_ELEMENT_TYPE, choices)
    fixed = Pod(SPA.Parameter(SPA.Object(object.type, object.id, properties)))
    before = copy(fixed.data)
    @test validate_format(fixed, CONTRACT) === nothing
    @test fixed.data == before
end

@testset "Owned sparse object updates preserve identity and detect deletion" begin
    runtime = TestRuntime()
    properties = Dict(
        "object.serial"=>"18446744073709551614",
        "node.name"=>"science",
        "client.id"=>"10",
    )
    info = NodeInfo(
        UInt32(11),
        UInt32(1),
        UInt32(1),
        UInt64(31),
        UInt32(1),
        UInt32(1),
        PipeWireAO.NODE_STATE_IDLE,
        nothing,
        copy(properties),
        ParamInfo[],
    )
    object = Object{TestProxy,NodeInfo}(
        UInt32(11),
        UInt64(18446744073709551614),
        copy(properties),
        TestProxy(false),
        info,
        false,
    )
    runtime.objects[object.id] = object
    capture!(runtime, UInt64(11))
    @test assert_identity!(runtime, UInt64(11)) === nothing
    state = NodeInfo(
        UInt32(11),
        UInt32(1),
        UInt32(1),
        PipeWireAO.NODE_CHANGE_STATE,
        UInt32(0),
        UInt32(0),
        PipeWireAO.NODE_STATE_RUNNING,
        nothing,
        Dict{String,String}(),
        ParamInfo[],
    )
    update!(runtime, ObjectUpdated(UInt32(11), object.serial, state))
    @test object.info.n_input_ports == 1 && object.info.n_output_ports == 1
    @test object.info.properties == properties && isempty(runtime.machine.losses)
    removed = copy(properties)
    delete!(removed, "client.id")
    changed = NodeInfo(
        UInt32(11),
        UInt32(1),
        UInt32(1),
        PipeWireAO.NODE_CHANGE_PROPERTIES,
        UInt32(0),
        UInt32(0),
        PipeWireAO.NODE_STATE_CREATING,
        nothing,
        removed,
        ParamInfo[],
    )
    update!(runtime, ObjectUpdated(UInt32(11), object.serial, changed))
    @test !isempty(runtime.machine.losses)
    @test_throws ArgumentError assert_identity!(runtime, UInt64(11))
    @test property(runtime, UInt64(11), "client.id") == "10" # global fallback cannot conceal native deletion
    stale = ObjectUpdated(UInt32(11), UInt64(123), state)
    before = object.info
    update!(runtime, stale)
    @test object.info === before
    remove_object!(runtime, UInt32(11))
    @test object.proxy.closed && find_object(runtime, 11) === nothing
    @test isempty(runtime.captured)
    runtime.objects[object.id] = object
    object.removed = false
    update!(runtime, ObjectError(object.id, object.serial, "binding failed before capture"))
    @test object.removed
    @test_throws ArgumentError find_object(runtime, "science", getpid())
end

@testset "Every Link event is validated; bad then good cannot erase failure" begin
    runtime = TestRuntime()
    runtime.client_id=UInt32(7)
    record = link_record()
    push!(runtime.links, record)
    bad = link_info(
        record;
        format = ndarray_format(
            NdArrayFormat(
                NdArray.F32_LE,
                (3,);
                layout = NdArray.ROW_MAJOR,
                rate = SPA.Fraction(100, 1),
            );
            schema = CONTRACT.schema,
        ),
    )
    update!(runtime, LinkUpdated(record.sequence, bad))
    @test record.failure !== nothing && !isempty(runtime.machine.losses)
    first = record.failure
    update!(runtime, LinkUpdated(record.sequence, link_info(record)))
    @test record.failure == first
    record = link_record(UInt64(2))
    push!(runtime.links, record)
    update!(runtime, LinkUpdated(record.sequence, link_info(record)))
    @test record.negotiated && record.failure === nothing
    update!(
        runtime,
        LinkUpdated(
            record.sequence,
            link_info(
                record;
                state = PipeWireAO.LINK_STATE_NEGOTIATING,
                mask = PipeWireAO.LINK_CHANGE_STATE,
            ),
        ),
    )
    @test record.failure !== nothing
    record.retiring = true
    update!(runtime, LinkDestroyed(record.sequence))
    @test record.destroyed && !record.pending
    before = length(runtime.machine.losses)
    update!(runtime, LinkDestroyed(UInt64(999)))
    @test length(runtime.machine.losses) == before
end

@testset "Bound and observed Link IDs agree in both callback orders" begin
    runtime = TestRuntime()
    runtime.client_id=UInt32(7)
    record = link_record()
    push!(runtime.links, record)
    update!(runtime, LinkBound(record.sequence, UInt32(31)))
    update!(runtime, LinkUpdated(record.sequence, link_info(record; id = UInt32(32))))
    @test record.failure !== nothing && !record.negotiated
    @test record.info === nothing
    failure = record.failure
    update!(runtime, LinkUpdated(record.sequence, link_info(record)))
    @test record.failure === failure

    record = link_record(UInt64(2))
    push!(runtime.links, record)
    update!(runtime, LinkUpdated(record.sequence, link_info(record)))
    @test record.negotiated && record.failure === nothing
    update!(runtime, LinkBound(record.sequence, UInt32(32)))
    @test record.failure !== nothing && record.id === nothing
    failure = record.failure
    update!(runtime, LinkBound(record.sequence, UInt32(31)))
    @test record.failure === failure

    record = link_record(UInt64(3))
    push!(runtime.links, record)
    update!(runtime, LinkBound(record.sequence, UInt32(31)))
    update!(runtime, LinkUpdated(record.sequence, link_info(record)))
    update!(
        runtime,
        LinkUpdated(
            record.sequence,
            link_info(record; mask = PipeWireAO.LINK_CHANGE_STATE),
        ),
    )
    @test record.negotiated && record.failure === nothing
    before = record.info
    # The sparse merger retains current.id, so reject this raw event first.
    update!(
        runtime,
        LinkUpdated(
            record.sequence,
            link_info(record; id = UInt32(32), mask = PipeWireAO.LINK_CHANGE_STATE),
        ),
    )
    @test record.failure !== nothing && record.info === before
    @test_throws ArgumentError _validate_link!(
        runtime,
        record,
        link_info(record; id = UInt32(32)),
    )

    record = link_record(UInt64(4))
    push!(runtime.links, record)
    update!(runtime, LinkUpdated(record.sequence, link_info(record)))
    before = record.info
    update!(
        runtime,
        LinkUpdated(
            record.sequence,
            link_info(record; id = UInt32(32), mask = PipeWireAO.LINK_CHANGE_STATE),
        ),
    )
    @test record.failure !== nothing && record.info === before
    failure = record.failure
    update!(runtime, LinkUpdated(record.sequence, link_info(record)))
    @test record.failure === failure
end

@testset "Clientless nodes require exact core and typed SPA factory provenance" begin
    configuration =
        Dict{String,Any}("core.owner"=>Dict("pid"=>991, "nodes"=>["core-source"]))
    runtime = TestRuntime(; configuration)
    runtime.core_info = CoreInfo(
        UInt32(0),
        UInt32(19),
        "user",
        "host",
        "version",
        "private-core",
        UInt64(1),
        Dict("application.process.id"=>"991"),
    )
    factory_properties = Dict("object.serial"=>"10")
    factory = Object{TestProxy,FactoryInfo}(
        UInt32(10),
        UInt64(10),
        factory_properties,
        TestProxy(false),
        FactoryInfo(
            UInt32(10),
            "spa-node-factory",
            "PipeWire:Interface:Node",
            UInt32(3),
            UInt64(1),
            factory_properties,
        ),
        false,
    )
    properties = Dict("object.serial"=>"11", "node.name"=>"core-source", "factory.id"=>"10")
    node = Object{TestProxy,NodeInfo}(
        UInt32(11),
        UInt64(11),
        properties,
        TestProxy(false),
        NodeInfo(
            UInt32(11),
            UInt32(0),
            UInt32(1),
            UInt64(31),
            UInt32(0),
            UInt32(1),
            PipeWireAO.NODE_STATE_IDLE,
            nothing,
            properties,
            ParamInfo[],
        ),
        false,
    )
    runtime.objects[factory.id]=factory
    runtime.objects[node.id]=node
    @test find_object(runtime, "core-source", 991) === node
    @test_throws ArgumentError find_object(runtime, "core-source", 992)
    capture!(runtime, UInt64(node.id); core = _core_identity(runtime))
    @test assert_identity!(runtime, UInt64(node.id)) === nothing
    # A fresh copied CoreInfo with the same values is the same incarnation.
    runtime.core_info = CoreInfo(
        UInt32(0),
        UInt32(19),
        "user",
        "host",
        "version",
        String(collect(codeunits("private-core"))),
        UInt64(1),
        Dict("application.process.id"=>"991"),
    )
    @test assert_identity!(runtime, UInt64(node.id)) === nothing
    runtime.core_info = CoreInfo(
        UInt32(0),
        UInt32(20),
        "user",
        "host",
        "version",
        "private-core",
        UInt64(1),
        Dict("application.process.id"=>"991"),
    )
    @test_throws ArgumentError assert_identity!(runtime, UInt64(node.id))
end


struct Added <: AbstractEvent
    global_object::Global
end
struct Removed <: AbstractEvent
    id::UInt32
end
struct CoreUpdated <: AbstractEvent
    info::CoreInfo
end
struct Done <: AbstractEvent
    sequence::Cint
end
update!(runtime, event::Added) = add_object!(runtime, event.global_object)
update!(runtime, event::Removed) = remove_object!(runtime, event.id)
update!(runtime, event::CoreUpdated) = (runtime.core_info = event.info; nothing)
update!(runtime, event::Done) = (push!(runtime.done, event.sequence); nothing)
update!(runtime, event::ParameterReceived) = nothing
now(runtime)::Int64 = Clocks.time_nanos(CLOCK)
function pump!(runtime)
    # Public native loop ABI, owned by this sticky test task. Native callbacks
    # only enqueue copied observations; update! runs after iterate returns.
    handle = PipeWireAO.LibPipeWire.pw_main_loop_get_loop(runtime.loop.handle)
    result = PipeWireAO.LibPipeWire.pw_loop_iterate(handle, 0)
    result >= 0 || error("private loop iteration failed")
    while !isempty(runtime.queue)
        update!(runtime, popfirst!(runtime.queue))
    end
    return nothing
end
function pump!(runtime::TestRuntime{Nothing,Nothing,Nothing})
    while !isempty(runtime.queue)
        update!(runtime, popfirst!(runtime.queue))
    end
    return nothing
end
function await_condition!(f, runtime, job)
    while true
        runtime.cancel_creation &&
            any(record->record.pending && record.proxy !== nothing, runtime.links) &&
            error("cancelled before Link binding")
        pump!(runtime)
        value = f()
        value === nothing || return value
        now(runtime) < job.ticket.deadline || error("private object gate expired")
        sleep(0.001)
    end
end
function synchronize!(runtime, job)
    sequence = sync!(runtime.core)
    await_condition!(runtime, job) do
        sequence in runtime.done ? true : nothing
    end
    return nothing
end
function synchronize!(runtime::TestRuntime{Nothing,Nothing,Nothing}, job)
    push!(runtime.done, Cint(1))
    return nothing
end

function shutdown_cohort(; shared_client = false, graph_client = UInt32(10))
    declaration = Dict{String,Any}(
        "pid"=>19,
        "bootstrap-node"=>"bootstrap",
        "bootstrap-instance"=>"17",
    )
    configuration = Dict{String,Any}(
        "owners"=>[declaration],
        "node.pids"=>Dict("science"=>19, "foreign"=>29),
    )
    runtime = TestRuntime(; configuration)
    function client(id, serial, pid)
        properties =
            Dict("object.serial"=>string(serial), "application.process.id"=>string(pid))
        runtime.objects[UInt32(id)] = Object{TestProxy,ClientInfo}(
            UInt32(id),
            UInt64(serial),
            copy(properties),
            TestProxy(false),
            ClientInfo(UInt32(id), UInt64(1), properties),
            false,
        )
    end
    function node(id, serial, name, parent; properties = Dict{String,String}())
        values = merge(
            Dict(
                "object.serial"=>string(serial),
                "node.name"=>name,
                "client.id"=>string(parent),
            ),
            properties,
        )
        runtime.objects[UInt32(id)] = Object{TestProxy,NodeInfo}(
            UInt32(id),
            UInt64(serial),
            copy(values),
            TestProxy(false),
            NodeInfo(
                UInt32(id),
                UInt32(0),
                UInt32(0),
                UInt64(31),
                UInt32(0),
                UInt32(0),
                PipeWireAO.NODE_STATE_IDLE,
                nothing,
                values,
                ParamInfo[],
            ),
            false,
        )
    end
    client(10, 100, 19)
    client(20, 200, 29)
    node(
        11,
        110,
        "bootstrap",
        10;
        properties = Dict(
            "pipewireao.rtc-control.protocol"=>ControlClient.PROTOCOL,
            "pipewireao.rtc-control.profile"=>ControlClient.profile_name(
                OwnerBootstrapCodec.PROFILE,
            ),
            "pipewireao.rtc-control.instance"=>"17",
            "pipewireao.rtc-control.owner-pid"=>"19",
        ),
    )
    node(12, 120, "science", graph_client)
    node(21, 210, "foreign", 20)
    shared_client && node(13, 130, "unrelated", 10)
    port_properties = Dict(
        "object.serial"=>"140",
        "node.id"=>"12",
        "port.name"=>"science-output",
        "port.direction"=>"out",
    )
    runtime.objects[UInt32(14)] = Object{TestProxy,PortInfo}(
        UInt32(14),
        UInt64(140),
        copy(port_properties),
        TestProxy(false),
        PortInfo(
            UInt32(14),
            PipeWireAO.DIRECTION_OUTPUT,
            UInt64(3),
            port_properties,
            ParamInfo[],
        ),
        false,
    )
    for id in keys(runtime.objects)
        capture!(runtime, UInt64(id))
    end
    owner = Owner(
        OwnerBootstrapCodec.PROFILE,
        ControlClient.Observation(OwnerBootstrapCodec.PROFILE, Int64(17), UInt32(19)),
        UInt64(11),
        UInt32(19),
        Int64(17),
        false,
    )
    return runtime, owner
end

@testset "Withdrawal retains captured controls through terminal owner receipts" begin
    runtime, owner = shutdown_cohort()
    before = copy(runtime.captured)
    remove_links!(runtime, (; ticket = (; deadline = now(runtime)+SECOND)))
    @test runtime.captured == before
    @test assert_identity!(runtime, owner.handle) === nothing
    @test isempty(runtime.machine.losses)
    @test_throws ArgumentError retire_owner!(runtime, owner)
    @test runtime.captured == before && isempty(runtime.retired)
    owner.retired = true # The control adapter sets this only after validating Stopped.
    @test retire_owner!(runtime, owner) === nothing
    @test runtime.retired == Dict(
        UInt32(10)=>UInt64(100),
        UInt32(11)=>UInt64(110),
        UInt32(12)=>UInt64(120),
        UInt32(14)=>UInt64(140),
    )
    @test Set(keys(runtime.captured)) == Set(UInt32[20, 21])
    for id in UInt32[14, 12, 11, 10]
        remove_object!(runtime, id)
    end
    @test isempty(runtime.machine.losses)
    @test length(runtime.retired) == 4
    remove_object!(runtime, UInt32(21))
    @test length(runtime.machine.losses) == 1
    @test occursin("id=21", only(runtime.machine.losses))
end

@testset "Retirement cannot weaken unacknowledged or foreign ownership proofs" begin
    runtime, owner = shutdown_cohort()
    remove_object!(runtime, UInt32(11))
    @test length(runtime.machine.losses) == 1
    @test isempty(runtime.retired)
    runtime, owner = shutdown_cohort(; graph_client = UInt32(20))
    before = copy(runtime.captured)
    owner.retired = true
    @test_throws ArgumentError retire_owner!(runtime, owner)
    @test runtime.captured == before && isempty(runtime.retired)
    runtime, owner = shutdown_cohort(; shared_client = true)
    owner.retired = true
    retire_owner!(runtime, owner)
    @test haskey(runtime.captured, UInt32(10)) && haskey(runtime.captured, UInt32(13))
    @test !haskey(runtime.retired, UInt32(10))
    remove_object!(runtime, UInt32(13))
    @test length(runtime.machine.losses) == 1
    runtime, owner = shutdown_cohort()
    owner.retired = true
    runtime.configuration["owners"][1]["bootstrap-instance"] = "18"
    @test_throws ArgumentError retire_owner!(runtime, owner)
    @test isempty(runtime.retired) && haskey(runtime.captured, UInt32(11))
    acquisition = Owner(
        AcquisitionLifecycleCodec.CALIBRATION_PROFILE,
        ControlClient.Observation(
            AcquisitionLifecycleCodec.CALIBRATION_PROFILE,
            Int64(17),
            UInt32(19),
        ),
        UInt64(11),
        UInt32(19),
        Int64(17),
        true,
    )
    @test_throws ArgumentError retire_owner!(runtime, acquisition)
end

@testset "Execution-group grants, passive boundaries and graph coverage" begin
    graph = Dict{String,Any}(
        "node.name"=>"science",
        "factory"=>"test-graph",
        "ownership"=>"external",
        "run-control"=>"session",
    )
    sink = Dict("node.name"=>"science-output", "ownership"=>"runner")
    spec = Dict{String,Any}(
        "sources"=>[],
        "graphs"=>[graph],
        "sinks"=>[sink],
        "execution-groups"=>[
            Dict("name"=>"science", "nodes"=>["science", "science-output"]),
        ],
        "links"=>[Dict("output"=>"science:output", "input"=>"science-output:input")],
    )
    configuration =
        Dict{String,Any}("session"=>spec, "node.pids"=>Dict("science"=>getpid()))
    runtime = TestRuntime(; configuration)
    properties=Dict("object.serial"=>"11", "node.name"=>"science", "client.id"=>"10")
    runtime.objects[UInt32(10)] = Object{TestProxy,ClientInfo}(
        UInt32(10),
        UInt64(10),
        Dict("object.serial"=>"10"),
        TestProxy(false),
        ClientInfo(UInt32(10), UInt64(1), Dict("application.process.id"=>string(getpid()))),
        false,
    )
    runtime.objects[UInt32(11)] = Object{TestProxy,NodeInfo}(
        UInt32(11),
        UInt64(11),
        properties,
        TestProxy(false),
        NodeInfo(
            UInt32(11),
            UInt32(0),
            UInt32(1),
            UInt64(31),
            UInt32(0),
            UInt32(1),
            PipeWireAO.NODE_STATE_IDLE,
            nothing,
            properties,
            ParamInfo[],
        ),
        false,
    )
    job = (; ticket = (; deadline = now(runtime)+30*SECOND))
    discover_graphs!(runtime, job)
    @test runtime.graphs["science"] == 11
    @test runtime.groups["science"].nodes == ["science"] &&
          !runtime.groups["science"].running
    empty!(runtime.groups)
    empty!(runtime.graphs)
    spec["execution-groups"][1]["nodes"] = ["science"]
    @test_throws ArgumentError discover_graphs!(runtime, job)
    @test _session_controlled(
        Dict("ownership"=>"external", "run-control"=>"application"),
        "graphs",
    ) == false
    @test_throws ArgumentError _session_controlled(Dict("ownership"=>"external"), "graphs")
    @test_throws ArgumentError _session_controlled(Dict("run-control"=>"session"), "graphs")
end

@testset "Empty registry cannot bypass pending creation or exact absence fence" begin
    runtime = TestRuntime()
    record = link_record()
    record.creation_pending=true
    push!(runtime.links, record)
    job = (; ticket = (; deadline = now(runtime)+Int64(10_000_000)))
    @test_throws ErrorException remove_links!(runtime, job)
    @test isempty(runtime.objects) && length(runtime.links) == 1 && runtime.withdrawing
    @test isempty(runtime.done)
    record.creation_pending=false
    properties = Dict("object.serial"=>"31", "object.path"=>record.path)
    runtime.objects[UInt32(31)] = Object{TestProxy,LinkInfo}(
        UInt32(31),
        UInt64(31),
        properties,
        TestProxy(false),
        link_info(record),
        false,
    )
    @test_throws ArgumentError remove_links!(
        runtime,
        (; ticket = (; deadline = now(runtime)+SECOND)),
    )
    @test Cint(1) in runtime.done && !isempty(runtime.links) && runtime.withdrawing
    empty!(runtime.objects)
    remove_links!(runtime, (; ticket = (; deadline = now(runtime)+SECOND)))
    @test isempty(runtime.links) && !runtime.withdrawing
end

include("control_private_core.jl")
@testset "Private core exact Link ownership and acknowledged withdrawal" begin
    with_control_private_core() do socket, directory, daemon
        queue = AbstractEvent[]
        loop = MainLoop()
        native_loop = PipeWireAO.LibPipeWire.pw_main_loop_get_loop(loop.handle)
        PipeWireAO.LibPipeWire.pw_loop_enter(native_loop)
        context = Context(loop)
        core = CoreConnection(
            context;
            properties = Dict("remote.name"=>socket),
            on_info = (_, info)->stage!(queue, CoreUpdated(info)),
            on_done = (_, id, sequence)->stage!(queue, Done(sequence)),
        )
        registry = Registry(core)
        listener = add_listener!(
            registry;
            on_global_added = (_, global_object)->stage!(queue, Added(global_object)),
            on_global_removed = (_, id)->stage!(queue, Removed(id)),
        )
        declaration(name, direction, port) = Dict(
            "node.name"=>name,
            "ownership"=>"external",
            "run-control"=>"application",
            "ports"=>[
                Dict(
                    "name"=>port,
                    "direction"=>direction,
                    "element-type"=>"F32_LE",
                    "shape"=>[2],
                    "schema"=>CONTRACT.schema,
                    "layout"=>"ROW_MAJOR",
                    "rate"=>"100/1",
                ),
            ],
        )
        configuration = Dict{String,Any}(
            "node.pids"=>Dict("objects-source"=>getpid(), "objects-sink"=>getpid()),
            "session"=>Dict(
                "sources"=>[declaration("objects-source", "output", "output_1")],
                "sinks"=>[declaration("objects-sink", "input", "input_1")],
                "graphs"=>[],
                "links"=>[
                    Dict(
                        "output"=>"objects-source:output_1",
                        "input"=>"objects-sink:input_1",
                    ),
                ],
            ),
        )
        runtime = TestRuntime(core, registry, loop; configuration, queue)
        source = NdArraySource(
            core,
            "objects-source",
            zeros(Float32, 2),
            FORMAT;
            schema = CONTRACT.schema,
        )
        sink = NdArraySink(
            core,
            "objects-sink",
            zeros(Float32, 2),
            FORMAT;
            schema = CONTRACT.schema,
        )
        unrelated = NdArraySource(
            core,
            "unrelated-objects-source",
            zeros(Float32, 2),
            FORMAT;
            schema = CONTRACT.schema,
        )
        job = (;
            ticket = (;
                session = UInt64(101),
                epoch = UInt64(1),
                serial = UInt64(10),
                deadline = now(runtime)+300*SECOND,
            )
        )
        try
            start!(source)
            start!(sink)
            start!(unrelated)
            synchronize!(runtime, job)
            runtime.client_id = PipeWireAO.LibPipeWire.pw_proxy_get_bound_id(
                Ptr{PipeWireAO.LibPipeWire.pw_proxy}(
                    PipeWireAO.LibPipeWire.pw_core_get_client(core.handle),
                ),
            )
            @test runtime.client_id != typemax(UInt32)
            @test node!(runtime, job, "objects-source", getpid()) == UInt64(node_id(source))
            @test_throws ArgumentError find_object(runtime, "objects-source", getpid()+1)
            discover_graphs!(runtime, job)
            create_links!(runtime, job)
            @test length(runtime.links) == 1 && only(runtime.links).negotiated
            @test only(runtime.links).serial !== nothing
            @test isempty(runtime.machine.losses)
            source_object = something(find_object(runtime, node_id(source)))
            old_proxy = source_object.proxy
            replacement = refresh_object!(runtime, source_object.id)
            @test !isopen(old_proxy) && replacement.serial == source_object.serial
            synchronize!(runtime, job)
            @test assert_identity!(runtime, UInt64(replacement.id)) === nothing
            retained = node_id(unrelated)
            old = only(runtime.links)
            remove_links!(runtime, job)
            @test isempty(runtime.links) &&
                  !isempty(runtime.captured) &&
                  !runtime.withdrawing
            @test find_object(runtime, retained) !== nothing
            @test !any(object->_correlated_link(object, [old]), values(runtime.objects))
            # Cancel before bound/Format events are consumed. Local destruction
            # receipts plus the server sync must fence pending creation.
            fresh = (;
                ticket = (;
                    session = UInt64(101),
                    epoch = UInt64(2),
                    serial = UInt64(11),
                    deadline = now(runtime)+300*SECOND,
                )
            )
            runtime.cancel_creation = true
            @test_throws ErrorException create_links!(runtime, fresh)
            @test only(runtime.links).pending && only(runtime.links).id === nothing
            runtime.cancel_creation = false
            pending = only(runtime.links)
            remove_links!(runtime, fresh)
            @test pending.destroyed && !pending.pending
            @test isempty(runtime.links) && isopen(unrelated)
        finally
            runtime.withdrawing = true
            for record in runtime.links
                _destroy_created!(core, record.proxy)
                _close_listener!(record.listener)
            end
            close(source)
            close(sink)
            close(unrelated)
            dispose_objects!(runtime)
            close(listener)
            close(registry)
            close(core)
            close(context)
            PipeWireAO.LibPipeWire.pw_loop_leave(native_loop)
            close(loop)
        end
    end
end
end
