include("observe.jl")

function set_closed(control, scc, llowfs)
    fields = String["properties-set", GRAPH]
    for (property, closed) in (("correction:closed", scc), ("llowfs-correction:closed", llowfs))
        current = graph_properties(control)[property]["value"]
        current == closed && continue
        append!(fields, (property, "bool", string(closed)))
    end
    length(fields) > 2 || return nothing
    result = control(fields...)
    result["ok"] || error("Closure transaction failed: $(result["error"])")
    @assert result["result"]["active_adoption_observed"]
    @assert all(row -> row["active"] == row["requested"],
        result["result"]["property_generations"])
    props = graph_properties(control)
    @assert props["correction:closed"]["value"] === scc
    @assert props["llowfs-correction:closed"]["value"] === llowfs
    return result
end

function observe_flat(wire, demand, control, generation)
    props = graph_properties(control)
    @assert props["correction:closed"]["value"] === false
    @assert props["llowfs-correction:closed"]["value"] === false
    actual = zeros(Float32, demand.option.format.shape)
    receipt = HIL.drain_pipewire_array!(actual, wire, DEMAND_INDEX)
    # A single pending demand packet does not establish freshness after Restart.
    return (; generation, demand_observed=receipt !== nothing,
        candidate_peak=receipt === nothing ? nothing : maximum(abs, actual),
        candidate_identity=receipt === nothing ? nothing : command_identity(receipt.identity),
        transport=demand_snapshot(wire, demand))
end

function qualify(root, runtime, out, zero_path)
    with_observer(root, runtime, out, zero_path) do wire, demand, control, mask, basis, ready
        write_record(name, value) = RTC.Common.write_json(joinpath(out, name), value; atomic=true)
        write_record("initial-flat.json", observe_flat(wire, demand, control, 1))
        write_record("baseline-close.json", set_closed(control, false, true))
        images = Images(size(mask))
        biased = collect_epoch!(
            wire, demand, "open", 1, mask, basis, images, Dict{Int,CameraSample}())
        write_record("baseline-demand-status.json", biased.demand)
        write(joinpath(out, "baseline-complete"), string(length(biased.camera)))
        write_record("baseline-open.json", set_closed(control, false, false))
        launcher = joinpath(root, "bin", "pipewireao-rtc-session")
        session = ready["ready"]["session_id"]
        write(joinpath(out, "restart.json"), read(`$launcher restart --session $session`, String))
        write_record("reset-flat.json", observe_flat(wire, demand, control, 2))
        write_record("close.json", set_closed(control, true, true))
        closed = collect_epoch!(wire, demand, "closed", 2, mask, basis, images, biased.camera)
        write_record("demand-status.json", closed.demand)
        props = graph_properties(control)
        @assert props["correction:closed"]["value"] && props["llowfs-correction:closed"]["value"]
        write_evidence(out, biased, closed, images, mask, basis)
        for (label, status) in (("LLOWFS-only", biased.demand), ("SCC and LLOWFS", closed.demand))
            status.transport.counters.failed && error("$label DM readback failed")
            status.count >= 2 && status.peak > 0f0 ||
                error("$label did not produce repeated nonzero DM demand readback")
        end
    end
end

if abspath(PROGRAM_FILE) == @__FILE__
    qualify(ARGS...)
end
