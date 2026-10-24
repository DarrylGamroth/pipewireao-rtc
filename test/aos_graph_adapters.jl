# Optional, CPU-only science selector; requires RTC, AOS, and AOS HIL.
using Test
using PipeWireAORTC
using AdaptiveOpticsSim
using AdaptiveOpticsSim.AlgorithmGraphs
using AdaptiveOpticsSimPipeWireHIL

const AdapterExtension = Base.get_extension(PipeWireAORTC, :PipeWireAORTCAOSExt)
# Permit validation against the frozen RTC science environment before wiring
# the new shared extension include into the deployment environment.
if !isdefined(AdapterExtension, :configured_graph_node_types)
    Base.include(AdapterExtension, joinpath(@__DIR__, "..", "ext", "aos", "graph_adapters.jl"))
end
const AdapterAOG = AdaptiveOpticsSim.AlgorithmGraphs
const AdapterTarget = AdaptiveOpticsSim.Backends.HostComputeDevice()

partition_config() = Dict{String,Any}(
    "input_size" => [5], "input_schema" => "test.command.f32/1",
    "partitions" => [
        Dict("name" => "first", "size" => [2], "schema" => "test.first.f32/1"),
        Dict("name" => "second", "size" => [3], "schema" => "test.second.f32/1")])
layout_config() = Dict{String,Any}(
    "input_size" => [2, 3], "output_size" => [5, 7], "origin" => [1, 2],
    "scale" => 2, "bias" => -3,
    "input_schema" => "test.output-electrons.f32/1",
    "output_schema" => "test.input-electrons.f32/1")

function adapter_document(type, config; props=Dict())
    vector = type == "vector_partition_f32"
    return Dict{String,Any}(
        "schema_version" => 1, "name" => "array_operations",
        "nodes" => [Dict("name" => "operation", "type" => type,
            "config" => config, "props" => props)],
        "inputs" => [Dict("name" => "command", "binding" => "input",
            "destination" => "operation." * (vector ? "command" : "detector_frame"))],
        "outputs" => [Dict("name" => "frame",
            "source" => "operation." * (vector ? "first" : "frame"))])
end

function adapter_definition(type, config, input; props=Dict())
    return load_algorithm_graph(adapter_document(type, config; props);
        node_types=AdapterExtension.configured_graph_node_types(), bindings=(; input))
end
adapter_graph(type, config, input; kwargs...) =
    prepare_algorithm_graph(adapter_definition(type, config, input; kwargs...); target=AdapterTarget)

adapter_owner(definition::AlgorithmGraphDefinition, inputs, outputs) =
    adapter_owner(only(definition.nodes), inputs, outputs)
function adapter_owner(node::AlgorithmNodeDefinition{Name,Node}, inputs, outputs) where {Name,Node}
    ports = AdapterAOG.graph_node_ports(Node, node.config)
    @test !isempty(ports)
    return AdapterAOG.prepare_graph_node(Node, node.config,
        node.props, inputs, outputs, NamedTuple(), AdapterTarget)
end

# Minimal offset-indexed host wrapper: rejection is the documented contract.
struct AdapterOffsetArray{T,N,A<:AbstractArray{T,N}} <: AbstractArray{T,N}
    parent::A
end
AdapterOffsetArray(parent::AbstractArray{T,N}) where {T,N} =
    AdapterOffsetArray{T,N,typeof(parent)}(parent)
Base.size(array::AdapterOffsetArray) = size(array.parent)
Base.axes(array::AdapterOffsetArray) = map(n -> 0:(n - 1), size(array))
Base.getindex(array::AdapterOffsetArray, indices::Vararg{Int}) =
    getindex(array.parent, (indices .+ 1)...)

function adapter_allocations(owner)
    AdapterAOG.step_graph_node!(owner)
    AdapterAOG.reset_graph_node!(owner)
    step = @allocated AdapterAOG.step_graph_node!(owner)
    reset = @allocated AdapterAOG.reset_graph_node!(owner)
    return (; step, reset)
end

@testset "Configured AOS generic array factories" begin
    registry = AdapterExtension.configured_graph_node_types()
    @test all(key -> hasproperty(registry, key), keys(builtin_graph_node_types()))
    @test registry.pyramid_rate_f32 === builtin_graph_node_types().pyramid_rate_f32

    @testset "Ordered vector partitions and command adoption" begin
        input = Float32.(1:5)
        definition = adapter_definition("vector_partition_f32", partition_config(), input)
        graph = prepare_algorithm_graph(definition; target=AdapterTarget)
        first = AdapterAOG.graph_output(graph, :frame)
        @test all(iszero, first)
        step_graph!(graph)
        @test first == input[1:2]
        input .= -10f0
        @test first == Float32[1, 2]
        step_graph!(graph)
        @test first == fill(-10f0, 2)
        reset_graph!(graph)
        @test all(iszero, first)

        # GPI's existing contiguous 97/2304/2 routing is a data configuration.
        config = partition_config()
        config["input_size"] = [2403]
        config["partitions"] = [Dict("name" => name, "size" => [count],
            "schema" => "test.$name.f32/1") for (name, count) in
            (("woofer", 97), ("tweeter", 2304), ("tiptilt", 2))]
        document = adapter_document("vector_partition_f32", config)
        document["outputs"] = [Dict("name" => name, "source" => "operation.$name")
            for name in ("woofer", "tweeter", "tiptilt")]
        source = Float32.(1:2403)
        routed = prepare_algorithm_graph(load_algorithm_graph(document;
            node_types=registry, bindings=(input=source,)); target=AdapterTarget)
        step_graph!(routed)
        @test AdapterAOG.graph_output(routed, :woofer) == source[1:97]
        @test AdapterAOG.graph_output(routed, :tweeter) == source[98:2401]
        @test AdapterAOG.graph_output(routed, :tiptilt) == source[2402:2403]
        reset_graph!(routed)
        @test all(name -> all(iszero, AdapterAOG.graph_output(routed, name)),
            (:woofer, :tweeter, :tiptilt))

        fill!(input, 0f0)
        exchange = prepare_graph_hil_boundary(
            prepare_algorithm_graph(definition; target=AdapterTarget);
            command_input=:command, frame_output=:frame)
        hil_command_buffer(exchange) .= 7f0
        sequence = step_hil_frame!(exchange)
        @test all(iszero, hil_frame_buffer(exchange))
        @test all(iszero, input)
        adopt_hil_command!(exchange, sequence)
        @test all(==(7f0), input)
        step_hil_frame!(exchange)
        @test hil_frame_buffer(exchange) == fill(7f0, 2)
        reset_hil_boundary!(exchange)
        @test all(iszero, input)
    end

    @testset "Rectangular placement, scale, bias, and optional clipping" begin
        input = reshape(Float32.(1:6), 2, 3)
        config = layout_config()
        graph = adapter_graph("detector_frame_layout_f32", config, input)
        frame = AdapterAOG.graph_output(graph, :frame)
        expected = zeros(Float32, 5, 7)
        expected[2:3, 3:5] .= input .* 2f0 .- 3f0
        step_graph!(graph)
        @test frame == expected
        @test frame[2, 3] == -1f0 # Omitted range preserves negative Float32 values.
        fill!(frame, 99f0)
        step_graph!(graph)
        @test frame == expected # Padding is cleared on every step.
        reset_graph!(graph)
        @test all(iszero, frame)
        @test input == reshape(Float32.(1:6), 2, 3)

        config["range"] = [0, 5]
        clipped = adapter_graph("detector_frame_layout_f32", config, input)
        step_graph!(clipped)
        expected[2:3, 3:5] .= clamp.(input .* 2f0 .- 3f0, 0f0, 5f0)
        @test AdapterAOG.graph_output(clipped, :frame) == expected

        config = layout_config()
        merge!(config, Dict("input_size" => [240, 240], "output_size" => [242, 240],
            "origin" => [0, 0], "scale" => 1 / 5000, "bias" => 0))
        electrons = fill(20_000f0, 240, 240)
        electrons[1, 1] = -5000f0
        electrons[2, 1] = 100_000_000f0
        gpi = adapter_graph("detector_frame_layout_f32", config, electrons)
        step_graph!(gpi)
        frame = AdapterAOG.graph_output(gpi, :frame)
        @test size(frame) == (242, 240)
        @test eltype(frame) === Float32
        @test frame[1:240, :] == electrons .* Float32(1 / 5000)
        @test frame[2, 1] > 16383f0
        @test all(iszero, frame[241:242, :])
    end

    @testset "Host views, one-based axes, concrete ownership, and allocation" begin
        definition = adapter_definition("vector_partition_f32", partition_config(), zeros(Float32, 5))
        input = view(Float32.(1:10), 1:2:10)
        outputs = (first=view(zeros(Float32, 4), 1:2:4), second=view(zeros(Float32, 6), 2:2:6))
        owner = adapter_owner(definition, (; command=input), outputs)
        AdapterAOG.step_graph_node!(owner)
        @test outputs.first == input[1:2]
        @test outputs.second == input[3:5]
        @test isconcretetype(typeof(owner))
        @test all(isconcretetype, fieldtypes(typeof(owner)))
        @test adapter_allocations(owner) == (; step=0, reset=0)
        @test AdapterAOG.graph_node_capture_capability(owner) isa AdapterAOG.GraphNodeCaptureUnsupported
        @test_throws ArgumentError adapter_owner(definition, (; command=AdapterOffsetArray(zeros(Float32, 5))), outputs)
        @test_throws DimensionMismatch adapter_owner(definition, (; command=zeros(Float32, 4)), outputs)
        @test_throws AlgorithmGraphError adapter_owner(definition, (; command=zeros(Float64, 5)), outputs)
        @test_throws AlgorithmGraphError adapter_owner(definition, (; command=input),
            (first=view(input, 1:2), second=zeros(Float32, 3)))

        definition = adapter_definition("detector_frame_layout_f32", layout_config(), zeros(Float32, 2, 3))
        input = view(reshape(Float32.(1:24), 4, 6), 1:2:4, 1:2:6)
        frame = view(fill(99f0, 10, 14), 1:2:10, 2:2:14)
        owner = adapter_owner(definition, (; detector_frame=input), (; frame))
        AdapterAOG.step_graph_node!(owner)
        expected = zeros(Float32, 5, 7)
        expected[2:3, 3:5] .= input .* 2f0 .- 3f0
        @test frame == expected
        @test all(isconcretetype, fieldtypes(typeof(owner)))
        @test adapter_allocations(owner) == (; step=0, reset=0)
        @test AdapterAOG.graph_node_capture_capability(owner) isa AdapterAOG.GraphNodeCaptureUnsupported
        clipped_config = layout_config()
        clipped_config["range"] = [0, 2]
        clipped_definition = adapter_definition("detector_frame_layout_f32", clipped_config, zeros(Float32, 2, 3))
        clipped_owner = adapter_owner(clipped_definition, (; detector_frame=input), (; frame))
        @test adapter_allocations(clipped_owner) == (; step=0, reset=0)
        @test_throws ArgumentError adapter_owner(definition,
            (; detector_frame=AdapterOffsetArray(zeros(Float32, 2, 3))), (; frame))
        @test_throws AlgorithmGraphError adapter_owner(definition,
            (; detector_frame=zeros(Float32, 2, 3)), (; frame=zeros(Float64, 5, 7)))
    end

    @testset "Malformed configurations fail through the public loader" begin
        vector_changes = (
            config -> (config["extra"] = 1),
            config -> delete!(config, "input_schema"),
            config -> (config["input_schema"] = 1),
            config -> (config["input_schema"] = ""),
            config -> (config["input_size"] = [5, 1]),
            config -> (config["input_size"] = [0]),
            config -> (config["input_size"] = [true]),
            config -> (config["input_size"] = [5.0]),
            config -> (config["input_size"] = [typemax(Int)]),
            config -> (config["input_size"] = [big(typemax(Int)) + 1]),
            config -> (config["partitions"] = []),
            config -> (config["partitions"] = "first"),
            config -> (config["partitions"][1]["offset"] = 0),
            config -> (config["partitions"][1]["name"] = "command"),
            config -> (config["partitions"][1]["name"] = "second"),
            config -> (config["partitions"][1]["name"] = "bad name"),
            config -> (config["partitions"][1]["size"] = [1]),
            config -> (config["partitions"][1]["size"] = [3]),
            config -> (config["partitions"][1]["size"] = [-1]),
            config -> (config["partitions"][1]["size"] = [2, 1]),
            config -> (config["partitions"][1]["schema"] = false))
        for change in vector_changes
            config = partition_config()
            change(config)
            @test_throws AlgorithmGraphError adapter_definition("vector_partition_f32", config, zeros(Float32, 5))
        end
        excessive = partition_config()
        excessive["input_size"] = [257]
        excessive["partitions"] = [Dict("name" => "partition$i", "size" => [1],
            "schema" => "test.partition.f32/1") for i in 1:257]
        @test_throws AlgorithmGraphError adapter_definition("vector_partition_f32", excessive, zeros(Float32, 257))
        layout_changes = (
            config -> (config["extra"] = 1),
            config -> delete!(config, "scale"),
            config -> (config["input_size"] = [2]),
            config -> (config["output_size"] = [typemax(Int), 2]),
            config -> (config["output_size"] = [0, 7]),
            config -> (config["origin"] = [1]),
            config -> (config["origin"] = [-1, 0]),
            config -> (config["origin"] = [typemax(Int), 0]),
            config -> (config["origin"] = [4, 0]),
            config -> (config["origin"] = [0, 5]),
            config -> (config["origin"] = [0.5, 0]),
            config -> (config["scale"] = Inf),
            config -> (config["scale"] = NaN),
            config -> (config["scale"] = 1e300),
            config -> (config["scale"] = true),
            config -> (config["bias"] = -Inf),
            config -> (config["bias"] = -1e300),
            config -> (config["range"] = [2, 1]),
            config -> (config["range"] = [1 + eps(), 1]),
            config -> (config["range"] = [0, Inf]),
            config -> (config["range"] = [0]),
            config -> (config["range"] = [false, true]),
            config -> (config["range"] = nothing))
        for change in layout_changes
            config = layout_config()
            change(config)
            @test_throws AlgorithmGraphError adapter_definition("detector_frame_layout_f32", config, zeros(Float32, 2, 3))
        end
        for (type, config, input) in (("vector_partition_f32", partition_config(), zeros(Float32, 5)),
                ("detector_frame_layout_f32", layout_config(), zeros(Float32, 2, 3)))
            @test_throws AlgorithmGraphError adapter_definition(type, config, input; props=Dict("extra" => 1))
        end
        @test_throws AlgorithmGraphError adapter_graph("vector_partition_f32", partition_config(), zeros(Float32, 4))
        @test_throws AlgorithmGraphError adapter_graph("detector_frame_layout_f32", layout_config(), zeros(Float64, 2, 3))
    end
end
