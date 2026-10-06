using Test
using PipeWireAO
include(joinpath(@__DIR__, "native_control_private_core.jl"))

# This /proc-based fixture runs on Linux. Julia 1.12 does not expose these two
# signals as Base constants.
const MONITOR_SIGSTOP = 19
const MONITOR_SIGCONT = 18

# Held, two-element diagnostic arrays. No science graph, source submission or
# sink acquisition is part of this required-object ordering test.
const MONITOR_FIXTURE_CONFIG = raw"""
profile = development
execution = external-rtc
authority = none
claim = development-characterization
rate = 100/1
sources = [
  { ownership = external run-control = application node.name = fixture.monitor-frame-source
    ports = [ { name = output_1 direction = output element-type = U16_LE shape = [ 2 ] schema = org.test.frame/1 } ] }
  { ownership = external run-control = application node.name = fixture.monitor-command-source
    ports = [ { name = output_1 direction = output element-type = F32_LE shape = [ 2 ] schema = org.test.command/1 } ] }
]
graphs = []
sinks = [
  { ownership = external node.name = fixture.monitor-frame-sink
    ports = [ { name = input_1 direction = input element-type = U16_LE shape = [ 2 ] schema = org.test.frame/1 } ] }
  { ownership = external node.name = fixture.monitor-command-sink
    ports = [ { name = input_1 direction = input element-type = F32_LE shape = [ 2 ] schema = org.test.command/1 } ] }
]
execution-groups = []
properties = {}
parameters = {}
observations = []
links = [
  { output = "fixture.monitor-frame-source:output_1" input = "fixture.monitor-frame-sink:input_1" passive = false }
  { output = "fixture.monitor-command-source:output_1" input = "fixture.monitor-command-sink:input_1" passive = false }
]
"""

function run_native_monitor_fixture(mode::Symbol)
    loss = mode in (:loss, :queued_loss)
    test_names = (
        loss="pending_preparation_is_fenced_by_required_object_loss",
        queued_loss="queued_request_is_fenced_by_required_object_loss",
        budget="accepted_runner_request_inherits_stalled_core_budget",
        queued_budget="queued_request_bounds_due_monitor",
        arriving_budget="arriving_request_bounds_already_running_monitor",
    )
    with_control_private_core() do socket, directory, daemon
        binary = ENV["NATIVE_RUNNER_BIN_TEST_BINARY"]
        evidence = mkpath(mode == :loss ? ENV["NATIVE_RUNNER_MONITOR_EVIDENCE"] :
            joinpath(ENV["NATIVE_RUNNER_MONITOR_EVIDENCE"], String(mode)))
        config = joinpath(directory, "monitor.conf")
        write(config, MONITOR_FIXTURE_CONFIG)
        thread_loop = ThreadLoop("fixture.runner-monitor")
        context = nothing
        core = nothing
        endpoints = Any[]
        child = nothing
        daemon_paused = false
        log = open(joinpath(evidence, "rust.log"), "w")
        try
            with_thread_loop_lock(thread_loop) do _
                context = Context(thread_loop)
                core = CoreConnection(context; properties=Dict("remote.name" => socket))
            end
            start!(thread_loop)
            frame = NdArrayFormat(NdArray.U16_LE, (2,); layout=NdArray.ROW_MAJOR,
                rate=PipeWireAO.SPA.Fraction(100, 1))
            command = NdArrayFormat(NdArray.F32_LE, (2,); layout=NdArray.ROW_MAJOR,
                rate=PipeWireAO.SPA.Fraction(100, 1))
            push!(endpoints, NdArraySource(core, "fixture.monitor-frame-source",
                zeros(UInt16, 2), frame; schema="org.test.frame/1"))
            push!(endpoints, NdArraySink(core, "fixture.monitor-frame-sink",
                zeros(UInt16, 2), frame; schema="org.test.frame/1"))
            push!(endpoints, NdArraySource(core, "fixture.monitor-command-source",
                zeros(Float32, 2), command; schema="org.test.command/1"))
            push!(endpoints, NdArraySink(core, "fixture.monitor-command-sink",
                zeros(Float32, 2), command; schema="org.test.command/1"))
            wait_proof(() -> all(endpoint -> node_id(endpoint) != typemax(UInt32), endpoints),
                10, "four held diagnostic nodes")
            @test all(endpoint -> !isrunning(endpoint), endpoints)
            test_name = test_names[mode]
            child = run(pipeline(addenv(Cmd([binary,
                "native_runner_endpoint::tests::$test_name",
                "--exact", "--ignored", "--nocapture"]),
                "PIPEWIREAO_MONITOR_PROOF_REMOTE" => socket,
                "PIPEWIREAO_MONITOR_PROOF_CONFIG" => config,
                "PIPEWIREAO_MONITOR_PROOF_DIRECTORY" => directory);
                stdout=log, stderr=log); wait=false)
            ready = loss ? "monitor-ready" : "budget-ready"
            wait_proof(() -> isfile(joinpath(directory, ready)),
                15, "pending preparation";
                check=() -> Base.process_exited(child) && error("Rust monitor test exited before readiness"))
            # These files synchronize this private diagnostic only. They are
            # not deployment request, reply or status files.
            if loss
                close(endpoints[2])
                endpoints[2] = nothing
                write(joinpath(directory, "required-removed"), "")
            else
                kill(daemon, MONITOR_SIGSTOP)
                daemon_paused = true
                wait_proof(() -> occursin(r"(?m)^State:\s+T",
                        read("/proc/$(getpid(daemon))/status", String)),
                    2, "private daemon stopped")
                write(joinpath(directory, "go-budget"), "")
                wait_proof(() -> isfile(joinpath(directory, "budget-observed")),
                    3, "250 ms owner budget";
                    check=() -> Base.process_exited(child) && error("Rust budget test exited before observation"))
                kill(daemon, MONITOR_SIGCONT)
                daemon_paused = false
                write(joinpath(directory, "budget-release"), "")
                cp(joinpath(directory, "budget-elapsed-ns"), joinpath(evidence, "elapsed-ns"); force=true)
            end
            wait_proof(() -> Base.process_exited(child), 15, "monitor fault and late result fence")
            wait(child)
            @test success(child)
        finally
            failures = String[]
            if daemon_paused
                try
                    kill(daemon, MONITOR_SIGCONT)
                catch error
                    push!(failures, sprint(showerror, error))
                end
            end
            try
                child === nothing || stop_proof_child!(child, "Rust monitor test")
            catch error
                push!(failures, sprint(showerror, error))
            end
            try
                close(log)
            catch error
                push!(failures, sprint(showerror, error))
            end
            for endpoint in reverse(endpoints)
                endpoint === nothing && continue
                try
                    close(endpoint)
                catch error
                    push!(failures, sprint(showerror, error))
                end
            end
            with_thread_loop_lock(thread_loop) do _
                for resource in (core, context)
                    resource === nothing && continue
                    try
                        close(resource)
                    catch error
                        push!(failures, sprint(showerror, error))
                    end
                end
            end
            try
                close(thread_loop)
            catch error
                push!(failures, sprint(showerror, error))
            end
            cp(config, joinpath(evidence, "monitor.conf"); force=true)
            cp(joinpath(directory, "private-core.log"), joinpath(evidence, "private-core.log"); force=true)
            isempty(failures) || error("monitor fixture cleanup failed: $(join(failures, "; "))")
        end
    end
end

@testset "native runner monitor and owner budget" begin
    cases = (:loss, :queued_loss, :budget, :queued_budget, :arriving_budget)
    selected = get(ENV, "NATIVE_RUNNER_MONITOR_CASE", "all")
    if selected != "all"
        Symbol(selected) in cases || error("unknown monitor fixture case $selected")
        cases = (Symbol(selected),)
    end
    for case in cases
        run_native_monitor_fixture(case)
    end
end
