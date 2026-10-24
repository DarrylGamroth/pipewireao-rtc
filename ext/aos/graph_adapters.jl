# Detector placement and affine conversion for configured AOS graphs.
# Boundary semantics follow the former GPI2Sim FrameLayoutNode.
# Dimensions are [rows, columns]; the detector origin counts from zero.

struct DetectorFrameLayoutNode end
struct DetectorFrameLayoutConfig{R,Q}
    input_size::Tuple{Int,Int}
    output_size::Tuple{Int,Int}
    origin::Tuple{Int,Int}
    scale::Float32
    bias::Float32
    range::R
    rounding::Q
    input_schema::String
    output_schema::String
end
struct DetectorFrameLayoutOwner{I,S,O,R,Q}
    detector_frame::I
    science::S
    frame::O
    scale::Float32
    bias::Float32
    range::R
    rounding::Q
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

function _adapter_range(value::Tuple, context)
    _adapter_tuple(value, 2, context)
    lower, upper = map(bound -> _adapter_f32(bound, context), value)
    value[1] <= value[2] || throw(_adapter_error("$context lower bound exceeds upper bound"))
    return (lower, upper)
end
_adapter_range(::Nothing, context) = nothing
_adapter_range(value, context) = throw(_adapter_error("$context must contain two real bounds"))

function _adapter_rounding(value::AbstractString, context)
    value == "none" && return nothing
    value == "nearest_even" && return RoundNearest
    throw(_adapter_error("$context must be 'none' or 'nearest_even'"))
end
_adapter_rounding(value, context) = throw(_adapter_error("$context must be 'none' or 'nearest_even'"))

function _adapter_rounding_range(range::Tuple, ::typeof(RoundNearest), context)
    all(isinteger, range) || throw(_adapter_error("$context requires integral bounds with nearest_even rounding"))
    return nothing
end
_adapter_rounding_range(range, rounding, context) = nothing

function _detector_frame_layout_f32_node(name::Symbol, config::NamedTuple, props::NamedTuple)
    fields = (:input_size, :output_size, :origin, :scale, :bias, :range, :rounding,
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
    rounding = _adapter_rounding(get(config, :rounding, "none"), "$context.rounding")
    _adapter_rounding_range(get(config, :range, nothing), rounding, "$context.range")
    input_schema = _adapter_string(config.input_schema, "$context.input_schema")
    output_schema = _adapter_string(config.output_schema, "$context.output_schema")
    return algorithm_node(name, DetectorFrameLayoutNode,
        DetectorFrameLayoutConfig(input_size, output_size, origin, scale, bias,
            range, rounding, input_schema, output_schema))
end

"""
Cold factory registry extending AOS with CPU detector layout:

- `detector_frame_layout_f32`: `input_size` and `output_size` in [rows, columns],
  zero-based `origin`, `scale`, `bias`, `input_schema`, and `output_schema`.
  Input `detector_frame` is placed in output `frame` with zero padding. Omit
  `range` for `input * scale + bias`; provide `[lower, upper]` to clamp it.
  Optional `rounding` is `"none"` (the default) or `"nearest_even"` to round
  the converted, clipped value to the nearest integer with ties to even while
  retaining Float32 storage. Rounded ranges require integral bounds.

The node resets its output buffer to zero and requires one-based Float32
arrays. Accelerator execution and command-graph capture are unsupported.
"""
function configured_graph_node_types()
    return merge(builtin_graph_node_types(), (
        detector_frame_layout_f32=_detector_frame_layout_f32_node,))
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
        config.scale, config.bias, config.range, config.rounding)
end

# Host wrappers and strided views are supported at the node protocol. Accelerator
# preparation and command-graph capture remain unqualified and unsupported.
AlgorithmGraphs.graph_node_capture_capability(::DetectorFrameLayoutOwner) = AlgorithmGraphs.GraphNodeCaptureUnsupported()

_layout_value(value, scale, bias, ::Nothing) = value * scale + bias
_layout_value(value, scale, bias, range::Tuple{Float32,Float32}) =
    clamp(value * scale + bias, range[1], range[2])
_layout_round(value, ::Nothing) = value
_layout_round(value, rounding::typeof(RoundNearest)) = round(value, rounding)
_layout_value(value, scale, bias, range, rounding) =
    _layout_round(_layout_value(value, scale, bias, range), rounding)

function AlgorithmGraphs.step_graph_node!(owner::DetectorFrameLayoutOwner)
    fill!(owner.frame, 0f0)
    owner.science .= _layout_value.(owner.detector_frame, owner.scale, owner.bias,
        Ref(owner.range), Ref(owner.rounding))
    return nothing
end
function AlgorithmGraphs.reset_graph_node!(owner::DetectorFrameLayoutOwner)
    fill!(owner.frame, 0f0)
    return nothing
end
