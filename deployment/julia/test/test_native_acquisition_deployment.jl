using Test, PipeWireAODeployment

const Deployment = PipeWireAODeployment.Deployment
const Codec = PipeWireAODeployment.NativeAcquisitionLifecycleCodec
const Envelope = PipeWireAODeployment.NativeControlCodec
const Common = PipeWireAODeployment.Common

function source_descriptor(instrument, protocol)
    node = "fixture.acquisition"
    return Dict{String,Any}("role" => "simulator", "environment" => Dict(),
        "control-protocol" => protocol, "control-node" => node, "instrument" => instrument,
        "argv" => ["julia", "owner.jl", "--profile", instrument,
            "--remote", "@RUNTIME@/@REMOTE@", "--control-node", node,
            "--control-instance", "@SOURCE_OWNER_INSTANCE@"])
end

@testset "Native acquisition descriptor has no live file fallback" begin
    mktempdir() do directory
        for name in ("session.conf.in", "core.conf.in", "client.conf.in")
            write(joinpath(directory, name), "{}\n")
        end
        contract = Dict("cpus" => [15], "leader-cpu" => 15, "rt-priority" => 0,
            "threads" => [], "locked-bytes" => 0)
        for instrument in ("classic", "copper"), protocol in
                ("pipewireao.rtc.calibration-lifecycle/1", "pipewireao.rtc.correction-lifecycle/1")
            source = source_descriptor(instrument, protocol)
            specification = Dict("version" => 1, "name" => "native-acquisition", "session" => "session.conf.in",
                "core" => "core.conf.in", "client" => Dict(role => "client.conf.in" for role in ("core", "rtc", "simulator")),
                "placement" => Dict(role => deepcopy(contract) for role in ("core", "rtc", "simulator")),
                "owners" => [source], "source-owner" => "simulator", "environment" => Dict(),
                "cpu-latency-us" => nothing, "artifacts" => Dict("session.conf.in" => Deployment.digest(joinpath(directory, "session.conf.in"))))
            path = joinpath(directory, "deployment.conf")
            Common.write_json(path, specification)
            @test Deployment.profile(path, "/unused") == specification
            for (key, value) in (("prepared", "old.prepared"), ("control-request", "old.request"),
                    ("instrument", "unknown"), ("control-node", "invalid node"),
                    ("control-protocol", "pipewireao.rtc.calibration-lifecycle/2"))
                invalid = deepcopy(specification)
                invalid["owners"][1][key] = value
                Common.write_json(path, invalid)
                @test_throws Deployment.DeploymentError Deployment.profile(path, "/unused")
            end
            for flag in ("--control-instance", "--profile", "--remote", "--control-node")
                invalid = deepcopy(specification)
                argv = invalid["owners"][1]["argv"]
                argv[findfirst(==(flag), argv) + 1] = "wrong"
                Common.write_json(path, invalid)
                @test_throws Deployment.DeploymentError Deployment.profile(path, "/unused")
            end
            invalid = deepcopy(specification)
            append!(invalid["owners"][1]["argv"], ["--quit-request", "old.quit"])
            Common.write_json(path, invalid)
            @test_throws Deployment.DeploymentError Deployment.profile(path, "/unused")
        end
    end
end

mutable struct AcquisitionClientFixture
    operations::Vector{Symbol}
    failure::Bool
    rejected::Bool
    running::Bool
end

function PipeWireAODeployment.NativeAcquisitionLifecycleClient.request!(client::AcquisitionClientFixture,
        operation::Symbol; deadline::Float64, check=()->nothing)
    check()
    time_ns() / 1e9 < deadline || error("fixture expired")
    push!(client.operations, operation)
    client.failure && error("lost exact owner")
    header = Envelope.ReplyHeader(Envelope.ControllerIdentity(UInt32(1), UInt64(2), Int64(3)),
        Int64(4), Int64(length(client.operations)), UInt32(1), Int32(client.rejected ? -95 : 0))
    client.rejected && return Codec.Rejection(header, Codec.Connected, "unsupported")
    operation === :resume && (client.running = true)
    operation === :pause && (client.running = false)
    cursor = Codec.AcquisitionCursor(typemax(UInt64), UInt64(1), UInt64(0), typemax(UInt64))
    snapshot = Codec.Snapshot(Codec.Classic, cursor, nothing, client.running, false,
        "initial", false, false, nothing)
    return Codec.Completion(header, Codec.Connected, snapshot, "")
end

function acquisition_deployment_fixture(client)
    source = source_descriptor("classic", "pipewireao.rtc.calibration-lifecycle/1")
    record = Dict{String,Any}("phase" => "running", "admitted" => true,
        "error" => nothing, "processes" => Dict())
    return Deployment.DeploymentRunner((;), "/unused", Dict{String,Any}("owners" => [source]),
        Dict{String,String}(), Set{Int}(), Tuple{String,Base.Process}[], IdDict{Base.Process,Int}(),
        nothing, nothing, nothing, nothing, nothing, nothing, source, client,
        0, "paused", false, false, false, nothing, record, nothing, nothing, nothing)
end

@testset "Acquisition caller preserves unsigned cursors and known rejection" begin
    client = AcquisitionClientFixture(Symbol[], false, false, false)
    deployment = acquisition_deployment_fixture(client)
    initial = Deployment.source_control(deployment, "pause"; initial=true)
    @test initial["ok"] && initial["state"] == "paused" && initial["sequence"] == 0
    @test initial["cursor"].domain == typemax(UInt64)
    @test initial["cursor"].model_ns == typemax(UInt64)
    @test initial["report_cursor"] === nothing
    @test initial["native_token"] == 1 && initial["endpoint_instance"] == 4
    mktempdir() do directory
        path = joinpath(directory, "saved-report.json")
        Common.write_json(path, deployment.record)
        saved = Common.read_json(path)["source"]["cursor"]
        @test saved["domain"] == typemax(UInt64) && saved["model_ns"] == typemax(UInt64)
    end
    @test Deployment.source_control(deployment, "resume")["state"] == "running"
    @test Deployment.source_control(deployment, "status")["state"] == "running"
    @test client.operations == [:pause, :resume, :status]
    client.rejected = true
    rejected = Deployment.source_control(deployment, "resume"; allow_rejection=true)
    @test !rejected["ok"] && rejected["error"] == "unsupported"
    @test rejected["cursor"] === nothing && rejected["state"] === nothing
    @test !deployment.source_failed && deployment.record["admitted"]
    @test deployment.record["source"]["id"] == 3
    before = length(client.operations)
    supervisor = PipeWireAODeployment.NativeSupervisorCodec
    binding = supervisor.Binding("source","pipewireao.rtc.calibration-lifecycle/1",
        UInt32(101),UInt32(21),UInt64(22),Int64(4))
    snapshot = Codec.Snapshot(Codec.Classic,initial["cursor"],nothing,false,false,
        "initial",false,false,nothing)
    observation = supervisor.SourceObservation(binding,Int64(1),Codec.Connected,snapshot)
    before_reset = supervisor.Snapshot([supervisor.OwnedProcess("source",UInt32(101))],
        nothing,observation,nothing)
    refused_reset = try
        Deployment.coordinate(deployment,PipeWireAODeployment.NativeRunnerCodec.RunnerCommand(:reset),
            before_reset;deadline=time_ns()/1e9+5,check=()->nothing)
        nothing
    catch error
        error
    end
    @test refused_reset isa Deployment.CoordinationRejected
    @test refused_reset.field == "source.reset"
    @test length(client.operations) == before
    client.rejected = false
    client.failure = true
    @test_throws Deployment.DeploymentError Deployment.source_control(deployment, "status")
    @test deployment.source_failed && !deployment.record["admitted"]
    @test_throws Deployment.DeploymentError Deployment.source_control(deployment, "pause"; initial=true)
    @test length(client.operations) == before + 1
    unprepared = acquisition_deployment_fixture(nothing)
    @test_throws Deployment.DeploymentError Deployment.source_control(unprepared, "pause"; initial=true)
    @test unprepared.source_client === nothing && unprepared.source_id == 0
end
