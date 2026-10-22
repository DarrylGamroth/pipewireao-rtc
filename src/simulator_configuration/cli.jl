function worker_main(args)
    length(args) == 3 && args[1] in ("describe", "preflight") ||
        throw(ArgumentError("settings worker requires describe|preflight CONFIG OUTPUT"))
    scientific_worker(args[2], args[3]; prepare=args[1] == "preflight")
    return nothing
end

function request_result(request)
    request isa AbstractDict && Set(keys(request)) == Set(("protocol", "op", "arguments")) &&
        request["protocol"] == PROTOCOL || throw(ArgumentError("invalid simulator settings request"))
    arguments = request["arguments"]
    arguments isa AbstractDict || throw(ArgumentError("arguments must be an object"))
    operation = request["op"]
    if operation == "describe"
        Set(keys(arguments)) == Set(("session_id",)) || throw(ArgumentError("describe requires session_id"))
        return describe(arguments["session_id"])
    elseif operation == "start_rebuild"
        Set(keys(arguments)) == Set(("session_id", "configuration_sha256", "settings", "resume_running")) ||
            throw(ArgumentError("start_rebuild requires session_id, configuration_sha256, settings and resume_running"))
        return start_rebuild(arguments["session_id"], arguments["configuration_sha256"], arguments["settings"];
            resume_running=arguments["resume_running"])
    elseif operation == "job"
        Set(keys(arguments)) == Set(("id",)) || throw(ArgumentError("job requires id"))
        return job(arguments["id"])
    end
    throw(ArgumentError("unknown simulator settings operation"))
end

function respond(line::AbstractString)
    try
        ncodeunits(line) <= MAX_REQUEST_BYTES || throw(ArgumentError("request exceeds 64 KiB"))
        result = request_result(C.parse_json(line))
        ncodeunits(JSON.json(result)) <= MAX_REPLY_BYTES || throw(ArgumentError("reply exceeds 1 MiB"))
        return Dict("ok"=>true, "result"=>result)
    catch error
        return Dict("ok"=>false, "error"=>sprint(showerror,error))
    end
end

serve(input::IO=stdin, output::IO=stdout) = ConfigurationStoreCLI.serve(input, output; responder=respond)

"Serve management requests, or execute one bounded request for Julia/CLI callers."
function main(args=ARGS; input::IO=stdin, output::IO=stdout)
    isempty(args) || args == ["serve"] || length(args) == 1 ||
        throw(ArgumentError("usage: simulator settings [serve|JSON_REQUEST]"))
    (isempty(args) || args == ["serve"]) && return serve(input, output)
    response = respond(only(args))
    JSON.json(output, response); write(output, '\n'); flush(output)
    return response["ok"] ? 0 : 1
end
