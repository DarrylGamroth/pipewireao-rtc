const OUTPUTS = ("mean", "variance", "stddev", "sample-count", "complete", "variance-valid")

function analysis_capture_configuration(directory, name; output_links = ())
    graph = Dict(
        "filter.graph" => Dict(
            "nodes" => [
                Dict(
                    "type" => "ndarray",
                    "name" => "statistics",
                    "label" => "array-statistics-f32",
                    "config" => Dict(
                        "size" => [2, 2],
                        "mode" => "finite",
                        "window_samples" => 8,
                        "input_schema" => "test/analysis-samples-f32/1",
                        "mean_schema" => "test/analysis-mean-f32/1",
                        "variance_schema" => "test/analysis-variance-f32/1",
                        "stddev_schema" => "test/analysis-stddev-f32/1",
                    ),
                ),
            ],
            "inputs" => ["statistics:sample"],
            "outputs" => ["statistics:" * port for port in OUTPUTS],
            "links" => [],
        ),
    )
    PipeWireAORTC.ScienceExport.write_spa_config(joinpath(directory, "graph.conf"), graph)
    links = [
        Dict("output" => "analysis-test-source:output_1", "input" => name * ":sample"),
        output_links...,
    ]
    config = Dict(
        "name" => name,
        "graph" => "graph.conf",
        "rate" => "1000/1",
        "links" => links,
        "capture" => Dict(
            "label" => "Native finite capture",
            "scope" => Dict(
                "session_label" => "native-test",
                "graph" => "controller",
                "parameter" => "reference",
            ),
            "products" => Dict(port => port for port in ("mean", "variance", "stddev")),
            "units" => Dict("mean" => "adu", "variance" => "adu^2", "stddev" => "adu"),
            "sample-count" => "sample-count",
            "complete" => "complete",
            "variance-valid" => "variance-valid",
        ),
    )
    path = joinpath(directory, "analysis.conf")
    PipeWireAORTC.ScienceExport.write_spa_config(path, config)
    return path
end

function nodes(registry, name; prefix = false)
    filter(find_globals(registry; interface = "PipeWire:Interface:Node")) do item
        value = get(item.properties, "node.name", "")
        prefix ? startswith(value, name) : value == name
    end
end

function start_analysis_capture(path, remote, state, log)
    project = dirname(Base.active_project())
    entry = "using PipeWireAORTC; exit(PipeWireAORTC.Analysis.main(ARGS))"
    command = `$(Base.julia_cmd()) --startup-file=no --threads=3 --project=$project -e $entry -- --config $path --remote $remote`
    return run(
        pipeline(addenv(command, "XDG_STATE_HOME" => state); stdout = log, stderr = log);
        wait = false,
    )
end
