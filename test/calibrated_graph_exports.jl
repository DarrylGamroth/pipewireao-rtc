# Optional cold owner-compiler and numerical check; no core, GPU or optical preparation.
# julia --project=/path/to/science-environment test/calibrated_graph_exports.jl
using Test,
    PipeWireAORTC,
    FilterGraphAlgorithms,
    FilterGraphIsland,
    FilterGraphPipeWire,
    JuliaFilterGraph

const E = PipeWireAORTC.InstrumentExport
const C = PipeWireAORTC.Common
const S = PipeWireAORTC.Schemas.CATALOG

function command_graph()
    Dict(
        "node.name" => "command-exports",
        "filter.graph" => Dict(
            "nodes" => [
                Dict(
                    "name" => "completion",
                    "type" => "ndarray",
                    "label" => "vdm-to-pdm-f32",
                    "config" => Dict(
                        "active_vdm_count" => 2,
                        "full_vdm_count" => 3,
                        "physical_actuator_count" => 4,
                    ),
                ),
                Dict(
                    "name" => "command",
                    "type" => "ndarray",
                    "label" => "vector-conditioning-f32",
                    "config" => Dict(
                        "count" => 4,
                        "requested_schema" => S["requested_pdm_command"]["id"],
                        "demanded_schema" => "pipewireao/demanded-pdm-command-f32/1",
                        "feedback_schema" => S["pdm_constraint_feedback"]["id"],
                        "command_limits" => [-0.5, 0.5],
                        "slew_limit" => nothing,
                        "initial_current" => nothing,
                        "quantization_origin" => nothing,
                        "quantization_step" => nothing,
                        "dither_seed" => nothing,
                    ),
                ),
            ],
            "links" => [
                Dict(
                    "output" => "completion:requested-pdm-command",
                    "input" => "command:requested",
                ),
            ],
            "inputs" => [
                Dict("name" => "input", "endpoint" => "completion:vdm-command"),
                Dict("name" => "completion", "endpoint" => "completion:active-to-full"),
                Dict("name" => "projection", "endpoint" => "completion:vdm-to-pdm"),
            ],
            "outputs" => [Dict("name" => "demanded", "endpoint" => "command:demanded")],
        ),
    )
end

@testset "append-only command feedback exports retain calibrated CPU results" begin
    frozen = command_graph()
    graph = deepcopy(frozen)
    added = [
        Dict("name" => "correction-role", "endpoint" => "completion:correction-role"),
        Dict("name" => "constraint-feedback", "endpoint" => "command:constraint-feedback"),
    ]
    append!(graph["filter.graph"]["outputs"], added)
    @test E.calibrated_graph_exports(graph, frozen) == added
    @test length(frozen["filter.graph"]["outputs"]) == 1
    mktempdir() do directory
        path = joinpath(directory, "executed.conf")
        PipeWireAORTC.ScienceExport.write_spa_config(path, graph)
        contracts = E.graph_port_contracts(path)["outputs"]
        @test contracts["correction-role"]["shape"] == [4]
        @test contracts["correction-role"]["element-type"] == "U8"
        @test contracts["correction-role"]["schema"] == S["pdm_correction_role"]["id"]
        @test contracts["constraint-feedback"]["shape"] == [4]
        @test contracts["constraint-feedback"]["element-type"] == "F32_LE"
        @test contracts["constraint-feedback"]["schema"] ==
            S["pdm_constraint_feedback"]["id"]
        baselinepath = joinpath(directory, "calibrated.conf")
        PipeWireAORTC.ScienceExport.write_spa_config(baselinepath, frozen)
        baseline = JuliaFilterGraph.prepare_graph(
            baselinepath; algorithms = FilterGraphAlgorithms.algorithms()
        )
        executed = JuliaFilterGraph.prepare_graph(
            path; algorithms = FilterGraphAlgorithms.algorithms()
        )
        for prepared in (baseline, executed)
            JuliaFilterGraph.replace_parameters!(
                prepared,
                :completion => Float32[1 0; 0 1; 0.5 -0.5],
                :projection => Float32[1 0 0; 0 1 0; 0 0 1; 0 0 0],
            )
        end
        old = (demanded = zeros(Float32, 4),)
        output = NamedTuple{(
            :demanded, Symbol("correction-role"), Symbol("constraint-feedback")
        )}((zeros(Float32, 4), zeros(UInt8, 4), zeros(Float32, 4)))
        for input in (Float32[2, -1], Float32[-0.25, 0.5], Float32[0, 0])
            @test JuliaFilterGraph.process!(old, baseline, (; input)) == (demanded = true,)
            @test all(values(JuliaFilterGraph.process!(output, executed, (; input))))
            @test old.demanded == output.demanded
            @test getproperty(output, Symbol("correction-role")) == UInt8[1, 1, 2, 0]
            requested = Float32[input[1], input[2], 0.5f0*(input[1]-input[2]), 0]
            @test getproperty(output, Symbol("constraint-feedback")) ==
                requested - output.demanded
        end
    end
    for endpoint in ("missing:correction-role", "completion:missing")
        changed = deepcopy(frozen)
        push!(
            changed["filter.graph"]["outputs"],
            Dict("name" => "roles", "endpoint" => endpoint),
        )
        @test_throws JuliaFilterGraph.GraphConfigurationError E.calibrated_graph_exports(
            changed, frozen
        )
    end
    @test !any(id -> id.name in ("AMDGPU", "CUDA", "Proper"), keys(Base.loaded_modules))
end
