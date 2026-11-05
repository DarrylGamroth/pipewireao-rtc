_queue_metadata_declarations(value) = throw(ArgumentError("queue metadata must be a list"))
_queue_metadata_declarations(::AbstractVector) = nothing
_queue_metadata_integer(value) =
    throw(ArgumentError("queue metadata requires integer type/size and Boolean required"))
_queue_metadata_integer(::Bool) =
    throw(ArgumentError("queue metadata requires integer type/size and Boolean required"))
_queue_metadata_integer(::Integer) = nothing
_queue_metadata_required(value) =
    throw(ArgumentError("queue metadata requires integer type/size and Boolean required"))
_queue_metadata_required(::Bool) = nothing
_queue_module(value) = throw(ArgumentError("native module must be an object"))
_queue_module(::AbstractDict) = nothing
_queue_capacity(value) =
    throw(ArgumentError("telemetry queue capacity must be a positive integer"))
_queue_capacity(::Bool) =
    throw(ArgumentError("telemetry queue capacity must be a positive integer"))
_queue_capacity(value::Integer) =
    value > 0 || throw(ArgumentError("telemetry queue capacity must be a positive integer"))

# RTC telemetry opts into the scientific records it can preserve. The generic
# native queue remains Header-only unless its cold profile declares more types.
function queue_metadata!(args; defaults = true)
    !defaults && !haskey(args, "metadata") && return args
    default_records() = [
        Dict("type" => r.type, "size" => r.size, "required" => false) for
        r in Common.TELEMETRY_METADATA
    ]
    declarations = get!(default_records, args, "metadata")
    _queue_metadata_declarations(declarations)
    requirements = map(declarations) do item
        InstrumentConfiguration.fields(
            item,
            ("type", "size", "required"),
            ("type", "size", "required"),
            "queue metadata",
        )
        type, size, required = item["type"], item["size"], item["required"]
        _queue_metadata_integer(type)
        _queue_metadata_integer(size)
        _queue_metadata_required(required)
        requirement = PipeWireAO.MetadataRequirement(type, size; required)
        PipeWireAO.metadata_is_transport_owned(requirement.type) &&
            throw(ArgumentError("queue metadata must not copy transport-owned records"))
        requirement
    end
    explicit_header = any(r -> r.type == PipeWireAO.SPA.META_HEADER, requirements)
    explicit_header &&
        !any(r -> r.type == PipeWireAO.SPA.META_HEADER && r.required, requirements) &&
        throw(ArgumentError("queue Header must be required"))
    PipeWireAO.validate_metadata_requirements(
        Tuple(requirements); header = !explicit_header
    )
    return args
end

# Explicit authoring templates compile to the native queue contract.
function queue_templates!(core; metadata_defaults = true)
    for (index, entry) in enumerate(get(core, "context.modules", []))
        _queue_module(entry)
        haskey(entry, "template") || continue
        InstrumentConfiguration.fields(
            entry, ("template", "args"), ("template", "args"), "queue template"
        )
        entry["template"] == "telemetry" || throw(ArgumentError("unknown queue template"))
        args = InstrumentConfiguration._declaration_fields(
            entry["args"],
            (
                "node.name",
                "queue.media",
                "queue.max-buffers",
                "queue.storage",
                "queue.overflow",
                "metadata",
                "capture.props",
                "playback.props",
            ),
            ("node.name", "playback.props"),
            "telemetry queue arguments",
        )
        name = InstrumentConfiguration._declaration_text(
            args["node.name"], "telemetry queue name"
        )
        playback = InstrumentConfiguration._declaration_object(
            args["playback.props"], "telemetry playback properties"
        )
        InstrumentConfiguration._declaration_text(
            get(playback, "media.name", nothing), "telemetry media name"
        )
        for (field, allowed) in (
            ("capture.props", ("node.loop.name", "node.name", "node.group")),
            (
                "playback.props",
                (
                    "node.loop.name",
                    "node.name",
                    "node.group",
                    "device.api",
                    "media.name",
                    "media.class",
                    "queue.max-buffers",
                    "queue.storage",
                    "queue.overflow",
                ),
            ),
        )
            haskey(args, field) &&
                InstrumentConfiguration.fields(args[field], allowed, (), "telemetry $field")
        end
        defaults = Dict(
            "node.name" => name,
            "queue.media" => "application/ndarray",
            "queue.max-buffers" => 1,
            "queue.storage" => "copy",
            "queue.overflow" => "drop-oldest",
            "capture.props" =>
                Dict("node.loop.name" => "rtc-data-loop", "node.name" => name * "-input"),
            "playback.props" => Dict(
                "node.loop.name" => "telemetry-loop",
                "node.name" => name * "-output",
                "device.api" => "pipewireao.queue",
                "media.name" => playback["media.name"],
                "media.class" => "Data/Source",
                "queue.max-buffers" => "1",
                "queue.storage" => "copy",
                "queue.overflow" => "drop-oldest",
            ),
        )
        resolved = merge_configuration(defaults, args)
        queue_metadata!(resolved; defaults = metadata_defaults)
        count = resolved["queue.max-buffers"]
        _queue_capacity(count)
        for field in ("queue.media", "queue.storage", "queue.overflow")
            InstrumentConfiguration._declaration_text(resolved[field], "telemetry $field")
        end
        for field in ("queue.max-buffers", "queue.storage", "queue.overflow")
            haskey(playback, field) ||
                (resolved["playback.props"][field] = string(resolved[field]))
        end
        core["context.modules"][index] = Dict(
            "name" => "libpipewire-module-queue", "args" => resolved
        )
    end
    return core
end

# Final source profiles and session links are available only after mode and
# scientific contract resolution. Keep inferred slots optional; explicit authored
# layouts remain authoritative and must be able to preserve their linked source.
function queue_metadata_profiles!(core, session, contracts, simulation)
    classifications = Set(
        UInt32.((
            PipeWireAO.SPA.META_OPTICAL_CHOPPING, PipeWireAO.SPA.META_ELECTRICAL_TRIGGER
        )),
    )
    profiles = Dict{String,Set{UInt32}}()
    for (node, contract) in contracts, (port, output) in contract["outputs"]
        profiles[node*":"*port] = Set(
            UInt32(r["type"]) for
            r in get(output, "metadata", []) if r["type"] in classifications
        )
    end
    if get(simulation, "version", nothing) in (4, 6)
        sensors = get(simulation, "sensor_nodes", Dict())
        for name in keys(get(get(simulation, "plant", Dict()), "chopping", Dict()))
            haskey(sensors, name) ||
                throw(ArgumentError("chopping names an unknown sensor: $name"))
            profiles[sensors[name]*":output_1"] = copy(classifications)
        end
    end
    queues = [
        module_["args"] for module_ in get(core, "context.modules", []) if
        get(module_, "name", nothing) == "libpipewire-module-queue" &&
            get(get(module_, "args", Dict()), "queue.media", nothing) ==
            "application/ndarray"
    ]
    links = get(session, "links", [])
    inferred = [
        Set(
            UInt32(record["type"]) for
            record in get(args, "metadata", []) if record["type"] in classifications
        ) for args in queues
    ]
    # At most one queue hop per pass, including reverse-ordered chains.
    for _ in 1:(length(queues)+1)
        changed = false
        for (index, args) in enumerate(queues)
            name = args["node.name"]
            capture = get(get(args, "capture.props", Dict()), "node.name", name * "-input")
            playback = get(
                get(args, "playback.props", Dict()), "node.name", name * "-output"
            )
            for link in links
                first(split(link["input"], ':'; limit = 2)) == capture || continue
                before = length(inferred[index])
                union!(inferred[index], get(profiles, link["output"], Set{UInt32}()))
                changed |= length(inferred[index]) != before
            end
            for link in links
                first(split(link["output"], ':'; limit = 2)) == playback || continue
                previous = get!(profiles, link["output"], Set{UInt32}())
                before = length(previous)
                union!(previous, inferred[index])
                changed |= length(previous) != before
            end
        end
        changed || break
    end
    for (args, types) in zip(queues, inferred)
        explicit = haskey(args, "metadata")
        queue_metadata!(args)
        for type in sort!(collect(types))
            any(record -> record["type"] == type, args["metadata"]) && continue
            explicit && throw(
                ArgumentError(
                    "queue $(args["node.name"]) metadata omits source classification $type",
                ),
            )
            record = PipeWireAO.MetadataRequirement(type)
            push!(
                args["metadata"],
                Dict("type" => record.type, "size" => record.size, "required" => false),
            )
        end
        queue_metadata!(args)
    end
    return core
end
