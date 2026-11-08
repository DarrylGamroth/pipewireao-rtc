using Test
using PipeWireAORTC
using PipeWireAO

module MediaSessionControlsTests
using Test, PipeWireAO
import Clocks
import PipeWireAORTC:
    ControlCodec,
    ControlClient,
    OwnerBootstrapCodec,
    AcquisitionLifecycleCodec,
    RunnerCodec,
    SourceControl,
    ParameterSource
import PipeWireAORTC.MediaSession: AbstractOrigin, ReadyOrigin, RunningOrigin
include(joinpath(@__DIR__, "..", "src", "media_session", "controls.jl"))
include(joinpath(@__DIR__, "..", "src", "media_session", "correction.jl"))
const SPA = PipeWireAO.SPA
const CC = ControlCodec
const BC = OwnerBootstrapCodec
const AC = AcquisitionLifecycleCodec
const IDENTITY = CC.ControllerIdentity(UInt32(7), UInt64(11), Int64(13))
struct Group
    nodes::Vector{String}
    members::Vector{String}
    running::Bool
end
mutable struct Runtime{C,P,K<:Clocks.AbstractNanoClock}
    configuration::C
    parameters::P
    controller::CC.ControllerIdentity
    token::Int64
    graphs::Dict{String,UInt64}
    groups::Dict{String,Group}
    machine::NamedTuple{(:lifecycle,),Tuple{RunnerCodec.Lifecycle}}
    properties::Dict{String,String}
    records::Vector{Vector{Pod}}
    index::Int
    submitted::Vector{Pod}
    mutations::Int
    queries::Int
    clock::K
    identity_valid::Bool
    send_failure::Bool
end
function Runtime(
    records;
    configuration = Dict{String,String}(),
    parameters = nothing,
    lifecycle = RunnerCodec.Running,
    clock::Clocks.AbstractNanoClock = Clocks.CachedNanoClock(
        Clocks.time_nanos(Clocks.SystemNanoClock())
    ),
    properties = Dict(
        "pipewireao.rtc-control.protocol" => ControlClient.PROTOCOL,
        "pipewireao.rtc-control.profile" => ControlClient.profile_name(BC.PROFILE),
        "pipewireao.rtc-control.instance" => "17",
        "pipewireao.rtc-control.owner-pid" => "19",
    ),
)
    Runtime(
        configuration,
        parameters,
        IDENTITY,
        Int64(0),
        Dict("graph" => UInt64(1)),
        Dict("loop" => Group(["graph"], String[], true)),
        (lifecycle = lifecycle,),
        properties,
        records,
        0,
        Pod[],
        0,
        0,
        clock,
        true,
        false,
    )
end
now(runtime::Runtime)::Int64 = Clocks.time_nanos(runtime.clock)
capture!(runtime::Runtime, handle) = nothing
assert_identity!(runtime::Runtime, handle) =
    runtime.identity_valid ? nothing : throw(ArgumentError("incarnation changed"))
property(runtime::Runtime, handle, key) = get(runtime.properties, key, nothing)
function enumerate!(runtime::Runtime, job, handle, param)
    runtime.index += 1
    return runtime.records[min(runtime.index, length(runtime.records))]
end
function setparam!(runtime::Runtime, job, handle, param, pod)
    runtime.mutations += 1
    push!(runtime.submitted, pod)
    runtime.send_failure && throw(ErrorException("native send failed"))
end
function queryparam!(runtime::Runtime, job, handle, param, pod)
    runtime.queries += 1
    push!(runtime.submitted, pod)
    runtime.send_failure && throw(ErrorException("native send failed"))
end
synchronize!(runtime::Runtime, job) = nothing
function await_condition!(f, runtime::Runtime, job)
    for _ in 1:20
        now(runtime) < job.ticket.deadline ||
            throw(ControlClient.UnknownOutcome("absolute deadline expired"))
        value = f()
        value === nothing || value === false || return value
        Clocks.advance!(runtime.clock, Int64(1_000_000))
    end
    throw(ErrorException("test operation failed to finish"))
end
job(runtime; origin = RunningOrigin()) = (
    ticket = (
        deadline = Base.Checked.checked_add(now(runtime), Int64(5_000_000_000)),
        origin = origin,
    ),
)
function capability(
    profile = BC.PROFILE; state = UInt32(2), token = Int64(0), registered = true
)
    names = ControlClient.capability_names(profile)
    rows =
        registered ?
        Pod[Pod(
            policy_struct(
                Pod(SPA.Id(IDENTITY.global_id)),
                Pod(reinterpret(Int64, IDENTITY.serial)),
                Pod(IDENTITY.instance),
            ),
        )] : Pod[]
    values = Pod[
        Pod(Int32(1)),
        Pod(Int64(17)),
        Pod(SPA.Id(UInt32(19))),
        Pod(SPA.Id(state)),
        Pod(token),
        Pod(SPA.Struct(rows)),
    ]
    Pod(
        PipeWireAO.props_param(SPA.Props([names[i] => values[i] for i in eachindex(names)]))
    )
end
bootstrap_reply(token = Int64(1)) = ControlClient.encode_completion(
    BC.PROFILE,
    CC.ReplyHeader(IDENTITY, Int64(17), token, UInt32(2), Int32(0)),
    BC.Connected,
    "",
)
function source_control_pod(;
    kind = SourceControl.INITIAL,
    token = Int64(0),
    generation = Int64(1),
    sequence = Int64(0),
    running = false,
    completed = false,
    report_generation = generation,
    report_sequence = sequence,
)
    values = SourceControl.snapshot_values(
        Int64(17),
        kind,
        token,
        Int32(0),
        generation,
        sequence,
        running,
        completed,
        report_generation,
        report_sequence,
    )
    Pod(
        PipeWireAO.props_param(
            SPA.Props([
                SourceControl.SNAPSHOT_NAMES[i] => Pod(values[i]) for i in eachindex(values)
            ]),
        ),
    )
end
@testset "session native owner correlation and one-shot effects" begin
    runtime = Runtime([
        [capability(; token = Int64(50))],
        [capability(; token = Int64(51)), bootstrap_reply(Int64(51))],
    ])
    owner = capture_owner(runtime, UInt64(1), BC.PROFILE, 17, 19)
    reply = request_owner!(runtime, job(runtime), owner, BC.Command(:connect))
    @test reply.lifecycle == BC.Connected
    @test length(runtime.submitted) == 1
    @test runtime.mutations == 1 && runtime.queries == 0
    header, _ = CC.decode_request(only(runtime.submitted))
    @test header.token == 51
    @test 0 < header.budget_ns <= 5_000_000_000
    @test owner.observation.pending === nothing
    @test runtime.token == 51
    runtime = Runtime([[capability()]])
    runtime.send_failure = true
    owner = capture_owner(runtime, UInt64(1), BC.PROFILE, 17, 19)
    @test_throws ErrorException request_owner!(
        runtime, job(runtime), owner, BC.Command(:connect)
    )
    @test length(runtime.submitted) == 1
    @test runtime.mutations == 1 && runtime.queries == 0
    @test owner.observation.pending === nothing
    runtime = Runtime([[capability(; registered = false)]])
    owner = capture_owner(runtime, UInt64(1), BC.PROFILE, 17, 19)
    @test_throws ControlClient.UnknownOutcome request_owner!(
        runtime,
        (ticket = (deadline = now(runtime) + Int64(2_000_000),),),
        owner,
        BC.Command(:connect),
    )
    @test isempty(runtime.submitted)
    runtime.identity_valid = false
    @test_throws ArgumentError check_owner!(runtime, owner)
    runtime = Runtime([[capability(; state = UInt32(3))]])
    owner = capture_owner(runtime, UInt64(1), BC.PROFILE, 17, 19)
    @test_throws ArgumentError wait_prepared!(runtime, job(runtime), owner)
    runtime = Runtime([[capability(), capability()]])
    owner = capture_owner(runtime, UInt64(1), BC.PROFILE, 17, 19)
    @test_throws ArgumentError observe_owner!(runtime, job(runtime), owner)
    runtime.token = typemax(Int64)
    @test_throws ArgumentError next_control_token!(runtime)
end
@testset "finite source operations return one correlated status" begin
    previous = source_control_snapshot(named_values(source_control_pod()), Int64(17))
    running = source_control_pod(; kind = SourceControl.RUN, token = Int64(1), running = true)
    records = control_records([running], Int64(17))
    @test matching_source_control_record(records, :run, Int64(1), "running", previous).running
    @test_throws ArgumentError matching_source_control_record(
        records, :run, Int64(1), "stopped", previous
    )
    properties = Dict(
        "pipewireao.source-control.instance" => "17",
        "pipewireao.source-control.owner-pid" => "19",
    )
    for (kind, receipt, expected_generation) in (
        (:run, running, 1),
        (:run, source_control_pod(; kind = SourceControl.RUN, token = Int64(1)), 1),
        (:reset, source_control_pod(;
            kind = SourceControl.RESET, token = Int64(1), generation = Int64(2)
        ), 2),
    )
        runtime = Runtime([[source_control_pod()], [receipt]]; properties)
        source = SourceControlBinding(UInt64(1), UInt32(19), Int64(17), nothing)
        status = source_operation!(runtime, job(runtime), source, kind; running = receipt === running)
        @test status.generation == expected_generation
        @test status.details.token == 1
        @test runtime.mutations == 1 && runtime.queries == 0
    end
    incomplete = control_records(
        [
            source_control_pod(;
                kind = SourceControl.QUERY,
                token = Int64(1),
                sequence = Int64(4),
                completed = true,
                report_sequence = Int64(3),
            ),
        ],
        Int64(17),
    )
    @test_throws ArgumentError matching_source_control_record(
        incomplete, :query, Int64(1), "", previous
    )
    @test_throws ArgumentError source_control_snapshot(
        named_values(source_control_pod(; running = true, completed = true)), Int64(17)
    )
    @test_throws ArgumentError source_control_snapshot(
        named_values(source_control_pod()), Int64(18)
    )
    @test control_state(true) == "running"
    @test control_state(1) == "stopped"
    runtime = Runtime(
        [
            [source_control_pod()],
            [source_control_pod(; kind = SourceControl.QUERY, token = Int64(1))],
        ];
        properties = Dict(
            "pipewireao.source-control.instance" => "17",
            "pipewireao.source-control.owner-pid" => "19",
        ),
    )
    source = SourceControlBinding(UInt64(1), UInt32(19), Int64(17), nothing)
    @test source_operation!(runtime, job(runtime), source, :query).generation == 1
    @test length(runtime.submitted) == 1
    @test runtime.mutations == 0 && runtime.queries == 1
end
@testset "read-only owner queries never mark a scientific mutation" begin
    status_reply = ControlClient.encode_completion(
        BC.PROFILE,
        CC.ReplyHeader(IDENTITY, Int64(17), Int64(1), UInt32(1), Int32(0)),
        BC.Prepared,
        "",
    )
    runtime = Runtime([[capability()], [capability(), status_reply]])
    owner = capture_owner(runtime, UInt64(1), BC.PROFILE, 17, 19)
    @test request_owner!(runtime, job(runtime), owner, BC.Command(:status)).lifecycle ==
        BC.Prepared
    @test runtime.mutations == 0 && runtime.queries == 1
    @test length(runtime.submitted) == 1
    runtime = Runtime([[capability()]])
    runtime.send_failure = true
    owner = capture_owner(runtime, UInt64(1), BC.PROFILE, 17, 19)
    @test_throws ErrorException request_owner!(
        runtime, job(runtime), owner, BC.Command(:status)
    )
    @test runtime.mutations == 0 && runtime.queries == 1
    @test length(runtime.submitted) == 1
    # Each public status command selects the same read-only native send boundary.
    for command in (
        BC.Command(:status),
        AC.LifecycleCommand(:status),
        RunnerCodec.RunnerCommand(:status),
    )
        runtime = Runtime(Vector{Pod}[])
        send_owner_request!(runtime, job(runtime), owner, command, Pod(nothing))
        @test runtime.mutations == 0 && runtime.queries == 1
    end
    runtime = Runtime(
        [[source_control_pod()]];
        properties = Dict(
            "pipewireao.source-control.instance" => "17",
            "pipewireao.source-control.owner-pid" => "19",
        ),
    )
    runtime.send_failure = true
    source = SourceControlBinding(UInt64(1), UInt32(19), Int64(17), nothing)
    @test_throws ErrorException source_operation!(runtime, job(runtime), source, :query)
    @test runtime.mutations == 0 && runtime.queries == 1
    @test length(runtime.submitted) == 1
end
@testset "correction and protective recovery admission" begin
    config = Dict(
        "node.pids" => Dict("graph" => 19),
        "owners" => [
            Dict(
                "pid" => 19,
                "bootstrap-node" => "bootstrap",
                "bootstrap-instance" => "17",
            ),
        ],
    )
    runtime = Runtime(Vector{Pod}[]; configuration = config)
    prefix = CORRECTION_PREFIX * "controller:closed"
    values = Dict(
        "pipewireao.correction-control.version" => Pod(Int32(1)),
        "pipewireao.correction-control.owner-instance" => Pod(Int64(17)),
        "pipewireao.run-control.actual-state" => Pod("running"),
        prefix * ".state" => Pod("Open"),
        prefix * ".fault" => Pod(""),
        prefix * ".requested" => Pod(false),
        "controller:closed" => Pod(false),
        "controller:requested-generation" => Pod(Int64(2)),
        "controller:active-generation" => Pod(Int64(2)),
    )
    updates = Dict("controller:closed" => Pod(true))
    declarations = Dict{String,PropertyDeclaration}()
    @test check_correction!(
        runtime, RunningOrigin(), "graph", values, updates, declarations
    ) === nothing
    @test_throws ArgumentError check_correction!(
        runtime, ReadyOrigin(), "graph", values, updates, declarations
    )
    runtime.machine = (lifecycle = RunnerCodec.Ready,)
    @test check_correction!(
        runtime, RunningOrigin(), "graph", values, updates, declarations
    ) === nothing
    runtime.groups["loop"] = Group(["graph"], String[], false)
    @test_throws ArgumentError check_correction!(
        runtime, RunningOrigin(), "graph", values, updates, declarations
    )
    runtime.groups["loop"] = Group(["graph"], String[], true)
    values["pipewireao.run-control.actual-state"] = Pod("stopped")
    @test_throws ArgumentError check_correction!(
        runtime, RunningOrigin(), "graph", values, updates, declarations
    )
    values["pipewireao.run-control.actual-state"] = Pod("running")
    values[CORRECTION_PREFIX*"owner-instance"] = Pod(Int64(18))
    @test_throws ArgumentError check_correction!(
        runtime, RunningOrigin(), "graph", values, updates, declarations
    )
    values[CORRECTION_PREFIX*"owner-instance"] = Pod(Int64(17))
    values[prefix*".fault"] = Pod("latched")
    @test_throws ArgumentError check_correction!(
        runtime, RunningOrigin(), "graph", values, updates, declarations
    )
    values[prefix*".fault"] = Pod("")
    runtime.machine = (lifecycle = RunnerCodec.Ready,)
    @test_throws ArgumentError check_correction!(
        runtime, ReadyOrigin(), "graph", values, updates, declarations
    )
    runtime.machine = (lifecycle = RunnerCodec.Running,)
    values[RECOVERY_PREFIX*"version"] = Pod(Int32(1))
    values[RECOVERY_PREFIX*"closure-inhibited"] = Pod(true)
    @test_throws ArgumentError check_parameter_correction(values)
    @test_throws ArgumentError check_correction!(
        runtime, RunningOrigin(), "graph", values, updates, declarations
    )
    values[RECOVERY_PREFIX*"closure-inhibited"] = Pod(false)
    values[RECOVERY_PREFIX*"controller"] = Pod("controller")
    values[RECOVERY_PREFIX*"requested-generation"] = Pod(Int64(2))
    values[RECOVERY_PREFIX*"active-generation"] = Pod(Int64(2))
    values[RECOVERY_PREFIX*"request-token"] = Pod(Int64(0))
    recovery = Dict(RECOVERY_PREFIX * "request-token" => Pod(Int64(1)))
    runtime.machine = (lifecycle = RunnerCodec.Ready,)
    @test check_correction!(
        runtime, RunningOrigin(), "graph", values, recovery, declarations
    ) === nothing
    runtime.machine = (lifecycle = RunnerCodec.Running,)
    @test_throws ArgumentError check_correction!(
        runtime, ReadyOrigin(), "graph", values, recovery, declarations
    )
    values[RECOVERY_PREFIX*"observation-monotonic-nanoseconds"] = Pod(Int64(1_000_000_000))
    values[RECOVERY_PREFIX*"reference-timeout-ms"] = Pod(Int32(100))
    @test recovery_reference_fresh(values, Int64(1_099_999_999))
    @test !recovery_reference_fresh(values, Int64(1_100_000_000))
    @test !recovery_reference_fresh(values, Int64(990_000_000))
    @test !recovery_reference_fresh(values, Int64(-1))
    @test_throws MethodError recovery_reference_fresh(values, 1.099999)
    @test correction_status_field(prefix * ".state")
    @test !correction_status_field(prefix * ".unsupported")
end
@testset "typed scalar admission and bitwise adoption" begin
    info = Pod(
        PipeWireAO.prop_info_param(
            SPA.PropInfo(
                "controller:gain", Pod(SPA.Choice(SPA.CHOICE_RANGE, Float32[1, 0, 2]))
            ),
        ),
    )
    @test property_declarations([info])["controller:gain"].kind == SPA.POD_FLOAT
    readonly = Pod(
        PipeWireAO.prop_info_param(
            SPA.PropInfo("controller:gain", Pod(Float32(1)); flags = 1)
        ),
    )
    @test !property_declarations([readonly])["controller:gain"].writable
    @test_throws ArgumentError property_declarations([info, info])
    before = Dict("controller" => Int64(2))
    after = Dict(
        "controller:requested-generation" => Pod(Int64(3)),
        "controller:active-generation" => Pod(Int64(3)),
        "controller:gain" => Pod(-0.0f0),
    )
    @test !properties_adopted(after, before, Dict("controller:gain" => Pod(0.0f0)))
    @test properties_adopted(after, before, Dict("controller:gain" => Pod(-0.0f0)))
    @test_throws ArgumentError RunnerCodec._scalar_pod(
        RunnerCodec.RunnerScalar(:float, reinterpret(UInt32, NaN32)); finite = true
    )
end
@testset "property transactions submit once and prove active generations" begin
    info = Pod(PipeWireAO.prop_info_param(SPA.PropInfo("controller:gain", Pod(Float32(1)))))
    props(generation, gain) = Pod(
        PipeWireAO.props_param(
            SPA.Props([
                "controller:requested-generation" => Pod(Int64(generation)),
                "controller:active-generation" => Pod(Int64(generation)),
                "controller:gain" => Pod(Float32(gain)),
            ]),
        ),
    )
    command = RunnerCodec.RunnerCommand(
        :properties_set,
        "graph",
        Dict(
            "controller:gain" =>
                RunnerCodec.RunnerScalar(:float, reinterpret(UInt32, 2.0f0)),
        ),
    )
    runtime = Runtime([[info], [props(2, 1)], [props(2, 1)], [props(3, 2)]])
    result = update_properties!(runtime, job(runtime), command)
    @test policy_text(result.values[1]) == "graph"
    @test policy_bool(result.values[3])
    @test length(runtime.submitted) == 1
    @test PipeWireAO.pod_value(
        Float32, named_values(only(runtime.submitted))["controller:gain"]
    ) == 2.0f0
    runtime = Runtime([[info], [props(2, 1)]]; lifecycle = RunnerCodec.Ready)
    result = update_properties!(runtime, job(runtime; origin = ReadyOrigin()), command)
    @test !policy_bool(result.values[3])
    @test length(runtime.submitted) == 1
    readonly = Pod(
        PipeWireAO.prop_info_param(
            SPA.PropInfo("controller:gain", Pod(Float32(1)); flags = 1)
        ),
    )
    runtime = Runtime([[readonly], [props(2, 1)]])
    @test_throws ArgumentError update_properties!(runtime, job(runtime), command)
    @test isempty(runtime.submitted)
    runtime = Runtime([[info], [props(2, 1)]])
    @test_throws ControlClient.UnknownOutcome update_properties!(
        runtime,
        (ticket = (deadline = now(runtime) + Int64(2_000_000), origin = RunningOrigin()),),
        command,
    )
    @test length(runtime.submitted) == 1
end
@testset "property admission follows the effect ticket origin" begin
    info = Pod(PipeWireAO.prop_info_param(SPA.PropInfo("controller:gain", Pod(Float32(1)))))
    props(generation, gain) = Pod(
        PipeWireAO.props_param(
            SPA.Props([
                "controller:requested-generation" => Pod(Int64(generation)),
                "controller:active-generation" => Pod(Int64(generation)),
                "controller:gain" => Pod(Float32(gain)),
            ]),
        ),
    )
    command = RunnerCodec.RunnerCommand(
        :properties_set,
        "graph",
        Dict(
            "controller:gain" =>
                RunnerCodec.RunnerScalar(:float, reinterpret(UInt32, 2.0f0)),
        ),
    )
    # A mutable wire status cannot replace the immutable Hsm admission origin.
    runtime = Runtime(
        [[info], [props(2, 1)], [props(3, 2)]]; lifecycle = RunnerCodec.Running
    )
    result = update_properties!(runtime, job(runtime; origin = ReadyOrigin()), command)
    @test !policy_bool(result.values[3])
    @test runtime.index == 2
    @test runtime.mutations == 1

    runtime = Runtime([[info], [props(2, 1)], [props(3, 2)]]; lifecycle = RunnerCodec.Ready)
    result = update_properties!(runtime, job(runtime; origin = RunningOrigin()), command)
    @test policy_bool(result.values[3])
    @test runtime.index == 3
    @test runtime.mutations == 1
end

@testset "typed acquisition state acknowledgements" begin
    profile = AC.CALIBRATION_PROFILE
    function cold_reply(;
        running = false,
        completed = false,
        sequence = UInt64(0),
        token = Int64(1),
        operation = UInt32(2),
        state = AC.Connected,
    )
        cursor = AC.AcquisitionCursor(UInt64(1), UInt64(1), sequence, UInt64(0))
        snapshot = AC.Snapshot(
            AC.Classic, cursor, cursor, running, completed, "initial", false, false, nothing
        )
        ControlClient.encode_completion(
            profile,
            CC.ReplyHeader(IDENTITY, Int64(17), token, operation, Int32(0)),
            state,
            snapshot,
            "",
        )
    end
    metadata = Dict(
        "pipewireao.rtc-control.protocol" => ControlClient.PROTOCOL,
        "pipewireao.rtc-control.profile" => ControlClient.profile_name(profile),
        "pipewireao.rtc-control.instance" => "17",
        "pipewireao.rtc-control.owner-pid" => "19",
    )
    runtime = Runtime(
        [
            [capability(profile; state = UInt32(3))],
            [capability(profile; state = UInt32(3)), cold_reply(; operation = UInt32(1))],
            [capability(profile; state = UInt32(3)), cold_reply(; operation = UInt32(1))],
            [capability(profile; state = UInt32(3)), cold_reply(; token = Int64(2))],
        ];
        properties = metadata,
    )
    owner = capture_owner(runtime, UInt64(1), profile, 17, 19)
    acquisition = AcquisitionBinding(owner, AC.Classic, nothing)
    snapshot = source_operation!(runtime, job(runtime), acquisition, :run; running = false)
    @test !snapshot.running && snapshot.generation == 1
    @test acquisition.previous !== nothing
    @test length(runtime.submitted) == 2
    @test runtime.mutations == 1 && runtime.queries == 1
    @test [CC.decode_request(pod)[1].operation for pod in runtime.submitted] == UInt32[1, 2]
    mismatched = ControlClient.decode_completion(profile, cold_reply())
    acquisition.instrument = AC.Copper
    @test_throws ArgumentError source_snapshot!(acquisition, mismatched)
    snapshot = SourceSnapshot(
        false,
        false,
        UInt64(2),
        UInt64(1),
        UInt64(2),
        UInt64(1),
        SourceControlDetails(Int32(2), Int64(1), Int32(0)),
    )
    @test_throws ArgumentError validate_source_operation(snapshot, :reset, false)
end

@testset "fresh pre-Connect acquisition status proves initial Hold without Pause" begin
    for profile in (AC.CALIBRATION_PROFILE, AC.CORRECTION_PROFILE),
        state in (AC.Preparing, AC.Prepared)

        metadata = Dict(
            "pipewireao.rtc-control.protocol" => ControlClient.PROTOCOL,
            "pipewireao.rtc-control.profile" => ControlClient.profile_name(profile),
            "pipewireao.rtc-control.instance" => "17",
            "pipewireao.rtc-control.owner-pid" => "19",
        )
        initial = AC.Snapshot(
            AC.Classic, nothing, nothing, false, false, "initial", false, false, nothing
        )
        status = ControlClient.encode_completion(
            profile,
            CC.ReplyHeader(
                IDENTITY,
                Int64(17),
                Int64(1),
                ControlClient.operation_id(profile, AC.LifecycleCommand(:status)),
                Int32(0),
            ),
            state,
            initial,
            "",
        )
        runtime = Runtime(
            [
                [capability(profile; state = UInt32(state))],
                [capability(profile; state = UInt32(state)), status],
            ];
            properties = metadata,
        )
        owner = capture_owner(runtime, UInt64(1), profile, 17, 19)
        acquisition = AcquisitionBinding(owner, AC.Classic, nothing)
        proof = source_operation!(runtime, job(runtime), acquisition, :run; running = false)
        @test proof.completion.lifecycle === state
        @test proof.completion.snapshot.cursor === nothing &&
            proof.completion.snapshot.report_cursor === nothing
        @test !proof.completion.snapshot.held && !proof.completion.snapshot.restored
        @test acquisition.previous === nothing && !owner.retired
        @test runtime.mutations == 0 && runtime.queries == 1
        header, payload = CC.decode_request(only(runtime.submitted))
        @test header.operation ==
              ControlClient.operation_id(profile, AC.LifecycleCommand(:status)) &&
            isempty(payload.values)
    end
end
@testset "initial Hold refuses incomplete, changed and regressed acquisition evidence" begin
    profile = AC.CALIBRATION_PROFILE
    metadata = Dict(
        "pipewireao.rtc-control.protocol" => ControlClient.PROTOCOL,
        "pipewireao.rtc-control.profile" => ControlClient.profile_name(profile),
        "pipewireao.rtc-control.instance" => "17",
        "pipewireao.rtc-control.owner-pid" => "19",
    )
    initial(;
        instrument = AC.Classic,
        cursor = nothing,
        report = nothing,
        running = false,
        completed = false,
        phase = "initial",
        held = false,
        restored = false,
        window = nothing,
    ) = AC.Snapshot(
        instrument, cursor, report, running, completed, phase, held, restored, window
    )
    cursor = AC.AcquisitionCursor(UInt64(1), UInt64(2), UInt64(3), UInt64(4))
    function hold_runtime(
        snapshot;
        state = AC.Prepared,
        message = "",
        controller = IDENTITY,
        token = Int64(1),
        instance = Int64(17),
        result = Int32(0),
    )
        reply = ControlClient.encode_completion(
            profile,
            CC.ReplyHeader(controller, instance, token, UInt32(1), result),
            state,
            snapshot,
            message,
        )
        runtime = Runtime(
            [
                [capability(profile; state = UInt32(state))],
                [capability(profile; state = UInt32(state)), reply],
            ];
            properties = metadata,
        )
        owner = capture_owner(runtime, UInt64(1), profile, 17, 19)
        return runtime, AcquisitionBinding(owner, AC.Classic, nothing)
    end
    for snapshot in (
        initial(; running = true),
        initial(; completed = true),
        initial(; phase = "held"),
        initial(; cursor),
        initial(; report = cursor),
        initial(; held = true),
        initial(; restored = true),
        initial(; instrument = AC.Copper),
    )
        runtime, acquisition = hold_runtime(snapshot)
        @test_throws ArgumentError source_operation!(
            runtime, job(runtime), acquisition, :run; running = false
        )
        @test runtime.mutations == 0 && runtime.queries == 1
        @test !acquisition.owner.retired && acquisition.previous === nothing
    end
    for state in (AC.Fault, AC.Stopped)
        runtime, acquisition = hold_runtime(initial(); state)
        @test_throws ArgumentError source_operation!(
            runtime, job(runtime), acquisition, :run; running = false
        )
        @test runtime.mutations == 0 && runtime.queries == 1
    end
    runtime, acquisition = hold_runtime(initial(); message = "preparation failed")
    @test_throws ArgumentError source_operation!(
        runtime, job(runtime), acquisition, :run; running = false
    )
    @test runtime.mutations == 0 && runtime.queries == 1
    runtime, acquisition = hold_runtime(initial())
    acquisition.previous = cursor
    @test_throws ArgumentError source_operation!(
        runtime, job(runtime), acquisition, :run; running = false
    )
    @test acquisition.previous === cursor && runtime.mutations == 0
    # A query without a current cursor cannot erase acknowledged Connect history.
    reply = ControlClient.decode_completion(profile, runtime.records[2][2])
    source_snapshot!(acquisition, reply)
    @test acquisition.previous === cursor
    # Capability observations are retained even when no Connected cursor was
    # acknowledged before an invalid rollback to Prepared.
    runtime, acquisition = hold_runtime(initial())
    runtime.records = [
        [capability(profile; state = UInt32(AC.Connected))], runtime.records...
    ]
    observe_owner!(runtime, job(runtime), acquisition.owner)
    @test acquisition.owner.connected_observed && acquisition.previous === nothing
    @test_throws ArgumentError source_operation!(
        runtime, job(runtime), acquisition, :run; running = false
    )
    @test acquisition.owner.connected_observed && runtime.mutations == 0
    for kwargs in (
        (token = Int64(2),),
        (controller = CC.ControllerIdentity(UInt32(8), UInt64(11), Int64(13)),),
    )
        runtime, acquisition = hold_runtime(initial(); kwargs...)
        short_job = (ticket = (deadline = now(runtime) + Int64(2_000_000),),)
        @test_throws ControlClient.UnknownOutcome source_operation!(
            runtime, short_job, acquisition, :run; running = false
        )
        @test runtime.mutations == 0 && runtime.queries == 1
    end
    runtime, acquisition = hold_runtime(initial(); instance = Int64(18))
    @test_throws ArgumentError source_operation!(
        runtime, job(runtime), acquisition, :run; running = false
    )
    @test runtime.mutations == 0 && runtime.queries == 1
    runtime, acquisition = hold_runtime(nothing; result = Int32(-95))
    @test_throws ArgumentError source_operation!(
        runtime, job(runtime), acquisition, :run; running = false
    )
    @test runtime.mutations == 0 && runtime.queries == 1
    runtime = Runtime(
        [[capability(profile; state = UInt32(AC.Prepared))]]; properties = metadata
    )
    owner = capture_owner(runtime, UInt64(1), profile, 17, 19)
    acquisition = AcquisitionBinding(owner, AC.Classic, nothing)
    @test_throws ControlClient.UnknownOutcome source_operation!(
        runtime,
        (ticket = (deadline = now(runtime) + Int64(2_000_000),),),
        acquisition,
        :run;
        running = false,
    )
    @test runtime.mutations == 0 && runtime.queries == 1
    # Connected Status alone is never a Hold acknowledgement: Pause must finish
    # Connected and actually report non-running ingress.
    connected = initial(; cursor, report = cursor)
    for (state, snapshot) in (
        (AC.Prepared, initial()),
        (AC.Connected, initial(; cursor, report = cursor, running = true)),
    )
        status = ControlClient.encode_completion(
            profile,
            CC.ReplyHeader(IDENTITY, Int64(17), Int64(1), UInt32(1), Int32(0)),
            AC.Connected,
            connected,
            "",
        )
        pause = ControlClient.encode_completion(
            profile,
            CC.ReplyHeader(IDENTITY, Int64(17), Int64(2), UInt32(2), Int32(0)),
            state,
            snapshot,
            "",
        )
        runtime = Runtime(
            [
                [capability(profile; state = UInt32(AC.Connected))],
                [capability(profile; state = UInt32(AC.Connected)), status],
                [capability(profile; state = UInt32(AC.Connected)), status],
                [capability(profile; state = UInt32(state)), pause],
            ];
            properties = metadata,
        )
        owner = capture_owner(runtime, UInt64(1), profile, 17, 19)
        acquisition = AcquisitionBinding(owner, AC.Classic, nothing)
        @test_throws ArgumentError source_operation!(
            runtime, job(runtime), acquisition, :run; running = false
        )
        @test runtime.queries == 1 && runtime.mutations == 1
        @test acquisition.previous === cursor || acquisition.previous == cursor
    end
end
@testset "typed sparse parameter publisher admission" begin
    profile = ParameterSource.PROFILE
    owner = Owner(
        profile,
        ControlClient.Observation(profile, Int64(17), UInt32(19)),
        UInt64(1),
        UInt32(19),
        Int64(17),
        false,
    )
    config = Dict(
        "session" => Dict(
            "sources" => [
                Dict(
                    "factory" => "pipewireao.runtime-parameter",
                    "node.name" => "publisher",
                ),
            ],
            "links" =>
                [Dict("output" => "publisher:output_1", "input" => "graph:matrix")],
        ),
    )
    metadata = Dict(
        "pipewireao.rtc-control.protocol" => ControlClient.PROTOCOL,
        "pipewireao.rtc-control.profile" => ControlClient.profile_name(profile),
        "pipewireao.rtc-control.instance" => "17",
        "pipewireao.rtc-control.owner-pid" => "19",
    )
    completion = ControlClient.encode_completion(
        profile,
        CC.ReplyHeader(IDENTITY, Int64(17), Int64(1), UInt32(14), Int32(0)),
        "graph",
        "matrix",
        Int64(3),
        true,
        false,
        "",
    )
    runtime = Runtime(
        [Pod[], [capability(profile)], [capability(profile), completion]];
        configuration = config,
        parameters = owner,
        properties = metadata,
    )
    command = RunnerCodec.RunnerCommand(
        :parameter, "graph", "matrix", "F32_LE", UInt32[2, 2], "schema", "/tmp/parameter"
    )
    result = submit_parameter!(runtime, job(runtime), command)
    @test policy_text(result.values[1]) == "graph"
    @test !policy_bool(result.values[4])
    @test PipeWireAO.pod_type(result.values[3]) == SPA.POD_NONE
    @test length(runtime.submitted) == 1
    runtime = Runtime([Pod[]]; configuration = config)
    @test_throws ArgumentError submit_parameter!(runtime, job(runtime), command)
    @test isempty(runtime.submitted)
end
@testset "shared codecs and unsupported owner discovery" begin
    runtime = Runtime(Vector{Pod}[])
    @test_throws ArgumentError capture_owner(
        runtime, UInt64(1), "org.example.instrument-owner", 17, 19
    )
    @test isempty(runtime.submitted)
    @test runtime.index == 0
    @test control_request(:run, Int64(7), "running", nothing) ==
        PipeWireAO.run_control_request(7, :running)
    @test control_request(:reset, Int64(8), nothing, nothing) ==
        PipeWireAO.reset_control_request(8)
    run = control_status(PipeWireAO.run_control_status(9, 0, :running), Val(:run))
    @test run.token == 9 && run.result == 0 && run.state == "running"
    reset = control_status(PipeWireAO.reset_control_status(10, 0), Val(:reset))
    @test reset.token == 10 && reset.result == 0
    @test_throws ArgumentError control_status(
        PipeWireAO.run_control_status(11, 1, :running), Val(:run)
    )
    @test_throws ArgumentError control_status(
        PipeWireAO.reset_control_status(12, 1), Val(:reset)
    )
    query = SPA.Props(control_request(:query, Int64(13), nothing, Int64(17)))
    @test Tuple(first.(query.values)) == SourceControl.QUERY_NAMES
end
@testset "signed nanosecond owner deadlines" begin
    clock = Clocks.CachedNanoClock(Int64(-60_000_000_000))
    runtime = Runtime([[capability()], [capability(), bootstrap_reply()]]; clock)
    owner = capture_owner(runtime, UInt64(1), BC.PROFILE, 17, 19)
    @test control_deadline(runtime, job(runtime)) === Int64(-55_000_000_000)
    @test request_owner!(runtime, job(runtime), owner, BC.Command(:connect)).lifecycle ==
        BC.Connected
    header, _ = CC.decode_request(only(runtime.submitted))
    @test header.budget_ns === Int64(5_000_000_000)
    @test runtime.mutations == 1 && runtime.queries == 0
    long_job = (ticket = (deadline = typemax(Int64),),)
    @test control_deadline(runtime, long_job) === now(runtime) + CONTROL_REQUEST_TIMEOUT_NS
    @test_throws TypeError control_deadline(runtime, (ticket = (deadline = 5.0,),))
    Clocks.update!(clock, typemax(Int64))
    @test_throws OverflowError control_deadline(runtime, long_job)
end
end
