module Common

import PipeWireAO
using JSON
using SHA
using YAML

export read_json,
    read_yaml, parse_json, write_json, write_yaml, sha256_file, cli_arguments, run_checked

# Use only during cold preparation, before accepting deadline-bound work.
function startup_phase(f, owner, phase)
    @info "Startup phase started" owner phase
    started = time_ns()
    try
        result = @timed f()
        @info "Startup phase completed" owner phase wall_seconds=result.time compile_seconds=result.compile_time
        return result.value
    catch
        @info "Startup phase interrupted" owner phase wall_seconds=(time_ns() - started) / 1e9
        rethrow()
    end
end

"""
    remaining_ns(deadline, now)

Return the nonnegative time to a deadline as signed nanoseconds. Saturate
differences outside the signed range at `typemax(Int64)`.
"""
function remaining_ns(deadline::Int64, now::Int64)
    deadline <= now && return Int64(0)
    remaining, overflow = Base.sub_with_overflow(deadline, now)
    return overflow ? typemax(Int64) : remaining
end

# Optional scientific facts preserved by RTC graph and observation boundaries.
# Required acquisition facts remain the consuming algorithm/profile's contract.
const TELEMETRY_METADATA = Tuple(
    PipeWireAO.MetadataRequirement(type) for type in (
        PipeWireAO.SPA.META_ACQUISITION_IDENTITY,
        PipeWireAO.SPA.META_EXPOSURE_TIMING,
        PipeWireAO.SPA.META_REFERENCE_TIMESTAMP,
    )
)
const ACQUISITION_METADATA = Tuple(
    PipeWireAO.MetadataRequirement(record.type, record.size; required = true) for
    record in TELEMETRY_METADATA
)

function telemetry_metadata_ports(names; required = NamedTuple(), optional = NamedTuple())
    profiles = map(Tuple(names)) do name
        needed = get(required, name, ())
        metadata = map(TELEMETRY_METADATA) do record
            demanded = any(r -> r.type == record.type && r.required, needed)
            PipeWireAO.MetadataRequirement(record.type, record.size; required = demanded)
        end
        supplied = get(optional, name, ())
        classifications = (needed..., supplied...)
        electrical =
            any(r -> r.type == PipeWireAO.SPA.META_OPTICAL_CHOPPING, classifications) &&
            !any(r -> r.type == PipeWireAO.SPA.META_ELECTRICAL_TRIGGER, classifications) ?
            (PipeWireAO.MetadataRequirement(PipeWireAO.SPA.META_ELECTRICAL_TRIGGER),) : ()
        offered = (needed..., supplied..., electrical...)
        extra = Tuple(r for r in offered if !any(base -> base.type == r.type, metadata))
        (; metadata = (metadata..., extra...))
    end
    return NamedTuple{Tuple(names)}(profiles)
end

# Output profiles inherit only the classifications of their declared source Port.
function telemetry_metadata_ports(names, input_names, sources; required = NamedTuple())
    inputs = telemetry_metadata_ports(input_names; required)
    optional = NamedTuple{Tuple(names)}(
        map(Tuple(sources)) do index
            iszero(index) && return ()
            return Tuple(
                PipeWireAO.MetadataRequirement(r.type, r.size) for
                r in getproperty(inputs, input_names[index]).metadata
            )
        end,
    )
    return telemetry_metadata_ports(names; optional)
end

"""
    reference_clock_configuration([value])

Parse `"realtime"` or `"tai"` as the corresponding clock symbol. Omit `value`
or pass `nothing` to select `:realtime`.
"""
reference_clock_configuration() = reference_clock_configuration(nothing)
reference_clock_configuration(::Nothing) = :realtime
function reference_clock_configuration(value::AbstractString)
    value in ("realtime", "tai") ||
        throw(ArgumentError("reference_clock must select realtime or tai"))
    return Symbol(value)
end
reference_clock_configuration(value) =
    throw(ArgumentError("reference_clock must select realtime or tai"))

"""
    prepare_reference_clock(options)

Return the PipeWire metadata clock for `options.reference_clock`. The default is
`:realtime`. A selection other than `:realtime` or `:tai` throws `ArgumentError`.
"""
function prepare_reference_clock(options)
    clock = get(options, :reference_clock, :realtime)
    clock in (:realtime, :tai) || throw(ArgumentError("unsupported reference clock"))
    return clock === :realtime ? PipeWireAO.METADATA_CLOCK_REALTIME :
           PipeWireAO.METADATA_CLOCK_TAI
end

"""
    read_yaml(path; maximum=1024 * 1024)

Read a single bounded YAML configuration, rejecting duplicate mapping keys.
"""
function read_yaml(path::AbstractString; maximum::Integer = 1024 * 1024)
    maximum >= 0 || throw(ArgumentError("negative YAML size bound"))
    isfile(path) && filesize(path) <= maximum ||
        throw(ArgumentError("YAML input exceeds size bound or is missing: $path"))
    function mapping(constructor, node)
        explicit = Set{String}()
        merge_seen = false
        for (key, _) in node.value
            if key.tag == "tag:yaml.org,2002:merge"
                merge_seen && throw(ArgumentError("duplicate YAML merge key"))
                merge_seen = true
                continue
            end
            name = YAML.construct_object(constructor, key)
            json_key(name) ||
                throw(ArgumentError("YAML configuration keys must be strings"))
            name in explicit && throw(ArgumentError("duplicate YAML key: $name"))
            push!(explicit, name)
        end
        return YAML.construct_mapping(
            Dict{String,Any}, constructor, node; strict_unique_keys = true
        )
    end
    constructors = Dict("tag:yaml.org,2002:map" => mapping)
    payload = open(path, "r") do io
        read(io, maximum + 1)
    end
    length(payload) <= maximum ||
        throw(ArgumentError("YAML input grew beyond size bound: $path"))
    documents = collect(YAML.load_all(IOBuffer(payload), constructors))
    length(documents) == 1 ||
        throw(ArgumentError("YAML configuration requires exactly one document: $path"))
    return yaml_configuration(only(documents))
end
yaml_configuration(value::AbstractDict) = value
yaml_configuration(value) =
    throw(ArgumentError("YAML configuration requires a root mapping"))

# JSON.jl preserves decimal tokens and materializes large integers exactly.
# Bound its general-purpose numeric range to the existing operational contract.
json_number(value) = value
function json_number(value::BigInt)
    typemin(Int64) <= value <= typemax(Int64) && return Int64(value)
    0 <= value <= typemax(UInt64) && return UInt64(value)
    throw(ArgumentError("JSON integer exceeds supported 64-bit range"))
end
function json_number(value::AbstractFloat)
    converted = Float64(value)
    isfinite(converted) || throw(ArgumentError("JSON contains a nonfinite number"))
    return converted
end
function json_number(value::AbstractDict)
    return Dict{String,Any}(key => json_number(item) for (key, item) in value)
end
json_number(value::AbstractVector) = Any[json_number(item) for item in value]

"""
    parse_json(payload)

Read bounded JSON with exact 64-bit integer identities and distinct decimal values.
"""
function parse_json(payload::AbstractString)
    isvalid(payload) || throw(ArgumentError("JSON input is not UTF-8"))
    token = strip(payload, [' ', '\t', '\n', '\r'])
    isempty(token) && throw(ArgumentError("empty JSON input"))
    # The operational interface accepts JSON ASCII whitespace, without a BOM.
    first(token) in ('{', '[', '"', 't', 'f', 'n', '-', '0':'9'...) ||
        throw(ArgumentError("invalid JSON input"))
    value = JSON.parse(token; dicttype = Dict{String,Any}, maxdepth = 64)
    return json_number(value)
end

# Sealed instrument arrays are tuples, sometimes with thousands of entries.
# JSON's generated tuple writer compiles one operation per entry. Lower only
# this immutable tree before writing; retain named-field order and let JSON
# handle all other values (including scalar lowering and multidimensional arrays).
Base.@nospecializeinfer function metadata_json_items(@nospecialize(value))
    items = Vector{Any}(undef, length(value))
    for index in eachindex(items)
        items[index] = metadata_json_value(getfield(value, index))
    end
    return items
end
Base.@nospecializeinfer metadata_json_value(@nospecialize(value)) = value
Base.@nospecializeinfer metadata_json_value(@nospecialize(value::Tuple)) =
    metadata_json_items(value)
Base.@nospecializeinfer metadata_json_value(@nospecialize(value::NamedTuple)) =
    NamedTuple{keys(value)}(Tuple(metadata_json_items(value)))

metadata_json(@nospecialize(value)) = JSON.json(metadata_json_value(value))

finite_json(value) = value
function finite_json(value::AbstractFloat)
    isfinite(value) || throw(ArgumentError("JSON contains a nonfinite number"))
    return value
end
json_key(::AbstractString) = true
json_key(_) = false
function finite_json(value::AbstractDict)
    all(json_key, keys(value)) || throw(ArgumentError("JSON object keys must be strings"))
    foreach(finite_json, values(value))
    return value
end
function finite_json(value::NamedTuple)
    for item in values(value)
        finite_json(item)
    end
    return value
end
function finite_json(value::Union{AbstractVector,Tuple})
    for item in value
        finite_json(item)
    end
    return value
end

"""
    read_json(path; maximum=16 * 1024 * 1024)

Read a bounded JSON file and preserve exact integer identities. The size limit is in bytes.
"""
function read_json(path::AbstractString; maximum::Integer = 16 * 1024 * 1024)
    maximum >= 0 || throw(ArgumentError("negative JSON size bound"))
    isfile(path) || throw(ArgumentError("JSON input must be a regular file: $path"))
    filesize(path) <= maximum ||
        throw(ArgumentError("JSON input exceeds size bound: $path"))
    payload = open(path) do io
        read(io, maximum + 1)
    end
    length(payload) <= maximum ||
        throw(ArgumentError("JSON input grew beyond size bound: $path"))
    return parse_json(String(payload))
end

"""
    write_json(path, value; atomic=false)

Write a JSON value to `path`. With `atomic=true`, replace the target after writing a
temporary file in the same directory.
"""
function write_json(path::AbstractString, value; atomic::Bool = false)
    finite_json(value)
    payload = JSON.json(value) * "\n"
    mkpath(dirname(path))
    if atomic
        temporary, io = mktemp(dirname(path))
        try
            write(io, payload)
            close(io)
            mv(temporary, path; force = true)
        finally
            isopen(io) && close(io)
            ispath(temporary) && rm(temporary)
        end
    else
        write(path, payload)
    end
    return path
end

# YAML.jl writes unknown scalar types through `string`. Keep its scalar quoting
# and numeric spelling, while supplying flow syntax only for validated numbers.
struct NumericSequence
    text::String
end
Base.print(io::IO, value::NumericSequence) = print(io, value.text)

yaml_value(value) = value
yaml_value(value::AbstractDict) = Dict(key => yaml_value(item) for (key, item) in value)
yaml_numeric_scalar(value) = nothing
yaml_numeric_scalar(value::Bool) = nothing
yaml_numeric_scalar(value::Union{Integer,AbstractFloat}) = chomp(YAML.write(value))
function yaml_value(value::AbstractVector)
    if 1 <= length(value) <= 8
        scalars = map(yaml_numeric_scalar, value)
        if all(!isnothing, scalars)
            text = "[" * join(scalars, ", ") * "]"
            length(text) <= 80 && return NumericSequence(text)
        end
    end
    return map(yaml_value, value)
end

"Keep a generated-file label even when a caller supplies additional provenance."
generated_header() = generated_header(nothing)
generated_header(::Nothing) = "Generated by PipeWireAORTC."
generated_header(header) =
    throw(ArgumentError("generated-file header must be valid text without NUL"))
function generated_header(header::AbstractString)
    standard = "Generated by PipeWireAORTC."
    isvalid(header) && !occursin('\0', header) ||
        throw(ArgumentError("generated-file header must be valid text without NUL"))
    text = replace(String(header), "\r\n" => "\n", "\r" => "\n")
    isempty(text) && return standard
    return occursin(r"(?i)^generated\b", text) ? text : standard * "\n" * text
end

"""
    write_yaml(path, value; atomic=false, header=nothing)

Write YAML configuration with a generated-file header, optionally atomically.

Numeric vectors of at most eight elements and 80 characters use inline arrays;
nested coordinate rows are kept as separate pairs. Longer vectors use block lists.
"""
function write_yaml(path::AbstractString, value; atomic::Bool = false, header = nothing)
    finite_json(value)
    payload = IOBuffer()
    for line in split(generated_header(header), '\n')
        println(payload, "# ", line)
    end
    YAML.write(payload, yaml_value(value))
    bytes = take!(payload)
    mkpath(dirname(path))
    if atomic
        temporary, io = mktemp(dirname(path))
        try
            write(io, bytes)
            close(io)
            mv(temporary, path; force = true)
        finally
            isopen(io) && close(io)
            ispath(temporary) && rm(temporary)
        end
    else
        write(path, bytes)
    end
    return path
end

"""
    sha256_file(path)

Return the lowercase hexadecimal SHA-256 checksum of the file at `path`.
"""
sha256_file(path::AbstractString) = open(io -> bytes2hex(SHA.sha256(io)), path)

"""
    cli_arguments(argv=ARGS; flags=String[], repeats=String[], required=String[],
                  defaults=NamedTuple(), positional=String[], allowed=String[])

Parse named command-line options and switches into a named tuple.
The caller validates option-specific values.
"""
function cli_arguments(
    argv = ARGS;
    flags = String[],
    repeats = String[],
    required = String[],
    defaults = NamedTuple(),
    positional = String[],
    allowed = String[],
)
    option_name(value) = Symbol(replace(String(value), "-" => "_"))
    values = Dict{Symbol,Any}(pairs(defaults))
    flag_names = Set(option_name.(flags))
    repeated_names = Set(option_name.(repeats))
    admitted = union(
        flag_names,
        repeated_names,
        Set(option_name.(required)),
        Set(option_name.(allowed)),
        Set(keys(defaults)),
    )
    seen = Set{Symbol}()
    positional_index = 1
    index = 1
    while index <= length(argv)
        argument = argv[index]
        if startswith(argument, "--")
            parts = split(argument[3:end], '='; limit = 2)
            isempty(parts[1]) && throw(ArgumentError("empty option name"))
            key = option_name(parts[1])
            isempty(admitted) ||
                key in admitted ||
                throw(ArgumentError("unknown option --$(parts[1])"))
            key in seen &&
                !(key in repeated_names) &&
                throw(ArgumentError("duplicate option $argument"))
            push!(seen, key)
            if key in flag_names
                length(parts) == 1 || throw(ArgumentError("flag $argument takes no value"))
                values[key] = true
            else
                if length(parts) == 2
                    value = parts[2]
                else
                    index += 1
                    index <= length(argv) && !startswith(argv[index], "--") ||
                        throw(ArgumentError("option $argument requires a value"))
                    value = argv[index]
                end
                if key in repeated_names
                    push!(get!(values, key, String[]), value)
                else
                    values[key] = value
                end
            end
        else
            positional_index <= length(positional) ||
                throw(ArgumentError("unexpected positional argument $argument"))
            values[option_name(positional[positional_index])] = argument
            positional_index += 1
        end
        index += 1
    end
    for flag in flag_names
        get!(values, flag, false)
    end
    for name in required
        haskey(values, option_name(name)) || throw(ArgumentError("missing --$name"))
    end
    return (; (key => value for (key, value) in values)...)
end

prepare_command(argv::Cmd) = argv
prepare_command(argv) = Cmd(String.(argv))

"""
    run_checked(argv; env=Dict(), timeout=30, cwd=nothing,
                stdout_path=nothing, stderr_path=nothing, maximum_output_bytes=16 * 1024 * 1024)

Run a subprocess under a deadline in seconds and return its stdout, stderr and exit status.
Apply `env` to the child and bound the captured output in bytes.
"""
function run_checked(
    argv;
    env = Dict{String,String}(),
    timeout::Real = 30,
    cwd = nothing,
    stdout_path = nothing,
    stderr_path = nothing,
    maximum_output_bytes::Integer = 16 * 1024 * 1024,
)
    isfinite(timeout) && timeout > 0 ||
        throw(ArgumentError("process timeout must be positive and finite"))
    maximum_output_bytes > 0 ||
        throw(ArgumentError("process output bound must be positive"))
    command = prepare_command(argv)
    cwd === nothing || (command = Cmd(command; dir = String(cwd)))
    command = addenv(
        command, (String(key) => String(value) for (key, value) in pairs(env))...
    )
    return mktempdir() do directory
        out_path =
            stdout_path === nothing ? joinpath(directory, "stdout") : String(stdout_path)
        err_path =
            stderr_path === nothing ? joinpath(directory, "stderr") : String(stderr_path)
        mkpath(dirname(out_path))
        mkpath(dirname(err_path))
        process = nothing
        open(out_path, "w") do out
            open(err_path, "w") do err
                process = run(
                    pipeline(ignorestatus(command); stdout = out, stderr = err);
                    wait = false,
                )
                try
                    state = timedwait(
                        timeout; pollint = clamp(timeout / 10, 0.001, 0.01)
                    ) do
                        filesize(out_path) <= maximum_output_bytes &&
                        filesize(err_path) <= maximum_output_bytes ||
                            throw(ArgumentError("subprocess output exceeds bound"))
                        process_exited(process)
                    end
                    state == :ok || throw(
                        ErrorException("subprocess exceeded $(timeout) second deadline")
                    )
                    wait(process)
                finally
                    if !process_exited(process)
                        kill(process, Base.SIGTERM)
                        timedwait(() -> process_exited(process), 1; pollint = 0.01) ==
                        :ok || kill(process, Base.SIGKILL)
                        wait(process)
                    end
                end
            end
        end
        filesize(out_path) <= maximum_output_bytes &&
        filesize(err_path) <= maximum_output_bytes ||
            throw(ArgumentError("subprocess output exceeds bound"))
        return (
            stdout = read(out_path, String),
            stderr = read(err_path, String),
            returncode = process.exitcode,
        )
    end
end

include("configuration/references.jl")

end
