# Opt-in CPU Ready-to-Quit regression; operates only on a newly created session.
module ClassicShutdown
using Test, PipeWireAORTC
module Cleanup
include("session_faults.jl")
end
const R=PipeWireAORTC
const W=R.SessionRuntime
const C=R.Common
const SOURCE_SHA256=C.sha256_file(@__FILE__)

function audit(handle,stage)
    ledger=W._ledger(handle)
    processes=Dict(role=>record["pid"] for (role,record) in ledger["owners"])
    processes["rtc"]=handle.main_pid
    result=Dict{String,Any}()
    for (role,pid) in processes
        gpu=filter(line -> occursin(r"(?i)(libcuda|libcudart|libcublas|libcufft|libamdhip|libhsa-runtime)",line),
            readlines("/proc/$pid/maps"))
        @test isempty(gpu)
        result[role]=Dict("pid"=>pid,"gpu_mappings"=>gpu)
    end
    C.write_json(joinpath(stage,"gpu-audit.json"),result)
end

function main(application,stage,prefix)
    config=C.read_json(joinpath(application,"simulation.conf"))
    config["backend"]=="cpu" || error("this validation requires the CPU backend")
    spec=C.read_json(joinpath(application,"deployment.conf"))
    for environment in (spec["environment"],(owner["environment"] for owner in spec["owners"])...)
        environment["CUDA_VISIBLE_DEVICES"]==environment["ROCR_VISIBLE_DEVICES"]=="" ||
            error("GPU visibility must be cleared for each process")
    end
    report=nothing
    @testset "Classic CPU Ready to Quit" begin
        handle=W.start!(application,stage;prefix,deadline=W.monotonic()+600)
        ledger=W._ledger(handle)
        failures=Exception[]
        try
            reply=W.control!(handle,R.RunnerCommands.parse(["status"]);deadline=W.monotonic()+20)
            C.write_json(joinpath(stage,"ready.json"),reply)
            @test reply["ok"]===true && reply["state"]=="Ready"
            audit(handle,stage)
            started=time_ns()
            println("Ready; requesting one native Quit");flush(stdout)
            final=W.shutdown!(handle;deadline=W.monotonic()+320)
            elapsed=(time_ns()-started)/1e9
            @test handle.shutdown_accepted
            @test final["phase"]=="stopped" && final["cleanup_complete"]===true
            @test get(final,"error",nothing)===nothing
            Cleanup.observe_cleanup!(handle,stage;failed=false)
            report=Dict("complete"=>true,"backend"=>"cpu","started"=>false,
                "native_quit_accepted"=>handle.shutdown_accepted,"shutdown_and_cleanup_seconds"=>elapsed,
                "session_uuid"=>ledger["session_uuid"],"unit"=>handle.unit,"invocation"=>handle.invocation,
                "deployment_sha256"=>C.sha256_file(joinpath(application,"deployment.conf")),
                "manifest_sha256"=>C.sha256_file(joinpath(application,"Manifest.toml")),
                "test_sha256"=>SOURCE_SHA256,
                "native_sha256"=>Dict(relative=>C.sha256_file(joinpath(prefix,relative)) for relative in
                    ("bin/pipewireao-rtc","lib/pipewireao-rtc/modules/libwireplumber-module-ao-control-endpoint.so",
                        "lib/libwireplumber-0.5.so.0")),
                "prefix"=>abspath(prefix),"policy_sha256"=>Dict(relative=>C.sha256_file(joinpath(prefix,
                    "share/pipewireao-rtc/scripts",relative)) for relative in ("ao/session.lua","lib/ao-owner.lua")))
        catch error
            push!(failures,error)
            C.write_json(joinpath(stage,"failure.json"),Dict("error"=>sprint(showerror,error)))
            try Cleanup.cleanup!(handle,stage;failed=true)
            catch cleanup_error; push!(failures,cleanup_error) end
        finally
            try
                Cleanup.journal_records(handle.unit,handle.invocation,handle.main_pid,stage,"rtc")
                for (role,owner) in ledger["owners"]
                    Cleanup.journal_records(owner["unit"],owner["invocation"],owner["pid"],stage,role)
                end
            catch error
                push!(failures,error)
            end
        end
        isempty(failures) || throw(CompositeException(failures))
        @test C.sha256_file(@__FILE__)==SOURCE_SHA256
    end
    C.write_json(joinpath(stage,"qualification.json"),report)
end
abspath(PROGRAM_FILE)==(@__FILE__) && main(ARGS...)
end
