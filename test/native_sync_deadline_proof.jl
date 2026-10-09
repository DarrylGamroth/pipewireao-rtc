using Test
using PipeWireAO

include(joinpath(@__DIR__, "native_control_private_core.jl"))

function run_sync_proof(socket::String, directory::String, mode::String; label=mode)
    binary = get(ENV, "NATIVE_SYNC_DEADLINE_PROOF", "")
    isempty(binary) && error("set NATIVE_SYNC_DEADLINE_PROOF to the built native_sync_deadline_proof binary")
    isfile(binary) && isexecutable(binary) || error("NATIVE_SYNC_DEADLINE_PROOF is not executable: $binary")
    log = open(joinpath(directory, "sync-$label.log"), "w+")
    child = nothing
    try
        child = run(pipeline(Cmd([binary, socket, directory, mode]); stdout=log, stderr=log); wait=false)
        wait_proof(() -> isfile(joinpath(directory, "ready")), 10, "$label adapter ready";
            check=()->(Base.process_exited(child) && error("$label proof child exited before ready")))
        return child
    catch
        child === nothing || stop_proof_child!(child, "$label proof startup")
        flush(log)
        seekstart(log)
        print(stderr, read(log, String))
        rethrow()
    finally
        close(log)
    end
end

function read_sync_result(directory, stage)
    path = joinpath(directory, "result-$stage")
    wait_proof(() -> isfile(path), 8, "synchronization $stage result")
    return read(path, String)
end

println("PipeWireAO_VERSION=$(Base.pkgversion(PipeWireAO)) private_core=true ports=0")
@testset "native callback synchronization deadlines" begin
    @test Base.pkgversion(PipeWireAO) == v"0.6.16"

    @testset "stopped core deadlines and fresh synchronization" begin
        with_control_private_core() do socket, directory, daemon
            child = run_sync_proof(socket, directory, "stopped"; label="stopped")
            try
                expired = read_sync_result(directory, "expired")
                @test occursin("before submission", expired)
                @test occursin("Err(", expired)
                @test occursin("elapsed_ns=", expired)
                println("SYNC_EXPIRED $expired")
                write(joinpath(directory, "release-expired"), "")

                run(`kill -STOP $(getpid(daemon))`)
                write(joinpath(directory, "go-budget"), "")
                bounded = read_sync_result(directory, "budget")
                @test occursin("completion is unknown", bounded)
                @test occursin("Err(", bounded)
                @test 200_000_000 <= parse(Int, match(r"elapsed_ns=(\d+)", bounded)[1]) <= 2_000_000_000
                println("SYNC_BOUNDED $bounded")
                write(joinpath(directory, "release-budget"), "")

                default = read_sync_result(directory, "default")
                @test occursin("Err(", default)
                @test occursin("expired", lowercase(default))
                @test 4_900_000_000 <= parse(Int, match(r"elapsed_ns=(\d+)", default)[1]) <= 5_500_000_000
                println("SYNC_DEFAULT $default")
                run(`kill -CONT $(getpid(daemon))`)
                sleep(0.25)
                run(`kill -STOP $(getpid(daemon))`)
                write(joinpath(directory, "release-default"), "")
                write(joinpath(directory, "go-stale"), "")
                stale = read_sync_result(directory, "stale")
                @test occursin("completion is unknown", stale)
                @test occursin("Err(", stale)
                @test 200_000_000 <= parse(Int, match(r"elapsed_ns=(\d+)", stale)[1]) <= 2_000_000_000
                println("SYNC_OLD_ACKS_DID_NOT_COMPLETE_FRESH_SYNC $stale")
                write(joinpath(directory, "release-stale"), "")

                run(`kill -CONT $(getpid(daemon))`)
                write(joinpath(directory, "go-fresh"), "")
                fresh = read_sync_result(directory, "fresh")
                @test occursin("result=Ok(())", fresh)
                @test parse(Int, match(r"elapsed_ns=(\d+)", fresh)[1]) < 5_000_000_000
                println("SYNC_FRESH_AFTER_TWO_TIMED_OUT_SYNCS $fresh")
                write(joinpath(directory, "release-fresh"), "")
                wait_proof(() -> Base.process_exited(child), 5, "stopped proof exit")
                wait(child)
                @test child.exitcode == 0
            finally
                Base.process_exited(daemon) || run(`kill -CONT $(getpid(daemon))`)
                child === nothing || stop_proof_child!(child, "stopped synchronization proof")
            end
        end
    end

    @testset "core termination interrupts synchronization" begin
        with_control_private_core(; check_running=false) do socket, directory, daemon
            child = run_sync_proof(socket, directory, "termination"; label="termination")
            try
                run(`kill -STOP $(getpid(daemon))`)
                write(joinpath(directory, "go-termination"), "")
                wait_proof(() -> isfile(joinpath(directory, "sync-entered")), 5, "termination sync entered")
                run(`kill -KILL $(getpid(daemon))`)
                wait_proof(() -> Base.process_exited(daemon), 5, "private daemon termination")
                wait(daemon)
                terminated = read_sync_result(directory, "termination")
                @test occursin("Err(", terminated)
                @test occursin("PipeWire operation failed:", terminated) || occursin("PipeWire sync failed:", terminated)
                @test !occursin("deadline expired", lowercase(terminated))
                @test parse(Int, match(r"elapsed_ns=(\d+)", terminated)[1]) < 5_000_000_000
                println("SYNC_TERMINATED $terminated")
                write(joinpath(directory, "release-termination"), "")
                wait_proof(() -> Base.process_exited(child), 6, "termination proof process exit after adapter cleanup")
                wait(child)
                @test child.exitcode == 0
            finally
                child === nothing || stop_proof_child!(child, "termination synchronization proof")
            end
        end
    end

    @testset "stopped core bounds discovery and cleanup" begin
        test_binary = get(ENV, "NATIVE_SYNC_DEADLINE_TEST_BINARY", "")
        isempty(test_binary) && error("set NATIVE_SYNC_DEADLINE_TEST_BINARY to the built ignored Rust test binary")
        isfile(test_binary) && isexecutable(test_binary) || error("NATIVE_SYNC_DEADLINE_TEST_BINARY is not executable: $test_binary")
        with_control_private_core() do socket, directory, daemon
            log = open(joinpath(directory, "sync-cleanup-test.log"), "w+")
            child = nothing
            try
                env = Dict(
                    "PIPEWIREAO_SYNC_PROOF_REMOTE" => socket,
                    "PIPEWIREAO_SYNC_PROOF_DIRECTORY" => directory,
                )
                command = Cmd([test_binary, "--exact", "--ignored",
                    "live::deadline_tests::stopped_core_bounds_discovery_and_cleanup"])
                child = run(pipeline(addenv(command, env); stdout=log, stderr=log); wait=false)
                wait_proof(() -> isfile(joinpath(directory, "ready")), 10, "cleanup test ready";
                    check=()->(Base.process_exited(child) && error("cleanup test child exited before ready")))

                run(`kill -STOP $(getpid(daemon))`)
                write(joinpath(directory, "go-discovery"), "")
                discovery = read_sync_result(directory, "discovery")
                @test occursin("Err(", discovery)
                @test occursin("expired", lowercase(discovery))
                discovery_ns = parse(Int, match(r"elapsed_ns=(\d+)", discovery)[1])
                @test 450_000_000 <= discovery_ns <= 2_000_000_000
                println("SYNC_DISCOVERY $discovery")
                write(joinpath(directory, "release-discovery"), "")

                cleanup = read_sync_result(directory, "cleanup")
                @test occursin("Err(", cleanup)
                @test occursin("expired", lowercase(cleanup))
                cleanup_ns = parse(Int, match(r"elapsed_ns=(\d+)", cleanup)[1])
                @test 4_800_000_000 <= cleanup_ns <= 7_000_000_000
                println("SYNC_CLEANUP $cleanup")
                run(`kill -CONT $(getpid(daemon))`)
                sleep(0.05)
                run(`kill -STOP $(getpid(daemon))`)
                write(joinpath(directory, "release-cleanup"), "")
                write(joinpath(directory, "go-stale"), "")
                stale = read_sync_result(directory, "stale")
                @test occursin("completion is unknown", stale)
                @test occursin("Err(", stale)
                stale_ns = parse(Int, match(r"elapsed_ns=(\d+)", stale)[1])
                @test 200_000_000 <= stale_ns <= 2_000_000_000
                late_count = read(joinpath(directory, "late-done-count"), String)
                @test late_count == "2"
                println("SYNC_LATE_DONE_COUNT=$late_count OLD_ACKS_NOT_COMPLETE $stale")
                write(joinpath(directory, "release-stale"), "")
                run(`kill -CONT $(getpid(daemon))`)
                write(joinpath(directory, "go-fresh"), "")
                wait_proof(() -> Base.process_exited(child), 5, "bounded cleanup test exit")
                wait(child)
                flush(log)
                seekstart(log)
                println(read(log, String))
                @test child.exitcode == 0
            finally
                Base.process_exited(daemon) || run(`kill -CONT $(getpid(daemon))`)
                child === nothing || stop_proof_child!(child, "bounded cleanup test")
                close(log)
            end
        end
    end

end
