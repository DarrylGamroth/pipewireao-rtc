#!/usr/bin/env julia
module WirePlumberServiceQualification
include("qualify_sustained.jl")
include("wireplumber/service.jl")
const S=SustainedQualification
const V=WirePlumberService
const W=V.W
const D,C=S.D,S.C
require(value,message)=value || error(message)

function command(argv;timeout=30)
    result=C.run_checked(argv;timeout,maximum_output_bytes=4*1024*1024)
    require(result.returncode==0,"Command failed: $(join(argv,' ')): $(result.stderr)")
    result.stdout
end
systemctl(args...;timeout=30)=command(["systemctl","--user",args...];timeout)
function state(unit)
    text=systemctl("show",unit,"-p","ActiveState","-p","SubState","-p","MainPID","-p","ControlGroup","-p","Result","-p","InvocationID")
    Dict(split(line,'=';limit=2) for line in split(strip(text),'\n'))
end
function wait_unit(unit,predicate;timeout=120)
    deadline=time_ns()/1e9+timeout
    while true
        observed=state(unit)
        predicate(observed) && return observed
        require(time_ns()/1e9<deadline,"Unit wait timed out: $unit $observed")
        sleep(0.1)
    end
end
function observe(unit,output;start=true)
    if start
        systemctl("start",unit;timeout=120)
    else
        wait_unit(unit,v->v["ActiveState"]=="active";timeout=120)
    end
    active=state(unit)
    require(active["ActiveState"]=="active","Observer unit did not start")
    binding=C.read_json(joinpath(output,"binding.json"))
    deadline=time_ns()/1e9+30
    while true
        # Inspect only the current observer incarnation's messages.
        current=command(["journalctl","--user","_PID="*active["MainPID"],
            "_SYSTEMD_INVOCATION_ID="*active["InvocationID"],"-b","--no-pager","-o","cat"])
        require(!occursin("_wplua_errhandler",current),"Observer rejected current cohort")
        occursin("HIL_COHORT_READY",current) && return Dict("unit"=>active,"binding"=>binding,"start_requested"=>start)
        require(state(unit)["MainPID"]==active["MainPID"] && time_ns()/1e9<deadline,"Observer discovery timed out or changed")
        sleep(0.1)
    end
end
function cgroup_empty(path)
    file=joinpath("/sys/fs/cgroup",lstrip(path,'/'),"cgroup.procs")
    !isfile(file) || isempty(strip(read(file,String)))
end

function main(args)
    length(args)==5 || error("expected INSTALLED_PACKAGE INSTALLED_COMPANION FRESH_EVIDENCE UNIQUE_INSTANCE BASELINE_RECEIPT")
    package,companion,evidence=abspath.(args[1:3]); instance=args[4]
    require(occursin(r"^wp-(fgn|jfg)-[A-Za-z0-9_.-]+$",instance),"Use a private wp-fgn/wp-jfg instance")
    require(!ispath(evidence),"Fresh evidence required");mkpath(evidence;mode=0o700)
    baseline=C.read_json(args[5])
    require(baseline["success"] && baseline["descriptor_sha256"]==C.sha256_file(joinpath(package,"deployment.conf")),
        "Baseline does not identify this qualified package")
    rtc="pipewireao-rtc@$instance.service"; observer="pipewireao-wireplumber@$instance.service"
    root=ENV["XDG_RUNTIME_DIR"]
    runtime=joinpath(root,"pipewireao-rtc-$instance"); output=joinpath(root,"pipewireao-wireplumber-$instance")
    require(!ispath(runtime)&&!ispath(output),"Fresh service runtime required")
    unitdir=joinpath(homedir(),".config/systemd/user");mkpath(unitdir)
    files=Dict{String,String}()
    template=read(joinpath(package,"julia/assets/deployment/pipewireao-rtc@.service.in"),String)
    cpus=join(sort!(unique(vcat([contract["cpus"] for contract in values(D.profile(joinpath(package,"deployment.conf"),"/opt/pipewireao")["placement"])]...)))," ")
    rtc_text=replace(template,"@LAUNCHER@"=>V.unit_quote(joinpath(package,"bin/pipewireao-rtc-deploy");argument=true),
        "@PIPEWIRE_PREFIX@"=>"\"/opt/pipewireao\"","@CPUS@"=>cpus,"@FITS_ARGUMENT@"=>"",
        "%h/.config/pipewireao-rtc/%i/deployment.conf"=>V.unit_quote(joinpath(package,"deployment.conf");argument=true))
    rtc_text=replace(rtc_text,"--runtime %t/pipewireao-rtc-%i"=>"--runtime %t/pipewireao-rtc-%i --owner-preparation-timeout-seconds 900")
    files[joinpath(unitdir,rtc)]=rtc_text
    files[joinpath(unitdir,observer)]=read(joinpath(companion,"pipewireao-wireplumber@.service"),String)
    require(all(path->!ispath(path)&&!islink(path),keys(files)),"Refusing existing user unit files")
    record=Dict{String,Any}("success"=>false,"scope"=>"optional Copper observer under user services; no timing claim",
        "package"=>package,"companion"=>companion,"rtc_unit"=>rtc,"observer_unit"=>observer,
        "coordinator_sha256"=>C.sha256_file(@__FILE__),"cycles"=>Any[],
        "baseline_receipt"=>abspath(args[5]),"baseline_receipt_sha256"=>C.sha256_file(args[5]))
    installed=false
    written=String[]
    try
        installed=true
        for (path,text) in files;write(path,text);push!(written,path);end
        systemctl("daemon-reload")
        write(joinpath(evidence,"unit-validation.log"),command(["systemd-analyze","--user","verify",keys(files)...]))
        for cycle in 1:2
            cycle==1 && systemctl("start","--no-block",rtc)
            wait_unit(rtc,v->v["ActiveState"]=="active" &&
                (cycle==1 || v["MainPID"]!=string(record["cycles"][end]["pid"]));timeout=600)
            D.wait_state(runtime,v->get(v,"admitted",false);timeout=600) do ready,client
                active=wait_unit(rtc,v->v["ActiveState"]=="active")
                pid=parse(Int,active["MainPID"])
                S.verify_admission_client(client,ready,pid)
                if cycle>1
                    previous=record["cycles"][end]
                    require(previous["uuid"]!=ready["deployment_uuid"] && previous["pid"]!=pid,"RTC restart reused its incarnation")
                    for (_,identity) in previous["owner_identities"]
                        require(identity["ownership_confirmed"],"Previous owned process identity was not confirmed")
                        # No signalling by numeric PID: scan for old detached groups.
                        old_pid=identity["pid"]
                        for name in readdir("/proc")
                            candidate=tryparse(Int,name);candidate===nothing && continue
                            found=S.process_identity(candidate)
                            require(found===nothing || found.group_pid!=old_pid || found.session_pid!=old_pid,
                                "RTC restart retained an old owned process group")
                        end
                    end
                    previous["cleanup_confirmed"]=true
                end
                S.native_control(client,["session-stop"]);S.native_control(client,["reset"])
                first=observe(observer,output;start=cycle==1)
                require(first["binding"]["deployment_uuid"]==ready["deployment_uuid"] && first["binding"]["owner_pid"]==pid,
                    "Service binding differs from native admission")
                if cycle>1
                    require(first["unit"]["MainPID"]!=record["cycles"][end]["observer_after_kill"]["unit"]["MainPID"],
                        "RTC restart retained the old observer process")
                end
                # Reset again with the observer present, retaining its identity.
                before_reset=S.native_control(client,["status"])
                S.native_control(client,["reset"])
                with_observer=S.native_control(client,["status"])
                require(with_observer["source"]["generation"]>before_reset["source"]["generation"] &&
                    with_observer["source"]["sequence"]==0 && with_observer["source"]["state"]=="paused" &&
                    state(observer)["MainPID"]==first["unit"]["MainPID"],"Reset changed observer or failed its held source contract")
                snapshot=W.registry(joinpath(ready["private_runtime"],ready["remote"]))
                _,original,_=W.manifest(snapshot,ready,package)
                initial=S.native_control(client,["status"])
                require(initial["state"]=="Ready" && initial["source"]["sequence"]==0,"Observer advanced held source")
                entry=Dict{String,Any}("pid"=>pid,"uuid"=>ready["deployment_uuid"],"ready"=>ready,
                    "rtc_state"=>active,"observer_start"=>first,"links"=>original,"initial"=>initial,
                    "owner_identities"=>S.owned_process_identities(ready["processes"],pid),
                    "reset_with_observer"=>with_observer)
                push!(record["cycles"],entry)
                generation=Int64(initial["source"]["generation"])
                S.native_control(client,["session-start"])
                tested=false; deadline=time_ns()/1e9+120
                while true
                    current=S.native_control(client,["status"])
                    cursor=S.native_completed_source(current["source"],generation)
                    if cursor!==nothing
                        require(tested,"Run completed before observer lifecycle checks")
                        prefix,summary=S.preserve_report(ready["private_runtime"],evidence,cycle,cursor)
                        require(summary["completed_commands"]==summary["completed_frames"]==512,"Unexpected completed extent")
                        S.require_allocation_free(summary)
                        entry["summary"]=summary;entry["frame_sha256"]=prefix["frame"]["sha256"]
                        entry["command_sha256"]=prefix["command"]["sha256"]
                        require(entry["frame_sha256"]==baseline["run-1"]["prefix_frame_sha256"] &&
                            entry["command_sha256"]==baseline["run-1"]["prefix_command_sha256"],
                            "User service changed the independently qualified baseline prefix")
                        break
                    end
                    if !tested && current["source"]["sequence"]>80
                        S.native_control(client,["session-stop"])
                        held=S.native_control(client,["status"])
                        require(held["source"]["state"]=="paused" && held["source"]["sequence"]<256,"Pause missed comparison prefix")
                        entry["held"]=held
                        systemctl("stop",observer)
                        require(state(observer)["ActiveState"]=="inactive" && !ispath(output),"Observer stop left runtime state")
                        second=observe(observer,output)
                        require(second["unit"]["MainPID"]!=first["unit"]["MainPID"],"Observer stop/start reused process")
                        entry["observer_restart"]=second
                        systemctl("kill","--kill-whom=main","--signal=SIGKILL",observer)
                        failed=wait_unit(observer,v->v["ActiveState"]=="failed")
                        require(failed["MainPID"]=="0" && failed["Result"]=="signal" && !ispath(output),"Observer kill outcome differs")
                        sleep(0.1)
                        require(state(observer)["MainPID"]=="0","Observer restarted automatically")
                        entry["observer_killed"]=failed
                        third=observe(observer,output)
                        entry["observer_after_kill"]=third
                        W.verify_links(W.registry(joinpath(ready["private_runtime"],ready["remote"])),original)
                        after=S.native_control(client,["status"])
                        require(after["source"]["sequence"]==held["source"]["sequence"] && after["source"]["generation"]==generation &&
                            after["processes"]==initial["processes"] && state(rtc)["MainPID"]==string(pid),"Observer lifecycle changed the RTC cohort/source")
                        S.native_control(client,["session-start"]);tested=true
                    end
                    require(time_ns()/1e9<deadline,"Service run completion timed out");sleep(0.05)
                end
                W.verify_links(W.registry(joinpath(ready["private_runtime"],ready["remote"])),original)
            end
            if cycle==1
                # An actual restart transaction tests PartOf, not stop/start.
                record["cycles"][end]["restart_requested_while_observer_active"]=state(observer)
                require(record["cycles"][end]["restart_requested_while_observer_active"]["ActiveState"]=="active",
                    "RTC restart was not requested with an active observer")
                systemctl("restart","--no-block",rtc)
                continue
            end
            # Unexpected RTC cohort exit must stop WP through BindsTo.
            systemctl("kill","--kill-whom=all","--signal=SIGKILL",rtc)
            wait_unit(rtc,v->v["ActiveState"]=="failed" && v["MainPID"]=="0")
            stopped=wait_unit(observer,v->v["ActiveState"]=="inactive")
            entry=record["cycles"][end];entry["observer_stopped_with_rtc"]=stopped
            require(state(rtc)["MainPID"]=="0" && !ispath(runtime) && !ispath(output),"Service stop retained private runtime")
            require(cgroup_empty(entry["rtc_state"]["ControlGroup"]) && cgroup_empty(entry["observer_after_kill"]["unit"]["ControlGroup"]),"Owned service cgroup retained processes")
            entry["cleanup_confirmed"]=true
        end
        a,b=record["cycles"]
        require(a["frame_sha256"]==b["frame_sha256"] && a["command_sha256"]==b["command_sha256"],"Service restarts changed retained prefixes")
        record["success"]=true
    catch exception
        record["failure"]=sprint(showerror,exception)
    finally
        if installed
            try
                systemctl("stop",observer,rtc;timeout=310)
                for path in written
                    require(isfile(path) && read(path,String)==files[path],"Owned unit file changed; preserving it")
                    rm(path)
                end
                systemctl("daemon-reload")
                # Only clear failed state for these freshly created units.
                C.run_checked(["systemctl","--user","reset-failed",observer,rtc];timeout=10)
                record["unit_cleanup"]=true
            catch exception
                record["cleanup_failure"]=sprint(showerror,exception);record["success"]=false
            end
        end
        for unit in (rtc,observer)
            try
                write(joinpath(evidence,unit*".log"),command(["journalctl","--user","-u",unit,"-b","--no-pager","-o","cat"]))
            catch exception
                record["journal_failure-$unit"]=sprint(showerror,exception);record["success"]=false
            end
        end
        C.write_json(joinpath(evidence,"receipt.json"),record)
    end
    println(joinpath(evidence,"receipt.json"))
    return record["success"] ? 0 : 1
end
end
abspath(PROGRAM_FILE)==(@__FILE__) && exit(WirePlumberServiceQualification.main(ARGS))
