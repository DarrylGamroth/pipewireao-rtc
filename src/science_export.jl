module ScienceExport

using JSON3
using SHA
using ..Common
import ..RuntimeExport: copy_file, copy_tree, copy_entries

import ..package_root, ..resource_root, ..source_relative_path
const RAW_SCHEMA = "org.calculon.ao.raw-detector-pixels/1"
const ROW_SCHEMA = "org.calculon.ao.raw-pixel-row-block/1"
const COMMAND_SCHEMA = "org.calculon.ao.demanded-pdm-command/1"
const TYPE_BYTES = Dict("F32_LE" => 4, "F64_LE" => 8, "U16_LE" => 2, "U32_LE" => 4, "U8" => 1, "Bool" => 1)
const JULIA_TYPES = Dict("F32_LE" => "Float32", "U16_LE" => "UInt16", "U32_LE" => "UInt32", "U8" => "UInt8", "Bool" => "Bool")

struct Parameter
    name::String
    endpoint::String
    element_type::String
    shape::Vector{Int}
    file::String
    schema::String
    function Parameter(name, endpoint, element_type, shape, file, schema)
        new(String(name), String(endpoint), String(element_type), Int[shape...], String(file), String(schema))
    end
end
Parameter(name, endpoint, element_type, shape, file) = Parameter(String(name), String(endpoint), String(element_type), Int[shape...], String(file), "")
Parameter(item::AbstractDict) = Parameter(item["name"], item["endpoint"], item["element_type"], item["shape"], item["file"], get(item, "schema", ""))
parameter_dict(p::Parameter) = Dict{String,Any}("name" => p.name, "endpoint" => p.endpoint, "element_type" => p.element_type, "shape" => p.shape, "file" => p.file, "schema" => p.schema)

sha256(path::AbstractString) = Common.sha256_file(path)
write_json(path::AbstractString, value) = Common.write_json(path, value)

"""Write native PipeWire SPA configuration with object-array delimiters on separate lines."""
function write_spa_config(path::AbstractString, value)
    Common.finite_json(value)
    io = IOBuffer()
    JSON3.pretty(io, value, JSON3.AlignmentContext(indent=2))
    payload = String(take!(io)) * "\n"
    Common.parse_json(payload) == value ||
        throw(ArgumentError("SPA configuration changed during JSON serialization"))
    mkpath(dirname(path))
    write(path, payload)
    return path
end

# Shared operational closure; instrument projects export their own sources.
const RUNTIME_ENTRIES = (
    "Project.toml", "Manifest.toml", "src", "test",
    "wireplumber_cli.jl", "wireplumber_launch.jl",
    "wireplumber_configuration.jl", "wireplumber_install.jl",
)
const RESOURCE_ENTRYPOINTS = ()

function copy_deployment_runtime(package::AbstractString)
    # Export a new package without carrying a previous coordinator launcher
    # or service template forward from a sealed input package.
    for relative in ("pipewireao-rtc@.service.in",
                     "pipewireao-rtc-systemd@.service.in",
                     "bin/pipewireao-rtc-deploy", "bin/pipewireao-rtc",
                     "bin/pipewireao-rtc@.service.in",
                     "bin/pipewireao-rtc-systemd@.service.in",
                     "bin/placement.py")
        obsolete = joinpath(package, relative)
        (ispath(obsolete) || islink(obsolete)) && rm(obsolete; force=true)
    end
    target = abspath(joinpath(package, "julia"))
    ancestor = target
    while !ispath(ancestor)
        ancestor = dirname(ancestor)
    end
    outside(relative) = relative == ".." || startswith(relative, ".." * string(Base.Filesystem.path_separator))
    for directory in (package_root(), joinpath(resource_root(), "hil"), joinpath(resource_root(), "templates"))
        source = realpath(directory)
        outside(relpath(realpath(ancestor), source)) &&
            (!ispath(target) || outside(relpath(source, realpath(target)))) ||
            throw(ArgumentError("deployment runtime destination must not overlap copied source: $directory"))
    end
    ispath(target) && rm(target; recursive=true, force=true)
    ignored = Set(["__pycache__", ".git"])
    copy_entries(package_root(), target, RUNTIME_ENTRIES; ignored)
    union!(ignored, Set(name for name in readdir(joinpath(resource_root(), "hil"))
        if startswith(name, "test_") || endswith(name, ".py")))
    for directory in ("templates", "hil")
        destination = joinpath(target, "assets", "deployment", directory)
        ispath(destination) && rm(destination; recursive=true, force=true)
        copy_tree(joinpath(resource_root(), directory), destination; ignored)
    end
    for name in RESOURCE_ENTRYPOINTS
        copy_file(joinpath(resource_root(), name), joinpath(target, "assets", "deployment", name))
    end
    session_service = joinpath(resource_root(), "pipewireao-session@.service.in")
    copy_file(session_service,
        joinpath(target, "assets/deployment/pipewireao-session@.service.in"))
    return target
end

function payload_bytes(shape, width::Integer)
    width > 0 || throw(ArgumentError("element width must be positive"))
    count = BigInt(width)
    isempty(shape) && throw(ArgumentError("payload shape must not be empty"))
    for dimension in shape
        dimension isa Integer && !(dimension isa Bool) && dimension > 0 ||
            throw(ArgumentError("payload dimensions must be positive integers"))
        count *= dimension
        count <= typemax(Int) || throw(ArgumentError("payload shape exceeds addressable size"))
    end
    return Int(count)
end

function validate_parameter(directory::AbstractString, p::Parameter)
    width = get(TYPE_BYTES, p.element_type, nothing)
    width === nothing && throw(ArgumentError("unsupported parameter type: $(p.element_type)"))
    all(x -> x > 0, p.shape) || throw(ArgumentError("parameter shape must be positive: $(p.name)"))
    path = joinpath(directory, p.file)
    expected = payload_bytes(p.shape, width)
    isfile(path) && !islink(path) && filesize(path) == expected ||
        throw(ArgumentError("$(p.name) requires $expected bytes for $(p.element_type)$(p.shape): $path"))
    bytes = read(path)
    if p.element_type == "Bool"
        all(x -> x <= 0x01, bytes) || throw(ArgumentError("$(p.name) Bool payload requires zero/one bytes"))
    elseif p.element_type == "F32_LE"
        all(isfinite, reinterpret(Float32, bytes)) || throw(ArgumentError("nonfinite parameter payload: $path"))
    elseif p.element_type == "F64_LE"
        all(isfinite, reinterpret(Float64, bytes)) || throw(ArgumentError("nonfinite parameter payload: $path"))
    end
    return path
end

function port(name, direction, shape, schema, element_type="F32_LE"; parameter=false, rate=nothing)
    value = Dict{String,Any}("name" => name, "direction" => direction, "element-type" => element_type,
                             "shape" => collect(shape), "schema" => schema)
    parameter && (value["parameter"] = true)
    rate === nothing || (value["rate"] = rate isa Integer ? "$rate/1" : rate)
    return value
end

"Copy WirePlumber assets from an installed prefix or an explicit development build."
function stage_wireplumber!(package; build=nothing, source=nothing, prefix=nothing)
    (build === nothing) == (source === nothing) ||
        throw(ArgumentError("WirePlumber build and source must be supplied together"))
    target = joinpath(package, "wireplumber")
    if build !== nothing || prefix !== nothing
        if build !== nothing
            build, source = realpath(build), realpath(source)
            binary = joinpath(build, "src/wireplumber")
            library = realpath(joinpath(build, "lib/wp/libwireplumber-0.5.so.0"))
            modules = joinpath(build, "modules")
            scripts = joinpath(source, "src/scripts")
        else
            prefix = realpath(prefix)
            candidates = [joinpath(prefix, "lib"), joinpath(prefix, "lib64")]
            isdir(joinpath(prefix, "lib")) && append!(candidates,
                readdir(joinpath(prefix, "lib"); join=true))
            libraries = filter(path -> isfile(joinpath(path, "libwireplumber-0.5.so.0")), candidates)
            length(libraries) == 1 ||
                throw(ArgumentError("expected one installed WirePlumber library directory in $prefix"))
            directory = only(libraries)
            binary = joinpath(prefix, "bin/wireplumber")
            library = realpath(joinpath(directory, "libwireplumber-0.5.so.0"))
            modules = joinpath(directory, "wireplumber-0.5")
            scripts = joinpath(prefix, "share/wireplumber/scripts")
        end
        isfile(binary) && (stat(binary).mode & 0o111) != 0 ||
            throw(ArgumentError("selected WirePlumber runtime has no executable"))
        islink(target) && throw(ArgumentError("staged WirePlumber directory must not be a symlink"))
        temporary = mktempdir(package; prefix="wireplumber-stage-")
        try
            copy_tree(scripts, joinpath(temporary, "scripts"); ignored=Set(["tests", "test"]))
            copy_file(binary, joinpath(temporary, "bin/wireplumber"))
            chmod(joinpath(temporary, "bin/wireplumber"), stat(binary).mode & 0o777)
            copy_file(library, joinpath(temporary, "lib/wp/libwireplumber-0.5.so.0"))
            for name in ("libwireplumber-module-lua-scripting.so",
                         "libwireplumber-module-ao-control-endpoint.so")
                copy_file(joinpath(modules, name), joinpath(temporary, "modules", name))
            end
            validate_wireplumber(temporary)
            ispath(target) && rm(target; recursive=true)
            mv(temporary, target)
        finally
            ispath(temporary) && rm(temporary; recursive=true)
        end
    end
    validate_wireplumber(target)
    return target
end

function validate_wireplumber(target)
    for file in ("bin/wireplumber", "lib/wp/libwireplumber-0.5.so.0",
                 "modules/libwireplumber-module-lua-scripting.so",
                 "modules/libwireplumber-module-ao-control-endpoint.so",
                 "scripts/ao/session.lua", "scripts/lib/ao-control.lua",
                 "scripts/lib/ao-owner.lua", "scripts/lib/ao-acquisition.lua",
                 "scripts/lib/ao-session-control.lua", "scripts/lib/ao-connections.lua")
        path = joinpath(target, file)
        isfile(path) && !islink(path) ||
            throw(ArgumentError("sealed WirePlumber asset is missing: $file"))
    end
    (stat(joinpath(target, "bin/wireplumber")).mode & 0o111) != 0 ||
        throw(ArgumentError("sealed WirePlumber executable is not executable"))
    return nothing
end

function revision(root::AbstractString)
    try
        return strip(read(`git -C $root rev-parse HEAD`, String))
    catch
        return nothing
    end
end

# Initial scientist-authored recorded-input assets are accepted as sealed base
# packages by HILExport. Their development-only generator is outside this
# operational calibration migration; no generator process is launched here.

"""Hash this package's declared operational sources and resources."""
function orchestration_sources()
    files = String[]
    for relative in RUNTIME_ENTRIES
        relative == "test" && continue
        path = joinpath(package_root(), relative)
        if isfile(path)
            push!(files, path)
        elseif isdir(path)
            for (parent, dirs, names) in walkdir(path)
                any(name -> islink(joinpath(parent, name)), dirs) &&
                    throw(ArgumentError("linked operational source directory"))
                append!(files, joinpath.(Ref(parent), names))
            end
        else
            throw(ArgumentError("missing operational source: $relative"))
        end
    end
    for (parent, dirs, names) in walkdir(resource_root())
        any(name -> islink(joinpath(parent, name)), dirs) &&
            throw(ArgumentError("linked operational resource directory"))
        append!(files, joinpath.(Ref(parent), names))
    end
    all(path -> isfile(path) && !islink(path), files) ||
        throw(ArgumentError("missing or linked operational source"))
    return Dict(abspath(path) => sha256(path) for path in unique(files))
end

end # module
