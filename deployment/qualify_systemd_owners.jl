#!/usr/bin/env julia
# Opt-in, non-actuating selected service-owner qualification.
module SystemdOwnerQualification
include("qualify_wireplumber_hil.jl")
const W = WirePlumberHILQualification
const S, D, C = W.S, W.D, W.C
const SO = S.PipeWireAODeployment.SystemdOwners
const QUALIFICATION_SOURCE_SHA256 = C.sha256_file(@__FILE__)
require(value, message) = value || error(message)

function command(argv; timeout=30)
    reply = C.run_checked(argv; timeout, maximum_output_bytes=4*1024*1024)
    require(reply.returncode == 0, "command failed: $(first(argv)): $(reply.stderr)")
    reply.stdout
end
ctl(args...; timeout=30) = command(["systemctl", "--user", args...]; timeout)
state(unit) = SO.properties(unit; extra="SubState,Result,ExecMainCode,ExecMainStatus")
function wait_unit(unit, predicate; timeout=300)
    deadline = time_ns()/1e9 + timeout
    while true
        value = state(unit)
        predicate(value) && return value
        require(time_ns()/1e9 < deadline, "unit state wait expired: $unit $value")
        sleep(0.1)
    end
end
unit_quote(value) = String(S.D.JSON3.write(replace(value, "%"=>"%%", "\$"=>"\$\$")))

function main(args)
    length(args) == 5 || error("expected INSTALLED_PACKAGE FRESH_RUNTIME FRESH_EVIDENCE BASELINE_RUN clean|restart|core|simulator|julia|manager|rtc|coordinator")
    package, runtime, evidence, baseline = abspath.(args[1:4]); kind = args[5]
    require(kind in ("clean","restart","core","simulator","julia","manager","rtc","coordinator"), "unsupported case")
    require(all(path->!ispath(path) && !islink(path), (runtime,evidence)), "fresh outputs required")
    S.PipeWireAODeployment.Placement.pin_supervisor(6)
    spec = D.profile(joinpath(package,"deployment.conf"), "/opt/pipewireao")
    provenance = C.read_json(joinpath(package,"provenance.json"))
    require(provenance["profile"] == "copper" && provenance["hil"]["backend"] == "cuda" &&
        provenance["engine"] in ("fgn","jfg") && haskey(spec,"session-manager"), "selected profile required")
    kind == "julia" && require(any(o->o["role"]=="julia",spec["owners"]), "Julia owner case requires JFG")
    mkpath(evidence; mode=0o700)
    instance = "sd-$(provenance["engine"])-" * first(replace(string(S.PipeWireAODeployment.Deployment.uuid4()),"-"=>""),12)
    unit = "pipewireao-rtc-systemd@$instance.service"
    unitpath = joinpath(homedir(),".config/systemd/user",unit)
    require(!ispath(unitpath) && state(unit)["LoadState"]=="not-found", "refusing existing unit")
    template = joinpath(package,"julia/assets/deployment/pipewireao-rtc-systemd@.service.in")
    cpus = join(sort!(unique(vcat([v["cpus"] for v in values(spec["placement"])]...)))," ")
    text = replace(read(template,String), "@LAUNCHER@"=>unit_quote(joinpath(package,"bin/pipewireao-rtc-deploy")),
        "@PIPEWIRE_PREFIX@"=>unit_quote("/opt/pipewireao"), "@CPUS@"=>cpus,"@FITS_ARGUMENT@"=>"",
        "%h/.config/pipewireao-rtc/%i/deployment.conf"=>unit_quote(joinpath(package,"deployment.conf")),
        "%t/pipewireao-rtc-systemd-%i"=>unit_quote(runtime),
        "TimeoutStartSec=600"=>"TimeoutStartSec=900",
        "--process-supervisor systemd"=>"--owner-preparation-timeout-seconds 900 --process-supervisor systemd")
    receipt = Dict{String,Any}("success"=>false,"case"=>kind,"unit"=>unit,"package"=>package,
        "descriptor_sha256"=>C.sha256_file(joinpath(package,"deployment.conf")),
        "qualification_source_sha256"=>QUALIFICATION_SOURCE_SHA256,"cycles"=>Any[],
        "scope"=>"Copper CPU FGN/JFG, CUDA AOS, native lifecycle and exact prefixes; no timing or physical claim")
    installed = false
    try
        mkpath(dirname(unitpath)); write(unitpath,text); installed=true
        write(joinpath(evidence,"coordinator.service"),text)
        ctl("daemon-reload")
        write(joinpath(evidence,"unit-validation.log"),command(["systemd-analyze","--user","verify",unitpath]))
        for cycle in 1:(kind == "restart" ? 2 : 1)
            ctl("start","--no-block",unit)
            live = wait_unit(unit,v->v["MainPID"]!="0" || v["ActiveState"]=="failed"; timeout=60)
            require(live["MainPID"]!="0", "coordinator failed before admission")
            coordinator_pid = parse(Int,live["MainPID"])
            entry = Dict{String,Any}("coordinator"=>live,"owners"=>Dict{String,Any}())
            push!(receipt["cycles"],entry)
            D.wait_state(runtime,v->get(v,"admitted",false); timeout=900,
                    expected_owner_pid=coordinator_pid) do ready, client
                S.verify_admission_client(client,ready,coordinator_pid)
                entry["ready"] = ready
                for (role, owner) in ready["processes"]
                    name = "$(SO.PREFIX)$(live["InvocationID"])-$role.service"
                    actual = state(name)
                    require(actual["ActiveState"]=="active" && parse(Int,actual["MainPID"])==owner["pid"], "owner unit differs from native owner")
                    require(SO.proc_cgroup(owner["pid"])==actual["ControlGroup"], "owner process outside service cgroup")
                    entry["owners"][role] = actual
                end
                S.native_control(client,["session-stop"]); S.native_control(client,["reset"])
                held = S.native_control(client,["status"])
                require(held["state"]=="Ready" && held["source"]["state"]=="paused" && held["source"]["sequence"]==0, "source advanced while held")
                entry["held"] = held
                remote = joinpath(ready["private_runtime"],ready["remote"])
                _, links, _ = W.manifest(W.registry(remote),ready,package; link_owner_pid=ready["processes"]["wireplumber"]["pid"])
                entry["links"] = links
                if kind in ("clean","restart")
                    for number in 1:2
                        initial = S.native_control(client,["status"])
                        generation = Int64(initial["source"]["generation"])
                        S.native_control(client,["session-start"])
                        deadline = time_ns()/1e9+120
                        while true
                            require(state(unit)["MainPID"]==string(coordinator_pid), "coordinator identity changed")
                            require(time_ns()/1e9<deadline, "run completion expired")
                            current = S.native_control(client,["status"])
                            cursor = S.native_completed_source(current["source"],generation)
                            if cursor !== nothing
                                prefix, summary = S.preserve_report(ready["private_runtime"],evidence,2*(cycle-1)+number,cursor)
                                require(summary["completed_frames"]==summary["completed_commands"]==512, "incorrect delivery extent")
                                S.require_allocation_free(summary)
                                equality = Dict(field=>read(prefix[field]["file"])==read(joinpath(baseline,name))
                                    for (field,name) in (("frame","simulator-result.frames.u16le"),("command","simulator-result.commands.f32le")))
                                require(all(values(equality)), "science prefix changed")
                                entry["run-$number"] = Dict("summary"=>summary,"prefix_equal"=>equality)
                                break
                            end
                            sleep(0.05)
                        end
                        W.verify_links(W.registry(remote),links)
                        S.native_control(client,["session-stop"])
                        number==1 && S.native_control(client,["reset"])
                    end
                    S.native_control(client,["quit"])
                else
                    S.native_control(client,["session-start"])
                    deadline=time_ns()/1e9+30
                    before=S.native_control(client,["status"])
                    while before["source"]["sequence"]<16
                        require(time_ns()/1e9<deadline,"no ingress before fault"); sleep(0.02)
                        before=S.native_control(client,["status"])
                    end
                    require(!before["source"]["completed"],"missed live fault window")
                    entry["before_loss"]=before
                    target=kind=="coordinator" ? unit : entry["owners"][kind=="manager" ? "wireplumber" : kind]["Id"]
                    ctl("kill","--kill-whom=main","--signal=SIGKILL",target)
                end
            end
            final = wait_unit(unit,v->v["ActiveState"] in ("inactive","failed") && v["MainPID"]=="0"; timeout=300)
            entry["final"]=final
            require(SO.cgroup_empty(live["ControlGroup"]),"coordinator cgroup remains populated")
            require(isempty(SO.listed_jobs(live["InvocationID"])),"pending owner starts after shutdown")
            entry["owner_final"] = Dict{String,Any}()
            for (role, actual) in entry["owners"]
                empty = SO.cgroup_empty(actual["ControlGroup"])
                observed = state(actual["Id"])
                entry["owner_final"][role] = Dict("unit"=>observed,"cgroup_empty"=>empty)
                require(empty,"$role cgroup remains populated")
                require(observed["MainPID"]=="0","$role still running")
            end
            entry["cleanup_confirmed"]=true
            saved=C.read_json(joinpath(runtime,"state.json"))
            entry["saved_report"]=saved
            retained = get(saved,"retained_runtime",nothing)
            if retained !== nothing
                entry["retained_runtime_present"] = isdir(retained)
                require(entry["retained_runtime_present"],"reported diagnostic runtime was removed")
            end
            write(joinpath(evidence,"cycle-$cycle-journal.log"),command(["journalctl","--user","--no-pager","-o","short-monotonic",
                "_SYSTEMD_INVOCATION_ID="*live["InvocationID"]]))
            for (role, actual) in entry["owners"]
                write(joinpath(evidence,"cycle-$cycle-$role-journal.log"),command(["journalctl","--user","--no-pager","-o","short-monotonic",
                    "_SYSTEMD_INVOCATION_ID="*actual["InvocationID"]]))
            end
            kind in ("clean","restart") && require(saved["phase"]=="stopped" && isempty(get(saved,"cleanup_errors",[])),"clean shutdown failed")
            kind in ("clean","restart","coordinator") || require(saved["phase"]=="failed" && !saved["admitted"],"owner loss did not revoke admission")
            if cycle>1
                require(receipt["cycles"][1]["coordinator"]["InvocationID"]!=live["InvocationID"], "restart reused invocation")
                require(receipt["cycles"][1]["ready"]["deployment_uuid"]!=entry["ready"]["deployment_uuid"], "restart reused admission UUID")
            end
        end
        receipt["success"]=true
    catch error
        receipt["error"]=sprint(showerror,error)
        rethrow()
    finally
        if installed
            try ctl("stop",unit;timeout=300) catch error receipt["cleanup_error"]=sprint(showerror,error) end
            for entry in receipt["cycles"]
                try SO.cleanup_invocation(entry["coordinator"]["InvocationID"]) catch error receipt["cleanup_error"]=sprint(showerror,error) end
            end
            isfile(unitpath) && rm(unitpath)
            ctl("daemon-reload")
        end
        C.write_json(joinpath(evidence,"receipt.json"),receipt)
    end
end
end
if abspath(PROGRAM_FILE) == @__FILE__
    SystemdOwnerQualification.main(ARGS)
end
