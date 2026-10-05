using Test
include("owner_protocol.jl")

# Load only the actual owner helpers. These tests exercise file controls and
# pacing without importing a plant, preparing a graph or connecting transport.
module OwnerLoopFixture
const Protocol = Main.HILOwnerProtocol
end

function owner_helper_definition(expression, name)
    expression isa Expr && expression.head === :function || return false
    signature = expression.args[1]
    signature isa Expr && signature.head === :where && (signature = signature.args[1])
    return signature isa Expr && signature.head === :call && signature.args[1] === name
end

source = Meta.parseall(read(joinpath(@__DIR__, "simulator.jl"), String))
for name in (:consume_control_request!, :pace_owner!)
    definitions = filter(expression -> owner_helper_definition(expression, name), source.args)
    length(definitions) == 1 || error("expected one owner helper definition: $name")
    Core.eval(OwnerLoopFixture, only(definitions))
end

const CONTROL_PUBLICATION_OBSERVER = Ref{Union{Nothing,Function}}(nothing)
function HILOwnerProtocol.write_json_atomic(path::String, value; maximum=HILOwnerProtocol.MAX_REPLY_BYTES)
    observer = CONTROL_PUBLICATION_OBSERVER[]
    observer === nothing || observer(:before, path, value)
    invoke(HILOwnerProtocol.write_json_atomic, Tuple{AbstractString,Any}, path, value; maximum)
    observer === nothing || observer(:after, path, value)
    return nothing
end

owner_noop() = nothing
request(id, operation) = (; version=1, id, operation)

function legacy_poll_bytes(path, repetitions)
    return @allocated for _ in 1:repetitions
        if isfile(path)
            open(path) do io
                String(read(io, HILOwnerProtocol.MAX_REQUEST_BYTES + 1))
            end
        end
    end
end

function quiet_poll_bytes(options, state, repetitions; paced=false)
    return @allocated for _ in 1:repetitions
        ispath(options.quit_request) && break
        OwnerLoopFixture.consume_control_request!(options, state, UInt64(2_000_000), owner_noop, owner_noop)
        ispath(options.quit_request) && break
        paced && OwnerLoopFixture.pace_owner!()
    end
end

function captured_poll_bytes(options, state, payload)
    reset_owner! = () -> payload[1]
    return @allocated for _ in 1:64
        OwnerLoopFixture.consume_control_request!(options, state, UInt64(2_000_000), reset_owner!, owner_noop)
    end
end

pacing_bytes() = @allocated OwnerLoopFixture.pace_owner!()
function marker_poll_bytes(path::String)
    return @allocated for _ in 1:64
        ispath(path)
    end
end

@testset "consumed control removes persistent-read allocation" begin
    mktempdir() do root
        options = (; control_request=joinpath(root, "request.json"),
            control_reply=joinpath(root, "reply.json"), quit_request=joinpath(root, "quit"))
        state = HILOwnerProtocol.OwnerState()
        HILOwnerProtocol.write_json_atomic(options.control_request, request(1, "status"))
        marker_poll_bytes(options.control_request)
        @test marker_poll_bytes(options.control_request) == 0
        legacy_poll_bytes(options.control_request, 1)
        before = legacy_poll_bytes(options.control_request, 64)
        @test before > 0
        reply = OwnerLoopFixture.consume_control_request!(options, state, UInt64(2_000_000), owner_noop, owner_noop)
        @test reply.ok && reply.id == 1 && reply.operation == "status"
        @test !ispath(options.control_request)
        @test marker_poll_bytes(options.control_request) == 0
        @test OwnerLoopFixture.consume_control_request!(options, state, UInt64(2_000_000), owner_noop, owner_noop) === nothing
        quiet_poll_bytes(options, state, 64)
        quiet_poll_bytes(options, state, 64; paced=true)
        unpaced = quiet_poll_bytes(options, state, 64)
        paced = quiet_poll_bytes(options, state, 64; paced=true)
        @test unpaced == paced == 0
        # The live reset closure captures the large prepared scientific owner.
        # A zero-sized function does not expose per-call closure boxing.
        payload = ntuple(i -> Float64(i), 512)
        captured_poll_bytes(options, state, payload)
        @test captured_poll_bytes(options, state, payload) == 0
        @test state.last_request_id == 1 && !state.running && state.sequence == 0
        pacing_bytes()
        @test pacing_bytes() == 0
        progressed = Ref(false)
        other = @async (progressed[] = true)
        @test OwnerLoopFixture.pace_owner!() === nothing
        wait(other)
        @test progressed[]
        println("OWNER_POLL_ALLOCATIONS repetitions=64 legacy_existing_request_bytes=", before,
            " consumed_absent_request_bytes=", unpaced, " paced_absent_request_bytes=", paced)
    end
end

@testset "consume before ACK preserves a serialized next request" begin
    mktempdir() do root
        options = (; control_request=joinpath(root, "request.json"),
            control_reply=joinpath(root, "reply.json"), quit_request=joinpath(root, "quit"))
        state = HILOwnerProtocol.OwnerState()
        HILOwnerProtocol.write_json_atomic(options.control_request, request(1, "status"))
        observations = Tuple{Symbol,Int}[]
        CONTROL_PUBLICATION_OBSERVER[] = function (stage, path, value)
            path == options.control_reply || return nothing
            @test !ispath(options.control_request)
            push!(observations, (stage, value.id))
            if stage === :after && value.id == 1
                published = HILOwnerProtocol.JSON3.read(read(path, String))
                @test published.id == 1 && published.ok
                # The broker can now publish its next request immediately.
                HILOwnerProtocol.write_json_atomic(options.control_request, request(2, "status"))
            end
            return nothing
        end
        try
            first = OwnerLoopFixture.consume_control_request!(options, state, UInt64(2_000_000), owner_noop, owner_noop)
            @test first.id == 1 && ispath(options.control_request)
            second = OwnerLoopFixture.consume_control_request!(options, state, UInt64(2_000_000), owner_noop, owner_noop)
            @test second.id == 2 && second.ok && !ispath(options.control_request)
            @test observations == [(:before, 1), (:after, 1), (:before, 2), (:after, 2)]
        finally
            CONTROL_PUBLICATION_OBSERVER[] = nothing
        end
    end
end

@testset "control errors, pause and reset retain their semantics" begin
    mktempdir() do root
        options = (; control_request=joinpath(root, "request.json"),
            control_reply=joinpath(root, "reply.json"), quit_request=joinpath(root, "quit"))
        state = HILOwnerProtocol.OwnerState()
        resets = Ref(0)
        reports = Ref(0)
        reset_owner! = () -> (resets[] += 1)
        report_owner! = () -> begin
            @test !ispath(options.control_request)
            reports[] += 1
        end
        function apply(id, operation)
            HILOwnerProtocol.write_json_atomic(options.control_request, request(id, operation))
            reply = OwnerLoopFixture.consume_control_request!(options, state, UInt64(2_000_000), reset_owner!, report_owner!)
            @test !ispath(options.control_request)
            published = HILOwnerProtocol.JSON3.read(read(options.control_reply, String))
            @test published.id == reply.id && published.operation == reply.operation && published.ok == reply.ok
            return reply
        end
        @test apply(1, "resume").ok && state.running
        state.sequence = 5
        rejected_reset = apply(2, "reset")
        @test !rejected_reset.ok && state.running && state.sequence == 5 && resets[] == 0
        @test apply(3, "pause").ok && !state.running && state.sequence == 5
        @test reports[] == 1
        @test apply(4, "reset").ok && state.sequence == 0 && resets[] == 1
        @test reports[] == 2
        stale = apply(4, "reset")
        @test !stale.ok && stale.error == "stale request id" && resets[] == 1
        @test reports[] == 2
        write(options.control_request, "{invalid}")
        malformed = OwnerLoopFixture.consume_control_request!(options, state, UInt64(2_000_000), reset_owner!, report_owner!)
        @test !malformed.ok && malformed.id == 0 && malformed.error == "invalid JSON request"
        @test !ispath(options.control_request)
        @test state.last_request_id == 4 && state.sequence == 0 && !state.running
        write(options.control_request, repeat(" ", HILOwnerProtocol.MAX_REQUEST_BYTES + 1))
        oversized = OwnerLoopFixture.consume_control_request!(options, state, UInt64(2_000_000), reset_owner!, report_owner!)
        @test !oversized.ok && !ispath(options.control_request)
        @test state.last_request_id == 4
        mkdir(options.control_request)
        previous_reply = read(options.control_reply)
        @test_throws ArgumentError OwnerLoopFixture.consume_control_request!(options, state,
            UInt64(2_000_000), reset_owner!, report_owner!)
        @test isdir(options.control_request)
        @test read(options.control_reply) == previous_reply
    end
end

@testset "FIFO and symlink requests are rejected before reading" begin
    mktempdir() do root
        options = (; control_request=joinpath(root, "request.json"),
            control_reply=joinpath(root, "reply.json"), quit_request=joinpath(root, "quit"))
        state = HILOwnerProtocol.OwnerState()
        outside = joinpath(root, "outside-request.json")
        HILOwnerProtocol.write_json_atomic(outside, request(9, "status"))
        original = read(outside)
        symlink(outside, options.control_request)
        @test_throws Base.IOError OwnerLoopFixture.consume_control_request!(options, state,
            UInt64(2_000_000), owner_noop, owner_noop)
        @test islink(options.control_request)
        @test read(outside) == original
        @test !ispath(options.control_reply)
        @test state.last_request_id == 0
        islink(options.control_request) && rm(options.control_request)
        ispath(options.control_reply) && rm(options.control_reply)

        # A bounded child makes a regression to blocking FIFO open fail instead
        # of hanging the test runner. It loads only the actual control helper.
        run(`mkfifo $(options.control_request)`)
        fifo_check = """
            include(ARGS[1])
            module FIFOFixture
            const Protocol = Main.HILOwnerProtocol
            end
            source = Meta.parseall(read(ARGS[2], String))
            definition = only(filter(source.args) do expression
                signature = expression isa Expr && expression.head === :function ? expression.args[1] : nothing
                signature isa Expr && signature.head === :where && (signature = signature.args[1])
                expression isa Expr && expression.head === :function &&
                    signature isa Expr && signature.head === :call &&
                    signature.args[1] === :consume_control_request!
            end)
            Core.eval(FIFOFixture, definition)
            state = HILOwnerProtocol.OwnerState()
            options = (; control_request=ARGS[3], control_reply=ARGS[4])
            try
                FIFOFixture.consume_control_request!(options, state, UInt64(2_000_000), ()->nothing, ()->nothing)
                error("FIFO control request was accepted")
            catch exception
                exception isa ArgumentError || rethrow()
                @assert ispath(options.control_request) && !ispath(options.control_reply)
                @assert state.last_request_id == 0
                println("FIFO_REJECTED_BEFORE_READ")
            end
            """
        command = Cmd([something(Sys.which("timeout")), "15s", Base.julia_cmd().exec...,
            "--startup-file=no", "--project=" * dirname(Base.active_project()), "-e", fifo_check,
            joinpath(@__DIR__, "owner_protocol.jl"), joinpath(@__DIR__, "simulator.jl"),
            options.control_request, options.control_reply])
        output = IOBuffer()
        result = run(pipeline(ignorestatus(command); stdout=output, stderr=output))
        @test result.exitcode == 0
        @test occursin("FIFO_REJECTED_BEFORE_READ", String(take!(output)))
        @test ispath(options.control_request) && !ispath(options.control_reply)
    end
end
