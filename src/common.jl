module Common

using JSON3
using SHA
using StructTypes

export read_json, parse_json, write_json, sha256_file, cli_arguments, run_checked

struct RawJSON
    text::String
end
StructTypes.StructType(::Type{RawJSON}) = JSON3.RawType()
StructTypes.construct(::Type{RawJSON}, raw::JSON3.RawValue) =
    RawJSON(String(copy(@view raw.bytes[raw.pos:raw.pos + raw.len - 1])))

"""Read JSON without rounding integer identities or treating decimal tokens as integers."""
function parse_json(payload::AbstractString; depth::Int=0)
    depth <= 64 || throw(ArgumentError("JSON nesting exceeds 64 levels"))
    token = strip(payload, [' ', '\t', '\n', '\r'])
    isempty(token) && throw(ArgumentError("empty JSON input"))
    if depth == 0
        JSON3.read(token, RawJSON).text == token ||
            throw(ArgumentError("JSON input has trailing data"))
    end
    if startswith(token, "{")
        raw = JSON3.read(token, Dict{String,RawJSON})
        return Dict{String,Any}(key => parse_json(value.text; depth=depth+1) for (key,value) in raw)
    elseif startswith(token, "[")
        raw = JSON3.read(token, Vector{RawJSON})
        return Any[parse_json(value.text; depth=depth+1) for value in raw]
    elseif occursin(r"^-?(?:0|[1-9][0-9]*)$", token)
        signed = tryparse(Int64, token)
        signed !== nothing && return signed
        unsigned = tryparse(UInt64, token)
        unsigned !== nothing && return unsigned
        throw(ArgumentError("JSON integer exceeds supported 64-bit range"))
    elseif first(token) in ('-', '0':'9'...)
        occursin(r"^-?(?:0|[1-9][0-9]*)(?:\.[0-9]+)?(?:[eE][+-]?[0-9]+)?$", token) ||
            throw(ArgumentError("invalid JSON number"))
        JSON3.read(token) # Validate JSON number grammar before conversion.
        value = parse(Float64, token)
        return finite_json(value)
    end
    startswith(token, "\"") && return JSON3.read(token, String)
    token == "true" && return true
    token == "false" && return false
    token == "null" && return nothing
    throw(ArgumentError("invalid JSON scalar"))
end

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
    foreach(finite_json, values(value))
    return value
end
function finite_json(value::Union{AbstractVector,Tuple})
    foreach(finite_json, value)
    return value
end

function read_json(path::AbstractString; maximum::Integer=16 * 1024 * 1024)
    maximum >= 0 || throw(ArgumentError("negative JSON size bound"))
    isfile(path) || throw(ArgumentError("JSON input must be a regular file: $path"))
    filesize(path) <= maximum || throw(ArgumentError("JSON input exceeds size bound: $path"))
    payload = open(path) do io
        read(io, maximum + 1)
    end
    length(payload) <= maximum || throw(ArgumentError("JSON input grew beyond size bound: $path"))
    return parse_json(String(payload))
end

function write_json(path::AbstractString, value; atomic::Bool=false)
    finite_json(value)
    payload = JSON3.write(value) * "\n"
    mkpath(dirname(path))
    if atomic
        temporary, io = mktemp(dirname(path))
        try
            write(io, payload)
            close(io)
            mv(temporary, path; force=true)
        finally
            isopen(io) && close(io)
            ispath(temporary) && rm(temporary)
        end
    else
        write(path, payload)
    end
    return path
end

sha256_file(path::AbstractString) = open(io -> bytes2hex(SHA.sha256(io)), path)

"""Parse a thin CLI; option-specific numeric and semantic validation stays with its owner."""
function cli_arguments(argv=ARGS; flags=String[], repeats=String[], required=String[],
                       defaults=NamedTuple(), positional=String[], allowed=String[])
    option_name(value) = Symbol(replace(String(value), "-" => "_"))
    values = Dict{Symbol,Any}(pairs(defaults))
    flag_names = Set(option_name.(flags))
    repeated_names = Set(option_name.(repeats))
    admitted = union(flag_names, repeated_names, Set(option_name.(required)),
                     Set(option_name.(allowed)), Set(keys(defaults)))
    seen = Set{Symbol}()
    positional_index = 1
    index = 1
    while index <= length(argv)
        argument = argv[index]
        if startswith(argument, "--")
            parts = split(argument[3:end], '='; limit=2)
            isempty(parts[1]) && throw(ArgumentError("empty option name"))
            key = option_name(parts[1])
            isempty(admitted) || key in admitted || throw(ArgumentError("unknown option --$(parts[1])"))
            key in seen && !(key in repeated_names) && throw(ArgumentError("duplicate option $argument"))
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

"""Run cold preparation under a deadline, collecting bounded stdout and stderr."""
prepare_command(argv::Cmd) = argv
prepare_command(argv) = Cmd(String.(argv))

function run_checked(argv; env=Dict{String,String}(), timeout::Real=30,
                     cwd=nothing, stdout_path=nothing, stderr_path=nothing,
                     maximum_output_bytes::Integer=16 * 1024 * 1024)
    isfinite(timeout) && timeout > 0 || throw(ArgumentError("process timeout must be positive and finite"))
    maximum_output_bytes > 0 || throw(ArgumentError("process output bound must be positive"))
    command = prepare_command(argv)
    cwd === nothing || (command = Cmd(command; dir=String(cwd)))
    command = addenv(command, (String(key) => String(value) for (key, value) in pairs(env))...)
    return mktempdir() do directory
        out_path = stdout_path === nothing ? joinpath(directory, "stdout") : String(stdout_path)
        err_path = stderr_path === nothing ? joinpath(directory, "stderr") : String(stderr_path)
        mkpath(dirname(out_path)); mkpath(dirname(err_path))
        process = nothing
        open(out_path, "w") do out
            open(err_path, "w") do err
                process = run(pipeline(ignorestatus(command); stdout=out, stderr=err); wait=false)
                try
                    state = timedwait(timeout; pollint=min(0.01, timeout / 10)) do
                        filesize(out_path) <= maximum_output_bytes && filesize(err_path) <= maximum_output_bytes ||
                            throw(ArgumentError("subprocess output exceeds bound"))
                        process_exited(process)
                    end
                    state == :ok || throw(ErrorException("subprocess exceeded $(timeout) second deadline"))
                    wait(process)
                finally
                    if !process_exited(process)
                        kill(process, Base.SIGTERM)
                        timedwait(() -> process_exited(process), 1; pollint=0.01) == :ok || kill(process, Base.SIGKILL)
                        wait(process)
                    end
                end
            end
        end
        filesize(out_path) <= maximum_output_bytes && filesize(err_path) <= maximum_output_bytes ||
            throw(ArgumentError("subprocess output exceeds bound"))
        return (stdout=read(out_path, String), stderr=read(err_path, String), returncode=process.exitcode)
    end
end

end
