#!/usr/bin/env julia
# Development-only same-process adapter test with the sealed scientific owners.
module WirePlumberRetryQualification
include("qualify_wireplumber_hil.jl")
const W=WirePlumberHILQualification
const S,D,C=W.S,W.D,W.C
require(value,message)=W.require(value,message)

function capture_children!(identities, launcher_pid, package, binary, owners)
    tasks="/proc/$launcher_pid/task"
    isdir(tasks) || return
    children=Set{Int}()
    names=try readdir(tasks) catch; return end
    for tid in names
        file=joinpath(tasks,tid,"children")
        values=try split(read(file,String)) catch; continue end
        union!(children,parse.(Int,values))
    end
    for pid in children
        path="/proc/$pid/cmdline"
        isfile(path) || continue
        args=try split(read(path,String),'\0';keepempty=false) catch; continue end
        isempty(args) && continue
        role=basename(first(args))=="pipewire-ao" ? "core" :
            first(args)==joinpath(package,"wireplumber/wireplumber") ? "wireplumber" :
            first(args)==binary || joinpath(package,"bin/pipewireao-rtc") in args ? "rtc" : nothing
        if role===nothing
            matches=[name for (name,script) in owners if script in args]
            length(matches)==1 && (role=only(matches))
        end
        role===nothing && continue
        observed=S.owned_process_identities(Dict(role=>Dict("pid"=>pid)),launcher_pid)[role]
        if observed["ownership_confirmed"]
            if haskey(identities,role)
                previous=identities[role]
                require(previous["pid"]==observed["pid"] &&
                    previous["identity"]["start_ticks"]==observed["identity"]["start_ticks"],
                    "Unexpected owner replacement during held retry test")
            end
            identities[role]=observed
        end
    end
end

function main(args)
    length(args)==4 || error("expected PACKAGE FRESH_RUNTIME FRESH_EVIDENCE LIBTEST_BINARY")
    original,runtime,evidence,binary=abspath.(args)
    require(all(path->!ispath(path)&&!islink(path),(runtime,evidence)),"Fresh outputs required")
    require(isfile(binary)&&isexecutable(binary),"Native test binary required")
    mkpath(evidence;mode=0o700)
    package=joinpath(evidence,"test-package");cp(original,package;follow_symlinks=true)
    descriptor=joinpath(package,"deployment.conf");spec=D.profile(descriptor,"/opt/pipewireao")
    require(haskey(spec,"session-manager"),"Selected realization manager required")
    wrapper=joinpath(@__DIR__,"../scripts/run_realization_probe.py")
    cp(wrapper,joinpath(package,"bin/pipewireao-rtc");force=true);chmod(joinpath(package,"bin/pipewireao-rtc"),0o755)
    spec["artifacts"]["bin/pipewireao-rtc"]=C.sha256_file(wrapper)
    spec["environment"]["PIPEWIREAO_REALIZATION_TEST_BINARY"]=binary
    C.write_json(descriptor,spec);D.profile(descriptor,"/opt/pipewireao")
    sdk=joinpath(package,"julia")
    command=`$(Base.julia_cmd()) --startup-file=no --compiled-modules=existing --project=$sdk $(joinpath(sdk,"deploy_cli.jl")) run --deployment $descriptor --pipewire-prefix /opt/pipewireao --runtime $runtime --owner-preparation-timeout-seconds 900`
    record=Dict{String,Any}("success"=>false,"package"=>original,"binary_sha256"=>C.sha256_file(binary),
        "wrapper_sha256"=>C.sha256_file(wrapper),"coordinator_sha256"=>C.sha256_file(@__FILE__),
        "scope"=>"same-process public adapter unload/retry with held scientific owners; deliberately no native runner endpoint or acquisition")
    owners=Dict(owner["role"]=>replace(only(filter(arg->endswith(arg,".jl"),owner["argv"])),
        "@PACKAGE@"=>package) for owner in spec["owners"])
    identities=Dict{String,Any}();logfile=joinpath(evidence,"deployment.log")
    open(logfile,"w") do log
        launcher=run(pipeline(command;stdout=log,stderr=log);wait=false)
        launcher_pid=getpid(launcher)
        try
            run(pipeline(`taskset -apc 12 $(getpid())`;stdout=devnull))
            deadline=time_ns()/1e9+900
            while process_running(launcher)
                capture_children!(identities,launcher_pid,package,binary,owners)
                require(time_ns()/1e9<deadline,"Retry qualification timed out")
                sleep(0.02)
            end
            wait(launcher);flush(log)
            require(launcher.exitcode!=0,"Endpoint-free native adapter test must not admit an outer deployment")
            transcript=read(logfile,String)
            require(occursin("test result: ok. 1 passed; 0 failed",transcript),"Native same-process test failed")
            require(count("REALIZATION_ADMITTED generation=",transcript)==2 &&
                count("REALIZATION_WITHDRAWN generation=",transcript)==2,"Two native realization fences not observed")
            require(Set(keys(identities))==Set(keys(spec["placement"])),"Owned cohort identities incomplete")
            record["cleanup"]=S.observed_cleanup(launcher,identities)
            require(record["cleanup"]["status"]=="complete","Owned cohort survived cleanup")
            final=C.read_json(joinpath(runtime,"state.json"));record["final_report"]=final
            require(final["phase"]=="failed" && !final["admitted"] && final["source"]["sequence"]==0 &&
                occursin("required rtc exited with status 0",string(final["error"])),
                "Unexpected admission or source progress in held adapter test")
            record["success"]=true
        catch error
            record["failure"]=sprint(showerror,error)
        finally
            record["owned_process_identities"]=identities
            process_running(launcher) && (record["fallback_cleanup"]=S.fallback_cleanup(launcher,identities))
            C.write_json(joinpath(evidence,"receipt.json"),record)
        end
    end
    println(joinpath(evidence,"receipt.json"))
    return record["success"] ? 0 : 1
end
end
abspath(PROGRAM_FILE)==(@__FILE__) && exit(WirePlumberRetryQualification.main(ARGS))
