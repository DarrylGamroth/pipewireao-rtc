const CALLBACK_FEEDBACK_GRAPH = """
filter.graph = {
    nodes = [
        {
            type = ndarray
            name = correction
            label = closed-loop-correction-f32
            config = { state_length = 1 hidden_mode_count = 1 }
            props = {
                gain = 1.0 pole = 0.99
                anti-windup-gain = 0.99 hidden-mode-gain = 0.0
            }
        }
        {
            type = ndarray
            name = projection
            label = controller-to-vdm-f32
            config = { controller_command_count = 1 active_vdm_count = 1 }
        }
        {
            type = ndarray
            name = physical
            label = vdm-to-pdm-f32
            config = { active_vdm_count = 1 full_vdm_count = 1 physical_actuator_count = 1 }
        }
        {
            type = ndarray
            name = command
            label = pdm-command-f32
            config = {
                actuator_count = 1
                command_limits = [-0.8, 0.8]
                slew_limit = null
                initial_current = null
                quantization_origin = null
                quantization_step = null
                dither_seed = null
            }
        }
        {
            type = ndarray
            name = feedback-vdm
            label = pdm-feedback-to-vdm-f32
            config = { active_vdm_count = 1 full_vdm_count = 1 physical_actuator_count = 1 }
        }
        {
            type = ndarray
            name = feedback-to-controller
            label = vdm-feedback-to-controller-f32
            config = { controller_command_count = 1 active_vdm_count = 1 }
        }
    ]
    links = [
        { output = "correction:correction" input = "projection:controller-command" }
        { output = "projection:vdm-command" input = "physical:vdm-command" }
        { output = "physical:requested-pdm-command" input = "command:requested" }
        { output = "command:constraint-feedback" input = "feedback-vdm:pdm-constraint-feedback" }
        { output = "feedback-vdm:vdm-constraint-feedback" input = "feedback-to-controller:vdm-constraint-feedback" }
    ]
    inputs = [
        "correction:residual-error"
        "correction:constraint-feedback"
        "correction:shape-to-hidden"
        "correction:hidden-to-shape"
        "projection:controller-to-vdm"
        "physical:active-to-full"
        "physical:vdm-to-pdm"
        "feedback-vdm:full-to-active"
        "feedback-vdm:pdm-to-vdm"
        "feedback-to-controller:vdm-to-controller"
    ]
    outputs = [
        "command:demanded"
        "feedback-to-controller:controller-constraint-feedback"
    ]
}
"""

const CALLBACK_FEEDBACK_PAIR =
    Symbol("constraint-feedback") => Symbol("controller-constraint-feedback")


# Uses the callback helpers and CPU feedback graph in feedback_bridge.jl.
function prepared_recovery_graph()
    additions = """
        { type = ndarray name = temporal label = biquad-cascade-f32
          config = { extent = 1 section_count = 1 per_mode = false
            initial_coefficients = [0 1 0 0 0]
            input_schema = controller.command.v1 output_schema = controller.command.v1 } }
        { type = ndarray name = flat label = pdm-system-flat-f32
          config = { actuator_count = 1 } }
    """
    text = replace(CALLBACK_FEEDBACK_GRAPH,
        "nodes = [" => "nodes = [\n$additions";
        count=1)
    text = replace(text,
        "input_schema = controller.command.v1 output_schema = controller.command.v1" =>
            "input_schema = $(CONTROLLER_COMMAND_V1) output_schema = $(CONTROLLER_COMMAND_V1)",
        "output = \"correction:correction\" input = \"projection:controller-command\"" =>
            "output = \"correction:correction\" input = \"temporal:input\" }\n" *
            "{ output = \"temporal:output\" input = \"projection:controller-command\"",
        "output = \"physical:requested-pdm-command\" input = \"command:requested\"" =>
            "output = \"physical:requested-pdm-command\" input = \"flat:requested\" }\n" *
            "{ output = \"flat:requested-with-system-flat\" input = \"command:requested\"",
        "slew_limit = null" => "slew_limit = 0.1",
        "initial_current = null" => "initial_current = [0.6]",
        "\"projection:controller-to-vdm\"" =>
            "\"temporal:coefficients\" \"flat:system-flat\" \"projection:controller-to-vdm\"")
    graph = prepare_graph_text(text; algorithms=algorithms())
    identity = ones(Float32, 1, 1)
    replace_parameters!(graph,
        Symbol("shape-to-hidden") => zeros(Float32, 1, 1),
        Symbol("hidden-to-shape") => zeros(Float32, 1, 1),
        Symbol("controller-to-vdm") => identity,
        Symbol("active-to-full") => identity,
        Symbol("vdm-to-pdm") => identity,
        Symbol("full-to-active") => identity,
        Symbol("pdm-to-vdm") => identity,
        Symbol("vdm-to-controller") => identity,
        Symbol("system-flat") => Float32[0.2])
    return graph
end

recovery_node(graph, name) = only(filter(node -> node.name === name, graph.nodes))

