module ScienceExport

using JSON3
using SHA
using ..Common

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
function copy_file(source::AbstractString, destination::AbstractString)
    isfile(source) && !islink(source) || throw(ArgumentError("missing or symlinked export prerequisite: $source"))
    mkpath(dirname(destination))
    cp(source, destination; force=true, follow_symlinks=true)
    return destination
end
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

function copy_tree(source::AbstractString, destination::AbstractString; ignored=Set{String}())
    isdir(source) && !islink(source) || throw(ArgumentError("missing or symlinked export directory: $source"))
    !ispath(destination) || throw(ArgumentError("export destination exists: $destination"))
    mkpath(destination)
    for name in readdir(source)
        name in ignored && continue
        from, to = joinpath(source, name), joinpath(destination, name)
        islink(from) && throw(ArgumentError("symlink in export source: $from"))
        if isdir(from)
            copy_tree(from, to; ignored)
        elseif isfile(from)
            copy_file(from, to)
        end
    end
    return destination
end

function copy_deployment_runtime(package::AbstractString; copy_service=true)
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
    copy_tree(package_root(), target; ignored)
    union!(ignored, Set(name for name in readdir(joinpath(resource_root(), "hil"))
        if startswith(name, "test_") || endswith(name, ".py")))
    for directory in ("templates", "hil")
        destination = joinpath(target, "assets", "deployment", directory)
        ispath(destination) && rm(destination; recursive=true, force=true)
        copy_tree(joinpath(resource_root(), directory), destination; ignored)
    end
    for name in readdir(resource_root())
        endswith(name, ".jl") && !startswith(name, "test_") || continue
        copy_file(joinpath(resource_root(), name), joinpath(target, "assets", "deployment", name))
    end
    service_source = joinpath(resource_root(), "pipewireao-rtc@.service.in")
    copy_file(service_source, joinpath(target, "assets/deployment/pipewireao-rtc@.service.in"))
    copy_service && copy_file(service_source, joinpath(package, "pipewireao-rtc@.service.in"))
    owner_service = joinpath(resource_root(), "pipewireao-rtc-systemd@.service.in")
    isfile(owner_service) && copy_file(owner_service,
        joinpath(target, "assets/deployment/pipewireao-rtc-systemd@.service.in"))
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

function classic_parameters()
    return Parameter[
        Parameter("background", "pixel-calibration:background", "F32_LE", [352,352], "background.f32le"),
        Parameter("subaperture-origins", "shack-hartmann:subaperture-origins", "U32_LE", [188,2], "subaperture-origins.u32le"),
        Parameter("coordinates", "shack-hartmann:coordinates", "F32_LE", [484,2], "shack-hartmann-coordinates.f32le"),
        Parameter("reference-slopes", "shack-hartmann:reference-slopes", "F32_LE", [188,2], "reference-slopes.f32le"),
        Parameter("thresholds", "shack-hartmann:thresholds", "F32_LE", [188,2], "thresholds.f32le"),
        Parameter("active", "shack-hartmann:active", "Bool", [188], "active-subapertures.u8"),
        Parameter("reconstructor", "reconstruction:reconstructor", "F32_LE", [221,376], "reconstructor.f32le", "org.calculon.ao.shwfs-reconstructor/1"),
        Parameter("controller-to-vdm", "controller-to-vdm:controller-to-vdm", "F32_LE", [221,221], "controller-to-vdm.f32le"),
        Parameter("active-to-full", "vdm-to-pdm:active-to-full", "F32_LE", [277,221], "active-to-full-vdm.f32le"),
        Parameter("vdm-to-pdm", "vdm-to-pdm:vdm-to-pdm", "F32_LE", [277,277], "vdm-to-pdm.f32le"),
        Parameter("full-to-active", "pdm-feedback-to-vdm:full-to-active", "F32_LE", [221,277], "full-to-active-vdm.f32le"),
        Parameter("pdm-to-vdm", "pdm-feedback-to-vdm:pdm-to-vdm", "F32_LE", [277,277], "pdm-to-vdm.f32le"),
        Parameter("vdm-to-controller", "vdm-feedback-to-controller:vdm-to-controller", "F32_LE", [221,221], "vdm-to-controller.f32le")
    ]
end

function port(name, direction, shape, schema, element_type="F32_LE"; parameter=false, rate=nothing)
    value = Dict{String,Any}("name" => name, "direction" => direction, "element-type" => element_type,
                             "shape" => collect(shape), "schema" => schema)
    parameter && (value["parameter"] = true)
    rate === nothing || (value["rate"] = rate isa Integer ? "$rate/1" : rate)
    return value
end

function placement(cpus, fifo_cpus; julia=false)
    threads = [Dict("cpus" => [cpu], "policy" => "fifo", "priority" => 83, "count" => 1) for cpu in fifo_cpus]
    julia && push!(threads, Dict("cpus" => [10], "policy" => "other", "priority" => 0, "count" => 1))
    return Dict("cpus" => collect(cpus), "leader-cpu" => 14, "rt-priority" => 83,
                "threads" => threads, "locked-bytes" => 0)
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

end # module
