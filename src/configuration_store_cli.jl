"""Bounded JSON-lines management interface; no live RTC control operations."""
module ConfigurationStoreCLI

using JSON3
using ..ConfigurationStore
using ..Artifacts

export main, serve, respond
const MAX_LINE_BYTES = 2 * 1024 * 1024
const MAX_REPLY_BYTES = 16 * 1024 * 1024
const TYPES = Dict(string(T)=>T for T in Artifacts.TARGET_TYPES)

function request_result(request)
    request isa AbstractDict || throw(ArgumentError("request must be an object"))
    get(request,"protocol",nothing) == ConfigurationStore.PROTOCOL || throw(ArgumentError("unsupported protocol"))
    operation = get(request,"op",nothing)
    operation in ("register","list","get","history") || throw(ArgumentError("unknown management operation"))
    arguments = get(request,"arguments",Dict{String,Any}())
    arguments isa AbstractDict || throw(ArgumentError("arguments must be an object"))
    root = get(request,"root",ConfigurationStore.default_root())
    root isa AbstractString || throw(ArgumentError("root must be a string"))
    store = ConfigurationStore.Store(root)
    if operation == "register"
        allowed = ("path","type","shape","hdu","axes","label","scope","metadata","schema")
        all(k->k in allowed,keys(arguments)) || throw(ArgumentError("unknown register argument"))
        type = get(TYPES,get(arguments,"type",nothing),nothing)
        type === nothing && throw(ArgumentError("unsupported target type"))
        source = Artifacts.FITSArtifact(arguments["path"]; hdu=get(arguments,"hdu",1),axes=get(arguments,"axes",nothing))
        return ConfigurationStore.register!(store,source,type,arguments["shape"];
            label=arguments["label"],scope=arguments["scope"],metadata=get(arguments,"metadata",Dict{String,Any}()),
            schema=get(arguments,"schema",""))
    elseif operation == "list"
        all(k->k in ("limit","after_sequence"),keys(arguments)) || throw(ArgumentError("unknown list argument"))
        return ConfigurationStore.list_artifacts(store;limit=get(arguments,"limit",50),
            after_sequence=get(arguments,"after_sequence",0))
    elseif operation == "get"
        all(k->k in ("id","layout"),keys(arguments)) && haskey(arguments,"id") || throw(ArgumentError("get requires id and optional layout"))
        return ConfigurationStore.materialize!(store,arguments["id"];storage_order=get(arguments,"layout","row-major"))
    else
        all(k->k in ("limit","before_sequence","session_id","include_records"),keys(arguments)) || throw(ArgumentError("unknown history argument"))
        return ConfigurationStore.history(store;limit=get(arguments,"limit",50),
            before_sequence=get(arguments,"before_sequence",typemax(Int64)),session_id=get(arguments,"session_id",nothing),
            include_records=get(arguments,"include_records",false))
    end
end

"Return a management response, including structured errors for malformed requests."
function respond(line::AbstractString)
    try
        ncodeunits(line) <= MAX_LINE_BYTES || throw(ArgumentError("request exceeds byte limit"))
        request = JSON3.read(line,Dict{String,Any})
        response = Dict("ok"=>true,"result"=>request_result(request))
        ncodeunits(JSON3.write(response)) <= MAX_REPLY_BYTES || throw(ArgumentError("reply exceeds byte limit; use a smaller page"))
        return response
    catch exception
        return Dict("ok"=>false,"error"=>sprint(showerror,exception))
    end
end

# Reading byte by byte also bounds malformed input without an unbounded readline allocation.
function bounded_line(input)
    bytes = UInt8[]
    overflow = false
    while !eof(input)
        byte = read(input,UInt8)
        byte == 0x0a && break
        if length(bytes) < MAX_LINE_BYTES
            push!(bytes,byte)
        else
            overflow = true
        end
    end
    overflow && return nothing
    return String(bytes)
end
"Serve bounded JSON-lines requests until EOF; materializations survive client exit."
function serve(input::IO=stdin,output::IO=stdout; responder=respond)
    while !eof(input)
        line = bounded_line(input)
        result = line === nothing ? Dict("ok"=>false,"error"=>"request exceeds byte limit") : responder(line)
        JSON3.write(output,result)
        write(output,'\n'); flush(output)
    end
    return 0
end
"Run a JSON-lines server or a one-shot JSON management request."
function main(args=ARGS; input::IO=stdin,output::IO=stdout)
    if args == ["serve"] || isempty(args)
        return serve(input,output)
    end
    # Materialized transport bytes persist across one-shot client lifetimes.
    length(args) == 1 || throw(ArgumentError("usage: configuration_store_cli.jl [serve|JSON_REQUEST]"))
    response = respond(only(args))
    JSON3.write(output,response); write(output,'\n'); flush(output)
    return response["ok"] ? 0 : 1
end

end
