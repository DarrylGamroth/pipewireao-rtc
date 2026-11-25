# Run with a matching PipeWireAO and FilterGraphPipeWire environment.
using Test, PipeWireAO, PipeWireAORTC
const B = PipeWireAORTC.OwnerBootstrapClient
const C = PipeWireAORTC.OwnerBootstrapCodec
const Client = PipeWireAORTC.ControlClient
include("control_private_core.jl")
const FIXTURE = raw"""
filter.graph = {
    nodes = [ { name=correction type=ndarray label=leaky-integrator-f32
        config={ extent=2 initial_state=0 input_schema=test/persistent-residual/1
            output_schema=test/persistent-command/1 }
        props={ gain=-0.05 pole=1 closed=false } } ]
    links=[]
    inputs=[ { name=residual endpoint="correction:input" } ]
    outputs=[ { name=offset endpoint="correction:output" } ]
}
"""
deadline(seconds=15) = Client.monotonic() + seconds
function fresh_client(remote, name, pid, previous; check)
    time = deadline()
    while Client.monotonic() < time
        check()
        binding = try
            B.connect(remote, name, pid, 71; deadline = min(time, deadline(0.4)))
        catch error
            error isa Client.UnknownOutcome || rethrow()
            sleep(0.01)
            continue
        end
        if binding.client.serial != previous
            return binding
        end
        close(binding)
        sleep(0.02)
    end
    error("persistent bootstrap did not publish a fresh endpoint")
end
function native_graph_serial(client, name)
    only(find_globals(client.client.registry; properties=("node.name" => name,))).properties["object.serial"]
end
function smoke(remote, directory, daemon)
    chmod(dirname(remote), 0o700)
    graph_path = joinpath(directory, "graph.conf")
    write(graph_path, FIXTURE)
    graph_name = "persistent-graph-smoke"
    bootstrap_name = "persistent-bootstrap-smoke"
    project = dirname(Base.active_project())
    expression = "using PipeWireAORTC; PipeWireAORTC.GraphOwner.main(ARGS)"
    command = `$(Base.julia_cmd()) --startup-file=no --compiled-modules=existing --threads=2,0 --project=$project -e $expression -- --persistent --bootstrap-node $bootstrap_name --bootstrap-instance 71 --remote $remote --graph $graph_path --name $graph_name --session-run-control --correction-property correction:closed --prime-on-output offset`
    log = joinpath(directory, "owner.log")
    open(log, "w") do stream
        invocation = "00000000000000000000000000000071"
        touch(joinpath(directory, "previous-invocation.stop"))
        environment = addenv(command, "PIPEWIREAORTC_GRAPH_STARTUP_TIMING" => "1",
                             "PIPEWIREAORTC_GRAPH_STOP_DIR" => directory, "INVOCATION_ID" => invocation)
        owner = run(pipeline(environment; stdout=stream, stderr=stream); wait=false)
        client = nothing
        try
            check() = process_exited(owner) ? error("graph owner exited: " * read(log, String)) : nothing
            pid = getpid(owner)
            client = B.connect(remote, bootstrap_name, pid, 71; deadline=deadline(120), check)
            @test B.connect_owner!(client; deadline=deadline(120), check).lifecycle == C.Connected
            first_graph = native_graph_serial(client, graph_name)
            first_bootstrap = client.client.serial
            # This deliberately changes the fixture after loading. The same service
            # invocation must use its retained configuration for the new attachment.
            write(graph_path, "invalid graph")
            close(client)
            client = fresh_client(remote, bootstrap_name, pid, first_bootstrap; check)
            @test getpid(owner) == pid
            @test client.client.serial != first_bootstrap
            @test B.connect_owner!(client; deadline=deadline(), check).lifecycle == C.Connected
            @test native_graph_serial(client, graph_name) != first_graph
            second_bootstrap = client.client.serial
            @test B.quit!(client; deadline=deadline(), check).lifecycle == C.Stopped
            close(client)
            client = nothing
            client = fresh_client(remote, bootstrap_name, pid, second_bootstrap; check)
            @test B.connect_owner!(client; deadline=deadline(), check).lifecycle == C.Connected
            # Stop the service while the owner is inside native run!, keeping its
            # controller alive so release cannot explain the graph's exit.
            touch(joinpath(directory, invocation * ".stop"))
            @test timedwait(() -> process_exited(owner), 15) == :ok
            @test success(owner)
            @test !occursin("called from wrong context", read(log, String))
        catch
            @error "graph owner diagnostics" log = read(log, String)
            rethrow()
        finally
            client === nothing || close(client)
            stop_proof_child!(owner, "persistent graph owner")
        end
    end
end
@testset "persistent complete-frame graph across attach and release" begin
    prefix = get(ENV, "PIPEWIREAO_PREFIX", String(PipeWireAO.LibPipeWire.PipeWireAO_jll.artifact_dir))
    withenv("PIPEWIREAO_PREFIX" => prefix) do
        with_control_private_core(smoke)
    end
end
