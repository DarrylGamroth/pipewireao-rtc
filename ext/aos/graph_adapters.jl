# Generic array operations for configured AOS graphs. Boundary semantics follow
# GPI2Sim's CommandRoutingNode and FrameLayoutNode (Darryl Gamroth); these cold
# factories independently express vector partitioning and rectangular placement.
# Dimensions are [rows, columns]; the detector origin counts from zero.

struct VectorPartitionNode end
struct VectorPartitionConfig{P}
    input_size::Tuple{Int}
    input_schema::String
    partitions::P
end
struct VectorPartitionOwner{I,O}
    inputs::I
    outputs::O
end

struct DetectorFrameLayoutNode end
struct DetectorFrameLayoutConfig{R}
    input_size::Tuple{Int,Int}
    output_size::Tuple{Int,Int}
    origin::Tuple{Int,Int}
    scale::Float32
    bias::Float32
    range::R
    input_schema::String
    output_schema::String
end
struct DetectorFrameLayoutOwner{I,S,O,R}
    detector_frame::I
    science::S
    frame::O
    scale::Float32
    bias::Float32
    range::R
end

_adapter_error(message) = AlgorithmGraphs.AlgorithmGraphError(message)

function _adapter_fields(values::NamedTuple, allowed, required, context)
    all(key -> key in allowed, keys(values)) ||
        throw(_adapter_error("$context contains an unknown field"))
    all(key -> hasproperty(values, key), required) ||
        throw(_adapter_error("$context is missing a required field"))
    return nothing
end
_adapter_fields(values, allowed, required, context) =
    throw(_adapter_error("$context must be a table"))

function _adapter_integer(value::Integer, context)
    typemin(Int) <= value <= typemax(Int) ||
        throw(_adapter_error("$context exceeds machine integer bounds"))
    return Int(value)
end
_adapter_integer(value, context) = throw(_adapter_error("$context must be an integer"))
_adapter_integer(value::Bool, context) = throw(_adapter_error("$context must be an integer"))

function _adapter_string(value::AbstractString, context)
    isempty(value) && throw(_adapter_error("$context must not be empty"))
    return String(value)
end
_adapter_string(value, context) = throw(_adapter_error("$context must be a string"))

function _adapter_identifier(value, context)
    text = _adapter_string(value, context)
    Base.isidentifier(text) || throw(_adapter_error("$context must be an identifier"))
    return Symbol(text)
end

function _adapter_tuple(value::Tuple, rank, context)
    length(value) == rank || throw(_adapter_error("$context must have $rank entries"))
    return value
end
_adapter_tuple(value, rank, context) = throw(_adapter_error("$context must be an array"))

function _adapter_shape(value, rank, context)
    dimensions = map(_adapter_tuple(value, rank, context)) do dimension
        count = _adapter_integer(dimension, context)
        count > 0 || throw(_adapter_error("$context dimensions must be positive"))
        return count
    end
    # Test division before multiplication, including the Float32 element width.
    bytes = sizeof(Float32)
    for count in dimensions
        count <= div(Owner.MAX_RETAINED_BYTES, bytes) ||
            throw(_adapter_error("$context exceeds the 512 MiB array limit"))
        bytes *= count
    end
    return dimensions
end

function _adapter_f32(value::Real, context)
    isfinite(value) && abs(value) <= floatmax(Float32) ||
        throw(_adapter_error("$context must be finite and within Float32 range"))
    return Float32(value)
end
_adapter_f32(value, context) = throw(_adapter_error("$context must be a real number"))
_adapter_f32(value::Bool, context) = throw(_adapter_error("$context must be a real number"))

function _vector_partition_f32_node(name::Symbol, config::NamedTuple, props::NamedTuple)
    fields = (:input_size, :input_schema, :partitions)
    context = "node '$name' config"
    _adapter_fields(config, fields, fields, context)
    _adapter_fields(props, (), (), "node '$name' props")
    input_size = _adapter_shape(config.input_size, 1, "$context.input_size")
    input_schema = _adapter_string(config.input_schema, "$context.input_schema")
    partitions = _adapter_partitions(config.partitions, input_size[1], context)
    return algorithm_node(name, VectorPartitionNode,
        VectorPartitionConfig(input_size, input_schema, partitions))
end

function _adapter_partitions(partitions::Tuple, count::Int, context)
    1 <= length(partitions) <= 256 ||
        throw(_adapter_error("$context.partitions must contain 1:256 entries"))
    # Input coverage bounds total output storage by the input's admitted size.
    configured = map(partitions) do partition
        fields = (:name, :size, :schema)
        _adapter_fields(partition, fields, fields, "$context.partitions")
        name = _adapter_identifier(partition.name, "$context.partitions.name")
        name === :command && throw(_adapter_error("partition name conflicts with input command"))
        shape = _adapter_shape(partition.size, 1, "$context.partitions.size")
        schema = _adapter_string(partition.schema, "$context.partitions.schema")
        return (; name, size=shape, schema)
    end
    names = map(partition -> partition.name, configured)
    length(unique(names)) == length(names) || throw(_adapter_error("partition names must be distinct"))
    covered = 0
    for partition in configured
        partition.size[1] <= count - covered ||
            throw(_adapter_error("partition sizes exceed the input vector"))
        covered += partition.size[1]
    end
    covered == count || throw(_adapter_error("partitions must cover the complete input vector"))
    return configured
end
_adapter_partitions(partitions, count, context) =
    throw(_adapter_error("$context.partitions must be an array"))

function _adapter_range(value::Tuple, context)
    _adapter_tuple(value, 2, context)
    lower, upper = map(bound -> _adapter_f32(bound, context), value)
    value[1] <= value[2] || throw(_adapter_error("$context lower bound exceeds upper bound"))
    return (lower, upper)
end
_adapter_range(::Nothing, context) = nothing
_adapter_range(value, context) = throw(_adapter_error("$context must contain two real bounds"))

function _detector_frame_layout_f32_node(name::Symbol, config::NamedTuple, props::NamedTuple)
    fields = (:input_size, :output_size, :origin, :scale, :bias, :range,
        :input_schema, :output_schema)
    required = (:input_size, :output_size, :origin, :scale, :bias, :input_schema, :output_schema)
    context = "node '$name' config"
    _adapter_fields(config, fields, required, context)
    _adapter_fields(props, (), (), "node '$name' props")
    input_size = _adapter_shape(config.input_size, 2, "$context.input_size")
    output_size = _adapter_shape(config.output_size, 2, "$context.output_size")
    origin = map(_adapter_tuple(config.origin, 2, "$context.origin")) do index
        _adapter_integer(index, "$context.origin")
    end
    all(d -> 0 <= origin[d] <= output_size[d] &&
        input_size[d] <= output_size[d] - origin[d], 1:2) ||
        throw(_adapter_error("input rectangle does not fit inside the output at origin"))
    scale = _adapter_f32(config.scale, "$context.scale")
    bias = _adapter_f32(config.bias, "$context.bias")
    range = _adapter_range(get(config, :range, nothing), "$context.range")
    input_schema = _adapter_string(config.input_schema, "$context.input_schema")
    output_schema = _adapter_string(config.output_schema, "$context.output_schema")
    return algorithm_node(name, DetectorFrameLayoutNode,
        DetectorFrameLayoutConfig(input_size, output_size, origin, scale, bias,
            range, input_schema, output_schema))
end

"""
Cold factory registry extending AOS with two CPU array operations:

- `vector_partition_f32`: `input_size=[N]`, `input_schema`, and
  1:256 ordered `partitions=[{name, size=[count], schema}, ...]` covering all N elements.
  Input port `command` is copied into the named, independent output buffers.
- `detector_frame_layout_f32`: `input_size` and `output_size` in [rows, columns],
  zero-based `origin`, `scale`, `bias`, `input_schema`, and `output_schema`.
  Input `detector_frame` is placed in output `frame` with zero padding. Omit
  `range` for `input * scale + bias`; provide `[lower, upper]` to clamp it.

Both nodes reset their output buffers to zero and require one-based Float32
arrays. Accelerator execution and command-graph capture are unsupported.
"""
function configured_graph_node_types()
    return merge(builtin_graph_node_types(), (
        vector_partition_f32=_vector_partition_f32_node,
        detector_frame_layout_f32=_detector_frame_layout_f32_node))
end

function AlgorithmGraphs.graph_node_ports(::Type{VectorPartitionNode}, config::VectorPartitionConfig)
    input = AlgorithmGraphs.graph_port_contract(:command, :input, :data, Float32,
        config.input_size, config.input_schema, :column_major)
    outputs = map(config.partitions) do partition
        AlgorithmGraphs.graph_port_contract(partition.name, :output, :data, Float32,
            partition.size, partition.schema, :column_major)
    end
    return (input, outputs...)
end

function AlgorithmGraphs.graph_node_ports(::Type{DetectorFrameLayoutNode}, config::DetectorFrameLayoutConfig)
    return (
        AlgorithmGraphs.graph_port_contract(:detector_frame, :input, :data, Float32,
            config.input_size, config.input_schema, :column_major),
        AlgorithmGraphs.graph_port_contract(:frame, :output, :data, Float32,
            config.output_size, config.output_schema, :column_major))
end

function _adapter_buffer(values::AbstractArray{Float32,N}, shape::NTuple{N,Int}) where {N}
    Base.require_one_based_indexing(values)
    size(values) == shape || throw(DimensionMismatch("graph adapter buffer shape differs from declaration"))
    return values
end
_adapter_buffer(values, shape) = throw(_adapter_error("graph adapter requires Float32 arrays of the declared rank"))

function AlgorithmGraphs.prepare_graph_node(::Type{VectorPartitionNode}, config::VectorPartitionConfig,
        ::NamedTuple{()}, inputs::NamedTuple{(:command,)}, outputs::NamedTuple,
        ::NamedTuple{()}, ::Backends.HostComputeDevice)
    command = _adapter_buffer(inputs.command, config.input_size)
    names = map(partition -> partition.name, config.partitions)
    keys(outputs) == names || throw(_adapter_error("partition output names differ from declaration"))
    offset = 0
    views = map(config.partitions) do partition
        output = _adapter_buffer(getproperty(outputs, partition.name), partition.size)
        Base.mightalias(output, command) &&
            throw(_adapter_error("partition output must not alias its input"))
        indices = (offset + 1):(offset + partition.size[1])
        offset += partition.size[1]
        view(command, indices)
    end
    for i in 1:length(outputs), j in (i + 1):length(outputs)
        Base.mightalias(outputs[i], outputs[j]) &&
            throw(_adapter_error("partition outputs must not alias each other"))
    end
    return VectorPartitionOwner(views, values(outputs))
end

function AlgorithmGraphs.prepare_graph_node(::Type{DetectorFrameLayoutNode}, config::DetectorFrameLayoutConfig,
        ::NamedTuple{()}, inputs::NamedTuple{(:detector_frame,)}, outputs::NamedTuple{(:frame,)},
        ::NamedTuple{()}, ::Backends.HostComputeDevice)
    detector_frame = _adapter_buffer(inputs.detector_frame, config.input_size)
    frame = _adapter_buffer(outputs.frame, config.output_size)
    Base.mightalias(frame, detector_frame) &&
        throw(_adapter_error("frame output must not alias its detector input"))
    rows = (config.origin[1] + 1):(config.origin[1] + config.input_size[1])
    columns = (config.origin[2] + 1):(config.origin[2] + config.input_size[2])
    return DetectorFrameLayoutOwner(detector_frame, view(frame, rows, columns), frame,
        config.scale, config.bias, config.range)
end

# Host wrappers and strided views are supported at the node protocol. Accelerator
# preparation and command-graph capture remain unqualified and unsupported.
AlgorithmGraphs.graph_node_capture_capability(::VectorPartitionOwner) = AlgorithmGraphs.GraphNodeCaptureUnsupported()
AlgorithmGraphs.graph_node_capture_capability(::DetectorFrameLayoutOwner) = AlgorithmGraphs.GraphNodeCaptureUnsupported()

function AlgorithmGraphs.step_graph_node!(owner::VectorPartitionOwner)
    map(copyto!, owner.outputs, owner.inputs)
    return nothing
end
function AlgorithmGraphs.reset_graph_node!(owner::VectorPartitionOwner)
    foreach(output -> fill!(output, 0f0), owner.outputs)
    return nothing
end

_layout_value(value, scale, bias, ::Nothing) = value * scale + bias
_layout_value(value, scale, bias, range::Tuple{Float32,Float32}) =
    clamp(value * scale + bias, range[1], range[2])

function AlgorithmGraphs.step_graph_node!(owner::DetectorFrameLayoutOwner)
    fill!(owner.frame, 0f0)
    owner.science .= _layout_value.(owner.detector_frame, owner.scale, owner.bias, Ref(owner.range))
    return nothing
end
function AlgorithmGraphs.reset_graph_node!(owner::DetectorFrameLayoutOwner)
    fill!(owner.frame, 0f0)
    return nothing
end
