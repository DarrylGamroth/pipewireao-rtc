using PipeWireAORTC
const R=PipeWireAORTC.SessionRuntime
const C=PipeWireAORTC.Common
destination=@__DIR__
previous="/home/dgamroth/.local/state/pipewireao/gpi2-annular-live-20261025b"
handle=R.attach(joinpath(previous,"session");deadline=R.monotonic()+30)
handle.unit=="pipewireao-session@39b42bfdc81e.service" || error("unexpected previous GPI unit")
handle.invocation=="221288c72f054c309b45cd24c6c610aa" || error("previous GPI invocation changed")
handle.main_pid==2556341 || error("previous GPI PID changed")
receipt=Dict{String,Any}("unit"=>handle.unit,"invocation"=>handle.invocation,"pid"=>handle.main_pid)
try
    receipt["result"]=R.shutdown!(handle;deadline=R.monotonic()+320)
    receipt["clean_native_quit"]=true
catch error
    receipt["clean_native_quit"]=false
    receipt["shutdown_error"]=sprint(showerror,error)
    # Observe cleanup after the one attempted Quit; never submit it again.
    try
        receipt["cleanup"]=R.reconcile_cleanup!(handle;deadline=R.monotonic()+320)
    catch cleanup_error
        receipt["cleanup_error"]=sprint(showerror,cleanup_error)
    end
finally
    finalpath=joinpath(previous,"session","final-launch.json")
    isfile(finalpath) && (receipt["final_record"]=C.read_json(finalpath))
    C.write_json(joinpath(destination,"previous-retirement.json"),receipt)
end
println(receipt)
