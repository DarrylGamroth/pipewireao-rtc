#!/usr/bin/env julia
# Ordinary sparse parameter owner; the installed WirePlumber session owns links and policy.
using PipeWireAODeployment
const Parameters = PipeWireAODeployment.NativeParameterSource
const Common = PipeWireAODeployment.Common
const Bootstrap = PipeWireAODeployment.NativeOwnerBootstrapRuntime

function main(arguments=ARGS)
    required = ["config", "remote", "bootstrap-node", "bootstrap-instance", "control-node", "control-instance"]
    options = Common.cli_arguments(arguments; required)
    isabspath(options.config) && isabspath(options.remote) ||
        throw(ArgumentError("parameter owner requires absolute --config and --remote paths"))
    for name in (:bootstrap_node, :control_node)
        occursin(r"^[a-zA-Z0-9_.-]{1,128}$", getproperty(options, name)) ||
            throw(ArgumentError("invalid parameter owner node name"))
    end
    bootstrap_instance = tryparse(Int64, options.bootstrap_instance)
    control_instance = tryparse(Int64, options.control_instance)
    bootstrap_instance !== nothing && bootstrap_instance > 0 &&
        control_instance !== nothing && control_instance > 0 ||
        throw(ArgumentError("parameter owner instances must be positive Int64"))
    options.bootstrap_node != options.control_node || throw(ArgumentError("bootstrap and parameter endpoints must have distinct names"))
    admitted = merge(options, (; bootstrap_instance, control_instance))
    runtime = Bootstrap.Runtime(admitted.remote, admitted.bootstrap_node, bootstrap_instance)
    failures = Exception[]
    try
        Parameters.run_owner(admitted, runtime)
    catch error
        if !(error isa InterruptException && Bootstrap.cancelled(runtime))
            push!(failures, error)
            Bootstrap.fault!(runtime, error)
        end
    finally
        try Bootstrap.finish!(runtime) catch error; push!(failures, error) end
        try close(runtime) catch error; push!(failures, error) end
    end
    isempty(failures) || throw(length(failures) == 1 ? only(failures) : CompositeException(failures))
    return nothing
end

abspath(PROGRAM_FILE) == abspath(@__FILE__) && main()
