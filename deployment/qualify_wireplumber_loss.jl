#!/usr/bin/env julia
# Development loss checks; runtime remains the admission and link owner.
module WirePlumberLossQualification
include("qualify_wireplumber_hil.jl")
const W=WirePlumberHILQualification
const S,D,C=W.S,W.D,W.C
require(value,message)=W.require(value,message)

function main(args)
    length(args)==6 || error("expected PACKAGE FRESH_RUNTIME FRESH_EVIDENCE WP_SOURCE WP_BUILD required-link|simulator-owner")
    package,runtime,evidence,source,build=abspath.(args[1:5]); kind=args[6]
    require(kind in ("required-link","simulator-owner"),"Unknown loss case")
    require(all(path->!ispath(path)&&!islink(path),(runtime,evidence)),"Fresh outputs required")
    D.profile(joinpath(package,"deployment.conf"),"/opt/pipewireao")
    provenance=C.read_json(joinpath(package,"provenance.json"))
    require(provenance["hil"]["backend"]=="cuda" && provenance["engine"] in ("fgn","jfg"),
        "Loss checks select CUDA AOS with CPU FGN/JFG")
    mkpath(evidence;mode=0o700)
    sdk=joinpath(package,"julia")
    command=`$(Base.julia_cmd()) --startup-file=no --compiled-modules=existing --project=$sdk $(joinpath(sdk,"deploy_cli.jl")) run --deployment $(joinpath(package,"deployment.conf")) --pipewire-prefix /opt/pipewireao --runtime $runtime --owner-preparation-timeout-seconds 900`
    record=Dict{String,Any}("success"=>false,"case"=>kind,"package"=>package,
        "descriptor_sha256"=>C.sha256_file(joinpath(package,"deployment.conf")),
        "coordinator_sha256"=>C.sha256_file(@__FILE__),
        "policy_sha256"=>C.sha256_file(joinpath(@__DIR__,"wireplumber/hil-observer.lua")),
        "engine"=>provenance["engine"],"hil"=>provenance["hil"],
        "scope"=>"required loss under CPU RTC / CUDA AOS; no timing or transfer claim")
    observer=nothing;identities=Dict{String,Any}()
    open(joinpath(evidence,"deployment.log"),"w") do log
        process=run(pipeline(command;stdout=log,stderr=log);wait=false)
        try
            run(pipeline(`taskset -apc 6 $(getpid())`;stdout=devnull))
            D.wait_state(runtime,state->get(state,"admitted",false);timeout=900,process) do ready,client
                S.verify_admission_client(client,ready,getpid(process))
                record["ready"]=ready
                identities=S.owned_process_identities(ready["processes"],getpid(process))
                record["owned_process_identities"]=identities
                S.native_control(client,["session-stop"]);S.native_control(client,["reset"])
                observer,remote,required,nodes=W.start_observer(ready,package,evidence,source,build)
                record["observer_pid"]=getpid(observer)
                held=S.native_control(client,["status"])
                require(held["source"]["sequence"]==0 && held["source"]["state"]=="paused","Discovery advanced held source")
                record["held"]=held
                S.native_control(client,["session-start"])
                deadline=time_ns()/1e9+30
                while true
                    before=S.native_control(client,["status"])
                    if before["source"]["sequence"]>=16
                        record["before_loss"]=before
                        break
                    end
                    require(time_ns()/1e9<deadline,"No pre-loss acquisition progress")
                    sleep(0.02)
                end
                S.verify_admission_client(client,ready,getpid(process))
                logfile=joinpath(evidence,"wireplumber/wireplumber.log")
                prior_log=read(logfile,String)
                require(process_running(observer) && !occursin("HIL_COHORT_LOST",prior_log) &&
                    !occursin("_wplua_errhandler",prior_log),"Observer failed before loss injection")
                record["observer_log_offset"]=sizeof(prior_log)
                started=time_ns()
                if kind=="required-link"
                    session=D.decode(joinpath(package,"session.conf.in"),"/opt/pipewireao")
                    names=Set(v["node.name"] for v in session["sources"] if get(v,"ownership",nothing)=="external")
                    node_id=only(v["id"] for v in nodes if W.properties(v)["node.name"] in names)
                    target=only(v for v in required if v["info"]["output-node-id"]==node_id)
                    latest=W.registry(remote)
                    require(count(v->v["type"]=="PipeWire:Interface:Link" && W.identity(v)==W.identity(target),latest)==1,
                        "Required link incarnation changed before loss injection")
                    record["removed_link"]=target
                    result=C.run_checked(["/opt/pipewireao/bin/pwao-cli","-r",remote,"destroy",string(target["id"])];
                        env=Dict("LD_LIBRARY_PATH"=>"/opt/pipewireao/lib/x86_64-linux-gnu"),timeout=5,maximum_output_bytes=16384)
                    record["destroy_result"]=Dict("returncode"=>result.returncode,"stdout"=>result.stdout,"stderr"=>result.stderr)
                    require(result.returncode==0,"Required link removal failed")
                else
                    owned=identities["simulator"];current=S.process_identity(owned["pid"])
                    require(owned["ownership_confirmed"] && current!==nothing &&
                        current.parent_pid==getpid(process) && current.start_ticks==owned["identity"]["start_ticks"],
                        "Simulator process identity changed before loss injection")
                    record["killed_owner"]=owned
                    helper=joinpath(@__DIR__,"../scripts/signal_test_owner.py")
                    record["signal_helper_sha256"]=C.sha256_file(helper)
                    result=C.run_checked(["python3",helper,string(owned["pid"]),string(getpid(process)),
                        string(owned["identity"]["start_ticks"])];timeout=5,maximum_output_bytes=4096)
                    record["signal_result"]=Dict("returncode"=>result.returncode,"stdout"=>result.stdout,"stderr"=>result.stderr)
                    require(result.returncode==0,"Owned simulator termination failed")
                end
                try
                    record["native_after_loss"]=S.native_control(client,["status"];timeout=1)
                catch exception
                    record["native_after_loss_error"]=sprint(showerror,exception)
                end
                record["wait"]=S.wait_for_launcher(process,60,0.02)
                require(record["wait"]["launcher_exited"],"Required loss did not stop deployment within test bound")
                wait(process)
                record["exit_code"]=process.exitcode
                record["observed_teardown_nanoseconds"]=time_ns()-started
                require(process.exitcode!=0,"Required loss was not reported as failure")
                record["final_saved_report"]=C.read_json(joinpath(runtime,"state.json"))
                require(record["final_saved_report"]["phase"]=="failed" && !record["final_saved_report"]["admitted"],
                    "Postmortem report did not preserve revoked admission")
                record["cleanup"]=S.observed_cleanup(process,identities)
                require(record["cleanup"]["status"]=="complete" && !ispath(ready["private_runtime"]),
                    "Required loss retained an owned process or private runtime")
                # Core/source owners have exited: ingress is revoked. Saved state
                # documents the failure; it is never used for live readiness.
                post_log=open(logfile) do file
                    seek(file,record["observer_log_offset"])
                    read(file,String)
                end
                record["observer_loss_reported"]=occursin("HIL_COHORT_LOST",post_log)
                require(record["observer_loss_reported"],"Policy did not report required cohort loss")
                record["success"]=true
            end
        catch exception
            record["failure"]=sprint(showerror,exception)
        finally
            if observer!==nothing
                try W.stop_observer(observer) catch exception
                    record["observer_cleanup_failure"]=sprint(showerror,exception);record["success"]=false
                end
            end
            try
                if process_running(process)
                    record["success"]=false
                    record["fallback_cleanup"]=S.fallback_cleanup(process,identities;initial_wait=0.05)
                end
            catch exception
                record["success"]=false
                record["fallback_cleanup_failure"]=sprint(showerror,exception)
            finally
                C.write_json(joinpath(evidence,"receipt.json"),record)
            end
        end
    end
    println(joinpath(evidence,"receipt.json"))
    return record["success"] ? 0 : 1
end
end
abspath(PROGRAM_FILE)==(@__FILE__) && exit(WirePlumberLossQualification.main(ARGS))
