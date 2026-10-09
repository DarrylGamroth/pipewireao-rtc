using Test
using JSON3
include("owner_protocol.jl")
using .HILOwnerProtocol
const Protocol = HILOwnerProtocol

function options_arguments(root)
    return [
        "--profile", "classic", "--graph", joinpath(root, "plant.toml"),
        "--rate", "500", "--exposure-ns", "2000000", "--remote", joinpath(root,"isolated-core"),
        "--prepared-event", joinpath(root, "prepared"),
        "--connect-request", joinpath(root, "connect-request"),
        "--connect-reply", joinpath(root, "connect-reply"),
        "--quit-request", joinpath(root, "quit"),
        "--control-request", joinpath(root, "request.json"),
        "--control-reply", joinpath(root, "reply.json"),
        "--output", joinpath(root, "result.json"),
    ]
end

@testset "complete-frame CLI" begin
    mktempdir() do root
        arguments = options_arguments(root)
        options = Protocol.parse_options(arguments)
        @test options.profile === :classic
        @test options.backend === :cpu
        @test !options.correction_diagnostics
        @test !options.detector_observation
        @test Protocol.parse_options([arguments;"--detector-observation";"true"]).detector_observation
        @test !Protocol.parse_options([arguments;"--detector-observation";"false"]).detector_observation
        @test_throws ArgumentError Protocol.parse_options([arguments;"--detector-observation";"yes"])
        @test_throws ArgumentError Protocol.parse_options([arguments;"--detector-observation";"true";
            "--transport";"heart";"--controller-request";joinpath(root,"heart.request");
            "--controller-reply";joinpath(root,"heart.reply")])
        @test Protocol.parse_options([arguments; "--correction-diagnostics"; "true"]).correction_diagnostics
        @test !Protocol.parse_options([arguments; "--correction-diagnostics"; "false"]).correction_diagnostics
        @test_throws ArgumentError Protocol.parse_options([arguments; "--correction-diagnostics"; "yes"])
        @test Protocol.parse_options([arguments; "--correction-diagnostics"; "true"; "--backend"; "cuda"]).correction_diagnostics
        copper = copy(arguments)
        copper[findfirst(==("--profile"), copper) + 1] = "copper"
        @test Protocol.parse_options([copper; "--correction-diagnostics"; "true"]).correction_diagnostics
        @test Protocol.parse_options([arguments; "--correction-diagnostics"; "true";
            "--transport"; "heart"; "--controller-node"; "fixture.heart";
            "--controller-pid"; "123"; "--controller-instance"; "17"]).correction_diagnostics
        @test options.frames == 16
        @test options.period_ns == 2_000_000
        native_options = copy(arguments)
        for key in ("--control-request", "--control-reply")
            index = findfirst(==(key), native_options)
            index === nothing || splice!(native_options, index:index + 1)
        end
        # Native PipeWire Props source controls need no legacy file paths.
        native = Protocol.parse_options([native_options; "--control-node"; "simulator-source"])
        @test native.control_request === nothing && native.control_reply === nothing
        @test native.control_node == "simulator-source"
        lifecycle_arguments = String[]
        for index in 1:2:length(arguments)
            arguments[index] in ("--prepared-event", "--connect-request", "--connect-reply",
                "--quit-request", "--control-request", "--control-reply") && continue
            append!(lifecycle_arguments, arguments[index:index + 1])
        end
        append!(lifecycle_arguments, ["--control-node", "calibration.lifecycle",
            "--control-instance", string(typemax(Int64))])
        lifecycle = Protocol.parse_options(lifecycle_arguments; native_lifecycle=true)
        @test lifecycle.control_instance == typemax(Int64)
        @test lifecycle.prepared_event === nothing && lifecycle.connect_request === nothing
        @test lifecycle.connect_reply === nothing && lifecycle.quit_request === nothing
        @test lifecycle.control_request === nothing && lifecycle.control_reply === nothing
        @test Protocol.require_fresh_instance(lifecycle) === nothing
        @test_throws ArgumentError Protocol.parse_options(arguments; native_lifecycle=true)
        @test_throws ArgumentError Protocol.parse_options(lifecycle_arguments[1:end-2]; native_lifecycle=true)
        @test_throws ArgumentError Protocol.parse_options([lifecycle_arguments; "--quit-request"; "x"];
            native_lifecycle=true)
        relative = copy(lifecycle_arguments)
        relative[findfirst(==("--remote"), relative) + 1] = "relative-remote"
        @test_throws ArgumentError Protocol.parse_options(relative; native_lifecycle=true)
        @test_throws ArgumentError Protocol.parse_options([arguments; "--control-instance"; "1"])
        @test_throws ArgumentError Protocol.parse_options([native_options; "--control-request"; "only-one"])
        @test Protocol.rounded_period(3) == 333_333_333
        @test Protocol.parse_options([arguments; "--frames"; "256"]).frames == 256
        @test Protocol.parse_options([arguments; "--backend"; "cuda"]).backend === :cuda
        for invalid in ("0", "257", "-1", "1.5", "true", string(big(2)^100))
            @test_throws ArgumentError Protocol.parse_options([arguments; "--frames"; invalid])
        end
        @test_throws ArgumentError Protocol.parse_options([arguments; "--backend"; "metal"])
        @test_throws ArgumentError Protocol.parse_options([arguments; "--rate"; "500"])
        bad_rate = copy(arguments)
        bad_rate[findfirst(==("--rate"), bad_rate) + 1] = "501"
        @test_throws ArgumentError Protocol.parse_options(bad_rate)
        @test_throws ArgumentError Protocol.parse_options([arguments; "--unknown"; "x"])
        @test_throws ArgumentError Protocol.parse_options(arguments[1:end-1])
        oversize_exposure = copy(arguments)
        oversize_exposure[findfirst(==("--exposure-ns"), oversize_exposure) + 1] = "2000001"
        @test_throws ArgumentError Protocol.parse_options(oversize_exposure)
        @test Protocol.require_fresh_instance(options) === nothing
        write(options.prepared_event, "stale")
        @test_throws ArgumentError Protocol.require_fresh_instance(options)
    end
end

@testset "wall periods remain future" begin
    @test Protocol.next_deadline(UInt64(100), UInt64(10), UInt64(105)) == (UInt64(110), UInt64(0))
    @test Protocol.next_deadline(UInt64(100), UInt64(10), UInt64(110)) == (UInt64(120), UInt64(1))
    @test Protocol.next_deadline(UInt64(100), UInt64(10), UInt64(139)) == (UInt64(140), UInt64(3))
    @test Protocol.next_deadline(UInt64(100), UInt64(10), UInt64(140)) == (UInt64(150), UInt64(4))
    @test_throws OverflowError Protocol.next_deadline(typemax(UInt64), UInt64(10), UInt64(1))
end

@testset "serialized typed control" begin
    state = Protocol.OwnerState()
    resets = Ref(0)
    reset_owner!() = (resets[] += 1)
    request(id, operation) = JSON3.write((version=1, id=id, operation=operation))
    apply(payload) = Protocol.control!(state, payload, UInt64(100), UInt64(10), reset_owner!)
    reply = apply(request(1, "resume"))
    @test reply.ok && reply.state == "running" && reply.sequence == 0
    @test state.deadline_ns == 110
    @test !apply(request(1, "pause")).ok
    @test state.running
    @test !apply(request(2, "reset")).ok
    @test resets[] == 0 && state.running
    # The owner sets sequence only after command adoption; pause replies with
    # that completed identity and never acknowledges an outstanding frame.
    state.sequence = 3
    reply = apply(request(3, "pause"))
    @test reply.ok && reply.state == "paused" && reply.sequence == 3
    @test state.deadline_ns == 0
    state.completed = true
    @test !apply(request(4, "resume")).ok
    @test !state.running && state.sequence == 3
    @test Protocol.response(state, 4, "resume").completed
    @test apply(request(5, "reset")).ok
    @test resets[] == 1 && state.sequence == 0 && !state.completed
    @test apply(request(6, "resume")).ok
    snapshot = (state.running, state.completed, state.sequence, state.last_request_id, state.deadline_ns)
    for payload in (
        "[1]", "null", "{", "x"^16385,
        JSON3.write((version=1, id=true, operation="pause")),
        JSON3.write((version=true, id=7, operation="pause")),
        JSON3.write((version=1, id=7.0, operation="pause")),
        JSON3.write((version=2, id=7, operation="pause")),
        JSON3.write((version=1, id=7, operation="stop")),
        JSON3.write((version=1, id=7, operation="pause", extra=1)),
    )
        @test !apply(payload).ok
        @test (state.running, state.completed, state.sequence, state.last_request_id, state.deadline_ns) == snapshot
    end
    @test apply(request(7, "pause")).ok
    @test apply(request(8, "pause")).ok
    @test !apply(request(7, "resume")).ok
    before_status = (state.running, state.completed, state.sequence, state.deadline_ns)
    @test apply(request(9, "status")).ok
    @test (state.running, state.completed, state.sequence, state.deadline_ns) == before_status
    mktempdir() do root
        path = joinpath(root, "reply.json")
        Protocol.write_json_atomic(path, apply(request(10, "reset")))
        written = JSON3.read(read(path, String))
        @test written.id == 10 && written.state == "paused" && written.sequence == 0 && !written.completed
        @test length(readdir(root)) == 1
        @test_throws ArgumentError Protocol.write_json_atomic(path, (payload="x"^100,); maximum=20)
        @test JSON3.read(read(path, String)).id == 10
    end
end

@testset "explicit HEART transport and native controller identity" begin
    mktempdir() do root
        arguments = options_arguments(root)
        @test Protocol.parse_options(arguments).transport === :scientific
        heart = [arguments; "--transport"; "heart"; "--controller-node"; "fixture.heart";
            "--controller-pid"; "123"; "--controller-instance"; "17"]
        @test Protocol.parse_options(heart).transport === :heart
        @test Protocol.parse_options(heart).controller_node == "fixture.heart"
        @test Protocol.parse_options(heart).controller_pid == UInt32(123)
        @test Protocol.parse_options(heart).controller_instance == Int64(17)
        @test_throws ArgumentError Protocol.parse_options([arguments; "--transport"; "heart"])
        @test_throws ArgumentError Protocol.parse_options([arguments; "--transport"; "invalid"])
        @test_throws ArgumentError Protocol.parse_options([arguments; "--controller-request"; "x"])
        @test_throws ArgumentError Protocol.parse_options([arguments; "--controller-request"; "x"; "--controller-reply"; "y"])
        bad = copy(heart)
        bad[findfirst(==("--controller-instance"),bad)+1] = "0"
        @test_throws ArgumentError Protocol.parse_options(bad)
        for (key, value) in (("--controller-pid","0"),("--controller-pid","4294967296"),
                ("--controller-node","invalid/name"),("--remote","implicit-remote"))
            bad = copy(heart)
            bad[findfirst(==(key),bad)+1] = value
            @test_throws ArgumentError Protocol.parse_options(bad)
        end
    end
end
