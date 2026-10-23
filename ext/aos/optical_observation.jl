module OpticalObservation

using AdaptiveOpticsSim
using AdaptiveOpticsSim.AlgorithmGraphs
using AdaptiveOpticsSim.AlgorithmGraphs: prepare_graph_output_snapshot, snapshot_values,
    poll_graph_output_snapshot!, snapshot_metadata, release_graph_output_snapshot!,
    try_snapshot_graph_output!, reset_graph_output_snapshot!,
    ShackHartmannRateNodeConfig, PyramidRateNodeConfig
using AdaptiveOpticsSimPipeWireHIL
using PipeWireAO
using ThreadPinning
using Base.Threads: Atomic, atomic_add!, atomic_cas!

const Optics = AdaptiveOpticsSim.Optics
const FOCAL_IMAGE_SCHEMA = "org.calculon.ao.focal-photon-rate.f32/1"
# Piston-removed OPD in nm on the transmitting pupil; excluded pixels are NaN.
const WAVEFRONT_SCHEMA = "org.calculon.ao.residual-pupil-opd.nm.f32/1"
# One row: uncorrected atmosphere RMS, corrected pupil RMS; both in nm OPD.
const RMS_SCHEMA = "org.calculon.ao.pupil-opd-rms.nm.f32/1"
const PERIOD_NS = UInt64(50_000_000)
const ZERO_PADDING = 2
const RMS_SHAPE = (1, 2)

mutable struct Observation{S,U,I,V,M}
    snapshot::S
    atmosphere_snapshot::U
    busy::Atomic{Bool}
    imaging::I
    values::V
    wavefront::V
    rms::V
    pupil::M
    stop::Atomic{Bool}
    failed::Atomic{Bool}
    completed::Atomic{UInt64}
    dropped::Atomic{UInt64}
    generation::UInt64
    next_sample_ns::UInt64
    task::Any
end

prepare(::Nothing, graph) = nothing
sensor_configuration(config) = nothing
sensor_configuration(config::ShackHartmannRateNodeConfig) = config
sensor_configuration(config::PyramidRateNodeConfig) = config
atmosphere_output(output) = false
atmosphere_output(::AdaptiveOpticsSim.AlgorithmGraphs.GraphOutputDefinition{:atmosphere_opd}) = true
reference_snapshots(::Nothing) = ()
reference_snapshots(snapshot) = (snapshot,)
snapshots(observation::Observation) =
    (observation.snapshot, reference_snapshots(observation.atmosphere_snapshot)...)

function guide_sensor(nodes::Tuple)
    sensors = filter(!isnothing, map(node -> sensor_configuration(node.config), nodes))
    length(sensors) == 1 || throw(ArgumentError("optical observation needs exactly one declared guide sensor"))
    return only(sensors)
end

"Describe the observation boundary from cold typed sensor configuration alone."
function port_contracts(nodes::Tuple; atmosphere::Bool)
    config = guide_sensor(nodes)
    resolution = config.telescope.resolution
    focal_resolution = Base.checked_mul(resolution, ZERO_PADDING)
    contract(shape) = Dict("shape" => collect(shape), "element-type" => "F32_LE")
    result = Dict("focal-image" => contract((focal_resolution, focal_resolution)),
        "residual-wavefront" => contract((resolution, resolution)))
    atmosphere && (result["wavefront-rms"] = contract(RMS_SHAPE))
    return result
end
port_contracts(definition::AlgorithmGraphDefinition) =
    port_contracts(definition.nodes; atmosphere=any(atmosphere_output, definition.outputs))

function verify_product(values, contract)
    collect(size(values)) == contract["shape"] && eltype(values) === Float32 ||
        throw(DimensionMismatch("optical observation product differs from its cold port contract"))
    return nothing
end

function prepare(definition::AlgorithmGraphDefinition, graph)
    config = guide_sensor(definition.nodes)
    contracts = port_contracts(definition)
    # Use the actual plant aperture and source, with no invented camera noise,
    # exposure or science wavelength. This product is ideal photon rate.
    telescope = Optics.prepare_telescope(config.telescope, AdaptiveOpticsSim.Backends.HostComputeDevice())
    source = config.source
    snapshot = prepare_graph_output_snapshot(graph, Val(:pupil_opd))
    atmosphere_snapshot = nothing
    try
        if any(atmosphere_output, definition.outputs)
            atmosphere_snapshot = prepare_graph_output_snapshot(graph, Val(:atmosphere_opd))
            axes(snapshot_values(atmosphere_snapshot)) == axes(snapshot_values(snapshot)) ||
                throw(DimensionMismatch("atmosphere and pupil OPD axes must match"))
        end
        pupil = Optics.PupilFunction(telescope, snapshot_values(snapshot))
        imaging = Optics.prepare_direct_imaging(pupil, source; zero_padding=ZERO_PADDING)
        Optics.form_direct_image!(imaging)
        focal = Matrix{Float32}(Optics.intensity_values(Optics.direct_imaging_output(imaging)))
        pupil_mask = Matrix{Bool}(Optics.pupil_mask(telescope))
        any(pupil_mask) || throw(ArgumentError("optical observation needs a transmitting pupil"))
        wavefront = Matrix{Float32}(undef, size(pupil_mask))
        verify_product(focal, contracts["focal-image"])
        verify_product(wavefront, contracts["residual-wavefront"])
        return Observation(snapshot, atmosphere_snapshot, Atomic{Bool}(false),
            imaging, focal, wavefront, zeros(Float32, RMS_SHAPE), pupil_mask, Atomic{Bool}(false),
            Atomic{Bool}(false), Atomic{UInt64}(0), Atomic{UInt64}(0), UInt64(0), UInt64(0), nothing)
    catch error
        try
            finalize_snapshots!(close, (snapshot, reference_snapshots(atmosphere_snapshot)...))
        catch cleanup
            throw(CompositeException([error, cleanup]))
        end
        rethrow()
    end
end

source_options(::Nothing) = ()
function source_options(observation::Observation)
    properties = Dict("node.loop.name"=>"observer-loop",
        "node.group"=>"pipewireao-optical-observation",
        "node.sync-group"=>"sync.pipewireao-optical-observation")
    images = (PipeWireImageSourceOptions(node_name="simulator-focal-image",
            media_name="focal-image", schema=FOCAL_IMAGE_SCHEMA,
            shape=size(observation.values), rate=SPA.Fraction(UInt32(20), UInt32(1)),
            buffers=3, properties=properties),
        PipeWireImageSourceOptions(node_name="simulator-residual-wavefront",
            media_name="residual-wavefront", schema=WAVEFRONT_SCHEMA,
            shape=size(observation.wavefront), rate=SPA.Fraction(UInt32(20), UInt32(1)),
            buffers=3, properties=properties))
    return (images..., rms_source_options(observation.atmosphere_snapshot, properties)...)
end

rms_source_options(::Nothing, properties) = ()
rms_source_options(snapshot, properties) =
    (PipeWireImageSourceOptions(node_name="simulator-wavefront-rms",
        media_name="wavefront-rms", schema=RMS_SCHEMA, shape=RMS_SHAPE,
        rate=SPA.Fraction(UInt32(20), UInt32(1)), buffers=3, properties=properties),)

# One producer admits the complete cohort before advancing the graph. Its busy
# flag stays set until the consumer releases every transfer, so independent
# snapshot slots cannot pair different graph frames under observer backpressure.
function submit!(observation::Observation; generation=observation.generation,
    pts=Int64(0), model_time_ns=Int64(0))
    atomic_cas!(observation.busy, false, true) == false || return false
    for snapshot in snapshots(observation)
        try_snapshot_graph_output!(snapshot; generation, pts, model_time_ns) ||
            throw(ArgumentError("optical snapshot cohort was not free"))
    end
    return true
end

function poll!(observation::Observation)
    observation.busy[] || return false
    ready = true
    for snapshot in snapshots(observation)
        ready &= poll_graph_output_snapshot!(snapshot)
    end
    return ready
end

function release!(observation::Observation)
    for snapshot in snapshots(observation)
        release_graph_output_snapshot!(snapshot)
    end
    observation.busy[] = false
    return nothing
end

function process_sample!(observation::Observation, pipewire)
    poll!(observation) || return false
    try
        metadata = snapshot_metadata(observation.snapshot)
        for snapshot in reference_snapshots(observation.atmosphere_snapshot)
            snapshot_metadata(snapshot) == metadata ||
                throw(ArgumentError("optical snapshot cohort metadata differs"))
        end
        # Reset may have advanced the source generation during optional imaging.
        metadata.generation == observation.generation || return false
        form_products!(observation)
        stage_pipewire_image!(pipewire, 1, observation.values, metadata.sequence,
            metadata.pts, metadata.generation)
        stage_pipewire_image!(pipewire, 2, observation.wavefront, metadata.sequence,
            metadata.pts, metadata.generation)
        stage_rms!(observation.atmosphere_snapshot, observation, pipewire, metadata)
    finally
        release!(observation)
    end
    atomic_add!(observation.completed, UInt64(1))
    return true
end

stage_rms!(::Nothing, observation, pipewire, metadata) = nothing
stage_rms!(snapshot, observation, pipewire, metadata) =
    stage_pipewire_image!(pipewire, 3, observation.rms, metadata.sequence,
        metadata.pts, metadata.generation)

function form_products!(observation::Observation)
    Optics.form_direct_image!(observation.imaging)
    copyto!(observation.values,
        Optics.intensity_values(Optics.direct_imaging_output(observation.imaging)))
    form_wavefront!(observation.wavefront, snapshot_values(observation.snapshot), observation.pupil)
    form_rms!(observation.atmosphere_snapshot, observation)
    return nothing
end

form_rms!(::Nothing, observation) = nothing
function form_rms!(atmosphere_snapshot, observation)
    observation.rms[1, 1] = pupil_rms_nm(snapshot_values(atmosphere_snapshot), observation.pupil)
    observation.rms[1, 2] = pupil_rms_nm(snapshot_values(observation.snapshot), observation.pupil)
    return nothing
end

# Spatial population RMS after removing pupil piston. Welford's update avoids
# subtracting two large moments and uses the same actual mask for both signals.
function pupil_rms_nm(opd, pupil)
    axes(opd) == axes(pupil) || throw(DimensionMismatch("OPD and pupil axes must match"))
    count = 0
    mean = 0.0
    variance_sum = 0.0
    for index in eachindex(opd, pupil)
        if pupil[index]
            value = Float64(opd[index])
            isfinite(value) || throw(ArgumentError("nonfinite OPD on the transmitting pupil"))
            count += 1
            delta = value - mean
            mean += delta / count
            variance_sum += delta * (value - mean)
        end
    end
    count > 0 || throw(ArgumentError("wavefront observation needs a transmitting pupil"))
    return Float32(sqrt(max(0.0, variance_sum / count)) * 1e9)
end

# Presentation of the same owned pupil snapshot used for ideal imaging. Uniform
# pupil-sample weighting matches the CPU replay metric; tip/tilt remain included.
# No controller state, graph output or physical command is modified.
function form_wavefront!(destination, opd, pupil)
    axes(destination) == axes(opd) == axes(pupil) ||
        throw(DimensionMismatch("wavefront image and pupil axes must match the OPD"))
    total = 0.0
    count = 0
    for index in eachindex(opd, pupil)
        if pupil[index]
            value = opd[index]
            isfinite(value) || throw(ArgumentError("nonfinite OPD on the transmitting pupil"))
            total += Float64(value)
            count += 1
        end
    end
    count > 0 || throw(ArgumentError("wavefront observation needs a transmitting pupil"))
    piston = total / count
    for index in eachindex(destination, opd, pupil)
        destination[index] = pupil[index] ? Float32((Float64(opd[index]) - piston) * 1e9) : NaN32
    end
    return destination
end

function worker!(observation::Observation, pipewire)
    # The cold static initializer schedules this task on default thread two.
    # Its CPU is declared by deployment; the source remains on thread one.
    current_task().sticky = true
    try
        Threads.threadid() == 2 || throw(ArgumentError("optical worker must run on Julia thread two"))
        cpu = parse(Int, ENV["PIPEWIREAO_OPTICAL_CPU"])
        ThreadPinning.pinthread(cpu)
        println("OPTICAL_WORKER thread=$(Threads.threadid()) cpu=$(ThreadPinning.getcpuid())")
        while !observation.stop[]
            process_sample!(observation, pipewire)
            GC.safepoint()
            yield()
        end
    catch
        # Optional observation faults stop observation only. The retained slot
        # is drained by close/reset; no exception crosses a native callback.
        observation.failed[] = true
    end
    return nothing
end

start!(::Nothing, pipewire) = nothing
function start!(observation::Observation, pipewire)
    observation.task === nothing || throw(ArgumentError("optical worker already started"))
    Threads.nthreads(:default) >= 2 && Threads.nthreads(:interactive) == 0 &&
        Threads.threadid() == 1 || throw(ArgumentError(
            "optical observation requires two default Julia threads with the source on thread one"))
    haskey(ENV, "PIPEWIREAO_OPTICAL_CPU") || throw(ArgumentError("optical worker CPU is not configured"))
    cpu = tryparse(Int, ENV["PIPEWIREAO_OPTICAL_CPU"])
    cpu !== nothing && cpu > 1 && cpu != ThreadPinning.getcpuid() ||
        throw(ArgumentError("optical worker CPU must differ from the source CPU and exclude CPU0/1"))
    observation.stop[] = false
    # Thread two also serves cold bootstrap polling. Both tasks yield; science
    # stays on thread one and no observation work enters a native callback.
    observation.task = ThreadPinning.@spawnat 2 worker!(observation, pipewire)
    return nothing
end

warm!(::Nothing, pipewire; check=()->nothing) = nothing
function pin_image_thread!(cpu::Integer)
    cpu > 1 || throw(ArgumentError("image thread CPU must exclude CPU0/1"))
    # pw_thread_loop_start passes only its name to the native thread creator.
    # Placement is deployment-owned and performed once before admission.
    root = "/proc/self/task"
    tids = filter(readdir(root)) do tid
        strip(read(joinpath(root, tid, "comm"), String)) == "AOS-HIL-images"
    end
    length(tids) == 1 || throw(ArgumentError("expected exactly one native image thread"))
    tid = only(tids)
    run(pipeline(`taskset -pc $cpu $tid`; stdout=devnull))
    status = read(joinpath(root, tid, "status"), String)
    affinity = match(r"(?m)^Cpus_allowed_list:\s*(.+)$", status)
    affinity !== nothing && strip(affinity.captures[1]) == string(cpu) ||
        throw(ArgumentError("native image thread CPU placement was not applied"))
    return nothing
end
function warm!(observation::Observation, pipewire; check=()->nothing)
    check()
    observation.generation = UInt64(frame_acquisition_generation(pipewire))
    pin_image_thread!(parse(Int, ENV["PIPEWIREAO_OPTICAL_CPU"]))
    start!(observation, pipewire)
    target = observation.completed[] + UInt64(1)
    submit!(observation;
        generation=observation.generation) ||
        throw(ArgumentError("cannot warm the optical snapshot"))
    deadline = time_ns() + UInt64(30_000_000_000)
    while observation.completed[] < target
        check()
        observation.failed[] && throw(ArgumentError("optical worker failed during preparation"))
        time_ns() < deadline || throw(ArgumentError("optical worker preparation timed out"))
        GC.safepoint()
        yield()
    end
    reset_pipewire_image_sources!(pipewire)
    # Keep the actual warmed task and its CUDA task-local state alive. The
    # completion counter publishes only after the slot has been released.
    return nothing
end

sample!(::Nothing, timing, model_ns, now) = false
function sample!(observation::Observation, timing::PipeWireFrameCommandTiming, model_ns::Int64, now::UInt64)
    observation.failed[] && return false
    now < observation.next_sample_ns && return false
    observation.next_sample_ns = now + PERIOD_NS
    pts = timing.source_published_nanoseconds
    admitted = try
        submit!(observation;
            generation=observation.generation, pts, model_time_ns=model_ns)
    catch
        observation.failed[] = true
        false
    end
    admitted || atomic_add!(observation.dropped, UInt64(1))
    return admitted
end

stop_worker!(::Nothing) = nothing
function stop_worker!(observation::Observation)
    observation.stop[] = true
    task = observation.task
    task === nothing || wait(task)
    observation.task = nothing
    return nothing
end

reset!(::Nothing, pipewire; check=()->nothing) = nothing
function reset!(observation::Observation, pipewire; check=()->nothing)
    observation.next_sample_ns = 0
    observation.failed[] = false
    warm!(observation, pipewire; check)
    return nothing
end

drain!(::Nothing) = nothing
function drain!(observation::Observation)
    stop_worker!(observation)
    finalize_snapshots!(reset_graph_output_snapshot!, observation)
    observation.busy[] = false
    return nothing
end

close!(::Nothing) = nothing
function close!(observation::Observation)
    stop_worker!(observation)
    finalize_snapshots!(close, observation)
    return nothing
end

finalize_snapshots!(operation, observation::Observation) =
    finalize_snapshots!(operation, snapshots(observation))
function finalize_snapshots!(operation, owned::Tuple)
    failures = Exception[]
    for snapshot in owned
        try operation(snapshot) catch error; push!(failures, error) end
    end
    isempty(failures) || throw(length(failures) == 1 ? only(failures) : CompositeException(failures))
    return nothing
end

function close!(observation, pipewire)
    failures = Exception[]
    try
        close!(observation)
    catch error
        push!(failures, error)
    end
    try pipewire === nothing || close(pipewire) catch error; push!(failures, error) end
    isempty(failures) || throw(length(failures) == 1 ? only(failures) : CompositeException(failures))
    return nothing
end

end
