# Exercise the public controls of the named installed private session.
using PipeWireAORTC
const R = PipeWireAORTC.SessionRuntime
const C = PipeWireAORTC.Common

function wait_marker(dir, name, seconds)
    limit = time_ns() + UInt64(seconds * 1_000_000_000)
    while !isfile(joinpath(dir, name))
        isfile(joinpath(dir, "probe_failed")) && error("flow probe failed before $name")
        time_ns() < limit || error("timed out waiting for probe marker $name")
        sleep(0.1)
    end
end

function main(unit, root, handshake, evidence)
    handle = R.attach(root)
    @assert handle.unit == unit
    save(name, value) = C.write_json(joinpath(evidence, name * ".json"), value; atomic=true)
    state = R.ready(handle)
    save("ready", state)
    @assert state["phase"] == "ready" && state["admitted"]
    armed = try
        wait_marker(handshake, "ready", 240)
        true
    catch err
        save("probe_arm_error", sprint(showerror, err))
        false
    end
    try
        start = R.control!(handle, PipeWireAORTC.SessionCodec.RunnerCommand(:session_start);
            deadline=Int64(time_ns()) + 60_000_000_000)
        save("start", start)
        @assert start["ok"] && start["state"] == "Running"
        running = R.ready(handle)
        save("running", running)
        @assert running["phase"] == "running" && running["processes"] == state["processes"]
        touch(joinpath(handshake, "running"))
        armed || error("Probe did not arm; native lifecycle exercised separately")
        wait_marker(handshake, "observed", parse(Int, get(ENV, "RTC_FLOW_RUNNING_TIMEOUT", "180")))
    finally
        phase = R.ready(handle)["phase"]
        if phase == "running"
            stop = R.control!(handle, PipeWireAORTC.SessionCodec.RunnerCommand(:session_stop);
                deadline=Int64(time_ns()) + 60_000_000_000)
            save("stop", stop)
            @assert stop["ok"] && stop["state"] == "Ready"
            held = R.ready(handle)
            save("held", held)
            @assert held["phase"] == "ready" && held["processes"] == state["processes"]
            touch(joinpath(handshake, "stopped"))
        end
    end
end

main(ARGS...)
