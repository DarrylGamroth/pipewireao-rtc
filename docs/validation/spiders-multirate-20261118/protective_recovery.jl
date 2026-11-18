const RECOVERY_PREFIX = "pipewireao-recovery:"
const RESET_TICK = 1801
const SCC_PRIME_TICK = 1804
const RELEASE_TICK = 1805
const LLOWFS_RECLOSE_TICK = 1806
const SCC_RECLOSE_TICK = 1807

function recovery_property(properties, name)
    return properties[RECOVERY_PREFIX*name]
end

function write_native_property!(state, remote, name, value)
    HIL.with_array_stream(state.wire,1) do _
        set_param!(remote,SPA.PARAM_PROPS,Pod(props_param(SPA.Props(name=>value))))
    end
    roundtrip(state.wire.core)
    return nothing
end

function await_recovery(predicate, state, remote, observed, gate)
    values = Ref{Any}(nothing)
    try
        TRANSPORT.wait_until(; timeout=5, description=gate) do
            values[] = property_values(state,remote,observed)
            predicate(values[])
        end
    catch err
        fields = values[] === nothing ? nothing : Dict(key=>value for (key,value) in values[] if
            startswith(key,RECOVERY_PREFIX) || key in ("correction:closed","llowfs-correction:closed"))
        println(stderr,"Protective recovery gate failed ($gate): ", fields)
        flush(stderr)
        rethrow(err)
    end
    return values[]
end

function record_gate!(trace, name, tick, properties; camera=nothing, demand=nothing)
    snapshot = Dict(key=>value for (key,value) in properties if startswith(key,RECOVERY_PREFIX) ||
        key in ("correction:closed","llowfs-correction:closed"))
    push!(trace["gates"],(; name, tick, properties=snapshot, camera=identity_record(camera),
        demand=identity_record(demand), host_ns=time_ns()))
    println("Protective recovery gate: $name at tick $tick"); flush(stdout)
    return nothing
end

function demand_quiet(state)
    drain = HIL.array_stream_status(state.wire,state.command_index)
    drain.failed && error("HIL command input failed during camera-silent control")
    return !drain.pending
end

function reset_protection!(trace,state,remote,observed,tick,preceding)
    before = property_values(state,remote,observed)
    recovery_property(before,"version")==2 && recovery_property(before,"controller-count")==2 &&
        recovery_property(before,"controller-1")=="correction" &&
        recovery_property(before,"controller-2")=="llowfs-correction" &&
        before["correction:closed"] && before["llowfs-correction:closed"] ||
        error("unexpected pre-reset native recovery descriptor")
    trace["last_clipped_demand_before_reset"] = identity_record(preceding)
    record_gate!(trace,"before_reset",tick,before; demand=preceding)
    demand_quiet(state) || error("unconsumed physical demand before protective reset")
    write_native_property!(state,remote,RECOVERY_PREFIX*"request-token",Int64(1))
    applied = await_recovery(state,remote,observed,"reset while cameras are silent") do props
        recovery_property(props,"state")=="applied"
    end
    record_gate!(trace,"reset_applied_cameras_silent",tick,applied)
    recovery_property(applied,"closure-inhibited") && !applied["correction:closed"] &&
        !applied["llowfs-correction:closed"] && !recovery_property(applied,"reference-reached") &&
        !recovery_property(applied,"controller-1-ready") && !recovery_property(applied,"controller-2-ready") &&
        demand_quiet(state) ||
        error("reset failed to inhibit closure or claimed camera-silent reference evidence")
    return nothing
end

function capture_reset_reference!(trace,state,remote,observed,tick,camera,demand,old_command,new_command,limiter)
    all(iszero,new_command) && all(iszero,limiter) ||
        error("fresh LLOWFS proof did not result in an actual flat native demand")
    held = await_recovery(state,remote,observed,"fresh LLOWFS shared flat reference") do props
        recovery_property(props,"reference-reached") && recovery_property(props,"controller-2-ready")
    end
    !recovery_property(held,"controller-1-ready") || error("SCC reported readiness before a fresh pair")
    record_gate!(trace,"fresh_llowfs_flat_reference",tick,held; camera,demand)
    if tick==RESET_TICK
        step = Float64.(new_command).-old_command
        trace["flat_transition"] = (; tick, demand=identity_record(demand), amplitude_native=maximum(abs,new_command),
            step_inf_native=maximum(abs,step), step_rms_native=sqrt(sum(abs2,step)/length(step)))
    end
    return held
end

function confirm_scc_priming!(trace,state,remote,observed,tick,camera)
    primed = await_recovery(state,remote,observed,"SCC prime invalidates shared proof") do props
        !recovery_property(props,"reference-reached") && !recovery_property(props,"controller-1-ready")
    end
    demand_quiet(state) || error("SCC priming fabricated a demand")
    record_gate!(trace,"scc_primed_without_demand",tick,primed; camera)
    return nothing
end

function release_protection!(trace,state,remote,observed,tick,held,camera,demand)
    generation = recovery_property(held,"recovery-generation")
    observation = recovery_property(held,"observation-sequence")
    observation > 0 && observation==recovery_property(held,"controller-2-observation-sequence") ||
        error("released reference is not the fresh LLOWFS callback witness")
    demand_quiet(state) || error("unconsumed physical demand before release")
    write_native_property!(state,remote,RECOVERY_PREFIX*"release-token",Int64(generation))
    released = await_recovery(state,remote,observed,"generation-correlated release") do props
        recovery_property(props,"state")=="released"
    end
    record_gate!(trace,"release_leaves_both_open",tick,released; camera,demand)
    !recovery_property(released,"closure-inhibited") &&
        !released["correction:closed"] && !released["llowfs-correction:closed"] &&
        recovery_property(released,"controller-1-close-guarded") &&
        recovery_property(released,"controller-2-close-guarded") && demand_quiet(state) ||
        error("release must leave independent guarded closes and no fabricated demand")
    return nothing
end

function reclose_protection!(trace,state,remote,observed,tick,camera,demand,slot)
    name = slot==1 ? "correction:closed" : "llowfs-correction:closed"
    ready = await_recovery(state,remote,observed,"fresh branch proof before $name") do props
        recovery_property(props,"controller-$slot-ready")
    end
    record_gate!(trace,"fresh_branch_$slot",tick,ready; camera,demand)
    closed = close_branch!(state,remote,observed,name)
    record_gate!(trace,"closed_branch_$slot",tick,closed; camera,demand)
    !recovery_property(closed,"controller-$slot-close-guarded") &&
        closed["llowfs-correction:closed"] &&
        closed["correction:closed"]==(slot==1) &&
        recovery_property(closed,"controller-1-close-guarded")==(slot==2) ||
        error("native branch reclose did not adopt independently")
    return nothing
end
