module QuitQueueCounters

using PipeWireAORTC: Common

require(value, message) = value || throw(ArgumentError(message))

function queue_counter(properties, key, queue)
    value = get(properties, key, nothing)
    require(
        value isa Integer && !(value isa Bool) && 0 <= value <= typemax(UInt64),
        "$queue has an invalid or missing $key counter",
    )
    # Widen before subtraction and addition so full-width counters remain exact.
    return Int128(value)
end

function core_cookie(objects)
    info = only(
        object["info"] for object in objects if
        object["type"] == "PipeWire:Interface:Core" && object["id"] == 0
    )
    return queue_counter(info, "cookie", "PipeWire core")
end

function queue_properties(objects, name)
    return only(
        object["info"]["props"] for object in objects if
        object["type"] == "PipeWire:Interface:Module" &&
        object["info"]["name"] == "libpipewire-module-queue" &&
        get(object["info"]["props"], "node.name", nothing) == name
    )
end

function quit_queue_counters(before, after, name)
    require(core_cookie(before) == core_cookie(after), "Quit snapshots use different cores")
    initial, final = queue_properties(before, name), queue_properties(after, name)
    for key in ("object.serial", "queue.state.capture-generation")
        require(
            queue_counter(initial, key, name) == queue_counter(final, key, name) > 0,
            "$name changed $key across Quit",
        )
    end
    before_buffers = queue_counter(initial, "queue.state.capture-buffers", name)
    after_buffers = queue_counter(final, "queue.state.capture-buffers", name)
    before_pending = queue_counter(initial, "queue.state.pending-depth", name)
    after_pending = queue_counter(final, "queue.state.pending-depth", name)
    require(
        before_buffers > 0 && after_buffers == 0 && before_pending == 1 && after_pending == 0,
        "$name did not retire its capture pool and pending loan",
    )
    for snapshot in (initial, final), key in (
        "queue.state.playback-buffers", "queue.state.completion-depth",
        "queue.stats.protocol-errors",
    )
        require(queue_counter(snapshot, key, name) == 0, "$name has nonzero $key")
    end
    changes = Dict{String,Int128}()
    for stat in (
        "publications", "replacements", "withdrawal-returns",
        "deliveries", "completions", "dropped-arrivals",
    )
        key = "queue.stats." * stat
        changes[stat] = queue_counter(final, key, name) - queue_counter(initial, key, name)
        require(changes[stat] >= 0, "$name counter $key regressed across Quit")
    end
    require(
        changes["withdrawal-returns"] == 1 &&
            changes["deliveries"] == changes["completions"] == changes["dropped-arrivals"] ==
            0,
        "$name did not return exactly one pending loan on Quit",
    )
    require(
        before_pending + changes["publications"] ==
            after_pending + changes["replacements"] + changes["withdrawal-returns"],
        "$name publications and loan returns did not balance across Quit",
    )
    return Dict(
        "capture_buffers_before" => before_buffers, "capture_buffers_after" => after_buffers,
        "pending_before" => before_pending, "pending_after" => after_pending,
        "counter_changes" => changes,
    )
end

if abspath(PROGRAM_FILE) == @__FILE__
    length(ARGS) >= 3 || error("usage: quit_queue_counters.jl BEFORE AFTER QUEUE...")
    before, after = Common.read_json(ARGS[1]), Common.read_json(ARGS[2])
    println(Common.metadata_json(Dict(
        name => quit_queue_counters(before, after, name) for name in ARGS[3:end]
    )))
end

end
