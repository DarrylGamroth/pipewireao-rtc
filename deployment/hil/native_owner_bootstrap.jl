"""Thin installed SDK cold entry point, loaded before scientific packages."""
module HILNativeOwnerBootstrap
const SOURCE = normpath(joinpath(@__DIR__, "..", "julia", "src"))
include(joinpath(SOURCE, "native_control_codec.jl"))
include(joinpath(SOURCE, "native_control_client.jl"))
include(joinpath(SOURCE, "native_control_endpoint.jl"))
include(joinpath(SOURCE, "native_owner_bootstrap_codec.jl"))
include(joinpath(SOURCE, "native_owner_bootstrap_runtime.jl"))
const Runtime = NativeOwnerBootstrapRuntime

"""Run construction on the caller thread and retain primary/cleanup failures."""
function with_owner(f, options)
    runtime = Runtime.Runtime(options.remote, options.bootstrap_node, options.bootstrap_instance)
    failures = Exception[]
    admitted = merge(options, (; bootstrap_runtime=runtime,
        owner_check=() -> Runtime.preparation_check!(runtime)))
    try
        f(admitted)
    catch error
        # Cooperative Quit during preparation is an ordinary clean cancellation.
        if !(error isa InterruptException && Runtime.cancelled(runtime))
            push!(failures, error)
            Runtime.fault!(runtime, error)
        end
    finally
        try Runtime.finish!(runtime) catch error; push!(failures, error) end
        try close(runtime) catch error; push!(failures, error) end
    end
    isempty(failures) || throw(length(failures) == 1 ? only(failures) : CompositeException(failures))
    return nothing
end

"""Extract only bootstrap flags; preserve all external graph arguments verbatim."""
function graph_arguments(arguments)
    values = Dict{String,String}()
    graph = String[]
    legacy = ("--prepared-event", "--connect-request", "--connect-reply", "--quit-request", "--control-request", "--control-reply", "--check")
    index = 1
    while index <= length(arguments)
        argument = arguments[index]
        key = first(split(argument, '='; limit=2))
        key in legacy && throw(ArgumentError("native graph owner forbids $key"))
        if key in ("--bootstrap-node", "--bootstrap-instance", "--remote")
            haskey(values, key) && throw(ArgumentError("duplicate $key"))
            terms = split(argument, '='; limit=2)
            if length(terms) == 2
                value = terms[2]
            else
                index < length(arguments) || throw(ArgumentError("$key requires a value"))
                index += 1
                value = arguments[index]
            end
            isempty(value) && throw(ArgumentError("$key must not be empty"))
            values[key] = value
            key == "--remote" && append!(graph, [key, value])
        else
            push!(graph, argument)
        end
        index += 1
    end
    all(key -> haskey(values, key), ("--bootstrap-node", "--bootstrap-instance", "--remote")) ||
        throw(ArgumentError("native graph owner requires explicit --bootstrap-node, --bootstrap-instance and --remote"))
    remote = values["--remote"]
    isabspath(remote) || throw(ArgumentError("native graph owner requires an absolute private remote"))
    node = values["--bootstrap-node"]
    occursin(r"^[a-zA-Z0-9_.-]{1,128}$", node) || throw(ArgumentError("invalid bootstrap node name"))
    instance = tryparse(Int64, values["--bootstrap-instance"])
    instance !== nothing && instance > 0 || throw(ArgumentError("invalid bootstrap instance"))
    return (; remote, bootstrap_node=node, bootstrap_instance=instance), graph
end
end
