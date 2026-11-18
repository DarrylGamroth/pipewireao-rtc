using AdaptiveOpticsSimPipeWireHIL
using LinearAlgebra
using Statistics
using PipeWireAO
using PipeWireAORTC

const FITS = PipeWireAORTC.InstrumentConfiguration.FITSIO.FITS
const HIL = AdaptiveOpticsSimPipeWireHIL
const RTC = PipeWireAORTC
const GRAPH = "spiders-controller"
const REGION = "generated/dual-calibration/scc/artifacts/scc-pixel-mask.fits"
const CAMERA = "spiders-scc"

const DEMAND_SCHEMA = "pipewireao/demanded-pdm-command-f32/1"
const DEMAND_INDEX = 2
const DEMAND_OUTPUT = "dm-command"
const DEMAND_NAME = "scc-error-command"
const DEMAND_METADATA = (
    MetadataRequirement(SPA.META_ACQUISITION_IDENTITY; required=false),
)

function port(registry, name, direction, label)
    node = only(find_globals(registry; interface="PipeWire:Interface:Node",
        properties=("node.name" => name,)))
    endpoint = only(find_globals(registry; interface="PipeWire:Interface:Port",
        properties=("node.id" => string(node.id), "port.direction" => direction,
            "port.name" => label)))
    return node.id, endpoint.id
end

function observe(wire, registry, producer, output, observer)
    port_ids = Ref{NTuple{4,UInt32}}()
    status = timedwait(30; pollint=0.1) do
        roundtrip(registry)
        try
            a = port(registry, producer, "out", output)
            b = port(registry, observer, "in", "input_1")
            port_ids[] = (a..., b...)
            return true
        catch failure
            failure isa ArgumentError || rethrow()
            return false
        end
    end
    status === :ok || error("Could not discover the Ports for $producer:$output")
    a, ap, b, bp = port_ids[]
    return HIL.with_array_stream(wire, 1) do _
        create_object(wire.core, "link-factory", Link; properties=Dict(
            "link.output.node" => string(a), "link.output.port" => string(ap),
            "link.input.node" => string(b), "link.input.port" => string(bp),
            "link.passive" => "true", "object.linger" => "false"))
    end
end

const BURN_IN = 2048
const LAST_EXPOSURE = 4096
const CAMERAS = ("spiders-scc", "output_1")
const MEASUREMENT_METADATA = (
    RTC.Common.ACQUISITION_METADATA...,
    MetadataRequirement(SPA.META_OPTICAL_CHOPPING; required=true),
)
const ASSETS = "generated/dual-calibration/scc/artifacts"
const BLOCK = 512

struct CameraSample
    pts::Int64
    phase::OpticalClassification
    mean_intensity::Float64
end

struct ResidualSample
    pts::Int64
    power::Float64
    coordinates::Vector{Float64}
end

struct Epoch
    camera::Dict{Int,CameraSample}
    pixels::Dict{Int,ResidualSample}
    modes::Dict{Int,ResidualSample}
    demand::NamedTuple
end

mutable struct Images
    open_frames::Dict{Int,Matrix{Float32}}
    open_sum::Matrix{Float64}
    closed_sum::Matrix{Float64}
    sequences::Vector{Int}
end

Images(shape) = Images(Dict{Int,Matrix{Float32}}(), zeros(shape), zeros(shape), Int[])

function read_asset(root, relative)
    return FITS(joinpath(root, relative)) do file
        array = read(file[1])
        return ndims(array) == 2 ? permutedims(array) : array
    end
end

function retain_image!(images, label, image, index, camera, baseline)
    iseven(index) || return nothing
    if label == "open"
        images.open_frames[index] = copy(image)
    elseif haskey(images.open_frames, index)
        @assert baseline[index].pts == camera.pts
        images.open_sum .+= images.open_frames[index]
        images.closed_sum .+= image
        push!(images.sequences, index)
    end
    return nothing
end

function retained_index(sample, generation)
    identity = something(sample.identity)
    identity.generation == generation || return nothing
    index = Int(identity.sequence)
    BURN_IN < index <= LAST_EXPOSURE || return nothing
    @assert sample.pts == (index - 1) * 10_000_000
    return index
end

function collect_epoch!(wire, demand, label, generation, mask, basis, images, baseline)
    image = zeros(Float32, size(mask))
    actual = zeros(Float32, demand.option.format.shape)
    command_count = 0
    identified_count = 0
    command_cohorts = Dict{Tuple{AcquisitionDomain,UInt64},Int}()
    late_commands = Dict{Int,Vector{Float32}}()
    contemporaneous_count = 0
    contemporaneous_sum = zeros(Float64, length(actual))
    first_sequence = nothing
    last_sequence = nothing
    peak = nothing
    pixel_error = zeros(Float32, count(mask))
    modal_error = zeros(Float32, size(basis, 2) + 2)
    camera = Dict{Int,CameraSample}()
    pixels = Dict{Int,ResidualSample}()
    modes = Dict{Int,ResidualSample}()
    selected = findall(mask)
    last_image = nothing
    camera_domain = nothing
    last_pixel = 0
    last_mode = 0
    clock = RTC.SessionRuntime.Clocks.SystemNanoClock()
    deadline = RTC.SessionRuntime.Clocks.time_nanos(clock) + 900_000_000_000
    while RTC.SessionRuntime.Clocks.time_nanos(clock) < deadline
        frame = HIL.drain_pipewire_array!(image, wire, 1)
        if frame !== nothing && something(frame.identity).generation == generation
            @assert all(isfinite, image)
            identity = something(frame.identity)
            camera_domain = something(camera_domain, identity.domain)
            @assert camera_domain == identity.domain
            index = retained_index(frame, generation)
            if index !== nothing
                role = isodd(index) ? OPTICAL_FRINGED : OPTICAL_UNFRINGED
                @assert frame.optical_classification == role
                camera[index] = CameraSample(frame.pts, role,
                    sum(i -> Float64(image[i]), selected) / length(selected))
                retain_image!(images, label, image, index, camera[index], baseline)
            end
            last_image = Int(identity.sequence)
        end
        receipt = HIL.drain_pipewire_array!(actual, wire, DEMAND_INDEX)
        if receipt !== nothing
            all(isfinite, actual) && maximum(abs, actual) <= 0.5f0 ||
                error("Nonfinite or out-of-range DM demand in $label")
            command_count += 1
            first_sequence = something(first_sequence, receipt.sequence)
            last_sequence = receipt.sequence
            peak = max(something(peak, 0f0), maximum(abs, actual))
            identity = receipt.identity
            if identity !== nothing
                identified_count += 1
                cohort = (identity.domain, identity.generation)
                command_cohorts[cohort] = get(command_cohorts, cohort, 0) + 1
            end
            if same_acquisition_cohort(identity, camera_domain, generation)
                if BURN_IN < identity.sequence <= LAST_EXPOSURE
                    late_commands[Int(identity.sequence)] = copy(actual)
                end
            elseif last_image !== nothing && BURN_IN < last_image <= LAST_EXPOSURE
                contemporaneous_count += 1
                contemporaneous_sum .+= actual
            end
        end
        pixel_receipt = HIL.drain_pipewire_array!(pixel_error, wire, 3)
        if pixel_receipt !== nothing && something(pixel_receipt.identity).generation == generation
            last_pixel = Int(something(pixel_receipt.identity).sequence)
            index = retained_index(pixel_receipt, generation)
            if index !== nothing
                @assert all(isfinite, pixel_error)
                residual = Float64.(pixel_error)
                pixels[index] = ResidualSample(pixel_receipt.pts, sum(abs2, residual),
                    transpose(basis) * residual)
            end
        end
        mode_receipt = HIL.drain_pipewire_array!(modal_error, wire, 4)
        if mode_receipt !== nothing && something(mode_receipt.identity).generation == generation
            last_mode = Int(something(mode_receipt.identity).sequence)
            index = retained_index(mode_receipt, generation)
            if index !== nothing
                @assert all(isfinite, modal_error)
                active_error = Float64.(view(modal_error, 3:length(modal_error)))
                modes[index] = ResidualSample(mode_receipt.pts, sum(abs2, active_error), active_error)
            end
        end
        if last_image !== nothing && min(last_image, last_pixel, last_mode) >= LAST_EXPOSURE
            late_sum = zeros(Float64, length(actual))
            matched = sort!(collect(intersect(keys(late_commands), keys(camera))))
            for index in matched
                late_sum .+= late_commands[index]
            end
            late_count = length(matched)
            cohorts = [
                (; domain=domain_hex(domain), generation=command_generation, count)
                for ((domain, command_generation), count) in command_cohorts
            ]
            sort!(cohorts; by=entry -> (entry.domain, entry.generation))
            observation = (; generation, camera_domain=domain_hex(camera_domain),
                count=command_count, identified_count, late_count, command_cohorts=cohorts,
                first_sequence, last_sequence, peak, transport=demand_snapshot(wire, demand),
                late_mean=command_mean(late_sum, late_count, "exact identity shared with camera"),
                contemporaneous_mean=command_mean(contemporaneous_sum, contemporaneous_count,
                    "arrival during late camera window; no shared acquisition cohort"))
            return Epoch(camera, pixels, modes, observation)
        end
        if last_image !== nothing && last_image > LAST_EXPOSURE + BLOCK
            error("Native residual stream did not keep up with $label camera (pixels=$last_pixel, modes=$last_mode)")
        end
        frame === nothing && pixel_receipt === nothing && mode_receipt === nothing && sleep(0.001)
    end
    error("Timed out collecting $label exposures (camera=$last_image, pixels=$last_pixel, modes=$last_mode)")
end

same_acquisition_cohort(identity, domain, generation) =
    identity !== nothing && domain !== nothing && identity.domain == domain &&
    identity.generation == generation

domain_hex(domain::AcquisitionDomain) = bytes2hex(collect(domain.bytes))

command_identity(identity) = identity === nothing ? nothing :
    (; domain=domain_hex(identity.domain), identity.generation, identity.sequence)

command_mean(sum, count, scope) = (; scope, count, values=count == 0 ? nothing : sum ./ count)

function write_evidence(out, biased, closed, images, mask, basis)
    common = intersect(keys(biased.camera), keys(closed.camera), keys(biased.pixels),
        keys(closed.pixels), keys(biased.modes), keys(closed.modes))
    indices = sort!(collect(common))
    @assert length(indices) >= 0.95 * (LAST_EXPOSURE - BURN_IN)
    @assert length(images.sequences) >= 0.95 * ((LAST_EXPOSURE - BURN_IN) ÷ 2)
    open(joinpath(out, "paired.csv"), "w") do io
        println(io, "sequence,phase,pts_ns,open_electrons,closed_electrons," *
            "open_pixel_power,closed_pixel_power,open_controllable_power,closed_controllable_power," *
            "open_modal_power,closed_modal_power")
        for index in indices
            a, b = biased.camera[index], closed.camera[index]
            p, q = biased.pixels[index], closed.pixels[index]
            m, n = biased.modes[index], closed.modes[index]
            @assert a.pts == b.pts == p.pts == q.pts == m.pts == n.pts
            @assert a.phase == b.phase
            phase = a.phase == OPTICAL_UNFRINGED ? "unfringed" : "fringed"
            println(io, join((index, phase, a.pts, a.mean_intensity, b.mean_intensity,
                p.power, q.power, sum(abs2, p.coordinates), sum(abs2, q.coordinates),
                m.power, n.power), ','))
        end
    end
    blocks = [[index for index in indices if start <= index < start + BLOCK]
        for start in (BURN_IN + 1):BLOCK:LAST_EXPOSURE]
    windows = [indices, blocks...]
    coordinates = [
        reduce(hcat, (mean(records[index].coordinates for index in window) for window in windows))
        for records in (biased.pixels, closed.pixels, biased.modes, closed.modes)
    ]
    RTC.InstrumentCalibration.write_fits(joinpath(out, "coordinate-means.fits"), cat(coordinates...; dims=3))
    count_images = length(images.sequences)
    normalized = cat(images.open_sum ./ count_images, images.closed_sum ./ count_images,
        Float64.(mask); dims=3)
    RTC.InstrumentCalibration.write_fits(joinpath(out, "unfringed-means.fits"), normalized;
        units="electron")
    window(epoch) = (; generation=epoch.demand.generation, epoch.demand.camera_domain,
        epoch.demand.command_cohorts, epoch.demand.late_mean, epoch.demand.contemporaneous_mean)
    RTC.Common.write_json(joinpath(out, "dm-demand-means.json"),
        (; units="native command", source_node=GRAPH, source_port=DEMAND_OUTPUT,
            first_exposure=BURN_IN + 1, last_exposure=LAST_EXPOSURE,
            baseline=window(biased), closed=window(closed)); atomic=true)
    RTC.Common.write_json(joinpath(out, "measurement.json"),
        (; biased_open_peak=biased.demand.peak, closed_peak=closed.demand.peak,
            baseline_command_count=biased.demand.count, closed_command_count=closed.demand.count,
            baseline_command_matched_count=biased.demand.late_count,
            closed_command_matched_count=closed.demand.late_count,
            matched_exposures=length(indices), image_sequences=images.sequences,
            region_pixels=count(mask), controllable_rank=size(basis, 2)); atomic=true)
    return nothing
end

function stream(name, schema, shape; metadata=MEASUREMENT_METADATA, rate=nothing)
    return HIL.PipeWireArrayStreamOptions(; node_name=name, media_name=name, schema,
        buffers=3, format=NdArrayFormat(NdArray.F32_LE, shape; layout=NdArray.ROW_MAJOR, rate),
        metadata)
end

function demand_option(root, active_zero)
    @assert size(active_zero) == (334,) && eltype(active_zero) == Float32 && iszero(active_zero)
    session = RTC.DeploymentConfiguration.decode(joinpath(root, "rtc", "session.conf.in"),
        ENV["PIPEWIREAO_PREFIX"])
    graph = only(filter(node -> node["node.name"] == GRAPH, session["graphs"]))
    contract = only(filter(port -> port["direction"] == "output" &&
        port["name"] == DEMAND_OUTPUT, graph["ports"]))
    @assert contract["element-type"] == "F32_LE" && contract["layout"] == "ROW_MAJOR"
    @assert contract["schema"] == DEMAND_SCHEMA
    @assert length(contract["shape"]) == 1
    rate = SPA.Fraction(parse.(Int, split(contract["rate"], '/'))...)
    return stream(DEMAND_NAME, contract["schema"], Tuple(contract["shape"]);
        metadata=DEMAND_METADATA, rate)
end

# Use the Classic observer's ChoiceNone decoding for negotiated ndarray PODs.
function fixed_negotiated_format(parameter::Pod)
    choice_type = pod_type(Pod(SPA.Choice(SPA.CHOICE_NONE, [SPA.Id(0)])))
    function fixed_value(value::Pod)
        pod_type(value) == choice_type || return value
        length(value.data) >= 24 || error("truncated negotiated SPA choice")
        kind = only(reinterpret(UInt32, value.data[9:12]))
        kind == UInt32(SPA.CHOICE_NONE) ||
            error("negotiated format contains an unfixed SPA choice")
        child = Pod(value.data[17:end])
        sizeof(child) + 16 == sizeof(value) ||
            error("negotiated SPA choice has multiple values")
        return child
    end
    object = pod_value(SPA.Parameter, parameter).object
    properties = [
        SPA.Property(p.key, fixed_value(p.value); flags=p.flags) for p in object.properties
    ]
    return SPA.Parameter(SPA.Object(object.type, object.id, properties))
end

function demand_snapshot(wire, demand)
    declared = demand.option.format
    link, state = HIL.with_array_stream(wire, DEMAND_INDEX) do stream
        info = has_current_info(demand.tracker) ? current_info(demand.tracker) : nothing
        info === nothing && return (nothing, string(stream_state(stream)))
        negotiated = if info.format === nothing
            nothing
        else
            try
                fixed = fixed_negotiated_format(info.format)
                format_record(NdArrayFormat(fixed), ndarray_schema(fixed))
            catch failure
                (; decode_error=sprint(showerror, failure))
            end
        end
        record = (; id=info.id, state=string(info.state), error=info.error,
            output_node=info.output_node_id, output_port=info.output_port_id,
            input_node=info.input_node_id, input_port=info.input_port_id, negotiated)
        return record, string(stream_state(stream))
    end
    return (; source_node=GRAPH, source_port=DEMAND_OUTPUT, target_node=DEMAND_NAME,
        target_port="input_1", passive=true, state, link,
        contract=format_record(declared, demand.option.schema),
        counters=HIL.array_stream_status(wire, DEMAND_INDEX))
end

function format_record(format, schema)
    rate = format.rate
    return (; schema, element_type=string(format.element_type), shape=collect(format.shape),
        layout=string(format.layout), rate=rate === nothing ? nothing : "$(rate.num)/$(rate.denom)")
end

function with_observer(f, root, runtime, out, command_path)
    rt = RTC.SessionRuntime
    handle = rt.attach(runtime)
    control(words...) = rt.control!(handle, RTC.RunnerCommands.parse(collect(words)))
    try
        held = rt.ready(handle)
        mask = read_asset(root, REGION) .!= 0
        @assert size(mask) == (221, 221) && count(mask) == 12703
        command = read_asset(root, command_path)
        interaction = read_asset(root, joinpath(ASSETS, "scc-interaction-matrix.fits"))
        @assert size(interaction) == (count(mask), 66)
        # Exclude the two fitted nuisance-mode columns from the SCC subspace.
        factor = svd(Float64.(view(interaction, :, 3:66)))
        @assert minimum(factor.S) > 1e-4 * maximum(factor.S)
        basis = factor.U
        modal_schema = "pipewireao/controller-residual-error-f32/1"
        demand_peer = demand_option(root, command)
        peers = (
            stream("scc-error-camera", "org.adaptiveopticssim.detector-electrons-f32/1", size(mask)),
            demand_peer,
            stream("scc-error-pixels", "pipewireao/scc-selected-pixel-residuals-f32/1", (count(mask),); metadata=RTC.Common.ACQUISITION_METADATA),
            stream("scc-error-modes", modal_schema, (size(interaction, 2),); metadata=RTC.Common.ACQUISITION_METADATA),
        )
        remote = held["observation_remote"]
        @assert isabspath(remote) && startswith(remote, runtime * "/") && ispath(remote)
        ENV["PIPEWIREAO_CONFIG_DIR"] = joinpath(held["private_runtime"], "session")
        HIL.with_array_streams(peers; remote, input=(true, true, true, true)) do wire
            registry = HIL.with_array_stream(_ -> Registry(wire.core), wire, 1)
            links = Link[]
            demand_tracker = nothing
            demand = nothing
            try
                for (index, (peer, (node, output))) in enumerate(zip(peers,
                        (CAMERAS, (GRAPH, DEMAND_OUTPUT), (GRAPH, "selected-residuals"),
                            (GRAPH, "modal-residual"))))
                    link = observe(wire, registry, node, output, peer.node_name)
                    push!(links, link)
                    if index == DEMAND_INDEX
                        demand_tracker = HIL.with_array_stream(wire, DEMAND_INDEX) do _
                            track_info!(link)
                        end
                        demand = (; option=demand_peer, tracker=demand_tracker)
                    end
                end
                roundtrip(registry)
                RTC.Common.write_json(joinpath(out, "demand-held.json"),
                    demand_snapshot(wire, demand); atomic=true)
                ready = rt.running!(handle)
                RTC.Common.write_json(joinpath(out, "ready.json"), ready; atomic=true)
                gpu = read(`nvidia-smi --query-compute-apps=pid,used_memory --format=csv`, String)
                pid = ready["processes"]["simulator"]["pid"]
                @assert any(startswith("$pid,"), split(gpu, '\n'))
                write(joinpath(out, "gpu.csv"), gpu)
                f(wire, demand, control, mask, basis, ready)
            catch failure
                if demand !== nothing
                    RTC.Common.write_json(joinpath(out, "demand-failure.json"),
                        (; failure=sprint(showerror, failure), transport=demand_snapshot(wire, demand));
                        atomic=true)
                end
                rethrow()
            finally
                HIL.with_array_stream(wire, 1) do _
                    demand_tracker === nothing || close(demand_tracker)
                    foreach(close, reverse(links))
                    close(registry)
                end
            end
        end
    finally
        report = rt.stop!(handle)
        RTC.Common.write_json(joinpath(out, "stop.json"), report; atomic=true)
        @assert report["systemd_quit"]["accepted"] === true
        @assert report["cleanup_complete"] === true && report["unit_files_removed"] === true
    end
end

function graph_properties(control)
    response = control("properties", GRAPH)
    @assert response["ok"]
    props = response["result"]["properties"]
    @assert props["pipewireao-recovery:version"]["value"] == 2
    return props
end
