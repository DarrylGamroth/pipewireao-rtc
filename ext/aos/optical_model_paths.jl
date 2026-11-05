# Resolve portable model paths only at cold factory invocation. Keep authored
# graph documents unchanged so prescription identities contain no host paths.
struct InstrumentOpticalPathsFactory{F}
    factory::F
    directory::String
end

AlgorithmGraphs.graph_node_configuration(
    factory::InstrumentOpticalPathsFactory, config::NamedTuple, bindings::NamedTuple
) = AlgorithmGraphs.graph_node_configuration(factory.factory, config, bindings)
AlgorithmGraphs.graph_node_bindings(
    factory::InstrumentOpticalPathsFactory, config::NamedTuple
) = AlgorithmGraphs.graph_node_bindings(factory.factory, config)

function (factory::InstrumentOpticalPathsFactory)(
    name::Symbol, config::NamedTuple, props::NamedTuple, bindings::NamedTuple = NamedTuple()
)
    path = config.model_path
    validate_optical_model_path(path)
    resolved = PipeWireAORTC.DeploymentConfiguration.relative_asset(factory.directory, path)
    return factory.factory(name, merge(config, (; model_path = resolved)), props, bindings)
end

function instrument_optical_factories(factories, directory)
    directory === nothing && return factories
    names = Tuple(
        name for name in keys(factories) if
        name in (:compiled_optical_paths_f32, :compiled_optical_paths_f64)
    )
    wrappers = map(
        name ->
            InstrumentOpticalPathsFactory(getproperty(factories, name), String(directory)),
        names,
    )
    return merge(factories, NamedTuple{names}(wrappers))
end

function validate_optical_model_path(path::AbstractString)
    !isabspath(path) ||
        throw(ArgumentError("instrument optical model path must be relative"))
    return nothing
end
validate_optical_model_path(path) =
    throw(ArgumentError("instrument optical model path must be relative"))
