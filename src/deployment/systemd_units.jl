_ordering_name(value) = fail("service ordering dependencies must be unit names")
_ordering_name(::AbstractString) = nothing
_owner_command(argv) = fail("owner command has an invalid executable or argument")
function _owner_command(argv::AbstractVector)
    !isempty(argv) || fail("owner command has an invalid executable or argument")
    foreach(_owner_argument, argv)
    !isempty(argv[1]) || fail("owner command has an invalid executable or argument")
    return nothing
end
_owner_argument(value) = fail("owner command has an invalid executable or argument")
_owner_argument(value::AbstractString) =
    !occursin('\0', value) || fail("owner command has an invalid executable or argument")
_owner_environment(key, value) = fail("invalid owner environment")
_owner_environment(key::AbstractString, value::AbstractString) =
    occursin(r"^[A-Za-z_][A-Za-z0-9_]*$", key) && !occursin('\0', value) ||
    fail("invalid owner environment")
_cohort_units(units) = fail("cohort must name generated owner service units")
function _cohort_units(units::AbstractVector)
    !isempty(units) || fail("cohort must name generated owner service units")
    foreach(_cohort_name, units)
    return nothing
end
_cohort_name(value) = fail("cohort must name generated owner service units")
_cohort_name(::AbstractString) = nothing

"""Quote one systemd unit-file argument as a double-quoted literal."""
function unit_argument(value::AbstractString)
    occursin('\0', value) && fail("systemd unit argument contains NUL")
    io = IOBuffer()
    write(io, '"')
    for character in value
        if character == '\\'
            write(io, "\\\\")
        elseif character == '"'
            write(io, "\\\"")
        elseif character == '\n'
            write(io, "\\n")
        elseif character == '\r'
            write(io, "\\r")
        elseif character == '\t'
            write(io, "\\t")
        elseif isascii(character) && (iscntrl(character))
            write(io, "\\x", string(UInt32(character); base = 16, pad = 2))
        elseif character == '%'
            write(io, "%%")
        else
            write(io, character)
        end
    end
    write(io, '"')
    return String(take!(io))
end

_unit_name(value, description) = fail("invalid $description service unit name")
function _unit_name(value::AbstractString, description)
    occursin(r"^[A-Za-z0-9_.@:-]+\.service$", value) ||
        fail("invalid $description service unit name")
    return String(value)
end

_after_units(after) = fail("service ordering dependencies must be unit names")
function _after_units(after::AbstractVector)
    foreach(_ordering_name, after)
    names = String[_unit_name(value, "ordering dependency") for value in after]
    length(unique(names)) == length(names) || fail("duplicate service ordering dependency")
    return names
end

"""Render a standalone owner service with the existing owner limits."""
function service_unit(
    service::Service,
    argv,
    env,
    cwd,
    placement;
    after = String[],
    binds_to = String[],
    part_of = String[],
    requisite = String[],
    ordinary = false,
)
    service.state == :pending || fail("owner unit rendering requires a pending handle")
    unit = _unit_name(service.unit, "owner")
    unit ==
    PREFIX *
    valid_invocation(service.coordinator.invocation) *
    "-" *
    service.role *
    ".service" || fail("owner service name differs from its invocation and role")
    _owner_command(argv)
    isabspath(String(argv[1])) || fail("owner executable must be absolute")
    isabspath(String(cwd)) && isdir(cwd) ||
        fail("owner working directory must exist and be absolute")
    !occursin(r"[\n\r\0]", cwd) && strip(cwd) == cwd ||
        fail("owner working directory must be a literal single-line path")
    cpu, cpus = validate_placement(placement)

    environment = Dict{String,String}()
    for (key, value) in pairs(env)
        _owner_environment(key, value)
        environment[String(key)] = String(value)
    end
    for key in ("NOTIFY_SOCKET", "INVOCATION_ID", "JOURNAL_STREAM", "SYSTEMD_EXEC_PID")
        delete!(environment, key)
    end
    # ROCr otherwise gives helper threads all CPUs, escaping the owner contract.
    get(environment, "HSA_OVERRIDE_CPU_AFFINITY_DEBUG", "0") == "0" || fail(
        "owner runtime requires HSA_OVERRIDE_CPU_AFFINITY_DEBUG=0 to preserve inherited CPU affinity",
    )
    environment["HSA_OVERRIDE_CPU_AFFINITY_DEBUG"] = "0"
    dependencies = _after_units(after)

    lines = String["[Unit]", "Description=PipeWireAO owner $(service.role)"]
    isempty(dependencies) || push!(lines, "After=" * join(dependencies, " "))
    for (key, units) in
        (("BindsTo", binds_to), ("PartOf", part_of), ("Requisite", requisite))
        names = _after_units(units)
        isempty(names) || push!(lines, key * "=" * join(names, " "))
    end
    append!(
        lines,
        [
            "",
            "[Service]",
            "Type=exec",
            "ExecStart=:" * join(unit_argument.(String.(argv)), " "),
            # Path directives consume the whole value, not a quoted argument list.
            "WorkingDirectory=" * replace(cwd, "%" => "%%"),
        ],
    )
    for key in sort!(collect(keys(environment)))
        push!(lines, "Environment=" * unit_argument(key * "=" * environment[key]))
    end
    ordinary && append!(lines, ["RestrictRealtime=yes", "Nice=10"])
    append!(
        lines,
        [
            "CPUAffinity=" * (ordinary ? join(cpus, " ") : string(cpu)),
            "LimitRTPRIO=" * (ordinary ? "0" : "95"),
            "LimitMEMLOCK=4294967296",
            "KillMode=control-group",
            "Restart=no",
            "UMask=0077",
            "TimeoutStartSec=20",
            "TimeoutStopSec=15",
            "StandardOutput=journal",
            "StandardError=journal",
            "",
        ],
    )
    return join(lines, "\n")
end

"""Render one cohort target ordered after its exact generated owner units."""
function cohort_unit(invocation, units)
    id = valid_invocation(invocation)
    _cohort_units(units)
    names = String[_unit_name(value, "cohort owner") for value in units]
    length(unique(names)) == length(names) || fail("duplicate cohort owner service unit")
    prefix = PREFIX * id * "-"
    for name in names
        startswith(name, prefix) || fail("cohort owner unit belongs to another invocation")
        role = name[(length(prefix)+1):(end-length(".service"))]
        occursin(r"^[a-z][a-z0-9-]{0,31}$", role) ||
            fail("cohort contains a malformed owner service unit")
    end
    joined = join(names, " ")
    return join(
        [
            "[Unit]",
            "Description=PipeWireAO owner cohort $(id)",
            "Wants=" * joined,
            "After=" * joined,
            "",
        ],
        "\n",
    )
end
