# Private dummy-service probes. No scientific or existing units are touched.
module Investigation
using UUIDs
const ROOT = normpath(joinpath(@__DIR__, "../../.."))
include(joinpath(ROOT, "deployment/julia/src/common.jl"))
include(joinpath(ROOT, "deployment/julia/src/systemd_owners.jl"))
const SO = SystemdOwners
const OUT = joinpath(@__DIR__, "investigation-results")
const PROJECT = "/tmp/rtc-systemd-fgn-20261007-package/julia"
const JULIA = "/home/dgamroth/.juliaup/bin/julia"
const UNIT = get(ENV,"REVIEW_UNIT","")
const PLACE = Dict("cpus"=>[2],"leader-cpu"=>2)
require(x,m) = x || error(m)
nonce() = replace(string(uuid4()), "-"=>"")
function cmd(args; timeout=30)
 r=Common.run_checked(args;timeout)
 require(r.returncode==0,"command failed: $args $(r.stderr)")
 r.stdout
end
ctl(args...) = cmd(["systemctl","--user",args...])
function await(pred; timeout=20)
 deadline=SO.monotonic()+timeout
 while !pred()
  require(SO.monotonic()<deadline,"probe condition timeout")
  sleep(.05)
 end
end
function direct(owner,role,argv; props=String[])
 s=SO.Service(owner,role)
 args=SO.launch_command(s,argv,Dict(),OUT,PLACE)
 splice!(args,findfirst(==("--"),args):findfirst(==("--"),args)-1,props)
 cmd(args)
 SO.retain!(s,SO.properties(s.unit))
 s
end
function unknown()
 mkpath(OUT)
 owner=SO.coordinator(UNIT;launcher=ENV["REVIEW_LAUNCHER"])
 s=SO.Service(owner,"unknown-reply")
 fake=mktempdir(OUT)
 write(joinpath(fake,"systemd-run"),"#!/bin/sh\n/usr/bin/systemd-run \"\$@\"\ncode=\$?\n[ \"\$code\" -eq 0 ] || exit \"\$code\"\nexit 23\n")
 chmod(joinpath(fake,"systemd-run"),0o700)
 failure=""
 try
  withenv("PATH"=>fake*":"*ENV["PATH"]) do
   try SO.launch!(s,["/bin/sleep","120"],Dict(),OUT,PLACE)
   catch e; failure=sprint(showerror,e); end
  end
  require(occursin("status 23",failure),"missing injected lost-success failure")
  require(s.main_pid>0 && !isempty(s.invocation) && SO.alive(s),"successful manager acceptance was not retained")
  before=SO.record(s)
  SO.stop!(s)
  require(SO.cgroup_empty(s.cgroup),"unknown-reply owner survived")
  Common.write_json(joinpath(OUT,"unknown-reply.json"),Dict("success"=>true,"before"=>before,"failure"=>failure,"after"=>SO.record(s)))
 finally
  SO.cleanup_invocation(owner.invocation)
  rm(fake;recursive=true)
 end
end
function crash()
 owner=SO.coordinator(UNIT;launcher=ENV["REVIEW_LAUNCHER"])
 core=direct(owner,"core",["/bin/sleep","120"])
 output=joinpath(OUT,"crash-consumer-"*owner.invocation)
 cg=joinpath("/sys/fs/cgroup",lstrip(core.cgroup,'/'),"cgroup.events")
 consumer=direct(owner,"consumer",["/usr/bin/python3","-c","import signal,time,pathlib,sys; signal.signal(signal.SIGTERM,lambda *a:(pathlib.Path(sys.argv[1]).write_text(pathlib.Path(sys.argv[2]).read_text() if pathlib.Path(sys.argv[2]).exists() else 'absent'),sys.exit(0))); time.sleep(120)",output,cg])
 sleep(.3)
 Common.write_json(joinpath(OUT,"crash-ready.json"),Dict("unit"=>UNIT,"invocation"=>owner.invocation,"core"=>SO.record(core),"consumer"=>SO.record(consumer),"output"=>output))
 sleep(120)
end
function main()
 mkpath(OUT)
 results=Dict{String,Any}("module_sha256"=>Common.sha256_file(joinpath(ROOT,"deployment/julia/src/systemd_owners.jl")),"systemd"=>ctl("show","--property=Version"))
 # Replacement detected before destructive stop must be fenced.
 owner=SO.Coordinator("unused.service",nonce(),"/unused")
 try
  s=direct(owner,"replacement",["/bin/sleep","120"])
  before=SO.record(s)
  ctl("restart",s.unit)
  replacement=SO.properties(s.unit)
  require(replacement["InvocationID"]!=s.invocation,"restart failed to replace invocation")
  failure=""
  try SO.stop!(s); catch e; failure=sprint(showerror,e); end
  require(occursin("incarnation changed",failure),"replacement not fenced")
  require(SO.properties(s.unit)["MainPID"]==replacement["MainPID"],"replacement was killed")
  results["replacement"]=Dict("success"=>true,"old"=>before,"replacement"=>replacement,"failure"=>failure)
 finally SO.cleanup_invocation(owner.invocation); end
 # Core-first fallback: consumer handler observes no populated core cgroup.
 owner=SO.Coordinator("unused.service",nonce(),"/unused")
 corefile=joinpath(OUT,"core-marker-"*owner.invocation)
 consumerfile=joinpath(OUT,"consumer-marker-"*owner.invocation)
 try
  core=direct(owner,"core",["/usr/bin/python3","-c","import signal,time,pathlib,sys; signal.signal(signal.SIGTERM,lambda *a:(pathlib.Path(sys.argv[1]).write_text('core-stopped'),sys.exit(0))); time.sleep(120)",corefile])
  cg=joinpath("/sys/fs/cgroup",lstrip(core.cgroup,'/'),"cgroup.events")
  consumer=direct(owner,"consumer",["/usr/bin/python3","-c","import signal,time,pathlib,sys; signal.signal(signal.SIGTERM,lambda *a:(pathlib.Path(sys.argv[1]).write_text(pathlib.Path(sys.argv[2]).read_text() if pathlib.Path(sys.argv[2]).exists() else 'absent'),sys.exit(0))); time.sleep(120)",consumerfile,cg])
  sleep(.3)
  SO.cleanup_invocation(owner.invocation)
  observed=read(consumerfile,String)
  require(isfile(corefile),"core handler did not run")
  require(observed=="absent" || occursin("populated 0",observed),"consumer stopped before core empty")
  results["ordering"]=Dict("success"=>true,"consumer_observed_core"=>observed,"core"=>SO.record(core),"consumer"=>SO.record(consumer))
 finally SO.cleanup_invocation(owner.invocation); end
 # Pending owner start waits behind an independently owned private blocker.
 owner=SO.Coordinator("unused.service",nonce(),"/unused")
 blocker="pipewireao-review-blocker-"*owner.invocation*".service"
 queued=SO.Service(owner,"core")
 marker=joinpath(OUT,"queued-start-"*owner.invocation)
 try
  cmd(["systemd-run","--user","--no-block","--unit="*blocker,"--service-type=notify","--property=CPUAffinity=2","--property=TimeoutStartSec=120","--property=TimeoutStopSec=3","/bin/sleep","120"])
  await(()->SO.properties(blocker)["MainPID"]!="0")
  cmd(["systemd-run","--user","--no-block","--unit="*queued.unit,"--service-type=exec","--property=CPUAffinity=2","--property=After="*blocker,"--property=Requires="*blocker,"/usr/bin/touch",marker])
  await(()->any(p->p.second==queued.unit,SO.listed_jobs(owner.invocation)))
  jobs=SO.listed_jobs(owner.invocation)
  SO.cleanup_invocation(owner.invocation)
  require(isempty(SO.listed_jobs(owner.invocation)),"queued owner job remains")
  ctl("stop",blocker)
  sleep(.3)
  require(!ispath(marker),"canceled owner executed")
  results["queued_start"]=Dict("success"=>true,"initial_jobs"=>Dict(jobs),"executed"=>ispath(marker))
 finally
  SO.properties(blocker)["LoadState"]=="not-found" || ctl("stop",blocker)
  SO.cleanup_invocation(owner.invocation)
 end
 # Actual launch! reconciliation and abrupt death use private coordinator MainPIDs.
 for mode in ("unknown","crash")
  unit="pipewireao-review-coordinator-"*nonce()*".service"
  launcher=joinpath(OUT,"probe-launcher-"*nonce())
  script=abspath(@__FILE__)
  shellquote(s)="'"*replace(s,"'"=>"'\"'\"'")*"'"
  write(launcher,"#!/bin/sh\nexec "*shellquote(JULIA)*" --startup-file=no --project="*shellquote(PROJECT)*" "*shellquote(script)*" \"\$@\"\n")
  chmod(launcher,0o700)
  hook=launcher*" cleanup-systemd-owners --invocation \${INVOCATION_ID}"
  try
   cmd(["systemd-run","--user","--no-block","--unit="*unit,"--service-type=exec","--property=CPUAffinity=2","--property=KillMode=mixed","--property=Restart=no","--property=TimeoutStopSec=120","--property=ExecStopPost="*hook,"--setenv=REVIEW_UNIT="*unit,"--setenv=REVIEW_LAUNCHER="*launcher,launcher,mode])
   if mode=="crash"
    readyfile=joinpath(OUT,"crash-ready.json")
    await(()->isfile(readyfile) && Common.read_json(readyfile)["unit"]==unit;timeout=60)
    results["crash_before"]=Common.read_json(readyfile)
    ctl("kill","--kill-whom=main","--signal=SIGKILL",unit)
   end
   await(()->SO.properties(unit)["ActiveState"] in ("inactive","failed");timeout=120)
   values=SO.properties(unit;extra="Result,ExecMainCode,ExecMainStatus")
   results[mode*"_coordinator"]=values
   if mode=="unknown"
    results["unknown_reply"]=Common.read_json(joinpath(OUT,"unknown-reply.json"))
    require(values["Result"]=="success","unknown-reply coordinator failed")
   else
    before=results["crash_before"]
    observed=read(before["output"],String)
    require(observed=="absent" || occursin("populated 0",observed),"crash hook stopped consumer before core empty")
    require(all(SO.cgroup_empty(before[role]["cgroup"]) for role in ("core","consumer")),"crash owner survived")
    require(isempty(SO.listed_jobs(before["invocation"])),"crash left pending jobs")
    results["crash_ordering"]=Dict("success"=>true,"consumer_observed_core"=>observed)
   end
  finally
   SO.properties(unit)["LoadState"]=="not-found" || ctl("stop",unit)
   SO.properties(unit)["LoadState"]=="not-found" || ctl("reset-failed",unit)
   rm(launcher)
  end
 end
 Common.write_json(joinpath(OUT,"receipt.json"),results)
 println("Private investigative probes passed: replacement fence, core-first order, queued start cancellation, unknown launch reconciliation")
end
end
if ARGS == ["unknown"]
 Investigation.unknown()
elseif ARGS == ["crash"]
 Investigation.crash()
elseif length(ARGS)==3 && ARGS[1]=="cleanup-systemd-owners" && ARGS[2]=="--invocation"
 Investigation.SO.cleanup_invocation(ARGS[3])
else
 Investigation.main()
end
