# Cold graph/default comparison against snapshots captured with the baseline RTC.
# snapshot <instrument-repository> <snapshot-directory>
# compare  <instrument-repository> <snapshot-directory>
using PipeWireAORTC, YAML, Test
const IC = PipeWireAORTC.InstrumentConfiguration
length(ARGS) == 3 && ARGS[1] in ("snapshot", "compare") ||
    error("usage: compare_defaults.jl snapshot|compare <instrument-repository> <snapshot-directory>")
mode, root, directory = ARGS
mkpath(directory)
@testset "resolved scientific defaults preserved" begin
    for name in ("gpi2", "revolt-classic")
        declaration = IC.load_simulation(joinpath(root, name, "simulation/definition.yaml"))
        settings = IC.settings(declaration)
        path = joinpath(directory, "$name-settings-before.yaml")
        if mode == "snapshot"
            YAML.write_file(path, settings)
        else
            @test settings == YAML.load_file(path)
        end
        for calibration in (false, true)
            label = calibration ? "calibration" : "production"
            graph = IC.graph_document(declaration, settings; calibration)
            path = joinpath(directory, "$name-$label-before.yaml")
            if mode == "snapshot"
                YAML.write_file(path, graph)
            else
                # Only the new, explicitly on-axis source declarations differ.
                for node in graph["nodes"]
                    node["name"] in ("pyramid", "atmosphere") || continue
                    for field in ("source_separation_arcsec", "source_position_angle_deg")
                        @test pop!(node["config"], field) == 0
                    end
                end
                @test graph == YAML.load_file(path)
            end
        end
    end
end
