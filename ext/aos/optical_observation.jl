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
using Base.Threads: Atomic, atomic_add!

const Optics = AdaptiveOpticsSim.Optics
const FOCAL_IMAGE_SCHEMA = "org.calculon.ao.focal-photon-rate.f32/1"
# Piston-removed OPD in nm on the transmitting pupil; excluded pixels are NaN.
const WAVEFRONT_SCHEMA = "org.calculon.ao.residual-pupil-opd.nm.f32/1"
const PERIOD_NS = UInt64(50_000_000)

mutable struct Observation{S,I,V,M}
    snapshot::S
    imaging::I
    values::V
    wavefront::V
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
function prepare(definition::AlgorithmGraphDefinition, graph)
    sensors = filter(!isnothing, map(node -> sensor_configuration(node.config), definition.nodes))
    length(sensors) == 1 || throw(ArgumentError("optical observation needs exactly one declared guide sensor"))
    config = only(sensors)
    # Use the actual plant aperture and source, with no invented camera noise,
    # exposure or science wavelength. This product is ideal photon rate.
    telescope = Optics.prepare_telescope(config.telescope, AdaptiveOpticsSim.Backends.HostComputeDevice())
    source = config.source
    snapshot = prepare_graph_output_snapshot(graph, Val(:pupil_opd))
    try
        pupil = Optics.PupilFunction(telescope, snapshot_values(snapshot))
        imaging = Optics.prepare_direct_imaging(pupil, source; zero_padding=2)
        Optics.form_direct_image!(imaging)
        focal = Matrix{Float32}(Optics.intensity_values(Optics.direct_imaging_output(imaging)))
        pupil_mask = Matrix{Bool}(Optics.pupil_mask(telescope))
        any(pupil_mask) || throw(ArgumentError("optical observation needs a transmitting pupil"))
        wavefront = Matrix{Float32}(undef, size(pupil_mask))
        return Observation(snapshot, imaging, focal, wavefront, pupil_mask, Atomic{Bool}(false),
            Atomic{Bool}(false), Atomic{UInt64}(0), Atomic{UInt64}(0), UInt64(0), UInt64(0), nothing)
    catch
        close(snapshot)
        rethrow()
    end
end

source_options(::Nothing) = ()
function source_options(observation::Observation)
    properties = Dict("node.loop.name"=>"observer-loop",
        "node.group"=>"pipewireao-optical-observation",
        "node.sync-group"=>"sync.pipewireao-optical-observation")
    return (PipeWireImageSourceOptions(node_name="simulator-focal-image",
            media_name="focal-image", schema=FOCAL_IMAGE_SCHEMA,
            shape=size(observation.values), rate=SPA.Fraction(UInt32(20), UInt32(1)),
            buffers=3, properties),
        PipeWireImageSourceOptions(node_name="simulator-residual-wavefront",
            media_name="residual-wavefront", schema=WAVEFRONT_SCHEMA,
            shape=size(observation.wavefront), rate=SPA.Fraction(UInt32(20), UInt32(1)),
            buffers=3, properties))
end

function process_sample!(observation::Observation, pipewire)
    poll_graph_output_snapshot!(observation.snapshot) || return false
    try
        metadata = snapshot_metadata(observation.snapshot)
        # Reset may have advanced the source generation during optional imaging.
        metadata.generation == observation.generation || return false
        form_products!(observation)
        stage_pipewire_image!(pipewire, 1, observation.values, metadata.sequence,
            metadata.pts, metadata.generation)
        stage_pipewire_image!(pipewire, 2, observation.wavefront, metadata.sequence,
            metadata.pts, metadata.generation)
    finally
        release_graph_output_snapshot!(observation.snapshot)
    end
    atomic_add!(observation.completed, UInt64(1))
    return true
end

function form_products!(observation::Observation)
    Optics.form_direct_image!(observation.imaging)
    copyto!(observation.values,
        Optics.intensity_values(Optics.direct_imaging_output(observation.imaging)))
    form_wavefront!(observation.wavefront, snapshot_values(observation.snapshot), observation.pupil)
    return nothing
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
    try_snapshot_graph_output!(observation.snapshot;
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
        try_snapshot_graph_output!(observation.snapshot;
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
    reset_graph_output_snapshot!(observation.snapshot)
    return nothing
end

close!(::Nothing) = nothing
function close!(observation::Observation)
    stop_worker!(observation)
    close(observation.snapshot)
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
