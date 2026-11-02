# RTC telemetry opts into the scientific records it can preserve. The generic
# native queue remains Header-only unless its cold profile declares more types.
function queue_metadata!(args)
    defaults() = [Dict("type"=>r.type,"size"=>r.size,"required"=>false)
        for r in Common.TELEMETRY_METADATA]
    declarations=get!(defaults,args,"metadata")
    declarations isa AbstractVector || throw(ArgumentError("queue metadata must be a list"))
    requirements=map(declarations) do item
        InstrumentConfiguration.fields(item,("type","size","required"),("type","size","required"),"queue metadata")
        type,size,required=item["type"],item["size"],item["required"]
        type isa Integer && !(type isa Bool) && size isa Integer && !(size isa Bool) && required isa Bool ||
            throw(ArgumentError("queue metadata requires integer type/size and Boolean required"))
        requirement=PipeWireAO.MetadataRequirement(type,size;required)
        PipeWireAO.metadata_is_transport_owned(requirement.type) &&
            throw(ArgumentError("queue metadata must not copy transport-owned records"))
        requirement
    end
    explicit_header=any(r->r.type==PipeWireAO.SPA.META_HEADER,requirements)
    explicit_header && !any(r->r.type==PipeWireAO.SPA.META_HEADER && r.required,requirements) &&
        throw(ArgumentError("queue Header must be required"))
    PipeWireAO.validate_metadata_requirements(Tuple(requirements);header=!explicit_header)
    return args
end

# Explicit authoring templates compile to the native queue contract.
function queue_templates!(core)
    for (index, entry) in enumerate(get(core, "context.modules", []))
        entry isa AbstractDict || throw(ArgumentError("native module must be an object"))
        haskey(entry, "template") || continue
        InstrumentConfiguration.fields(entry, ("template", "args"), ("template", "args"), "queue template")
        entry["template"] == "telemetry" || throw(ArgumentError("unknown queue template"))
        args = InstrumentConfiguration._declaration_fields(entry["args"],
            ("node.name", "queue.media", "queue.max-buffers", "queue.storage", "queue.overflow", "metadata", "capture.props", "playback.props"),
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
        queue_metadata!(resolved)
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
