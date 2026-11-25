const LIBSYSTEMD = "libsystemd.so.0"
const SYSTEMD = "org.freedesktop.systemd1"
const MANAGER_PATH = "/org/freedesktop/systemd1"
const UNIT_PATH = MANAGER_PATH * "/unit"
const MANAGER_INTERFACE = SYSTEMD * ".Manager"
const UNIT_INTERFACE = SYSTEMD * ".Unit"
const SERVICE_INTERFACE = SYSTEMD * ".Service"
const DBUS = "org.freedesktop.DBus"
const DBUS_PATH = "/org/freedesktop/DBus"
const PROPERTIES_INTERFACE = DBUS * ".Properties"

const UNIT_SIGNATURES = Dict(
    "Id" => "s",
    "ActiveState" => "s",
    "LoadState" => "s",
    "InvocationID" => "ay",
    "FragmentPath" => "s",
    "DropInPaths" => "as",
    "NeedDaemonReload" => "b",
)
const EXEC_COMMAND_FIELDS = "sasbttttuii"
const EXEC_COMMANDS_SIGNATURE = "a(" * EXEC_COMMAND_FIELDS * ")"
const SERVICE_SIGNATURES = Dict(
    "MainPID" => "u",
    "ControlGroup" => "s",
    "Type" => "s",
    "NotifyAccess" => "s",
    "Restart" => "s",
    "KillMode" => "s",
    "ExecStop" => EXEC_COMMANDS_SIGNATURE,
    "ExecStopPost" => EXEC_COMMANDS_SIGNATURE,
)

struct ExecCommand
    path::String
    argv::Vector{String}
    ignore_failure::Bool
end

# One task owns this connection for the duration of admission.
mutable struct UserManager
    bus::Ptr{Cvoid}
    owner::String
    watched_units::Dict{String,String}
    invocations::Dict{String,String}
    changes::Set{String}
    fault::Union{Nothing,String}
end

function bus_checked(result, operation)
    result >= 0 || fail("systemd bus $operation failed (errno $(-result))")
    return result
end

function bus_timeout(deadline, clock)
    remaining = Base.checked_sub(deadline_ns(deadline), Clocks.time_nanos(clock))
    remaining > 0 || fail("systemd owner operation exceeded its deadline")
    return UInt64(clamp(fld(remaining, 1000), 1, 5_000_000))
end

bus_deadline(deadline, clock) = deadline === nothing ?
    Base.checked_add(Clocks.time_nanos(clock), Int64(5_000_000_000)) : deadline_ns(deadline)

bus_unref(message) =
    ccall((:sd_bus_message_unref, LIBSYSTEMD), Ptr{Cvoid}, (Ptr{Cvoid},), message)

function bus_call(f, bus, destination, path, interface, method, argument; deadline, clock)
    request = Ref{Ptr{Cvoid}}(C_NULL)
    reply = Ref{Ptr{Cvoid}}(C_NULL)
    bus_checked(
        ccall(
            (:sd_bus_message_new_method_call, LIBSYSTEMD), Cint,
            (Ptr{Cvoid}, Ref{Ptr{Cvoid}}, Cstring, Cstring, Cstring, Cstring),
            bus, request, destination, path, interface, method,
        ),
        "create $method request",
    )
    try
        if argument !== nothing
            bus_checked(
                ccall(
                    (:sd_bus_message_append_basic, LIBSYSTEMD), Cint,
                    (Ptr{Cvoid}, Cchar, Cstring), request[], 's', argument,
                ),
                "append $method argument",
            )
        end
        timeout = bus_timeout(deadline, clock)
        bus_checked(
            ccall(
                (:sd_bus_call, LIBSYSTEMD), Cint,
                (Ptr{Cvoid}, Ptr{Cvoid}, UInt64, Ptr{Cvoid}, Ref{Ptr{Cvoid}}),
                bus, request[], timeout, C_NULL, reply,
            ),
            method,
        )
        value = f(reply[])
        bus_timeout(deadline, clock)
        return value
    finally
        bus_unref(reply[])
        bus_unref(request[])
    end
end

function bus_read(message, type, ::Type{T}) where {T}
    value = Ref{T}()
    result = ccall(
        (:sd_bus_message_read_basic, LIBSYSTEMD), Cint,
        (Ptr{Cvoid}, Cchar, Ref{T}), message, type, value,
    )
    bus_checked(result, "read $type")
    return result == 0 ? nothing : value[]
end

function bus_required(value)
    value === nothing && fail("systemd bus reply ended unexpectedly")
    return value
end

bus_string(message, type = 's') = unsafe_string(bus_required(bus_read(message, type, Cstring)))

function bus_enter(message, type, contents)
    return bus_checked(
        ccall(
            (:sd_bus_message_enter_container, LIBSYSTEMD), Cint,
            (Ptr{Cvoid}, Cchar, Cstring), message, type, contents,
        ),
        "enter $type container",
    ) > 0
end

bus_exit(message) = bus_checked(
    ccall((:sd_bus_message_exit_container, LIBSYSTEMD), Cint, (Ptr{Cvoid},), message),
    "exit container",
)

function bus_skip(message, types)
    bus_checked(
        ccall(
            (:sd_bus_message_skip, LIBSYSTEMD), Cint,
            (Ptr{Cvoid}, Cstring), message, types,
        ),
        "skip $types",
    ) > 0 || fail("systemd bus reply ended unexpectedly")
    return nothing
end

function bus_strings(message)
    bus_enter(message, 'a', "s") || fail("systemd bus reply lacks a string array")
    values = String[]
    while true
        value = bus_read(message, 's', Cstring)
        value === nothing && break
        push!(values, unsafe_string(value))
    end
    bus_exit(message)
    return values
end

function bus_invocation(message)
    bytes = Ref{Ptr{UInt8}}(C_NULL)
    count = Ref{Csize_t}(0)
    bus_checked(
        ccall(
            (:sd_bus_message_read_array, LIBSYSTEMD), Cint,
            (Ptr{Cvoid}, Cchar, Ref{Ptr{UInt8}}, Ref{Csize_t}), message, 'y', bytes, count,
        ),
        "read invocation ID",
    ) > 0 || fail("systemd bus reply lacks InvocationID")
    count[] == 0 && return ""
    count[] == 16 || fail("systemd returned an invalid InvocationID size")
    value = unsafe_wrap(Vector{UInt8}, bytes[], 16)
    return all(iszero, value) ? "" : bytes2hex(value)
end

function bus_exec_commands(message)
    bus_enter(message, 'a', "(" * EXEC_COMMAND_FIELDS * ")") ||
        fail("systemd bus reply lacks an exec command array")
    commands = ExecCommand[]
    while bus_enter(message, 'r', EXEC_COMMAND_FIELDS)
        path = bus_string(message)
        argv = bus_strings(message)
        ignore_failure = !iszero(bus_required(bus_read(message, 'b', Cint)))
        bus_skip(message, "ttttuii")
        bus_exit(message)
        push!(commands, ExecCommand(path, argv, ignore_failure))
    end
    bus_exit(message)
    return commands
end

function bus_property(message, signature)
    signature == "s" && return bus_string(message)
    signature == "u" && return Int(bus_required(bus_read(message, 'u', UInt32)))
    signature == "b" && return !iszero(bus_required(bus_read(message, 'b', Cint)))
    signature == "as" && return bus_strings(message)
    signature == "ay" && return bus_invocation(message)
    signature == EXEC_COMMANDS_SIGNATURE && return bus_exec_commands(message)
    fail("unsupported systemd property signature $signature")
end

function bus_read_properties!(values, message, fields)
    bus_enter(message, 'a', "{sv}") || fail("systemd returned no unit properties")
    while bus_enter(message, 'e', "sv")
        field = bus_string(message)
        signature = get(fields, field, nothing)
        if signature === nothing
            bus_skip(message, "v")
        else
            haskey(values, field) && fail("systemd returned duplicate property $field")
            bus_enter(message, 'v', signature) ||
                fail("systemd returned no value for property $field")
            values[field] = bus_property(message, signature)
            bus_exit(message)
        end
        bus_exit(message)
    end
    bus_exit(message)
    return nothing
end

function bus_unit_path(unit)
    path = Ref{Ptr{UInt8}}(C_NULL)
    bus_checked(
        ccall(
            (:sd_bus_path_encode, LIBSYSTEMD), Cint,
            (Cstring, Cstring, Ref{Ptr{UInt8}}), UNIT_PATH, unit, path,
        ),
        "encode path for $unit",
    )
    try
        return unsafe_string(path[])
    finally
        Libc.free(path[])
    end
end

systemd_bus_owner(bus; deadline, clock) =
    bus_call(bus_string, bus, DBUS, DBUS_PATH, DBUS, "GetNameOwner", SYSTEMD; deadline, clock)

function add_bus_match(bus, rule; deadline, clock)
    bus_call(_ -> nothing, bus, DBUS, DBUS_PATH, DBUS, "AddMatch", rule; deadline, clock)
end

function authenticate_bus!(bus; deadline, clock)
    # sd_bus_call applies its timeout only after the connection is ready.
    while true
        bus_timeout(deadline, clock)
        ready = ccall((:sd_bus_is_ready, LIBSYSTEMD), Cint, (Ptr{Cvoid},), bus)
        bus_checked(ready, "check authentication") > 0 && return nothing
        progress = ccall(
            (:sd_bus_process, LIBSYSTEMD), Cint, (Ptr{Cvoid}, Ptr{Cvoid}), bus, C_NULL,
        )
        if bus_checked(progress, "process authentication") == 0
            timeout = bus_timeout(deadline, clock)
            bus_checked(
                ccall((:sd_bus_wait, LIBSYSTEMD), Cint, (Ptr{Cvoid}, UInt64), bus, timeout),
                "wait for authentication",
            )
        end
    end
end

close_user_bus(bus) =
    ccall((:sd_bus_close_unref, LIBSYSTEMD), Ptr{Cvoid}, (Ptr{Cvoid},), bus)

function open_user_bus(; deadline, clock)
    bus_timeout(deadline, clock)
    bus = Ref{Ptr{Cvoid}}(C_NULL)
    bus_checked(
        ccall((:sd_bus_open_user, LIBSYSTEMD), Cint, (Ref{Ptr{Cvoid}},), bus),
        "open user manager",
    )
    try
        authenticate_bus!(bus[]; deadline, clock)
        return bus[]
    catch
        close_user_bus(bus[])
        rethrow()
    end
end

"""
    with_unit_reference(f, unit; deadline, clock)

Keep the unit's exit properties available while `f` runs. Bound connection
and reference acquisition to five seconds within `deadline`. Closing the
dedicated bus connection releases the reference.
"""
function with_unit_reference(f, unit; deadline, clock)
    deadline = deadline_ns(deadline)
    current = Clocks.time_nanos(clock)
    if Base.checked_sub(deadline, current) > 5_000_000_000
        deadline = Base.checked_add(current, Int64(5_000_000_000))
    end
    bus = open_user_bus(; deadline, clock)
    try
        bus_call(
            _ -> nothing, bus, SYSTEMD, MANAGER_PATH, MANAGER_INTERFACE, "RefUnit", unit;
            deadline, clock,
        )
        return f()
    finally
        close_user_bus(bus)
    end
end

"""
    UserManager(watch; deadline=nothing, clock=Clocks.SystemNanoClock())

Connect to the current user systemd manager. Subscribe to changes of the exact
unit names in `watch` before reading any unit properties. One task owns the
connection and must close it at the end of observation.
"""
function UserManager(
    watch; deadline = nothing, clock::Clocks.AbstractNanoClock = Clocks.SystemNanoClock(),
)
    isempty(watch) && fail("systemd unit watch is empty")
    deadline = bus_deadline(deadline, clock)
    bus = open_user_bus(; deadline, clock)
    try
        add_bus_match(
            bus,
            "type='signal',sender='$DBUS',path='$DBUS_PATH',interface='$DBUS'," *
            "member='NameOwnerChanged',arg0='$SYSTEMD'";
            deadline, clock,
        )
        owner = systemd_bus_owner(bus; deadline, clock)
        watched_units = Dict{String,String}(bus_unit_path(unit) => unit for unit in watch)
        manager = UserManager(
            bus, owner, watched_units, Dict{String,String}(), Set{String}(), nothing,
        )
        add_bus_match(
            bus,
            "type='signal',sender='$owner',path_namespace='$UNIT_PATH'," *
            "interface='$PROPERTIES_INTERFACE',member='PropertiesChanged'";
            deadline, clock,
        )
        add_bus_match(
            bus,
            "type='signal',sender='$owner',path='$MANAGER_PATH',interface='$MANAGER_INTERFACE'";
            deadline, clock,
        )
        bus_call(
            _ -> nothing, bus, owner, MANAGER_PATH, MANAGER_INTERFACE, "Subscribe", nothing;
            deadline, clock,
        )
        drain_unit_changes!(manager; deadline, clock)
        return manager
    catch
        close_user_bus(bus)
        rethrow()
    end
end

function Base.close(manager::UserManager)
    manager.bus == C_NULL && return nothing
    close_user_bus(manager.bus)
    manager.bus = C_NULL
    return nothing
end

function watched_property_changed(message)
    interface = bus_string(message)
    fields = if interface == UNIT_INTERFACE
        UNIT_SIGNATURES
    elseif interface == SERVICE_INTERFACE
        SERVICE_SIGNATURES
    else
        return false
    end
    bus_enter(message, 'a', "{sv}") || fail("systemd bus signal lacks changed properties")
    while bus_enter(message, 'e', "sv")
        haskey(fields, bus_string(message)) && return true
        bus_skip(message, "v")
        bus_exit(message)
    end
    bus_exit(message)
    return any(field -> haskey(fields, field), bus_strings(message))
end

function bus_signal!(manager, message)
    member = ccall(
        (:sd_bus_message_get_member, LIBSYSTEMD), Cstring, (Ptr{Cvoid},), message
    )
    member == C_NULL && return nothing
    sender = ccall(
        (:sd_bus_message_get_sender, LIBSYSTEMD), Cstring, (Ptr{Cvoid},), message
    )
    sender == C_NULL && return nothing
    name = unsafe_string(member)
    origin = unsafe_string(sender)
    if origin == DBUS && name == "NameOwnerChanged"
        unit = bus_string(message)
        old_owner = bus_string(message)
        if unit == SYSTEMD && old_owner == manager.owner
            manager.fault = "user systemd manager changed during observation"
        end
    elseif origin == manager.owner
        if name == "PropertiesChanged"
            path = unsafe_string(ccall(
                (:sd_bus_message_get_path, LIBSYSTEMD), Cstring, (Ptr{Cvoid},), message,
            ))
            if haskey(manager.watched_units, path) && watched_property_changed(message)
                push!(manager.changes, manager.watched_units[path])
            end
        elseif name in ("UnitNew", "UnitRemoved")
            unit = bus_string(message)
            path = bus_string(message, 'o')
            if get(manager.watched_units, path, nothing) == unit
                if name == "UnitRemoved" && haskey(manager.invocations, unit)
                    manager.fault = "systemd removed watched unit $unit during observation"
                end
                push!(manager.changes, unit)
            end
        elseif name in ("Reloading", "UnitFilesChanged")
            union!(manager.changes, values(manager.watched_units))
        end
    end
    return nothing
end

function drain_unit_changes!(manager; deadline, clock)
    manager.bus == C_NULL && fail("user systemd manager connection is closed")
    message = Ref{Ptr{Cvoid}}(C_NULL)
    while true
        manager.fault === nothing || fail(manager.fault)
        bus_timeout(deadline, clock)
        result = ccall(
            (:sd_bus_process, LIBSYSTEMD), Cint,
            (Ptr{Cvoid}, Ref{Ptr{Cvoid}}), manager.bus, message,
        )
        bus_checked(result, "process signals")
        result == 0 && break
        if message[] != C_NULL
            try
                bus_signal!(manager, message[])
            finally
                bus_unref(message[])
                message[] = C_NULL
            end
        end
    end
    return nothing
end

"""
    check_unit_changes!(manager; deadline=nothing, clock=Clocks.SystemNanoClock())

Drain watched signals and report whether any unit snapshot needs to be read
again. Fail if the manager or a watched activation was removed or replaced.
"""
function check_unit_changes!(
    manager::UserManager; deadline = nothing,
    clock::Clocks.AbstractNanoClock = Clocks.SystemNanoClock(),
)
    drain_unit_changes!(manager; deadline = bus_deadline(deadline, clock), clock)
    return !isempty(manager.changes)
end

"""
    unit_properties(manager, unit; extra="", deadline=nothing, clock=Clocks.SystemNanoClock())

Read exact watched service properties from their D-Bus interfaces. Return a
string-keyed snapshot with typed values. Absent invocation IDs are empty strings.
"""
function unit_properties(
    manager::UserManager, unit::AbstractString; extra = "", deadline = nothing,
    clock::Clocks.AbstractNanoClock = Clocks.SystemNanoClock(),
)
    deadline = bus_deadline(deadline, clock)
    path = bus_unit_path(unit)
    get(manager.watched_units, path, nothing) == unit || fail("systemd unit $unit is not watched")
    unit_fields = Dict(field => UNIT_SIGNATURES[field] for field in
                      ("Id", "LoadState", "ActiveState", "InvocationID"))
    service_fields = Dict("MainPID" => "u", "ControlGroup" => "s")
    for field in split(extra, ','; keepempty = false)
        if haskey(UNIT_SIGNATURES, field)
            unit_fields[field] = UNIT_SIGNATURES[field]
        elseif haskey(SERVICE_SIGNATURES, field)
            service_fields[field] = SERVICE_SIGNATURES[field]
        else
            fail("unsupported systemd property $field for $unit")
        end
    end
    while true
        drain_unit_changes!(manager; deadline, clock)
        delete!(manager.changes, unit)
        values = Dict{String,Any}()
        for (interface, fields) in ((UNIT_INTERFACE, unit_fields), (SERVICE_INTERFACE, service_fields))
            bus_call(
                message -> bus_read_properties!(values, message, fields),
                manager.bus, manager.owner, path, PROPERTIES_INTERFACE, "GetAll", interface;
                deadline, clock,
            )
            for field in keys(fields)
                haskey(values, field) || fail("missing systemd property $field for $unit")
            end
        end
        values["Id"] == unit || fail("systemd returned a different unit identity for $unit")
        invocation = values["InvocationID"]
        if get(manager.invocations, unit, invocation) != invocation
            manager.fault = "systemd replaced watched unit $unit during observation"
            fail(manager.fault)
        end
        if !isempty(invocation) && values["ActiveState"] in ("active", "activating", "reloading")
            manager.invocations[unit] = invocation
        end
        drain_unit_changes!(manager; deadline, clock)
        # An event between interface reads can produce a mixed snapshot.
        haskey(manager.invocations, unit) && unit in manager.changes && continue
        return values
    end
end
