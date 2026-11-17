include(joinpath(@__DIR__, "..", "spiders-scc-error-20261117", "observe.jl"))

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

function observe_flat(wire, control, command)
    @assert iszero(command)
    props = graph_properties(control)
    @assert props["correction:closed"]["value"] === false
    @assert props["llowfs-correction:closed"]["value"] === false
    actual = similar(command)
    seen = HIL.drain_pipewire_array!(actual, wire, 2) !== nothing
    peak = seen ? maximum(abs, actual) : nothing
    if seen
        @assert peak <= 1f-6
    end
    return (; demand_observed=seen, peak)
end

function qualify(root, runtime, out, zero_path)
    with_observer(root, runtime, out, zero_path) do wire, control, mask, command, basis, ready
        write_record(name, value) = RTC.Common.write_json(joinpath(out, name), value; atomic=true)
        write_record("initial-flat.json", observe_flat(wire, control, command))
        write_record("baseline-close.json", set_closed(control, false, true))
        images = Images(size(mask))
        biased = collect_epoch!(wire, "open", 1, mask, command, basis,
            images, Dict{Int,CameraSample}())
        write(joinpath(out, "baseline-complete"), string(length(biased.camera)))
        write_record("baseline-open.json", set_closed(control, false, false))
        launcher = joinpath(root, "bin", "pipewireao-rtc-session")
        session = ready["ready"]["session_id"]
        write(joinpath(out, "restart.json"), read(`$launcher restart --session $session`, String))
        write_record("reset-flat.json", observe_flat(wire, control, command))
        write_record("close.json", set_closed(control, true, true))
        closed = collect_epoch!(wire, "closed", 2, mask, command, basis, images, biased.camera)
        props = graph_properties(control)
        @assert props["correction:closed"]["value"] && props["llowfs-correction:closed"]["value"]
        write_evidence(out, biased, closed, images, mask, basis; require_fixed_baseline=false)
    end
end

qualify(ARGS...)
