# Site bindings supplied to the installed RTC service by its systemd environment.
# These services are observed on each RTC activation and never submitted or stopped by it.
const EXTERNAL_SERVICE_ENV = (
    "PIPEWIREAORTC_CORE_UNIT", "PIPEWIREAORTC_CORE_SOCKET", "PIPEWIREAORTC_SOURCE_UNIT"
)

function external_services(env = ENV)
    keys = EXTERNAL_SERVICE_ENV
    any(key -> haskey(env, key), keys) || return nothing
    all(key -> haskey(env, key) && !isempty(env[key]), keys) ||
        fail("an independent source requires its core unit, private core socket and source unit")
    core, socket, source = map(key -> String(env[key]), keys)
    external_unit(core)
    external_unit(source)
    core != source || fail("external core and source require distinct services")
    isabspath(socket) && normpath(socket) == socket && !occursin(r"[\r\n\0]", socket) ||
        fail("external core requires an absolute socket path")
    return (; core, socket, source)
end

function external_unit(unit)
    unit isa String && occursin(r"^[a-zA-Z0-9][a-zA-Z0-9_.@-]*\.service$", unit) &&
        !startswith(unit, S.PREFIX) && !startswith(unit, "pipewireao-session@") ||
        fail("external service must be a separately supervised unit")
    return unit
end

# Treat the sealed primary source declaration as the exact data-plane contract.
# Its managed bootstrap and acquisition controls belong to the legacy HIL launch.
function external_source!(spec, source)
    isempty(get(spec, "auxiliary-source-owners", [])) ||
        fail("independent input cannot be combined with RTC-controlled auxiliary acquisition")
    D.uses_heart_protocol(source) && fail("HEART requires its own source protocol")
    for key in ("control-node", "control-instance", "bootstrap-node", "bootstrap-protocol")
        delete!(source, key)
    end
    source["control-protocol"] = D.EXTERNAL_STREAM
    return nothing
end

function external_service(coordinator, role, unit; manager = nothing, deadline = nothing, clock = Clocks.SystemNanoClock())
    service = S.Service(coordinator, role)
    service.unit = external_unit(unit)
    values = S.unit_properties(manager, service.unit; deadline, clock)
    values["ActiveState"] == "active" ||
        fail("external service $(service.unit) is not active")
    S.retain!(service, values)
    S.verify!(manager, service; deadline, clock)
    return service
end

function record_external_service!(record, service, placement)
    record["owners"][service.role] = merge(
        S.record(service),
        Dict("role" => service.role, "external" => true, "placement" => deepcopy(placement)),
    )
    return service
end

function record_external_service!(coordinator, record, role, unit, placement; kwargs...)
    service = external_service(coordinator, role, unit; kwargs...)
    return record_external_service!(record, service, placement)
end

# Check the native Core before any RTC-owned graph or bootstrap node is published.
# Socket activation can give the listening descriptor a different Unix peer PID.
function verify_external_core(prefix, remote, pid, env)
    command = [joinpath(prefix, "bin", "pwao-dump"), "-N", "-r", remote, "0"]
    reply = C.run_checked(command; env, timeout = 10, maximum_output_bytes = 128 * 1024)
    reply.returncode == 0 || fail("cannot inspect independent PipeWire core: " * reply.stderr)
    objects = C.parse_json(reply.stdout)
    length(objects) == 1 || fail("independent socket did not report exactly one Core")
    core = only(objects)
    get(core, "type", nothing) == "PipeWire:Interface:Core" && get(core, "id", nothing) == 0 &&
        string(get(core["info"]["props"], "application.process.id", "")) == string(pid) ||
        fail("private socket does not belong to the declared core service")
    return nothing
end

function recorded_service(coordinator, role, item)
    service = S.Service(coordinator, role)
    if get(item, "external", false)
        service.unit = external_unit(item["unit"])
    end
    item["unit"] == service.unit || fail("recorded service unit differs from its invocation")
    service.main_pid = Int(item["pid"])
    service.invocation = String(item["invocation"])
    service.start_ticks = UInt64(item["start-ticks"])
    service.cgroup = String(item["cgroup"])
    S.running!(service)
    return service
end
