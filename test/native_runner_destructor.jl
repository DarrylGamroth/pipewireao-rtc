using Test
include(joinpath(@__DIR__, "native_control_private_core.jl"))

# Markers synchronize this diagnostic test only. They are not live deployment
# control messages. Stop only this fixture's private daemon after clean unload.
with_control_private_core() do socket, directory, daemon
    binary = ENV["NATIVE_RUNNER_LIB_TEST_BINARY"]
    evidence = mkpath(ENV["NATIVE_RUNNER_DROP_EVIDENCE"])
    log = open(joinpath(evidence, "rust.log"), "w")
    child = nothing
    try
        child = run(pipeline(addenv(Cmd([binary,
            "live::deadline_tests::dropped_clean_adapter_does_not_start_new_sync",
            "--exact", "--ignored", "--nocapture"]),
            "PIPEWIREAO_DROP_PROOF_REMOTE" => socket,
            "PIPEWIREAO_DROP_PROOF_DIRECTORY" => directory);
            stdout=log, stderr=log); wait=false)
        wait_proof(() -> isfile(joinpath(directory, "ready")), 15, "clean adapter";
            check=() -> Base.process_exited(child) && error("Rust test exited before readiness"))
        kill(daemon, 19)
        try
            write(joinpath(directory, "drop"), "")
            wait_proof(() -> Base.process_exited(child), 8, "adapter destructor")
        finally
            kill(daemon, 18)
        end
        cp(joinpath(directory, "elapsed-ns"), joinpath(evidence, "elapsed-ns"); force=true)
        wait(child)
        @test success(child)
    finally
        child === nothing || stop_proof_child!(child, "Rust destructor test")
        close(log)
    end
end
