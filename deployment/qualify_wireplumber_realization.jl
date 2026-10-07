#!/usr/bin/env julia
# Opt-in ownership transfer qualification; science/calibration bytes are sealed.
module WirePlumberRealizationQualification
include("qualify_wireplumber_hil.jl")
const W=WirePlumberHILQualification
const S,D,C=W.S,W.D,W.C
require(value,message)=W.require(value,message)

function main(args)
    length(args)==5 || error("expected PACKAGE FRESH_RUNTIME FRESH_EVIDENCE BASELINE_RUN clean|required-link|manager|runtime|core")
    package,runtime,evidence,baseline=abspath.(args[1:4]); kind=args[5]
    require(kind in ("clean","required-link","manager","runtime","core"),"Unknown qualification case")
    require(all(path->!ispath(path)&&!islink(path),(runtime,evidence)),"Fresh outputs required")
    spec=D.profile(joinpath(package,"deployment.conf"),"/opt/pipewireao")
    require(haskey(spec,"session-manager"),"Explicit manager selection is required")
    provenance=C.read_json(joinpath(package,"provenance.json"))
    require(provenance["profile"]=="copper" && provenance["hil"]["backend"]=="cuda" && provenance["engine"] in ("fgn","jfg"),
        "Qualification selects Copper CPU RTC with CUDA AOS")
    mkpath(evidence;mode=0o700)
    sdk=joinpath(package,"julia")
    command=`$(Base.julia_cmd()) --startup-file=no --compiled-modules=existing --project=$sdk $(joinpath(sdk,"deploy_cli.jl")) run --deployment $(joinpath(package,"deployment.conf")) --pipewire-prefix /opt/pipewireao --runtime $runtime --owner-preparation-timeout-seconds 900`
    record=Dict{String,Any}("success"=>false,"case"=>kind,"package"=>package,"engine"=>provenance["engine"],
        "descriptor_sha256"=>C.sha256_file(joinpath(package,"deployment.conf")),
        "coordinator_sha256"=>C.sha256_file(@__FILE__),
        "policy_sha256"=>C.sha256_file(joinpath(package,"wireplumber/scripts/realization.lua")),
        "scope"=>"selected deployed ownership/lifecycle/numerical prefix/allocation gates; no latency or hardware claim")
    identities=Dict{String,Any}()
    open(joinpath(evidence,"deployment.log"),"w") do log
        process=run(pipeline(command;stdout=log,stderr=log);wait=false)
        try
            # Spawn with the existing complete owner envelope, then confine the test coordinator.
            run(pipeline(`taskset -apc 6 $(getpid())`;stdout=devnull))
            D.wait_state(runtime,state->get(state,"admitted",false);timeout=900,process) do ready,client
                S.verify_admission_client(client,ready,getpid(process)); record["ready"]=ready
                identities=S.owned_process_identities(ready["processes"],getpid(process));record["owned_process_identities"]=identities
                require(all(v->v["ownership_confirmed"],values(identities)),"Required process group ownership unproved")
                S.native_control(client,["session-stop"]);S.native_control(client,["reset"])
                remote=joinpath(ready["private_runtime"],ready["remote"])
                snapshot=W.registry(remote)
                _,required,nodes=W.manifest(snapshot,ready,package;link_owner_pid=ready["processes"]["wireplumber"]["pid"])
                marker=only(v for v in snapshot if v["type"]=="PipeWire:Interface:Node" &&
                    get(W.properties(v),"node.name",nothing)==spec["session-manager"]["marker-node"])
                record["marker"]=marker;record["links"]=required
                held=S.native_control(client,["status"])
                require(held["state"]=="Ready" && held["source"]["state"]=="paused" && held["source"]["sequence"]==0,
                    "Held reset/source authority did not remain with RTC")
                record["held"]=held
                if kind=="clean"
                    for number in 1:2
                        initial=S.native_control(client,["status"]);generation=Int64(initial["source"]["generation"])
                        S.native_control(client,["session-start"])
                        deadline=time_ns()/1e9+900
                        while true
                            require(process_running(process),"Deployment exited before acquisition completion")
                            require(time_ns()/1e9<deadline,"Acquisition completion timed out")
                            observed=S.native_control(client,["status"])
                            cursor=S.native_completed_source(observed["source"],generation)
                            if cursor!==nothing
                                prefix,summary=S.preserve_report(ready["private_runtime"],evidence,number,cursor)
                                require(summary["requested_exchanges"]==512 && summary["retained_prefix_frames"]==256,
                                    "Selected sealed cohort extent changed")
                                S.require_allocation_free(summary)
                                equality=Dict{String,Bool}()
                                for (field,name) in (("frame","simulator-result.frames.u16le"),("command","simulator-result.commands.f32le"))
                                    equality[field]=read(prefix[field]["file"])==read(joinpath(baseline,name))
                                end
                                require(all(values(equality)),"Retained science prefix changed")
                                record["run-$number"]=Dict("summary"=>summary,"prefix_equal"=>equality,"completion"=>observed)
                                break
                            end
                            sleep(0.05)
                        end
                        W.verify_links(W.registry(remote),required)
                        S.native_control(client,["session-stop"])
                        number==1 && S.native_control(client,["reset"])
                    end
                    S.native_control(client,["quit"])
                else
                    S.native_control(client,["session-start"])
                    deadline=time_ns()/1e9+30
                    while S.native_control(client,["status"])["source"]["sequence"]<16
                        require(time_ns()/1e9<deadline,"No progress before loss injection");sleep(0.02)
                    end
                    before=S.native_control(client,["status"])
                    require(before["state"]=="Running" && before["source"]["state"]=="running" &&
                        !before["source"]["completed"] && 16 <= before["source"]["sequence"] < 512,
                        "Loss injection missed live acquisition window")
                    record["before_loss"]=before
                    if kind=="required-link"
                        latest=W.registry(remote);target=first(required)
                        require(count(v->v["type"]=="PipeWire:Interface:Link" && W.identity(v)==W.identity(target),latest)==1,
                            "Required Link incarnation changed before injection")
                        result=C.run_checked(["/opt/pipewireao/bin/pwao-cli","-r",remote,"destroy",string(target["id"])];
                            env=Dict("LD_LIBRARY_PATH"=>"/opt/pipewireao/lib/x86_64-linux-gnu"),timeout=5,maximum_output_bytes=16384)
                        require(result.returncode==0,"Required Link removal failed");record["removed_link"]=target
                    else
                        role=kind=="manager" ? "wireplumber" : kind=="runtime" ? "rtc" : "core"
                        target=identities[role];observed=S.process_identity(target["pid"])
                        require(observed!==nothing && observed.parent_pid==getpid(process) &&
                            observed.start_ticks==target["identity"]["start_ticks"],"Owner incarnation changed")
                        helper=joinpath(@__DIR__,"../scripts/signal_test_owner.py")
                        result=C.run_checked(["python3",helper,string(target["pid"]),string(getpid(process)),string(observed.start_ticks)];
                            timeout=5,maximum_output_bytes=4096)
                        require(result.returncode==0,"Selected owner termination failed");record["killed_owner"]=target
                    end
                end
                record["wait"]=S.wait_for_launcher(process,60,0.02)
                require(record["wait"]["launcher_exited"],"Deployment cleanup exceeded check bound")
                wait(process);record["exit_code"]=process.exitcode
                require(kind=="clean" ? success(process) : process.exitcode!=0,"Unexpected terminal result")
                record["cleanup"]=S.observed_cleanup(process,identities)
                require(record["cleanup"]["status"]=="complete" && !ispath(ready["private_runtime"]),"Owned cohort survived cleanup")
                record["final_report"]=C.read_json(joinpath(runtime,"state.json"))
                kind=="clean" || require(record["final_report"]["phase"]=="failed" && !record["final_report"]["admitted"],
                    "Required loss was not retained as a fault")
                record["success"]=true
            end
        catch exception
            record["failure"]=sprint(showerror,exception)
        finally
            if process_running(process)
                record["success"]=false
                try record["fallback_cleanup"]=S.fallback_cleanup(process,identities)
                catch exception; record["fallback_failure"]=sprint(showerror,exception); end
            end
            C.write_json(joinpath(evidence,"receipt.json"),record)
        end
    end
    println(joinpath(evidence,"receipt.json"))
    return record["success"] ? 0 : 1
end
end
abspath(PROGRAM_FILE)==(@__FILE__) && exit(WirePlumberRealizationQualification.main(ARGS))
