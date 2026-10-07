using Test, PipeWireAODeployment

const D = PipeWireAODeployment.Deployment
const C = PipeWireAODeployment.Common

function terminal_fixture(base; phase="running", error=nothing, cleanup_errors=String[])
    runtime = joinpath(base, "run-fixture")
    mkpath(runtime)
    record = Dict{String,Any}("phase" => phase, "admitted" => true, "error" => error,
        "processes" => Dict{String,Any}())
    isempty(cleanup_errors) || (record["cleanup_errors"] = copy(cleanup_errors))
    return D.DeploymentRunner((;), base, Dict{String,Any}("owners" => Any[]), Dict{String,String}(),
        Set{Int}(), Tuple{String,Union{Base.Process,PipeWireAODeployment.SystemdOwners.Service}}[],
        IdDict{Base.Process,Int}(), runtime, nothing, nothing, nothing, nothing, nothing,
        nothing, nothing, 0, nothing, false, false, false, joinpath(base, "state.json"),
        record, nothing, nothing, nothing,
        Dict{String,PipeWireAODeployment.NativeOwnerBootstrapClient.Connection}())
end

@testset "completed run has no second terminal cleanup" begin
    mktempdir() do directory
        deployment = terminal_fixture(directory)
        D._emergency_cleanup!(deployment, Ref(true))
        @test isdir(deployment.runtime)
        @test deployment.record["phase"] == "running"
        @test deployment.record["admitted"]
        @test !isfile(deployment.state_path)
    end
end

@testset "emergency cleanup preserves prior failure and uncertain runtime" begin
    withenv("NOTIFY_SOCKET" => nothing) do
        mktempdir() do directory
            deployment = terminal_fixture(directory; phase="failed", error="required core stopped",
                cleanup_errors=["ingress revocation unconfirmed"])
            D._emergency_cleanup!(deployment, Ref(false))
            @test deployment.record["phase"] == "failed"
            @test deployment.record["error"] == "required core stopped"
            @test !deployment.record["admitted"]
            @test deployment.record["retained_runtime"] == deployment.runtime
            @test isdir(deployment.runtime)
            saved = C.read_json(deployment.state_path)
            @test saved["phase"] == "failed"
            @test saved["error"] == "required core stopped"
            @test saved["retained_runtime"] == deployment.runtime
        end
    end
end

@testset "successful emergency stop does not erase a prior owner failure" begin
    withenv("NOTIFY_SOCKET" => nothing) do
        mktempdir() do directory
            deployment = terminal_fixture(directory; phase="failed", error="required core stopped")
            D._emergency_cleanup!(deployment, Ref(false))
            @test deployment.record["phase"] == "failed"
            @test deployment.record["error"] == "required core stopped"
            @test C.read_json(deployment.state_path)["phase"] == "failed"
            @test !ispath(deployment.runtime)
        end
    end
end

@testset "emergency cleanup failure retains the original cause and runtime" begin
    withenv("NOTIFY_SOCKET" => nothing) do
        mktempdir() do directory
            deployment = terminal_fixture(directory; phase="failed", error="required core stopped")
            push!(deployment.spec["owners"], Dict("role" => "fixture-without-native-lifecycle"))
            D._emergency_cleanup!(deployment, Ref(false))
            @test deployment.record["phase"] == "failed"
            @test deployment.record["error"] == "required core stopped"
            @test !isempty(deployment.record["cleanup_errors"])
            @test deployment.record["retained_runtime"] == deployment.runtime
            @test isdir(deployment.runtime)
            @test C.read_json(deployment.state_path)["error"] == "required core stopped"
        end
    end
end

@testset "confirmed emergency cleanup records a stop" begin
    withenv("NOTIFY_SOCKET" => nothing) do
        mktempdir() do directory
            deployment = terminal_fixture(directory)
            D._emergency_cleanup!(deployment, Ref(false))
            @test deployment.record["phase"] == "stopped"
            @test deployment.record["error"] === nothing
            @test !deployment.record["admitted"]
            @test !ispath(deployment.runtime)
            @test C.read_json(deployment.state_path)["phase"] == "stopped"
        end
    end
end

@testset "retained _run_locked diagnostics survive Julia process exit" begin
    mktempdir() do directory
        script = raw"""
            using PipeWireAODeployment
            const D = PipeWireAODeployment.Deployment
            const SO = PipeWireAODeployment.SystemdOwners
            record = Dict{String,Any}(
                "phase" => "preflight", "admitted" => false, "error" => nothing,
                "cleanup_errors" => ["cleanup identity uncertain"],
                "processes" => Dict{String,Any}())
            deployment = D.DeploymentRunner((;), ARGS[1],
                Dict{String,Any}("owners" => Any[]), Dict{String,String}(), Set{Int}(),
                Tuple{String,Union{Base.Process,SO.Service}}[], IdDict{Base.Process,Int}(),
                nothing, nothing, nothing, nothing, nothing, nothing, nothing, nothing,
                0, nothing, false, false, false, nothing, record, nothing, nothing, nothing,
                Dict{String,PipeWireAODeployment.NativeOwnerBootstrapClient.Connection}())
            try
                D._run_locked(deployment, ARGS[1])
            catch
                # The empty options fail immediately after _run_locked creates its runtime.
            end
            println(deployment.runtime)
            """
        project = dirname(@__DIR__)
        result = withenv("NOTIFY_SOCKET" => nothing) do
            C.run_checked([Base.julia_cmd().exec[1], "--startup-file=no", "--history-file=no",
                "--project=" * project, "-e", script, directory]; timeout=60)
        end
        @test result.returncode == 0
        runtime = strip(result.stdout)
        @test startswith(runtime, joinpath(directory, "run-"))
        saved = C.read_json(joinpath(directory, "state.json"))
        @test saved["retained_runtime"] == runtime
        @test saved["phase"] == "failed"
        @test isdir(runtime)
    end
end
