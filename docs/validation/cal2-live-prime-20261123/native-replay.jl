length(ARGS) == 4 || error("expected APPLICATION BRANCH warm|skip CAPTURE")
const app, branch, mode, capture = ARGS
const image_dir = joinpath(app, "graph-startup", "cal2-" * branch)
pushfirst!(LOAD_PATH, image_dir)
pushfirst!(DEPOT_PATH, joinpath(image_dir, "depot"))
try
    Base.require(Main, :ExportedGraphWarmup)
finally
    popfirst!(DEPOT_PATH)
    popfirst!(LOAD_PATH)
end

using PipeWireAO, PipeWireAORTC, FilterGraphAlgorithms, FilterGraphs, FilterGraphPipeWire
using Libdl, LinearAlgebra

const RTC = PipeWireAORTC
const FGP = FilterGraphPipeWire
const FG = FilterGraphs
const Ext = Base.get_extension(RTC, :PipeWireAORTCGraphExt)
const Owner = RTC.GraphOwner
const Native = PipeWireAO.LibPipeWire
const Buffer = Native.pw_ndarray_filter_buffer
const UNAVAILABLE = Native.PW_NDARRAY_FILTER_BUFFER_FLAG_OUTPUT_UNAVAILABLE

function installed_workload()
    path = joinpath(image_dir, "depot", "compiled", "v1.13", "ExportedGraphWarmup.so")
    only(filter(==(path), Libdl.dllist()))
end

function prepare_controller()
    deployment = RTC.Common.read_json(joinpath(app, "deployment.conf"))
    owner = only(owner for owner in deployment["owners"] if owner["role"] == "cal2-" * branch)
    argv = owner["argv"][(findfirst(==("--"), owner["argv"]) + 1):end]
    bindings = Dict(
        "PACKAGE" => app, "RUNTIME" => tempdir(), "REMOTE" => "offline-cal2-replay",
        "BOOTSTRAP_INSTANCE_CAL2_" * uppercase(branch) => "1",
    )
    args = map(arg -> RTC.DeploymentConfiguration.substitute(arg, bindings), argv)
    binding, graph_args, fits, properties, timeout, recovery, supervision, offsets, qualification, local_output = Owner.arguments(args)
    options = if hasproperty(binding, :prime_on_output)
        Owner.graph_options(FGP, graph_args, properties, timeout, recovery, supervision,
            offsets, qualification, local_output; offline=true,
            prime_on_output=binding.prime_on_output)
    elseif qualification isa NamedTuple
        Owner.graph_options(FGP, graph_args, properties, timeout, recovery, supervision,
            offsets, qualification, local_output; offline=true)
    else
        Owner.graph_options(FGP, graph_args, properties, timeout, recovery, supervision,
            offsets, qualification, local_output)
    end
    entries = Owner.bindings(fits)
    declarations = FGP.algorithm_declarations(;
        packages=options.packages, algorithms=options.algorithms, builtins=options.builtins,
    )
    graph = FGP.prepare_service_graph(options.graph; algorithms=declarations,
        execution=:complete_frame, matrix_layout=options.matrix_layout,
        workers=options.row_workers, initial_parameters=formats -> Owner.prepare_bindings(entries, formats),
        parameters=options.parameters)
    return graph, options
end

function new_metadata()
    types = (SPA.META_HEADER, SPA.META_ACQUISITION_IDENTITY, SPA.META_EXPOSURE_TIMING,
        SPA.META_REFERENCE_TIMESTAMP, SPA.META_OPTICAL_CHOPPING, SPA.META_ELECTRICAL_TRIGGER)
    return MetadataSnapshot(map(MetadataRequirement, types))
end

function buffer(data::Vector, owner)
    extent = UInt32(sizeof(eltype(data)) * length(data))
    return Buffer(UInt32(sizeof(Buffer)), UInt32(0), Ptr{Cvoid}(pointer(data)),
        extent, extent, owner.count, 0, pointer(owner.descriptors))
end

function fill_input_metadata!(metadata, frame, seq)
    key = frame["identity"]
    duration = UInt64(frame["duration_ns"])
    pts = Int64((seq-1)*duration)
    writable = writable_metadata_records(metadata)
    identity = AcquisitionIdentity(AcquisitionDomain(Tuple(hex2bytes(key["domain"]))),
        UInt64(key["generation"]), UInt64(seq))
    header = BufferHeader(UInt32(frame["flags"]), UInt32(frame["offset"]), pts,
        Int64(frame["dts_offset"]), UInt64(seq))
    set_buffer_header!(writable, header)
    set_acquisition_identity!(writable, identity)
    set_exposure_timing!(writable, ExposureTiming(; duration_nanoseconds=duration))
    reference = frame["reference"]
    set_reference_timestamp!(writable, ReferenceTimestamp(reference["timestamp_ns"];
        clock=METADATA_CLOCK_REALTIME, duration_nanoseconds=reference["duration_ns"]))
    if frame["optical"] != "nothing"
        fringed = frame["optical"] == "OPTICAL_FRINGED"
        set_optical_classification!(writable, fringed ? OPTICAL_FRINGED : OPTICAL_UNFRINGED)
        set_trigger_classification!(writable, fringed ? ACQUISITION_TRIGGER_HIGH : ACQUISITION_TRIGGER_LOW)
    end
    return (; duration, pts, identity)
end

@noinline function timed_callback(
    @nospecialize(callback), @nospecialize(filter),
    inputs::NdArrayFilterBuffers{false}, outputs::NdArrayFilterBuffers{true},
)
    started = time_ns()
    Base.invokelatest(callback, filter, inputs, outputs)
    return time_ns() - started
end

no_callback(filter, input, output) = nothing

function exercise(node, graph, stream)
    phase_length = length(stream["frames"])
    packed = reinterpret(Float32, read(joinpath(capture, stream["payload"])))
    stride = prod(stream["shape"])
    images = [collect(@view packed[(i-1)*stride+1:i*stride]) for i in 1:phase_length]
    formats = FG.output_formats(graph)
    payloads = map(format -> fill(convert(format.element_type, 73), prod(format.shape)), formats)
    metas = map(_ -> new_metadata(), formats)
    inmeta = new_metadata()
    source_buffers = Buffer[buffer(first(images), inmeta)]
    output_buffers = Buffer[buffer(data, meta) for (data, meta) in zip(payloads, metas)]
    callback = node.filter.callbacks.on_process
    durations_ns = zeros(UInt64, 130)
    overhead_ns = zeros(UInt64, 128)
    scc = branch == "scc"
    GC.@preserve images payloads metas inmeta source_buffers output_buffers begin
        input = NdArrayFilterBuffers{false}(Ptr{Cvoid}(pointer(source_buffers)), UInt32(1))
        output = NdArrayFilterBuffers{true}(Ptr{Cvoid}(pointer(output_buffers)), UInt32(length(output_buffers)))
        for i in eachindex(overhead_ns)
            overhead_ns[i] = timed_callback(no_callback, node.filter, input, output)
        end
        for seq in eachindex(durations_ns)
            image_index = mod1(seq, phase_length)
            frame = stream["frames"][image_index]
            expected = fill_input_metadata!(inmeta, frame, seq)
            source_buffers[1] = buffer(images[image_index], inmeta)
            durations_ns[seq] = timed_callback(callback, node.filter, input, output)
            if scc && seq == 1
                all(record -> record.flags & UNAVAILABLE != 0, output_buffers) ||
                    error("SCC published before a live pair was available")
                all(data -> all(==(73), data), payloads) ||
                    error("priming overwrote withheld output")
                continue
            end
            all(record -> record.flags & UNAVAILABLE == 0, output_buffers) ||
                error("accepted exposure failed to publish")
            for metadata in metas
                header = buffer_header(metadata)
                header.pts == expected.pts && header.sequence == seq &&
                    acquisition_identity(metadata) == expected.identity ||
                    error("output metadata changed")
            end
            all(iszero, payloads[Symbol("physical-offset")]) ||
                error("open loop produced a correction")
            residual = payloads[Symbol("modal-residual")]
            all(isfinite, residual) && any(!iszero, residual) ||
                error("expected finite nonzero residual")
            scc && payloads[Symbol("pair-status")] != UInt8[1] &&
                error("SCC published without a complete pair")
        end
    end
    node.owner.process_count == length(durations_ns) ||
        error("unexpected callback count")
    return (; durations_ns, overhead_ns)
end

function main()
    loaded = installed_workload()
    BLAS.set_num_threads(1)
    stream = RTC.Common.read_json(joinpath(capture, "cal2-samples.json"))[branch * "-image"]
    graph, options = prepare_controller()
    (; node, observer) = Ext.graph_node(options, graph, Int64(1))
    try
        started = time_ns()
        mode == "warm" && Ext.warm_graph!(node, graph, options)
        warmup_ns = time_ns() - started
        FGP._prepare_owner(node.owner)
        node.owner.process_count == 0 || error("startup did not leave a fresh live owner")
        result = exercise(node, graph, stream)
        return (; result..., warmup_ns, loaded, pid=getpid(), julia=string(VERSION),
            threads=(Threads.nthreads(:default), Threads.nthreads(:interactive)),
            cpu=ccall(:sched_getcpu, Cint, ()), arm=mode, branch,
            graph_wire=string(pkgversion(FGP)), rtc=string(pkgversion(RTC)),
            graph_package=string(pkgversion(FG)), controller_observer=hasproperty(options, :prime_on_output))
    finally
        close(node)
        isnothing(observer) || close(observer)
        FGP.close_execution(graph)
    end
end

RTC.Common.write_json(ENV["CAL2_REPLAY_RESULT"], main())
