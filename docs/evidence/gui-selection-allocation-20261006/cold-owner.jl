using Test,PipeWireAO
import ThreadPinning
include("/tmp/rtc-gui-selection-allocation-review/deployment/julia/test/native_control_private_core.jl")
include("/tmp/gui-source-allocation-diagnostic-20261006/package/hil/native_owner_bootstrap.jl")
const M=HILNativeOwnerBootstrap
Base.include(M,joinpath(M.SOURCE,"native_owner_bootstrap_client.jl"))
include("/tmp/gui-source-allocation-diagnostic-20261006/package/hil/owner_protocol.jl")
const B=M.NativeOwnerBootstrapClient
const C=M.NativeControlClient
const R=M.NativeOwnerBootstrapRuntime
const OUTPUT="/tmp/gui-source-allocation-diagnostic-20261006/cold-discriminator"
const ROWS=Dict{String,Any}[]
function interval(label,f)
    println(stderr,"PHASE_BEGIN ",label);flush(stderr)
    Base.cumulative_compile_timing(true)
    before_jit=Base.jit_total_bytes();before_compile=Base.cumulative_compile_time_ns();before=Base.gc_num()
    f()
    after=Base.gc_num();after_compile=Base.cumulative_compile_time_ns();after_jit=Base.jit_total_bytes()
    diff=Base.GC_Diff(after,before)
    println(stderr,"PHASE_END ",label);flush(stderr)
    push!(ROWS,Dict("phase"=>label,"allocated_bytes"=>diff.allocd,"pool"=>diff.poolalloc,
      "malloc"=>diff.malloc,"gc_pauses"=>diff.pause,"jit_bytes"=>after_jit-before_jit,
      "compile_ns"=>after_compile[1]-before_compile[1],"recompile_ns"=>after_compile[2]-before_compile[2]))
end
function quiet()
    @ccall gc_safe=true usleep(Cuint(300_000)::Cuint)::Cint
end
function round(client,phase,expected)
    println(client,phase);flush(client)
    readline(client)==expected || error("late controller phase failed")
    quiet()
end
function measured(remote,directory,daemon)
    chmod(dirname(remote),0o700)
    runtime=R.Runtime(remote,"diagnostic.bootstrap",Int64(91))
    client=child=nothing
    child_error=open(joinpath(OUTPUT,"late-controller.stderr.log"),"w")
    try
        client=B.connect(remote,"diagnostic.bootstrap",getpid(),91;deadline=C.monotonic()+20)
        R.prepared!(runtime)
        request=ThreadPinning.@spawnat 2 B.connect_owner!(client;deadline=C.monotonic()+20)
        ticket=R.take_connect!(runtime);R.connected!(runtime,ticket);R.await_connected!(runtime,ticket);fetch(request)
        @test runtime.transport.endpoint.lifecycle===M.NativeOwnerBootstrapCodec.Connected
        quiet();interval("quiet_before",quiet)
        cmd=`$(Base.julia_cmd()) --startup-file=no --compiled-modules=existing --project=$(dirname(Base.active_project())) $(joinpath(OUTPUT,"late_controller.jl")) /tmp/gui-source-allocation-diagnostic-20261006/package/hil/native_owner_bootstrap.jl $remote diagnostic.bootstrap $(getpid()) 91`
        child=open(pipeline(cmd;stderr=child_error),"r+")
        readline(child)=="READY" || error("late controller did not prepare")
        interval("first_late_attach",()->round(child,"attach","ATTACHED"))
        interval("retained_late_status",()->round(child,"status","STATUS"))
        interval("late_remove",()->round(child,"remove","REMOVED"))
        interval("quiet_after",quiet)
        close(child);child=nothing
        println(stderr,"OWNER_PID ",getpid()," CORE_PID ",getpid(daemon));flush(stderr)
        HILOwnerProtocol.write_json_atomic(joinpath(OUTPUT,"result.json"),Dict(
           "owner_pid"=>getpid(),"core_pid"=>getpid(daemon),"sdk_source"=>pathof(PipeWireAO),
           "project"=>Base.active_project(),"runtime_type"=>string(typeof(runtime)),
           "endpoint_type"=>string(typeof(runtime.transport.endpoint)),"phases"=>ROWS,
           "scope"=>"cold private core; process allocations include diagnostic closures, pipe IO and sleeping; not SCI or zero-allocation acceptance",
           "connected"=>runtime.transport.endpoint.lifecycle===M.NativeOwnerBootstrapCodec.Connected);maximum=1024*1024)
    finally
        child===nothing || close(child)
        close(child_error)
        R.finish!(runtime)
        client===nothing || close(client)
        close(runtime)
    end
end
with_control_private_core(measured)
println("CLEANUP_CONFIRMED")
