# Included in Analysis. The optional graph publishes arrays; this one-shot
# observer copies completed results, then the control task registers artifacts.
struct CaptureProvenance
    acquisition_receipt_sha256::String
    graph_sha256::String
    fits_bindings_sha256::Union{Nothing,String}
    source_graph_sha256::String
    recipe_sha256::String
    calibration_identity::String
    operation::String
    reference_space::String
    source_stage::Union{Nothing,String}
    parameter_sha256::Dict{String,String}
    source_parameter_sha256::Dict{String,String}
end

function capture_provenance(value)
    fields=Set(String.(fieldnames(CaptureProvenance)))
    value isa AbstractDict && Set(keys(value))==fields ||
        throw(ArgumentError("capture provenance requires exact acquisition, graph, recipe, calibration, reference-space and parameter identities"))
    sha(x)=x isa String && occursin(r"^[0-9a-f]{64}$",x)
    text(x,limit)=x isa String && isvalid(x) && 0<ncodeunits(x)<=limit && !any(iscntrl,x)
    for key in ("acquisition_receipt_sha256","graph_sha256","source_graph_sha256","recipe_sha256")
        sha(value[key]) || throw(ArgumentError("invalid capture provenance SHA-256: $key"))
    end
    value["fits_bindings_sha256"]===nothing || sha(value["fits_bindings_sha256"]) ||
        throw(ArgumentError("invalid capture FITS bindings SHA-256"))
    identity=value["calibration_identity"]
    identity isa String && occursin(r"^sha256:[0-9a-f]{64}$",identity) ||
        throw(ArgumentError("capture provenance requires a SHA-256 calibration identity"))
    text(value["operation"],64) && text(value["reference_space"],2048) ||
        throw(ArgumentError("invalid capture reference-space declaration"))
    value["source_stage"]===nothing || endpoint(value["source_stage"])
    function hashes(key)
        mapping=value[key]
        mapping isa AbstractDict && length(mapping)<=64 &&
            all(pair -> first(pair) isa String && occursin(r"^[A-Za-z0-9_.-]{1,128}$",first(pair)) && sha(last(pair)),pairs(mapping)) ||
            throw(ArgumentError("invalid capture parameter SHA-256 mapping"))
        return Dict{String,String}(mapping)
    end
    return CaptureProvenance(value["acquisition_receipt_sha256"],value["graph_sha256"],value["fits_bindings_sha256"],
        value["source_graph_sha256"],value["recipe_sha256"],identity,value["operation"],
        value["reference_space"],value["source_stage"],hashes("parameter_sha256"),hashes("source_parameter_sha256"))
end

provenance_metadata(provenance::CaptureProvenance)=Dict(String(name)=>getfield(provenance,name)
    for name in fieldnames(CaptureProvenance))

struct CaptureConfig
    label::String
    scope::Dict{String,String}
    products::Dict{Symbol,Symbol}
    units::Dict{Symbol,String}
    count::Symbol
    complete::Symbol
    variance_valid::Symbol
    window_samples::UInt64
    provenance::Union{Nothing,CaptureProvenance}
end

function capture_configuration(value)
    fields = Set(["label", "scope", "products", "units", "sample-count", "complete", "variance-valid"])
    value isa AbstractDict && fields ⊆ Set(keys(value)) && Set(keys(value)) ⊆ union(fields,Set(["provenance"])) ||
        throw(ArgumentError("analysis capture requires label, scope, products, units, sample-count, complete and variance-valid"))
    text(x) = x isa String && isvalid(x) && 0 < ncodeunits(x) <= 255 && !any(iscntrl, x)
    port(x) = text(x) && occursin(r"^[A-Za-z0-9_.-]+$", x)
    text(value["label"]) || throw(ArgumentError("invalid capture label"))
    scope = value["scope"]
    scope isa AbstractDict && Set(keys(scope)) == Set(["session_label", "graph", "parameter"]) &&
        all(pair -> text(first(pair)) && text(last(pair)), pairs(scope)) ||
        throw(ArgumentError("capture scope must declare session_label, graph and parameter for the artifact interface"))
    products = value["products"]
    products isa AbstractDict && "mean" in keys(products) &&
        Set(keys(products)) ⊆ Set(["mean", "variance", "stddev"]) && all(port, values(products)) ||
        throw(ArgumentError("capture products require mean and optional variance/stddev output Ports"))
    units = value["units"]
    units isa AbstractDict && Set(keys(units)) == Set(keys(products)) &&
        all(unit -> text(unit) && all(isascii, unit), values(units)) ||
        throw(ArgumentError("capture units must name each product explicitly"))
    foreach(ConfigurationStore.fits_units, values(units))
    all(key -> port(value[key]), ("sample-count", "complete", "variance-valid")) ||
        throw(ArgumentError("invalid capture status output Port"))
    names = [values(products)..., value["sample-count"], value["complete"], value["variance-valid"]]
    length(unique(names)) == length(names) || throw(ArgumentError("capture output Ports must be distinct"))
    return CaptureConfig(value["label"], Dict{String,String}(scope),
        Dict(Symbol(k)=>Symbol(v) for (k,v) in products),
        Dict(Symbol(k)=>v for (k,v) in units), Symbol(value["sample-count"]),
        Symbol(value["complete"]), Symbol(value["variance-valid"]), 0,
        haskey(value,"provenance") ? capture_provenance(value["provenance"]) : nothing)
end

# Qualify all captured products against one directly exported finite statistics
# Algorithm. Shape/type alone cannot distinguish EW population variance from
# finite sample variance, nor attest that a Bool belongs to these same moments.
function capture_contract(config::CaptureConfig, document::AbstractDict)
    graph = get(document, "filter.graph", document)
    exports = Dict{Symbol,String}()
    for output in get(graph, "outputs", [])
        endpoint, name = if output isa AbstractString
            parts = split(output, ':'; limit=2)
            length(parts) == 2 || throw(ArgumentError("capture exports must identify exact node:port endpoints"))
            String(output), Symbol(last(parts))
        elseif output isa AbstractDict && Set(keys(output)) == Set(["name", "endpoint"])
            String(output["endpoint"]), Symbol(output["name"])
        else
            throw(ArgumentError("invalid capture Graph output"))
        end
        haskey(exports, name) && throw(ArgumentError("duplicate capture Graph output"))
        exports[name] = endpoint
    end
    expected = [(port, String(product)) for (product,port) in config.products]
    append!(expected, [(config.count,"sample-count"), (config.complete,"complete"),
        (config.variance_valid,"variance-valid")])
    owner = nothing
    for (name, product) in expected
        haskey(exports,name) || throw(ArgumentError("capture output $name is not exported"))
        parts = split(exports[name], ':'; limit=2)
        length(parts) == 2 && last(parts) == product ||
            throw(ArgumentError("capture output $name must export the statistics $product Port directly"))
        owner === nothing && (owner=first(parts))
        first(parts) == owner || throw(ArgumentError("capture products must come from one statistics node"))
    end
    nodes = filter(node -> get(node,"name",nothing) == owner, get(graph,"nodes",[]))
    length(nodes) == 1 || throw(ArgumentError("capture statistics node is missing or ambiguous"))
    node = only(nodes)
    get(node,"label",nothing) == "array-statistics-f32" ||
        throw(ArgumentError("capture requires the array-statistics-f32 Algorithm"))
    settings = get(node,"config",Dict())
    get(settings,"mode",nothing) == "finite" || throw(ArgumentError("artifact capture requires finite statistics"))
    window = get(settings,"window_samples",nothing)
    window isa Integer && !(window isa Bool) && 1 <= window <= typemax(Int) ||
        throw(ArgumentError("capture requires a positive finite window_samples"))
    return CaptureConfig(config.label, config.scope, config.products, config.units,
        config.count,config.complete,config.variance_valid,UInt64(window),config.provenance)
end

# State 0: the single frame writer owns buffers/counters. State 1: immutable
# completed snapshot, release-published to the control reader. State 2: invalid.
# After either terminal state, the writer never touches the payload again.
mutable struct Capture{B,S,P,Count,Complete,Valid}
    const configuration::CaptureConfig
    const buffers::B
    const schemas::S
    const ports::P
    const ready::Threads.Atomic{UInt8}
    reason::Symbol
    count::UInt64
    first_sequence::UInt64
    last_sequence::UInt64
    sequence_gaps::UInt64
    has_identity::Bool
    domain::NTuple{16,UInt8}
    generation::UInt64
end

function prepare_capture(configuration::CaptureConfig, formats::NamedTuple)
    configuration.window_samples > 0 || throw(ArgumentError("capture must qualify a finite statistics Graph"))
    status = ((configuration.count, UInt64), (configuration.complete, Bool),
        (configuration.variance_valid, Bool))
    for (name, type) in status
        hasproperty(formats, name) || throw(ArgumentError("capture output $name is absent"))
        format = getproperty(formats, name)
        format.element_type === type && format.shape == (1,) ||
            throw(ArgumentError("capture status $name has the wrong type or shape"))
    end
    products = Tuple(sort!(collect(keys(configuration.products))))
    selected = map(products) do product
        name = configuration.products[product]
        hasproperty(formats, name) || throw(ArgumentError("capture output $name is absent"))
        format = getproperty(formats, name)
        format.element_type === Float32 || throw(ArgumentError("capture products must be Float32"))
        Artifacts.checked_shape(format.shape, sizeof(Float32))
        !isempty(format.schema) || throw(ArgumentError("capture products require declared schemas"))
        format
    end
    all(format -> format.shape == first(selected).shape, selected) ||
        throw(DimensionMismatch("capture product shapes differ"))
    sum(format -> prod(format.shape) * sizeof(Float32), selected) <= 64 * 1024^2 ||
        throw(ArgumentError("capture snapshot exceeds 64 MiB"))
    buffers = NamedTuple{products}(map(format -> zeros(Float32, format.shape), selected))
    schemas = NamedTuple{products}(map(format -> String(format.schema), selected))
    ports = NamedTuple{products}(map(product -> Val(configuration.products[product]), products))
    return Capture{typeof(buffers),typeof(schemas),typeof(ports),configuration.count,
        configuration.complete,configuration.variance_valid}(
        configuration, buffers, schemas, ports, Threads.Atomic{UInt8}(0), :none,
        0, 0, 0, 0, false, ntuple(_ -> UInt8(0), 16), 0)
end
prepare_capture(::Nothing, formats) = nothing

function fail_capture!(capture::Capture, reason::Symbol)
    capture.reason = reason
    capture.ready[] = UInt8(2)
    return nothing
end

capture_header(::Nothing) = nothing
function capture_header(record)
    if hasproperty(record, :present) && hasproperty(record, :value)
        return record.present ? record.value : nothing
    end
    return record
end

capture_output(outputs, ::Val{Name}) where Name = getproperty(outputs, Name)

function (capture::Capture{B,S,P,Count,Complete,Valid})(::Val{:frame},
        outputs::NamedTuple, metadata::NamedTuple) where {B,S,P,Count,Complete,Valid}
    capture.ready[] == 0 || return nothing
    config = capture.configuration
    count = getproperty(outputs, Count)[1]
    count == capture.count + UInt64(1) || return fail_capture!(capture, :sample_count)
    header = capture_header(getproperty(metadata, Count))
    header === nothing && return fail_capture!(capture, :missing_metadata)
    header.offset == 0 && !header.corrupted && !header.discontinuity ||
        return fail_capture!(capture, :invalid_metadata)
    matched = all((values(capture.ports)..., Val(Complete), Val(Valid))) do port
        other = capture_header(capture_output(metadata, port))
        return other !== nothing && other == header
    end
    matched || return fail_capture!(capture, :unmatched_metadata)
    identity = header.has_acquisition_identity
    if capture.count == 0
        capture.first_sequence = header.sequence
        capture.has_identity = identity
        if identity
            capture.domain = header.acquisition_identity.domain
            capture.generation = header.acquisition_identity.generation
        end
    else
        header.sequence > capture.last_sequence || return fail_capture!(capture, :sequence)
        identity == capture.has_identity || return fail_capture!(capture, :identity)
        if identity
            header.acquisition_identity.domain == capture.domain &&
                header.acquisition_identity.generation == capture.generation ||
                return fail_capture!(capture, :identity)
        end
        capture.sequence_gaps += header.sequence - capture.last_sequence - UInt64(1)
    end
    capture.count = count
    capture.last_sequence = header.sequence
    complete = getproperty(outputs, Complete)[1]
    count <= config.window_samples && complete == (count == config.window_samples) ||
        return fail_capture!(capture, :completion)
    complete || return nothing
    if (haskey(config.products, :variance) || haskey(config.products, :stddev)) &&
            !getproperty(outputs, Valid)[1]
        return fail_capture!(capture, :variance_unavailable)
    end
    for product in keys(capture.buffers)
        source = capture_output(outputs, getproperty(capture.ports, product))
        all(isfinite, source) || return fail_capture!(capture, :nonfinite)
        copyto!(getproperty(capture.buffers, product), source)
    end
    capture.ready[] = UInt8(1)
    return nothing
end

function (capture::Capture)(::Val{Event}) where Event
    capture.ready[] == 0 && capture.count > 0 && fail_capture!(capture, Event)
    return nothing
end

"""Register a completed immutable analysis snapshot. Never called on a frame thread.

Registration creates catalog candidates only. It does not apply, negate, or
convert a reference, change an RTC parameter, or select a startup calibration.
Each product is an independent existing Git/SQLite registration, not a transaction.
"""
function register_capture!(store::ConfigurationStore.Store, capture::Capture;
        source, graph_sha256, check=()->nothing, records=Dict{String,Any}())
    capture.ready[] == 1 || throw(ArgumentError("analysis capture is not complete"))
    provenance=capture.configuration.provenance
    provenance===nothing || provenance.graph_sha256==graph_sha256 ||
        throw(ArgumentError("registration graph differs from acquisition provenance"))
    for product in keys(capture.buffers)
        check()
        metadata = Dict("statistic"=>String(product), "units"=>capture.configuration.units[product],
            "sample_count"=>capture.count, "first_sequence"=>capture.first_sequence,
            "last_sequence"=>capture.last_sequence, "source_sequence_gaps"=>capture.sequence_gaps,
            "source"=>source, "graph_sha256"=>graph_sha256,
            "variance_convention"=>"sample (N-1)",
            "acquisition_identity_available"=>capture.has_identity)
        if capture.configuration.provenance !== nothing
            metadata["acquisition_provenance"]=provenance_metadata(capture.configuration.provenance)
        end
        if capture.has_identity
            metadata["acquisition_domain"] = bytes2hex(collect(capture.domain))
            metadata["acquisition_generation"] = capture.generation
        end
        record = ConfigurationStore.register!(store, getproperty(capture.buffers, product);
            label=capture.configuration.label * " · " * String(product),
            scope=capture.configuration.scope, metadata, schema=getproperty(capture.schemas, product),
            units=capture.configuration.units[product])
        records[String(product)] = record
    end
    return records
end

# One control task per optional capture. There are no file, Git, database, lock
# or sleep operations in the frame observer. A failed registration is recorded
# once; neither registration nor any scientific update is automatically retried.
function capture_artifacts(config, capture::Capture, finished;
        root=ConfigurationStore.default_root(),
        runtime=get(ENV, "PIPEWIREAO_RUNTIME_DIR", ""), pause=sleep,
        graph_sha256=D.digest(config.graph))
    while capture.ready[] == 0 && !finished[]
        pause(0.05)
    end
    record = Dict{String,Any}("analysis"=>config.name, "state"=>"incomplete")
    try
        state = capture.ready[]
        if state == 1
            source = [Dict("node"=>link.output.node, "port"=>link.output.port)
                for link in config.links if link.input.node == config.name]
            record["artifacts"] = Dict{String,Any}()
            register_capture!(ConfigurationStore.Store(root), capture;
                source, graph_sha256, records=record["artifacts"])
            record["state"] = "registered"
        elseif state == 2
            record["state"] = "rejected"
            record["reason"] = String(capture.reason)
        end
    catch error
        record["state"] = "registration_failed"
        record["error"] = sprint(showerror, error)
        @error "Analysis artifact registration failed" analysis=config.name exception=(error, catch_backtrace())
    end
    if !isempty(runtime)
        Common.write_json(joinpath(runtime, config.name * "-capture.json"), record; atomic=true)
    end
    return record
end
