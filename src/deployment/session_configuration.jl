# Cold session references use the same JSON Pointer contract as graph authoring.
# Scientific owners supply metadata; the session keeps its schemas and policies.

"Return the prepared JFG boundary's shape and wire element type, without binding artifacts."
function graph_port_contracts end

"Return the simulator observation owner's cold port contracts for selected settings."
function simulator_port_contracts end

# PipeWireAO exposes the wire enum, but no public Julia-type conversion. Keep this
# serialization boundary explicit, including Bool's distinct representation.
wire_element_type(::Type{Bool}) = string(PipeWireAO.NdArray.BOOL8)
wire_element_type(::Type{Int8}) = string(PipeWireAO.NdArray.I8)
wire_element_type(::Type{UInt8}) = string(PipeWireAO.NdArray.U8)
wire_element_type(::Type{Int16}) = string(PipeWireAO.NdArray.I16_LE)
wire_element_type(::Type{UInt16}) = string(PipeWireAO.NdArray.U16_LE)
wire_element_type(::Type{Int32}) = string(PipeWireAO.NdArray.I32_LE)
wire_element_type(::Type{UInt32}) = string(PipeWireAO.NdArray.U32_LE)
wire_element_type(::Type{Int64}) = string(PipeWireAO.NdArray.I64_LE)
wire_element_type(::Type{UInt64}) = string(PipeWireAO.NdArray.U64_LE)
wire_element_type(::Type{Float32}) = string(PipeWireAO.NdArray.F32_LE)
wire_element_type(::Type{Float64}) = string(PipeWireAO.NdArray.F64_LE)
wire_element_type(::Type{T}) where {T} =
    throw(ArgumentError("unsupported session ndarray element type $T"))

function port_contract(format)
    return Dict("shape" => collect(Int, format.shape),
        "element-type" => wire_element_type(format.element_type))
end

function reference_roots!(roots, value::AbstractDict)
    if haskey(value, "\$ref")
        pointer = graph_reference_pointer(value)
        parts = split(pointer, '/'; keepempty=true)
        push!(roots, length(parts) > 1 ? parts[2] : "")
    else
        for item in values(value)
            reference_roots!(roots, item)
        end
    end
    return roots
end
function reference_roots!(roots, value::AbstractVector)
    for item in value
        reference_roots!(roots, item)
    end
    return roots
end
reference_roots!(roots, value) = roots

function graph_contract_context(application, declarations, prefix)
    Base.require(Main, :FilterGraphIsland)
    result = Dict{String,Any}()
    for entry in declarations
        path = D.relative_asset(application, entry["path"])
        declaration = D.decode(path, prefix)
        name = declaration["node.name"]
        haskey(result, name) && throw(ArgumentError("duplicate graph contract node name: $name"))
        contracts = Base.invokelatest(graph_port_contracts, path)
        for ports in values(contracts), contract in values(ports)
            contract["element-count"] = foldl(Base.checked_mul, contract["shape"]; init=1)
        end
        result[name] = contracts
    end
    return result
end

"Resolve references across the composed session and core before validation and sealing."
function prepare_session_configuration!(application, spec, declarations, instrumentpath, prefix;
        dimensions::AbstractDict=Dict(), mirror_controls::AbstractDict=Dict(), configurations=[])
    files = [map(("session", "core")) do field
        path = D.relative_asset(application, spec[field])
        (; path, format="spa-json", document=D.decode(path, prefix))
    end...]
    InstrumentDefinition.array_value(configurations) ||
        throw(ArgumentError("configuration-files must be an array"))
    paths = Set(entry.path for entry in files)
    for declaration in configurations
        InstrumentDefinition.object_value(declaration) &&
            Set(keys(declaration)) == Set(["path", "format"]) ||
            throw(ArgumentError("configuration-files entries require path and format"))
        path = D.relative_asset(application, declaration["path"])
        path in paths && throw(ArgumentError("duplicate configuration file: $path"))
        push!(paths, path)
        format = declaration["format"]
        document = read_configuration(path, format, prefix)
        push!(files, (; path, format, document))
    end
    roots = Set{String}()
    for entry in files
        reference_roots!(roots, entry.document)
    end
    if isempty(roots)
        foreach(entry -> Schemas.validate(entry.document), files)
        return nothing
    end
    instrument = Common.read_json(D.relative_asset(application, instrumentpath))
    context = graph_context(instrument; dimensions, mirror_controls)
    if "graphs" in roots
        context["graphs"] = graph_contract_context(application, declarations, prefix)
    end
    if "simulator" in roots
        Base.require(Main, :AdaptiveOpticsSim)
        Base.require(Main, :AdaptiveOpticsSimPipeWireHIL)
        simulation = D.decode(D.relative_asset(application, "simulation.conf"), prefix)
        plant = simulation["plant"]
        definition = D.relative_asset(application, plant["definition"])
        context["simulator"] = Base.invokelatest(simulator_port_contracts, definition;
            settings=get(plant, "settings", Dict()))
    end
    # Resolve every document first so a bad reference cannot partly rewrite it.
    prepared = map(files) do entry
        document = graph_configuration_value(entry.document, context)
        Schemas.validate(document)
        (; entry.path, entry.format, document)
    end
    header = "Generated by PipeWireAORTC from the instrument, prepared graph contracts and selected simulator settings; do not edit.\nEdit the instrument source and rebuild."
    for entry in prepared
        write_configuration(entry.path, entry.format, entry.document; header)
    end
    return nothing
end

function read_configuration(path, format, prefix)
    format == "spa-json" && return D.decode(path, prefix)
    format == "yaml" && return Common.read_yaml(path)
    throw(ArgumentError("unsupported configuration file format: $format"))
end

function write_configuration(path, format, document; header)
    format == "spa-json" && return ScienceExport.write_spa_config(path, document; header)
    format == "yaml" || throw(ArgumentError("unsupported configuration file format: $format"))
    payload = YAML.write(document)
    write(path, join(("# " * line for line in split(header, '\n')), '\n') * "\n" * payload)
    return path
end
