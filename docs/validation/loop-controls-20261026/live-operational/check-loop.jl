using PipeWireAORTC
const R=PipeWireAORTC.SessionRuntime
const C=PipeWireAORTC.Common
const root="/home/dgamroth/.local/state/pipewireao/gpi2-loop-controls-live-20261026"
identity=C.read_json(joinpath(root,"live-identity.json"))
handle=R.attach(joinpath(root,"session"); deadline=R.monotonic()+30)
@assert handle.invocation==identity["invocation"] && handle.main_pid==identity["pid"]
command(args)=R.control!(handle,PipeWireAORTC.RunnerCommands.parse(args);deadline=R.monotonic()+30)
record=Dict{String,Any}()
record["initial"]=command(["properties","gpi2-jfg-frame-graph"])
C.write_json(joinpath(root,"loop-control-verification.json"),record)
for (label,value) in (("open","false"),("close","true"))
 reply=command(["property","gpi2-jfg-frame-graph","closed-loop-correction:closed","bool",value])
 record[label]=reply
 C.write_json(joinpath(root,"loop-control-verification.json"),record)
 reply["ok"]===true || error("loop $label was rejected: $reply")
 @assert reply["owner_pid"]==handle.main_pid && reply["result"]["active_adoption_observed"]===true
 @assert all(g -> g["requested"]==g["active"],reply["result"]["property_generations"])
 record[label*"_readback"]=command(["properties","gpi2-jfg-frame-graph"])
 readback=record[label*"_readback"]
 @assert readback["ok"]===true && readback["owner_pid"]==handle.main_pid
 @assert readback["result"]["properties"]["closed-loop-correction:closed"]["value"]==parse(Bool,value)
 props=readback["result"]["properties"]
 prefix="pipewireao.correction-control.closed-loop-correction:closed"
 @assert props[prefix*".state"]["value"]==(label=="open" ? "Open" : "Closed")
 @assert props[prefix*".fault"]["value"]==""
 @assert props[prefix*".requested"]["value"]==parse(Bool,value)
 C.write_json(joinpath(root,"loop-control-verification.json"),record)
 println(label,": ",reply); flush(stdout)
end
record["status"]=command(["status"])
C.write_json(joinpath(root,"loop-control-verification.json"),record)
@assert record["status"]["ok"]===true && record["status"]["state"]=="Running"
write(joinpath(root,"loop-controls-complete"),"")
println("Loop controls exercised with active generation acknowledgement and exact readback; correction left closed")
