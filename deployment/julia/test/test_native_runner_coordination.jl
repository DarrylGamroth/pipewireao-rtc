using Test, JSON3, Sockets, PipeWireAODeployment

const D = PipeWireAODeployment.Deployment
const Codec = PipeWireAODeployment.NativeRunnerCodec
const Envelope = PipeWireAODeployment.NativeControlCodec

struct CoordinationClient
    operations::Vector{UInt32}
end

@testset "runner admission requires a successful matching completion" begin
    for state in ("Ready", "Running")
        good = Dict("ok" => true, "state" => state)
        @test D.runner_admission(good, state) === good
        for reply in (Dict("ok" => false, "state" => state),
                Dict("ok" => true, "state" => "Fault"),
                Dict("ok" => 1, "state" => state), Dict("state" => state))
            @test_throws D.DeploymentError D.runner_admission(reply, state)
        end
    end
end

function PipeWireAODeployment.NativeRunnerClient.request!(client::CoordinationClient,
        command::Codec.RunnerCommand; deadline::Float64, check=()->nothing)
    check()
    operation = Codec.operation_id(command)
    operation == 3 || error("fixture expects status only")
    push!(client.operations, operation)
    details = (running=false, owned_nodes=UInt64(0), owned_links=UInt64(0),
        discarded_buffers=UInt64(0), discarded_by_sink=Dict{String,UInt64}())
    result = Codec.RunnerResult{:status,typeof(details)}(Codec.Observed, details)
    header = Envelope.ReplyHeader(Envelope.ControllerIdentity(UInt32(7), UInt64(8), Int64(9)),
        Int64(10), Int64(length(client.operations)), operation, Int32(0))
    Codec.Completion(header, Codec.Ready, result, nothing)
end

function coordination_runner(directory, client; source=nothing, broker=nothing)
    record = Dict{String,Any}("phase" => "running", "admitted" => true, "error" => nothing)
    D.DeploymentRunner((;), directory, Dict{String,Any}("owners" => Any[]),
        Dict{String,String}(), Set{Int}(), Tuple{String,Base.Process}[],
        IdDict{Base.Process,Int}(), directory, nothing, client, broker, nothing,
        nothing, source, nothing, 0, source === nothing ? nothing : "running",
        false, false, false, nothing, record, nothing, nothing, nothing)
end

@testset "invalid runner commands do not terminate or pause a deployment" begin
    mktempdir() do directory
        client = CoordinationClient(UInt32[])
        path = joinpath(directory, "public.sock")
        broker = listen(path)
        runner = coordination_runner(directory, client; broker)
        try
            for (index, argv) in enumerate((["bogus"], ["property", "g", "n:x", "float", "NaN"], ["status"]))
                peer = connect(path)
                try
                    write(peer, JSON3.write(Dict("version" => 1, "id" => string(index), "argv" => argv)) * "\n")
                    serving = @async D.fixture_serve_control(runner)
                    reply = JSON3.read(String(D._read_line_bounded(peer, D.MAX_REPLY_BYTES,
                        D.monotonic() + 5)), Dict{String,Any})
                    @test reply["id"] == string(index)
                    @test reply["ok"] == (argv == ["status"])
                    @test_nowarn fetch(serving)
                    @test runner.record["admitted"]
                    @test !runner.stopping && !runner.source_failed
                finally
                    close(peer)
                end
            end
            @test client.operations == [UInt32(3)]
        finally
            close(broker)
        end

        # No source files/client exist: any source coordination would fail.
        source = Dict("role" => "source", "control-request" => "missing.request",
            "control-reply" => "missing.reply")
        source_runner = coordination_runner(directory, client; source)
        for argv in (["stop", ""], ["start", ""], ["parameter", "g", "p", "F32_LE", "0", "", "file"])
            reply = D.fixture_coordinate(source_runner, argv, "invalid")
            @test reply["ok"] === false
            @test source_runner.source_id == 0
            @test source_runner.source_state == "running"
            @test !source_runner.source_failed && source_runner.record["admitted"]
        end
        @test client.operations == [UInt32(3)]
    end
end
