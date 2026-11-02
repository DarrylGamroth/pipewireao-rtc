# Explicit authoring templates compile to the unchanged native queue contract.
function queue_templates!(core)
    for (index, entry) in enumerate(get(core, "context.modules", []))
        entry isa AbstractDict || throw(ArgumentError("native module must be an object"))
        haskey(entry, "template") || continue
        InstrumentConfiguration.fields(entry, ("template", "args"), ("template", "args"), "queue template")
        entry["template"] == "telemetry" || throw(ArgumentError("unknown queue template"))
        args = InstrumentConfiguration._declaration_fields(entry["args"],
            ("node.name", "queue.media", "queue.max-buffers", "queue.storage", "queue.overflow", "capture.props", "playback.props"),
            ("node.name", "playback.props"), "telemetry queue arguments")
        name = InstrumentConfiguration._declaration_text(args["node.name"], "telemetry queue name")
        playback = InstrumentConfiguration._declaration_object(args["playback.props"], "telemetry playback properties")
        InstrumentConfiguration._declaration_text(get(playback, "media.name", nothing), "telemetry media name")
        for (field, allowed) in (("capture.props", ("node.loop.name", "node.name", "node.group")),
                ("playback.props", ("node.loop.name", "node.name", "node.group", "device.api", "media.name", "media.class", "queue.max-buffers", "queue.storage", "queue.overflow")))
            haskey(args, field) && InstrumentConfiguration.fields(args[field], allowed, (), "telemetry $field")
        end
        defaults = Dict("node.name" => name, "queue.media" => "application/ndarray", "queue.max-buffers" => 1,
            "queue.storage" => "copy", "queue.overflow" => "drop-oldest",
            "capture.props" => Dict("node.loop.name" => "rtc-data-loop", "node.name" => name * "-input"),
            "playback.props" => Dict("node.loop.name" => "telemetry-loop", "node.name" => name * "-output",
                "device.api" => "pipewireao.queue", "media.name" => playback["media.name"], "media.class" => "Data/Source",
                "queue.max-buffers" => "1", "queue.storage" => "copy", "queue.overflow" => "drop-oldest"))
        resolved = merge_configuration(defaults, args)
        count = resolved["queue.max-buffers"]
        count isa Integer && !(count isa Bool) && count > 0 || throw(ArgumentError("telemetry queue capacity must be a positive integer"))
        for field in ("queue.media", "queue.storage", "queue.overflow")
            InstrumentConfiguration._declaration_text(resolved[field], "telemetry $field")
        end
        for field in ("queue.max-buffers", "queue.storage", "queue.overflow")
            haskey(playback, field) || (resolved["playback.props"][field] = string(resolved[field]))
        end
        core["context.modules"][index] = Dict("name" => "libpipewire-module-queue", "args" => resolved)
    end
    return core
end
