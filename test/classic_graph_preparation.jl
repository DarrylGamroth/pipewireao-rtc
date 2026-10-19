# Optional application check, run in its resolved scientific environment.
using Test, PipeWireAORTC, FilterGraphIsland, JSON3

function check_application(application)
    R = PipeWireAORTC
    application = realpath(application)
    spec = JSON3.read(read(joinpath(application, "deployment.conf"), String), Dict{String,Any})
    owner = only(filter(owner -> owner["role"] == "julia", spec["owners"]))
    arguments = owner["argv"][findfirst(==("--"), owner["argv"]) + 1:end]
    bindings = Dict("PACKAGE" => application, "RUNTIME" => dirname(application),
        "REMOTE" => "not-connected", "BOOTSTRAP_INSTANCE_JULIA" => "1")
    arguments = [R.DeploymentConfiguration.substitute(argument, bindings) for argument in arguments]
    _, graph_arguments, fits_path = R.GraphOwner.arguments(arguments)
    options = FilterGraphIsland.parse_arguments(graph_arguments)
    entries = R.GraphOwner.bindings(fits_path)
    graph = FilterGraphIsland.prepare_service_graph(options;
        initial_parameters=formats -> R.GraphOwner.prepare_bindings(entries, formats))
    try
        @test length(entries) == 16
        @test options.capture_backend === nothing
        @test options.session_run_control
        println("Classic graph prepared with ", length(entries), " FITS startup parameters")
    finally
        FilterGraphIsland.close_execution(graph)
    end
end

@testset "Classic application graph preparation" begin
    length(ARGS) == 1 || error("usage: classic_graph_preparation.jl APPLICATION_DIRECTORY")
    check_application(only(ARGS))
end
