using PipeWireAORTC
const R=PipeWireAORTC.SessionRuntime
const C=PipeWireAORTC.Common
const old="/home/dgamroth/.local/state/pipewireao/gpi2-shape-live-20261025"
const root="/home/dgamroth/.local/state/pipewireao/gpi2-registered-live-20261025"
handle=R.attach(joinpath(old,"session");deadline=R.monotonic()+30)
@assert handle.unit=="pipewireao-session@4774985dfca6.service"
@assert handle.invocation=="16d89668f72f4f7a8d944e98f1ebc343"
@assert handle.main_pid==2990499
receipt=Dict{String,Any}("unit"=>handle.unit,"invocation"=>handle.invocation,"pid"=>handle.main_pid)
try
 receipt["result"]=R.shutdown!(handle;deadline=R.monotonic()+120)
 receipt["clean_native_quit"]=true
catch error
 receipt["clean_native_quit"]=false
 receipt["shutdown_error"]=sprint(showerror,error)
 try
  receipt["cleanup"]=R.reconcile_cleanup!(handle;deadline=R.monotonic()+120)
 catch cleanup_error
  receipt["cleanup_error"]=sprint(showerror,cleanup_error)
 end
finally
 final=joinpath(old,"session/final-launch.json")
 isfile(final) && (receipt["final_record"]=C.read_json(final))
 C.write_json(joinpath(root,"previous-retirement.json"),receipt)
end
final=get(receipt,"final_record",Dict())
get(final,"cleanup_complete",false)===true || error("Old GPI cleanup not confirmed; replacement is gated")
for owner in values(final["owners"])
 !isdir("/proc/$(owner["pid"])") || error("old owner remains")
end
!isdir("/proc/2990499") || error("old manager remains")
println("Exact old GPI retired; native completion=",receipt["clean_native_quit"],"; all owned processes absent")
