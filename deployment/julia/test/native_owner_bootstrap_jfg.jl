# Actual public JFG connect/run/quit seams; no linked source and no SCI frame.
using Test, PipeWireAODeployment
include("native_control_private_core.jl")
const B = PipeWireAODeployment.NativeOwnerBootstrapClient
const C = PipeWireAODeployment.NativeOwnerBootstrapCodec
const Client = PipeWireAODeployment.NativeControlClient
function external_jfg_bootstrap_proof(remote, directory, daemon)
    chmod(dirname(remote),0o700)
    sdk = normpath(joinpath(@__DIR__,"..","..","hil","jfg_owner.jl"))
    jfg = get(ENV,"BOOTSTRAP_JFG_ROOT",normpath(joinpath(@__DIR__,"..","..","..","..","JuliaFilterGraph.jl")))
    graph = joinpath(jfg,"julia","FilterGraphPipeWire","test","fixtures","leaky-graph.conf")
    owner_script = joinpath(jfg,"deployment","run_island.jl")
    project = dirname(Base.active_project())
    expression = "push!(LOAD_PATH," * repr(joinpath(jfg,"deployment")) * "); include(" * repr(sdk) * "); main(ARGS; owner_script=" * repr(owner_script) * ")"
    log = open(joinpath(directory,"native-jfg-owner.log"),"w+")
    child = client = nothing
    try
        child = run(pipeline(`$(Base.julia_cmd()) --startup-file=no --threads=2,0 --project=$project -e $expression -- --graph $graph --name test.native.jfg.science --remote $remote --session-run-control --bootstrap-node test.native.jfg.bootstrap --bootstrap-instance 61`;
            stdout=log,stderr=log);wait=false)
        check = () -> (Base.process_exited(child) && error("native JFG owner exited before completion"))
        client = B.connect(remote,"test.native.jfg.bootstrap",getpid(child),61;
            deadline=Client.monotonic()+30,check)
        @test client.binding.owner_pid == getpid(child)
        @test B.status(client;deadline=Client.monotonic()+30,check).lifecycle in (C.Preparing,C.Prepared)
        connected = B.connect_owner!(client;deadline=Client.monotonic()+30,check)
        @test connected.lifecycle === C.Connected
        @test B.status(client;deadline=Client.monotonic()+10,check).lifecycle === C.Connected
        stopped = B.quit!(client;deadline=Client.monotonic()+10)
        @test stopped.lifecycle === C.Stopped
        timedwait(() -> Base.process_exited(child),10;pollint=0.005) == :ok || error("JFG owner did not exit after completed Quit")
        wait(child)
        @test child.exitcode == 0
    catch
        flush(log);seekstart(log);print(stderr,read(log,String))
        rethrow()
    finally
        client === nothing || close(client)
        child === nothing || stop_proof_child!(child,"native JFG owner")
        close(log)
    end
end
@testset "actual external JFG native bootstrap" begin
    with_control_private_core(external_jfg_bootstrap_proof)
end
