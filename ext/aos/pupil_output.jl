"Scientific completed pupil frames; the source owner never waits on transport."
module PupilOutput

import PipeWireAORTC
using AdaptiveOpticsSim.AlgorithmGraphs
using AdaptiveOpticsSim.AlgorithmGraphs: prepare_graph_output_snapshot, snapshot_values,
    poll_graph_output_snapshot!, snapshot_metadata, release_graph_output_snapshot!,
    try_snapshot_graph_output!, reset_graph_output_snapshot!, external_pupil_contract
using AdaptiveOpticsSimPipeWireHIL
using PipeWireAO
using JSON
using ThreadPinning
using UUIDs
using Base.Threads: Atomic, atomic_add!

const Extension = parentmodule(@__MODULE__)
const IC = PipeWireAORTC.InstrumentConfiguration
const NODE_NAME = "simulator-pupil-output"

# Names and units follow AOS external_pupil_contract; the Stream exposes output_1.
# This is cold Node information, not part of the scientific packet or its hash.
function source_planes(boundary, format)
    length(format.shape) == 3 && first(format.shape) == 2 ||
        throw(ArgumentError("scientific pupil output requires two quantity planes"))
    descriptor = JSON.json((; version=2, outputs=((;
        port="output_1", schema=boundary.schema,
        element_type=UInt32(format.element_type), layout=UInt32(format.layout), shape=format.shape,
        planes=((; name="opd_m", index=0, title="Pupil OPD", units="m OPD"),
            (; name="amplitude", index=1, title="Pupil amplitude", units="relative field amplitude"))),)))
    ncodeunits(descriptor) <= 16384 ||
        throw(ArgumentError("scientific pupil planes exceed 16384 UTF-8 bytes"))
    return descriptor
end

function PipeWireAORTC.InstrumentExport.pupil_output_port_contract(path::AbstractString;
        settings=Dict(), simulation_graph="production")
    declaration = IC.load_simulation(path)
    boundary = contract(declaration, IC.settings(declaration, settings); simulation_graph)
    return Dict("schema" => boundary.schema, "shape" => collect(boundary.shape),
        "element-type" => string(NdArray.F32_LE), "layout" => "ROW_MAJOR")
end

mutable struct Publisher{S,O}
    snapshot::S
    amplitude::Matrix{Float32}
    packet::Array{Float32,3}
    options::O
    domain::AcquisitionDomain
    period_ns::UInt64
    generation::Atomic{UInt64}
    flushed::Atomic{UInt64}
    paused::Atomic{Bool}
    drain_request::Atomic{UInt64}
    drained::Atomic{UInt64}
    stop::Atomic{Bool}
    registered::Atomic{Bool}
    failed::Atomic{Bool}
    completed::Atomic{UInt64}
    dropped::Atomic{UInt64}
    transport_dropped::Atomic{UInt64}
    gaps::Atomic{UInt64}
    sequence::UInt64 # worker-owned last staged source sequence in this generation
    task::Any
end

function contract(declaration, configured; simulation_graph="production")
    output = IC.pupil_output(declaration, configured; simulation_graph)
    output === nothing && throw(ArgumentError("scientific pupil output is not declared"))
    optical = output.optical
    boundary = external_pupil_contract(; output.pupil_resolution,
        diameter_m=optical["diameter_m"], plane=optical["plane"],
        curvature=optical["curvature"], registration=optical["registration"])
    PipeWireAORTC.Artifacts.checked_shape(boundary.shape, sizeof(Float32))
    return boundary
end

function prepare(graph, opd::Symbol, amplitude::AbstractMatrix{Float32}, boundary;
        period_ns::UInt64, properties=Dict{String,String}())
    Base.require_one_based_indexing(amplitude)
    PipeWireAORTC.Artifacts.checked_shape(boundary.shape, sizeof(Float32))
    size(amplitude) == Base.tail(boundary.shape) || throw(DimensionMismatch("pupil amplitude shape differs from contract"))
    all(x -> isfinite(x) && x >= 0, amplitude) && any(>(0), amplitude) ||
        throw(ArgumentError("pupil amplitude must be finite, nonnegative and transmitting"))
    period_ns > 0 || throw(ArgumentError("pupil output period must be positive"))
    snapshot = prepare_graph_output_snapshot(graph, opd)
    try
        values = snapshot_values(snapshot)
        eltype(values) === Float32 && size(values) == size(amplitude) ||
            throw(DimensionMismatch("scientific pupil output requires matching Float32 OPD and amplitude"))
        format = NdArrayFormat(NdArray.F32_LE, boundary.shape; layout=NdArray.ROW_MAJOR)
        extra = merge(Dict(boundary.properties), Dict(properties),
            Dict("node.loop.name" => "telemetry-loop", "aos.pupil-output.failed" => "false",
                "aos.pupil-output.completed" => "0", "aos.pupil-output.dropped" => "0",
                "pipewireao.ndarray.channels" => source_planes(boundary, format)))
        option = PipeWireArrayStreamOptions(node_name=NODE_NAME, media_name="scientific pupil",
            schema=boundary.schema, format=format, properties=extra)
        bits = uuid4().value
        domain = AcquisitionDomain(ntuple(i -> UInt8((bits >> (8 * (i - 1))) & 0xff), Val(16)))
        return Publisher(snapshot, Matrix(amplitude), Array{Float32}(undef, boundary.shape), option,
            domain, period_ns, Atomic{UInt64}(1), Atomic{UInt64}(0), Atomic{Bool}(false),
            Atomic{UInt64}(0), Atomic{UInt64}(0), Atomic{Bool}(false), Atomic{Bool}(false), Atomic{Bool}(false),
            Atomic{UInt64}(0), Atomic{UInt64}(0), Atomic{UInt64}(0), Atomic{UInt64}(0), UInt64(0), nothing)
    catch
        close(snapshot)
        rethrow()
    end
end

function prepare(options, science)
    get(options, :pupil_output, false) || return nothing
    declaration = IC.load_simulation(options.plant.definition)
    configured = IC.settings(declaration, options.plant.settings)
    selected = get(options.plant, :graph, "production")
    output = IC.pupil_output(declaration, configured; simulation_graph=selected)
    boundary = contract(declaration, configured; simulation_graph=selected)
    amplitude = getproperty(Extension.prepare_bindings(declaration, configured, (output.amplitude,)), output.amplitude)
    properties = Extension.simulation_properties(options, science)
    properties["aos.simulation.prescription-identity"] = options.prescription_identity
    return prepare(science.graph, output.opd, amplitude, boundary; options.period_ns, properties)
end

"One-based host snapshot [x,y] becomes [quantity,y,x]; no display transform."
function pack!(packet::Array{Float32,3}, opd::AbstractMatrix{Float32}, amplitude::Matrix{Float32})
    Base.require_one_based_indexing(opd)
    axes(opd) == axes(amplitude) && size(packet) == (2, size(opd, 2), size(opd, 1)) ||
        throw(DimensionMismatch("scientific pupil packet axes differ"))
    for x in axes(opd, 1), y in axes(opd, 2)
        value = opd[x, y]
        isfinite(value) || throw(ArgumentError("scientific pupil OPD must be finite"))
        packet[1, y, x] = value
        packet[2, y, x] = amplitude[x, y]
    end
    return packet
end

sample!(::Nothing; kwargs...) = false
function sample!(publisher::Publisher; generation::UInt64, model_ns::Int64)
    (publisher.failed[] || publisher.paused[]) && return false
    accepted = try
        try_snapshot_graph_output!(publisher.snapshot; generation, pts=model_ns, model_time_ns=model_ns)
    catch
        publisher.failed[] = true
        false
    end
    accepted || atomic_add!(publisher.dropped, UInt64(1))
    return accepted
end

status(::Nothing) = nothing
status(p::Publisher) = (; failed=p.failed[], completed=p.completed[], dropped=p.dropped[],
    transport_dropped=p.transport_dropped[], gaps=p.gaps[], generation=p.generation[])
registered(::Nothing) = true
registered(p::Publisher) = p.registered[]

function publish_status!(p, owner; failure=nothing)
    transport = array_stream_status(owner, 1)
    p.transport_dropped[] = transport.dropped
    transport.failed && (p.failed[] = true)
    properties = Dict("aos.pupil-output.failed" => string(p.failed[]),
        "aos.pupil-output.completed" => string(p.completed[]),
        "aos.pupil-output.dropped" => string(p.dropped[]),
        "aos.pupil-output.transport-dropped" => string(p.transport_dropped[]),
        "aos.pupil-output.gaps" => string(p.gaps[]),
        "aos.pupil-output.generation" => string(p.generation[]))
    failure === nothing || (properties["aos.pupil-output.failure"] =
        first(replace(sprint(showerror, failure), '\0' => '?'), 1024))
    with_array_stream(owner, 1) do stream
        properties["aos.pupil-output.stream-state"] = string(stream_state(stream))
        properties["aos.pupil-output.driving"] = string(is_driving(stream))
        update_properties!(stream, properties)
    end
    return nothing
end

function process_sample!(p, owner)
    poll_graph_output_snapshot!(p.snapshot) || return false
    try
        metadata = snapshot_metadata(p.snapshot)
        metadata.generation == p.generation[] || return false
        pack!(p.packet, snapshot_values(p.snapshot), p.amplitude)
        if metadata.sequence != 0 # Cold warmup must never appear as scientific data.
            accepted = stage_pipewire_array!(owner, 1, p.packet;
                identity=AcquisitionIdentity(p.domain, metadata.generation, metadata.sequence),
                pts=metadata.model_time_ns, duration=p.period_ns)
            accepted || atomic_add!(p.dropped, UInt64(1))
            if accepted
                atomic_add!(p.gaps, metadata.sequence - p.sequence - UInt64(1))
                p.sequence = metadata.sequence
            end
        end
    finally
        release_graph_output_snapshot!(p.snapshot)
    end
    atomic_add!(p.completed, UInt64(1))
    return true
end

function worker!(p, remote, cpu)
    cpu === nothing || ThreadPinning.pinthread(cpu)
    with_array_streams((p.options,); remote, input=(false,)) do owner
        cpu === nothing || PipeWireAORTC.Placement.pin_loop!(owner.loop, cpu)
        next_status = next_trigger = UInt64(0)
        trigger_period = max(p.period_ns, UInt64(100_000))
        while !p.stop[]
            try
                request = p.drain_request[]
                if p.drained[] != request
                    reset_graph_output_snapshot!(p.snapshot)
                    p.drained[] = request
                end
                if p.flushed[] != p.generation[]
                    reset_pipewire_arrays!(owner; identity=AcquisitionIdentity(p.domain, p.generation[], UInt64(0)))
                    p.sequence = 0
                    p.gaps[] = 0
                    p.flushed[] = p.generation[]
                end
                if !p.paused[] && !p.failed[]
                    process_sample!(p, owner)
                    # An unlinked source holds the latest packet. Never drive a
                    # native graph until it has a streaming consumer.
                    if time_ns() >= next_trigger
                        pending = array_stream_status(owner, 1).pending
                        with_array_stream(owner, 1) do stream
                            p.registered[] = node_id(stream) != typemax(UInt32) && stream_state(stream) in
                                (PipeWireAO.LibPipeWire.PW_STREAM_STATE_PAUSED, PipeWireAO.LibPipeWire.PW_STREAM_STATE_STREAMING)
                            pending && stream_state(stream) == PipeWireAO.LibPipeWire.PW_STREAM_STATE_STREAMING &&
                                is_driving(stream) && trigger_process!(stream)
                        end
                        next_trigger = time_ns() + trigger_period
                    end
                end
                if time_ns() >= next_status
                    publish_status!(p, owner)
                    next_status = time_ns() + UInt64(100_000_000)
                end
            catch failure
                p.failed[] = true
                # Retain the optional port until final owner cleanup. Its loss
                # would otherwise invalidate the session's native node ledger.
                try publish_status!(p, owner; failure) catch end
            end
            yield()
            GC.safepoint()
        end
    end
    return nothing
end

function await!(predicate, p; check=()->nothing)
    deadline = time_ns() + UInt64(30_000_000_000)
    while !predicate()
        check()
        if p.task !== nothing && istaskdone(p.task)
            fetch(p.task)
            error("scientific pupil worker stopped before acknowledging cold operation")
        end
        time_ns() < deadline || error("scientific pupil worker did not acknowledge cold operation")
        sleep(0.001)
    end
    return nothing
end

start!(::Nothing; kwargs...) = nothing
function start!(p::Publisher; remote, cpu=nothing, check=()->nothing)
    Threads.nthreads(:default) >= 3 || throw(ArgumentError("pupil output requires three Julia threads"))
    p.task = ThreadPinning.@spawnat 3 begin
        current_task().sticky = true
        worker!(p, remote, cpu)
    end
    # Compile the actual snapshot/packing path without emitting sequence zero.
    sample!(p; generation=p.generation[], model_ns=Int64(0)) || error("pupil warmup snapshot was not free")
    await!(() -> p.failed[] || (p.registered[] && p.completed[] > 0), p; check)
    p.failed[] && error("scientific pupil worker failed during preparation")
    p.completed[] = 0
    return nothing
end

drain!(::Nothing; kwargs...) = nothing
function drain!(p::Publisher; check=()->nothing)
    p.paused[] = true
    request = atomic_add!(p.drain_request, UInt64(1)) + UInt64(1)
    await!(() -> p.drained[] == request, p; check)
    return nothing
end

reset!(::Nothing, generation; kwargs...) = nothing
function reset!(p::Publisher, generation::UInt64; check=()->nothing)
    p.paused[] && p.drained[] == p.drain_request[] || error("pupil output must be drained before reset")
    generation > p.generation[] || error("pupil output generation must increase")
    p.generation[] = generation
    await!(() -> p.flushed[] == generation, p; check)
    p.paused[] = false
    return nothing
end

close!(::Nothing) = nothing
function close!(p::Publisher)
    p.stop[] = true
    try
        p.task === nothing || wait(p.task)
    finally
        close(p.snapshot)
    end
    return nothing
end

end
