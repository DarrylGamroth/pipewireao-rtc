pushfirst!(LOAD_PATH,"/home/dgamroth/workspaces/codex/pipewire/PipeWireAO.jl")
using PipeWireAO
popfirst!(LOAD_PATH)
using PipeWireAODeployment, Test
include("/home/dgamroth/workspaces/codex/pipewire/rtc-bootstrap-allocation-review/deployment/julia/test/native_control_private_core.jl")
const R=PipeWireAODeployment.NativeOwnerBootstrapRuntime
const E=PipeWireAODeployment.NativeControlEndpoint
const P=PipeWireAODeployment.NativeOwnerBootstrapCodec
function cost(transport)
    transport.wake[]=false
    quiet=@allocated R._poll_ready!(transport)
    transport.wake[]=true
    wake=@allocated R._poll_ready!(transport)
    snapshot=@allocated PipeWireAO.find_globals(something(transport.endpoint.registry);interface="PipeWire:Interface:Node")
    publication=@allocated E.capability(transport.endpoint)
    return (;quiet,wake,snapshot,publication)
end
function measured(remote,directory,daemon)
    chmod(dirname(remote),0o700)
    transport=R.Transport(P.PROFILE,remote,"review.bootstrap.alloc",Int64(91))
    try
        sleep(0.5)
        for _ in 1:4; cost(transport);end
        first=cost(transport);second=cost(transport)
        println("SDK=",pathof(PipeWireAO));println("DEPLOYMENT=",pathof(PipeWireAODeployment))
        println("FIRST ",first);println("SECOND ",second)
        @test first.quiet==0 && second.quiet==0
        @test first.wake>0 && second.wake>0
        @test first.snapshot>0 && second.snapshot>0
        @test first.publication>0 && second.publication>0
    finally
        close(transport)
    end
end
with_control_private_core(measured)
