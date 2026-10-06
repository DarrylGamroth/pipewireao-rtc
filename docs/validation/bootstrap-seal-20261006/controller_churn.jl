# Same cold owner-process allocation oracle before and after controller sealing.
pushfirst!(LOAD_PATH,ARGS[1]);using PipeWireAO,Test
pushfirst!(LOAD_PATH,ARGS[2]);using PipeWireAODeployment
include(joinpath(ARGS[2],"test","native_control_private_core.jl"))
const R=PipeWireAODeployment.NativeOwnerBootstrapRuntime
const C=PipeWireAODeployment.NativeControlClient
const OUTPUT=ARGS[3]
mkpath(OUTPUT)
function idle(microseconds)
    @ccall gc_safe=true usleep(Cuint(microseconds)::Cuint)::Cint
end
function window(microseconds)
    before=Base.gc_num();idle(microseconds);after=Base.gc_num();Base.GC_Diff(after,before)
end
function peer(mode,remote)
    cmd=`$(Base.julia_cmd()) --startup-file=no --compiled-modules=existing --project=$(dirname(Base.active_project())) /tmp/gui-source-allocation-diagnostic-20261006/candidate-cold-tests/controller_peer.jl $(ARGS[1]) $(ARGS[2]) $mode $remote test.churn $(getpid()) 61`
    process=open(pipeline(cmd;stderr=joinpath(OUTPUT,mode*".stderr.log")),"r+")
    readline(process)=="READY" || error("peer failed preparation")
    process
end
function churn(remote,directory,daemon)
    chmod(dirname(remote),0o700)
    runtime=R.Runtime(remote,"test.churn",Int64(61))
    primary=foreign=nothing
    try
        primary=peer("primary",remote)
        R.prepared!(runtime);println(primary,"connect");flush(primary)
        ticket=R.take_connect!(runtime);R.connected!(runtime,ticket);R.await_connected!(runtime,ticket)
        @test readline(primary)=="CONNECTED"
        # Warm only this synthetic measurement wrapper before any foreign event.
        window(100_000);quiet=window(300_000);@test quiet.allocd==0
        foreign=peer("foreign",remote)
        idle(300_000)
        println(foreign,"publish");flush(foreign)
        started=time_ns()
        observed=window(3_000_000)
        finished=time_ns()
        published=readline(foreign);removed=readline(foreign)
        @test startswith(published,"PUBLISHED ")
        @test startswith(removed,"REMOVED ")
        @test started < parse(UInt64,split(published)[end]) < parse(UInt64,split(removed)[end]) < finished
        println("OWNER_CHURN bytes=",observed.allocd," pool=",observed.poolalloc," malloc=",observed.malloc,
            " gc=",observed.pause," quiet=",quiet.allocd," window=",started,":",finished," publisher=",published," removal=",removed)
        flush(stdout)
        @test observed.allocd==0
        @test observed.pause==0
        println(primary,"quit");flush(primary)
        wait_proof(() -> R.cancelled(runtime),5,"Quit")
        R.finish!(runtime);@test readline(primary)=="STOPPED"
    finally
        foreign===nothing || close(foreign)
        primary===nothing || close(primary)
        close(runtime)
    end
end
@testset "unrelated native controller churn owner-process allocation" begin
    with_control_private_core(churn)
end
println("CLEANUP_CONFIRMED")
