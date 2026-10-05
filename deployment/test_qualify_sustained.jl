using Test
include("qualify_sustained.jl")
const SQ = SustainedQualification

@testset "continuous and stopped-reset qualification modes" begin
    paths = ["package", "runtime", "evidence"]
    @test SQ.qualification_mode(paths) === :continuous
    @test SQ.qualification_mode([paths; "reset"]) === :reset
    @test SQ.qualification_mode([paths; "lifecycle"]) === :lifecycle
    @test_throws ErrorException SQ.qualification_mode(paths[1:2])
    @test_throws ErrorException SQ.qualification_mode([paths; "unknown"])
    @test_throws ErrorException SQ.qualification_mode([paths; "reset"; "extra"])
end

@testset "whole simulator allocation gate" begin
    clean = Dict("requested_exchanges"=>128, "retained_prefix_frames"=>64,
        "metrics"=>Dict("measured_count"=>64), "allocation"=>Dict(
        "completed_exchanges"=>64, "allocated_bytes"=>0, "gc_time_ns"=>0,
        "gc_pauses"=>0, "full_sweeps"=>0,
        "allocations"=>Dict("pool"=>0,"big"=>0,"malloc"=>0,"realloc"=>0)))
    @test SQ.require_allocation_free(clean) === nothing
    for key in ("allocated_bytes","gc_time_ns","gc_pauses","full_sweeps")
        for value in (1,-1,nothing,true)
            failed = deepcopy(clean)
            failed["allocation"][key] = value
            @test_throws ErrorException SQ.require_allocation_free(failed)
        end
    end
    for key in ("pool","big","malloc","realloc")
        failed = deepcopy(clean)
        failed["allocation"]["allocations"][key] = 1
        @test_throws ErrorException SQ.require_allocation_free(failed)
    end
    for key in ("allocation",)
        failed = deepcopy(clean)
        delete!(failed,key)
        @test_throws ErrorException SQ.require_allocation_free(failed)
    end
    for key in ("completed_exchanges","allocated_bytes","gc_time_ns","gc_pauses","full_sweeps","allocations")
        failed = deepcopy(clean)
        delete!(failed["allocation"],key)
        @test_throws ErrorException SQ.require_allocation_free(failed)
    end
    for value in (0,-1,true,65)
        failed = deepcopy(clean)
        failed["allocation"]["completed_exchanges"] = value
        @test_throws ErrorException SQ.require_allocation_free(failed)
    end
    shortened = deepcopy(clean)
    shortened["allocation"]["completed_exchanges"] = 63
    shortened["metrics"]["measured_count"] = 63
    @test_throws ErrorException SQ.require_allocation_free(shortened)
    for key in ("requested_exchanges","retained_prefix_frames")
        failed = deepcopy(clean)
        delete!(failed,key)
        @test_throws ErrorException SQ.require_allocation_free(failed)
        failed = deepcopy(clean)
        failed[key] = true
        @test_throws ErrorException SQ.require_allocation_free(failed)
    end
end

@testset "bounded memory sample ring" begin
    @test_throws ArgumentError SQ.SampleRing(0)
    ring = SQ.SampleRing(3)
    @test isempty(SQ.retained_samples(ring))
    for number in 1:2
        SQ.retain_sample!(ring,number)
    end
    @test SQ.retained_samples(ring) == [1,2]
    SQ.retain_sample!(ring,3)
    @test SQ.retained_samples(ring) == [1,2,3]
    SQ.retain_sample!(ring,4)
    @test SQ.retained_samples(ring) == [2,3,4]
    for number in 5:10
        SQ.retain_sample!(ring,number)
    end
    @test SQ.retained_samples(ring) == [8,9,10]
    @test length(ring) == 3
    @test ring.count == 10
end

# Fake detached owner and grandchild only. No RTC, device or graph is started.
const FAKE_SUPERVISOR = raw"""
Base.exit_on_sigint(false)
ccall(:prctl,Cint,(Cint,Culong,Culong,Culong,Culong),36,1,0,0,0) == 0 || error("subreaper")
directory,mode = ARGS
pidfile = joinpath(directory,"owner.pids")
ready = joinpath(directory,"ready")
shell = raw"trap '' INT TERM; sleep 60 & child=$!; printf '%s %s\n' $$ $child > $1; wait $child"
owner = run(Cmd(Cmd(["sh","-c",shell,"owner",pidfile]);detach=true);wait=false)
owner_pid = getpid(owner)
while !isfile(pidfile) || isempty(read(pidfile,String)); sleep(0.01); end
descendant = parse.(Int,split(read(pidfile,String)))[2]
function clean_owner()
    sleep(0.25)
    # The test supervisor owns this live detached leader. Its group ID cannot
    # be recycled while that leader is still alive.
    process_running(owner) || error("fake owner exited early")
    ccall(:kill,Cint,(Cint,Cint),-owner_pid,Base.SIGKILL) == 0 || error("fake group kill")
    wait(owner)
    status = Ref{Cint}(0)
    ccall(:waitpid,Cint,(Cint,Ref{Cint},Cint),descendant,status,0) == descendant || error("fake descendant reap")
end
try
    write(ready,"ready\n")
    if mode == "already-cleaning"
        while !isfile(joinpath(directory,"begin-cleanup")); sleep(0.01); end
        clean_owner()
    else
        while true
            try
                sleep(0.02)
            catch exception
                mode == "ignored" && exception isa InterruptException || rethrow()
            end
        end
    end
catch exception
    exception isa InterruptException || rethrow()
    clean_owner()
end
"""

function fake_supervisor(directory,mode)
    script = joinpath(directory,"supervisor.jl")
    write(script,FAKE_SUPERVISOR)
    log = open(joinpath(directory,"supervisor.log"),"w")
    process = run(pipeline(`$(Base.julia_cmd()) --startup-file=no $script $directory $mode`;stdout=log,stderr=log);wait=false)
    ready = joinpath(directory,"ready")
    deadline = time()+15
    while !isfile(ready) && process_running(process) && time()<deadline
        sleep(0.02)
    end
    if !isfile(ready)
        process_running(process) && kill(process,Base.SIGKILL)
        wait(process)
        close(log)
        error("fake supervisor not ready: " * read(joinpath(directory,"supervisor.log"),String))
    end
    pids = parse.(Int,split(read(joinpath(directory,"owner.pids"),String)))
    identities = SQ.owned_process_identities(Dict("owner"=>Dict("pid"=>pids[1])),getpid(process))
    observed = [SQ.process_identity(pid) for pid in pids]
    return process,log,identities,observed
end

function cleanup_fake(process,identities,observed)
    process_running(process) && kill(process,Base.SIGKILL)
    wait(process)
    # The test is a subreaper; only matching adopted fake descendants can be
    # signalled or reaped. Never act on a reused numeric PID.
    entry = identities["owner"]["identity"]
    anchor = SQ.process_identity(entry["pid"])
    if anchor !== nothing && anchor.start_ticks == entry["start_ticks"] &&
       anchor.parent_pid == getpid() && anchor.group_pid == anchor.session_pid == anchor.pid
        ccall(:kill,Cint,(Cint,Cint),-anchor.pid,Base.SIGKILL)
    end
    deadline = time()+5
    while time()<deadline
        remaining = false
        for original in observed
            original === nothing && continue
            current = SQ.process_identity(original.pid)
            current === nothing && continue
            current.start_ticks == original.start_ticks || continue
            remaining = true
            if current.parent_pid == getpid() && current.state in ("Z","X")
                status = Ref{Cint}(0)
                ccall(:waitpid,Cint,(Cint,Ref{Cint},Cint),current.pid,status,1)
            end
        end
        remaining || return
        sleep(0.02)
    end
    error("fake descendants remain after test cleanup")
end

@testset "owned supervisor fallback and explicit cleanup" begin
    @test SQ.SUPERVISOR_CLEANUP_GRACE_SECONDS == 300.0
    @test SQ.process_identity(getpid()).pid == getpid()
    @test SQ.process_identity(true) === nothing
    @test SQ.process_identity(-1) === nothing
    # Isolate fake orphan ownership within this test process.
    @test ccall(:prctl,Cint,(Cint,Culong,Culong,Culong,Culong),36,1,0,0,0) == 0
    for mode in ("already-cleaning","delayed","ignored")
        mktempdir() do directory
            process,log,identities,observed = fake_supervisor(directory,mode)
            try
                @test identities["owner"]["ownership_confirmed"]
                @test length(observed) == 2 && all(!isnothing,observed)
                record = Dict{String,Any}("success"=>true,"shutdown_confirmed"=>false)
                function rejected_shutdown(runtime,process;timeout)
                    mode == "already-cleaning" && write(joinpath(directory,"begin-cleanup"),"quit requested\n")
                    error("injected public shutdown failure")
                end
                started = time()
                SQ.shutdown_qualification!(record,"mock",process,identities;
                    shutdown=rejected_shutdown,initial_wait=mode == "already-cleaning" ? 2.0 : 0.1,
                    post_interrupt_grace=2.0,kill_grace=2.0)
                @test !record["shutdown_confirmed"]
                @test !record["success"]
                @test SQ.qualification_exit_code(record) == 1
                @test record["shutdown_failure"] == "injected public shutdown failure"
                @test record["cleanup"]["fallback"]
                @test record["cleanup"]["launcher_exited"]
                initial = record["cleanup"]["initial_wait"]
                post_interrupt = record["cleanup"]["post_interrupt_wait"]
                @test initial["limit_seconds"] == (mode == "already-cleaning" ? 2.0 : 0.1)
                @test post_interrupt["limit_seconds"] == 2.0
                if mode == "already-cleaning"
                    @test !record["cleanup"]["launcher_interrupted"]
                    @test !record["cleanup"]["launcher_killed"]
                    @test initial["launcher_exited"]
                    @test initial["elapsed_seconds"] > 0
                    @test !post_interrupt["attempted"]
                    @test post_interrupt["elapsed_seconds"] == 0
                    @test record["cleanup"]["status"] == "complete"
                    @test all(p -> SQ.process_identity(p.pid) === nothing,observed)
                elseif mode == "delayed"
                    @test record["cleanup"]["launcher_interrupted"]
                    @test initial["elapsed_seconds"] >= 0.1
                    @test !initial["launcher_exited"]
                    @test post_interrupt["attempted"]
                    @test post_interrupt["elapsed_seconds"] >= 0.25
                    @test time()-started >= 0.25
                    @test !record["cleanup"]["launcher_killed"]
                    @test record["cleanup"]["status"] == "complete"
                    @test record["cleanup"]["groups"]["owner"]["status"] == "complete"
                    @test all(p -> SQ.process_identity(p.pid) === nothing,observed)
                else
                    @test record["cleanup"]["launcher_interrupted"]
                    @test initial["elapsed_seconds"] >= 0.1
                    @test post_interrupt["attempted"]
                    @test post_interrupt["elapsed_seconds"] >= 2.0
                    @test record["cleanup"]["launcher_killed"]
                    @test record["cleanup"]["post_kill_wait"]["attempted"]
                    @test record["cleanup"]["status"] == "unresolved"
                    group = record["cleanup"]["groups"]["owner"]
                    @test group["status"] == "unresolved"
                    @test length(group["observed_members"]) == 2
                    @test all(p -> SQ.process_identity(p.pid) !== nothing,observed)
                    # A changed leader identity is observed, never signalled.
                    changed = deepcopy(identities)
                    changed["owner"]["identity"]["start_ticks"] += 1
                    @test SQ.observed_cleanup(process,changed)["groups"]["owner"]["status"] == "identity_changed"
                    unknown = SQ.owned_process_identities(Dict("user"=>Dict("pid"=>getpid())),
                        identities["owner"]["identity"]["parent_pid"])
                    @test !unknown["user"]["ownership_confirmed"]
                    @test SQ.observed_cleanup(process,unknown)["groups"]["user"]["status"] == "unknown"
                    @test SQ.observed_cleanup(process,Dict())["status"] == "unknown"
                end
                @test_throws ArgumentError SQ.fallback_cleanup(process,identities;initial_wait=0)
                @test_throws ArgumentError SQ.fallback_cleanup(process,identities;post_interrupt_grace=0)
            finally
                cleanup_fake(process,identities,observed)
                close(log)
            end
        end
    end
end
