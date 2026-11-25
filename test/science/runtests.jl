using PipeWireAO, Test

const COLD = (
    "calibrated_graph_exports",
    "analysis_links",
    "instrument_influences_science",
    "aos_graph_adapters",
    "ideal_pupil_relay_preparation",
    "test_aos_configuration_bindings",
    "optical_model_paths",
    "test_response_cadence",
    "simulation_export",
    "external_optical_preparation",
    "simulation_optical_export",
    "simulation_compiled_export",
    "test_aos_pupil_bindings",
    "captured_optical_preparation",
    "zemax_component_preparation",
    "pupil_feedback_composition",
    "test_feedback_composition",
    "analysis_metadata",
    "analysis_statistics",
    "analysis_synchronized_inputs",
    "calibration_type_dispatch",
    "test_modal_completion",
    "physical_offsets_observer",
    "test_session_configuration_integration",
)

const PRIVATE_CORE = (
    "latest_output_private_core",
    "calibration_worker",
    "calibration_named_transport",
    "calibration_readiness",
)

const SELECTIONS = (
    cold = COLD,
    private_core = PRIVATE_CORE,
    physical_offset_inputs = ("physical_offset_inputs_private_core",),
    physical_offsets = ("physical_offsets_private_core",),
)

const USAGE = "Select one of cold, private_core, physical_offset_inputs or physical_offsets"
length(ARGS) == 1 || error(USAGE)
const SELECTION = Symbol(only(ARGS))
hasproperty(SELECTIONS, SELECTION) || error(USAGE)

const PREFIX = String(PipeWireAO.LibPipeWire.PipeWireAO_jll.artifact_dir)
withenv(
    "PIPEWIREAO_PREFIX" => PREFIX,
    "PIPEWIREAO_HIL_TEST_PREFIX" => PREFIX,
    "PIPEWIREAORTC_TEST_BACKEND" => "cpu",
) do
    @testset "CPU science ($SELECTION)" verbose = true begin
        for name in getproperty(SELECTIONS, SELECTION)
            @testset "$name" begin
                suite = Module(gensym(:ScienceTests))
                Core.eval(suite, :(include(path) = Base.include($suite, path)))
                Base.include(suite, joinpath(@__DIR__, "..", name * ".jl"))
            end
        end
    end
end
