using AdaptiveOpticsSimPipeWireHIL
using LinearAlgebra
using SHA
using Statistics
using PipeWireAO
using PipeWireAORTC

const FITS = PipeWireAORTC.InstrumentConfiguration.FITSIO.FITS
const HIL = AdaptiveOpticsSimPipeWireHIL
const RTC = PipeWireAORTC
const GRAPH = "spiders-controller"
const REGION = "generated/dual-calibration/scc/artifacts/scc-pixel-mask.fits"
const CAMERA = "spiders-scc"

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
    peak_correction::Float32
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

function collect_epoch!(wire, label, generation, mask, command, basis, images, baseline)
    image = zeros(Float32, size(mask))
    actual_command = similar(command)
    pixel_error = zeros(Float32, count(mask))
    modal_error = zeros(Float32, size(basis, 2) + 2)
    camera = Dict{Int,CameraSample}()
    pixels = Dict{Int,ResidualSample}()
    modes = Dict{Int,ResidualSample}()
    selected = findall(mask)
    peak_correction = 0f0
    last_image = nothing
    last_pixel = 0
    last_mode = 0
    clock = RTC.SessionRuntime.Clocks.SystemNanoClock()
    deadline = RTC.SessionRuntime.Clocks.time_nanos(clock) + 900_000_000_000
    while RTC.SessionRuntime.Clocks.time_nanos(clock) < deadline
        demand = HIL.drain_pipewire_array!(actual_command, wire, 2)
        if demand !== nothing
            @assert all(isfinite, actual_command) && maximum(abs, actual_command) <= 0.5f0
            peak_correction = max(peak_correction, maximum(abs, actual_command .- command))
        end
        frame = HIL.drain_pipewire_array!(image, wire, 1)
        if frame !== nothing && something(frame.identity).generation == generation
            @assert all(isfinite, image)
            identity = something(frame.identity)
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
            return Epoch(camera, pixels, modes, peak_correction)
        end
        if last_image !== nothing && last_image > LAST_EXPOSURE + BLOCK
            error("Native residual stream did not keep up with $label camera (pixels=$last_pixel, modes=$last_mode)")
        end
        frame === nothing && pixel_receipt === nothing && mode_receipt === nothing && sleep(0.001)
    end
    error("Timed out collecting $label exposures (camera=$last_image, pixels=$last_pixel, modes=$last_mode)")
end

function write_evidence(out, biased, closed, images, mask, basis; require_fixed_baseline=true)
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
    require_fixed_baseline && (@assert biased.peak_correction <= 1f-6)
    @assert closed.peak_correction > 0f0
    RTC.Common.write_json(joinpath(out, "measurement.json"),
        (; biased_open_peak=biased.peak_correction, closed_peak=closed.peak_correction,
            matched_exposures=length(indices), image_sequences=images.sequences,
            region_pixels=count(mask), controllable_rank=size(basis, 2)); atomic=true)
    return nothing
end

function stream(name, schema, shape; metadata=MEASUREMENT_METADATA)
    return HIL.PipeWireArrayStreamOptions(; node_name=name, media_name=name, schema,
        buffers=3, format=NdArrayFormat(NdArray.F32_LE, shape; layout=NdArray.ROW_MAJOR), metadata)
end

function with_observer(f, root, runtime, out, command_path)
    rt = RTC.SessionRuntime
    handle = rt.attach(runtime)
    held = rt.ready(handle)
    control(words...) = rt.control!(handle, RTC.RunnerCommands.parse(collect(words)))
    try
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
        peers = (
            stream("scc-error-camera", "org.adaptiveopticssim.detector-electrons-f32/1", size(mask)),
            stream("scc-error-command", "pipewireao/demanded-pdm-command-f32/1", size(command); metadata=()),
            stream("scc-error-pixels", "pipewireao/scc-selected-pixel-residuals-f32/1", (count(mask),); metadata=RTC.Common.ACQUISITION_METADATA),
            stream("scc-error-modes", modal_schema, (size(interaction, 2),); metadata=RTC.Common.ACQUISITION_METADATA),
        )
        remote = held["observation_remote"]
        @assert isabspath(remote) && startswith(remote, runtime * "/") && ispath(remote)
        ENV["PIPEWIREAO_CONFIG_DIR"] = joinpath(held["private_runtime"], "session")
        HIL.with_array_streams(peers; remote, input=(true, true, true, true)) do wire
            registry = HIL.with_array_stream(_ -> Registry(wire.core), wire, 1)
            links = Link[]
            try
                for (peer, (node, output)) in zip(peers,
                        (CAMERAS, (GRAPH, "dm-command"), (GRAPH, "selected-residuals"), (GRAPH, "modal-residual")))
                    push!(links, observe(wire, registry, node, output, peer.node_name))
                end
                ready = rt.running!(handle)
                RTC.Common.write_json(joinpath(out, "ready.json"), ready; atomic=true)
                gpu = read(`nvidia-smi --query-compute-apps=pid,used_memory --format=csv`, String)
                pid = ready["processes"]["simulator"]["pid"]
                @assert any(startswith("$pid,"), split(gpu, '\n'))
                write(joinpath(out, "gpu.csv"), gpu)
                f(wire, control, mask, command, basis, ready)
            finally
                HIL.with_array_stream(wire, 1) do _
                    foreach(close, reverse(links))
                    close(registry)
                end
            end
        end
    finally
        report = rt.stop!(handle)
        RTC.Common.write_json(joinpath(out, "stop.json"), report; atomic=true)
        @assert report["systemd_quit"]["accepted"] === true
    end
end

function graph_properties(control)
    response = control("properties", GRAPH)
    @assert response["ok"]
    props = response["result"]["properties"]
    @assert props["pipewireao-recovery:version"]["value"] == 2
    return props
end

function verify(root, runtime, out, command_path)
    with_observer(root, runtime, out, command_path) do wire, control, mask, command, basis, ready
        function closure()
            props = graph_properties(control)
            @assert props["llowfs-correction:closed"]["value"] === false
            return props["correction:closed"]["value"]
        end
        @assert closure() === false
        images = Images(size(mask))
        biased = collect_epoch!(wire, "open", 1, mask, command, basis, images, Dict{Int,CameraSample}())
        write(joinpath(out, "open-complete"), string(length(biased.camera)))
        launcher = joinpath(root, "bin", "pipewireao-rtc-session")
        session = ready["ready"]["session_id"]
        restart = read(`$launcher restart --session $session`, String)
        write(joinpath(out, "restart.json"), restart)
        result = control("property", GRAPH, "correction:closed", "bool", "true")
        RTC.Common.write_json(joinpath(out, "close.json"), result; atomic=true)
        @assert result["ok"] && closure() === true
        closed = collect_epoch!(wire, "closed", 2, mask, command, basis, images, biased.camera)
        @assert closure() === true
        write_evidence(out, biased, closed, images, mask, basis)

    end
end

if abspath(PROGRAM_FILE) == @__FILE__
    verify(ARGS...)
end
