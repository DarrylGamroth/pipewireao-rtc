#!/usr/bin/env julia
using Test, PipeWireAO, PipeWireAORTC

include("/home/dgamroth/workspaces/codex/worktrees/rtc-wireplumber-reuse-20261021/test/integration/session_faults.jl")

const PACKAGE = "/home/dgamroth/workspaces/codex/worktrees/wavelength-nm-validation-20261021/managed/installed"
const PREFIX = "/home/dgamroth/.local/opt/pipewireao-wp-reuse-20261021"

function main()
    root = abspath(joinpath(@__DIR__, "normal-lifecycle"))
    stage = joinpath(root, "session")
    !ispath(stage) && !islink(stage) || error("normal-lifecycle stage must be fresh: $stage")
    spec = D.profile(joinpath(PACKAGE, "deployment.conf"), PREFIX)
    handle = nothing
    result = Dict{String,Any}("package" => realpath(PACKAGE), "prefix" => PREFIX,
        "stage" => stage, "completed" => false)
    !ispath(root) || error("evidence root must be fresh")
    mkpath(root; mode=0o700)
    save() = C.write_json(joinpath(root, "normal-lifecycle.json"), result; atomic=true)
    save()
    try
        handle = W.start!(PACKAGE, stage; prefix=PREFIX,
            deadline=clock()+startup_budget(spec))
        result["unit"] = handle.unit
        result["ready"] = session_phase(handle, "Ready")
        result["initial_running"] = session_phase(handle, "Running"; start=true)

        stopped = W.control!(handle, Command(:session_stop); deadline=clock()+30)
        checked(stopped["ok"] === true && stopped["state"] == "Ready",
            "session Stop did not complete in Ready")
        result["stopped"] = stopped
        result["stop_status"] = session_phase(handle, "Ready")

        reset = W.control!(handle, Command(:reset); deadline=clock()+30)
        checked(reset["ok"] === true && reset["state"] == "Ready",
            "Reset did not complete in Ready")
        result["reset"] = reset
        result["reset_status"] = session_phase(handle, "Ready")
        result["running"] = session_phase(handle, "Running"; start=true)

        # shutdown! sends one native Quit and validates the matching Offline
        # completion plus the exact manager cleanup receipt.
        result["shutdown"] = W.shutdown!(handle; deadline=clock()+320)
        result["final_record"] = W.final_record(stage)
        result["cleanup"] = observe_cleanup!(handle, stage; failed=false)
        result["completed"] = true
        save()
    finally
        if handle !== nothing
            # Never repeat a submitted Quit or Stop. An unknown completion is
            # reconciled read-only by the same session-fault helpers.
            cleanup_error = try
                if handle.shutdown_attempted || handle.stop_attempted
                    reconcile_cleanup!(handle, stage)
                else
                    cleanup!(handle, stage; failed=true)
                end
                nothing
            catch error
                sprint(showerror, error)
            end
            result["final_cleanup_error"] = cleanup_error
            save()
        end
    end
end

abspath(PROGRAM_FILE) == (@__FILE__) && main()
