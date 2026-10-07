using Test, PipeWireAODeployment
const D = PipeWireAODeployment.Deployment

struct CleanupRunnerClient
    core::Base.Process
    source_group::Int
    requests::Vector{UInt32}
end
function PipeWireAODeployment.NativeRunnerClient.request!(client::CleanupRunnerClient,
        command::PipeWireAODeployment.NativeRunnerCodec.RunnerCommand;
        deadline::Float64, check=()->nothing)
    check()
    @test process_running(client.core)
    @test isempty(D._owned_group_members(client.source_group))
    codec = PipeWireAODeployment.NativeRunnerCodec
    envelope = PipeWireAODeployment.NativeControlCodec
    operation = codec.operation_id(command)
    push!(client.requests, operation)
    details = operation == 3 ?
        (running=false, owned_nodes=UInt64(1), owned_links=UInt64(0),
            discarded_buffers=UInt64(0), discarded_by_sink=Dict{String,UInt64}()) :
        (shutdown=true,)
    result = operation == 3 ? codec.RunnerResult{:status,typeof(details)}(codec.Observed, details) :
        codec.RunnerResult{:quit,typeof(details)}(codec.Accepted, details)
    header = envelope.ReplyHeader(envelope.ControllerIdentity(UInt32(7), UInt64(8), Int64(9)),
        Int64(10), Int64(1), operation, Int32(0))
    return codec.Completion(header, codec.Ready, result, nothing)
end

struct UnexpectedSourceRequest end
function PipeWireAODeployment.NativeSourceClient.request!(::UnexpectedSourceRequest,
        operation::String, id::Int64; deadline::Float64, check=()->nothing)
    error("shutdown attempted $operation on an exited source")
end

@testset "Exited source is revoked without a pause request" begin
    withenv("NOTIFY_SOCKET" => nothing) do
        for source_failed in (false, true)
            mktempdir() do directory
                D._enable_subreaper()
                owner = Dict("role"=>"simulator", "control-protocol"=>"pipewireao.source-control/1",
                    "control-node"=>"source", "bootstrap-protocol"=>"pipewireao.rtc.owner-bootstrap/1",
                    "bootstrap-node"=>"source.bootstrap")
                children = Tuple{String,Base.Process}[]
                pids = IdDict{Base.Process,Int}()
                try
                    core = run(Cmd(`sleep 60`; detach=true); wait=false)
                    push!(children, ("core", core)); pids[core] = getpid(core)
                    source = run(Cmd(`true`; detach=true); wait=false)
                    push!(children, ("simulator", source)); pids[source] = getpid(source)
                    wait(source)
                    requests = UInt32[]
                    runner_client = CleanupRunnerClient(core, pids[source], requests)
                    spec = Dict{String,Any}("owners"=>[owner])
                    record = Dict{String,Any}("phase"=>"failed", "admitted"=>false,
                        "error"=>"required simulator exited", "processes"=>Dict{String,Any}())
                    deployment = D.DeploymentRunner((;), directory, spec, Dict{String,String}(),
                        Set{Int}(), children, pids, directory, "", runner_client, nothing, nothing,
                        nothing, owner, UnexpectedSourceRequest(), 0, "running", source_failed,
                        false, false, joinpath(directory,"state.json"), record,
                        nothing, nothing, nothing,
                        Dict{String,PipeWireAODeployment.NativeOwnerBootstrapClient.Connection}())
                    errors = Any[]
                    D._stop_processes(deployment, errors; source=true)
                    @test isempty(errors)
                    @test requests == UInt32[3, 1]
                    @test deployment.source_id == 0
                    @test deployment.source_failed == source_failed
                    @test deployment.record["error"] == "required simulator exited"
                    @test all(pair -> !process_running(last(pair)), children)
                finally
                    for (_, process) in reverse(children)
                        D._owned_wait(process, pids[process], 0)
                    end
                end
            end
        end
    end
end

@testset "Exited source revokes its adopted owned descendants" begin
    if Sys.islinux()
        withenv("NOTIFY_SOCKET" => nothing) do
            mktempdir() do directory
                D._enable_subreaper()
                owner = Dict("role"=>"simulator", "control-protocol"=>"pipewireao.source-control/1",
                    "control-node"=>"source", "bootstrap-protocol"=>"pipewireao.rtc.owner-bootstrap/1",
                    "bootstrap-node"=>"source.bootstrap")
                children = Tuple{String,Base.Process}[]
                pids = IdDict{Base.Process,Int}()
                try
                    core = run(Cmd(`sleep 60`; detach=true); wait=false)
                    push!(children, ("core", core)); pids[core] = getpid(core)

                    child_path = joinpath(directory, "source-descendant.pid")
                    source = run(Cmd(Cmd(["sh", "-c", "sleep 60 & echo \$! > \"\$1\"", "source", child_path]);
                        detach=true); wait=false)
                    push!(children, ("simulator", source)); pids[source] = getpid(source)
                    @test timedwait(() -> isfile(child_path), 5; pollint=0.01) == :ok
                    descendant = parse(Int, strip(read(child_path, String)))
                    wait(source)
                    @test !process_running(source)
                    @test timedwait(() -> any(member -> member.pid == descendant && member.ppid == getpid(),
                        D._live_owned_orphans(pids[source])), 5; pollint=0.01) == :ok
                    @test ispath("/proc/$descendant")

                    spec = Dict{String,Any}("owners"=>[owner])
                    record = Dict{String,Any}("phase"=>"failed", "admitted"=>false,
                        "error"=>"required simulator exited", "processes"=>Dict{String,Any}())
                    deployment = D.DeploymentRunner((;), directory, spec, Dict{String,String}(),
                        Set{Int}(), children, pids, directory, "", nothing, nothing, nothing,
                        nothing, owner, UnexpectedSourceRequest(), 0, "running", false,
                        false, false, joinpath(directory,"state.json"), record,
                        nothing, nothing, nothing,
                        Dict{String,PipeWireAODeployment.NativeOwnerBootstrapClient.Connection}())
                    errors = Any[]
                    D._stop_processes(deployment, errors; source=true)

                    # Assert the descendant and its detached group were removed
                    # before the final safety cleanup below can act on them.
                    @test isempty(errors)
                    @test deployment.source_id == 0
                    @test !deployment.source_failed
                    @test deployment.record["error"] == "required simulator exited"
                    @test !process_running(core) && !process_running(source)
                    @test !ispath("/proc/$descendant")
                    @test isempty(D._owned_group_members(pids[source]))
                    @test isempty(D._live_owned_orphans(pids[source]))
                finally
                    for (_, process) in reverse(children)
                        D._owned_wait(process, pids[process], 0)
                    end
                end
            end
        end
    end
end

@testset "Unknown live source gets report grace after core revocation" begin
    if Sys.islinux()
        withenv("NOTIFY_SOCKET" => nothing) do
            mktempdir() do directory
                D._enable_subreaper()
                owner = Dict("role"=>"simulator", "control-protocol"=>"pipewireao.source-control/1",
                    "control-node"=>"source", "bootstrap-protocol"=>"pipewireao.rtc.owner-bootstrap/1",
                    "bootstrap-node"=>"source.bootstrap")
                children = Tuple{String,Base.Process}[]
                pids = IdDict{Base.Process,Int}()
                try
                    core = run(Cmd(`sleep 60`; detach=true); wait=false)
                    push!(children, ("core", core)); pids[core] = getpid(core)

                    source_exit_path = joinpath(directory, "source-exited-after-core-revocation")
                    source_script = "while test -e /proc/\$1; do sleep 0.01; done; sleep 0.25; " *
                        "echo source-exited > \$2"
                    source = run(Cmd(Cmd(["sh", "-c", source_script, "source",
                        string(pids[core]), source_exit_path]); detach=true); wait=false)
                    push!(children, ("simulator", source)); pids[source] = getpid(source)
                    @test process_running(source)
                    @test !ispath(source_exit_path)

                    requests = UInt32[]
                    runner_client = CleanupRunnerClient(core, pids[source], requests)
                    spec = Dict{String,Any}("owners"=>[owner])
                    record = Dict{String,Any}("phase"=>"failed", "admitted"=>false,
                        "error"=>"required rtc exited with status 1", "processes"=>Dict{String,Any}())
                    deployment = D.DeploymentRunner((;), directory, spec, Dict{String,String}(),
                        Set{Int}(), children, pids, directory, "", runner_client, nothing, nothing,
                        nothing, owner, UnexpectedSourceRequest(), 0, "running", false,
                        false, false, joinpath(directory,"state.json"), record,
                        nothing, nothing, nothing,
                        Dict{String,PipeWireAODeployment.NativeOwnerBootstrapClient.Connection}())
                    errors = Any[]
                    D._stop_processes(deployment, errors; source=true)

                    @test isempty(requests)
                    @test isfile(source_exit_path)
                    @test all(pair -> !process_running(last(pair)), children)
                    @test isempty(D._owned_group_members(pids[core]))
                    @test isempty(D._owned_group_members(pids[source]))
                    @test deployment.source_id == 1
                    @test deployment.source_failed
                    @test record["error"] == "required rtc exited with status 1"
                    @test any(message -> occursin("shutdown attempted pause", message),
                        get(record, "cleanup_errors", String[]))
                    @test length(errors) == 1
                    @test occursin("source coordination failed", sprint(showerror, only(errors)))
                finally
                    for (_, process) in reverse(children)
                        D._owned_wait(process, pids[process], 0)
                    end
                end
            end
        end
    end
end
