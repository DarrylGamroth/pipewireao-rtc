using AdaptiveOpticsSimPipeWireHIL
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

function collect_window!(io, label, wire, mask, command, generation; final_sequence=4096)
    image = zeros(Float32, size(mask))
    actual = similar(command)
    peak_correction = 0f0
    selected = findall(mask)
    finish = time_ns() + UInt64(900_000_000_000)
    while time_ns() < finish
        demand = HIL.drain_pipewire_array!(actual, wire, 2)
        if demand !== nothing
            all(isfinite, actual) || error("nonfinite physical demand")
            maximum(abs, actual) <= 0.5f0 || error("physical command exceeds bounds")
            peak_correction = max(peak_correction, maximum(abs, actual .- command))
        end
        sample = HIL.drain_pipewire_array!(image, wire, 1)
        if sample === nothing
            sleep(0.001)
            continue
        end
        identity = something(sample.identity)
        identity.generation == generation || continue
        all(isfinite, image) || error("nonfinite SCC image")
        phase = sample.optical_classification
        phase in (OPTICAL_FRINGED, OPTICAL_UNFRINGED) || error("missing SCC phase")
        mean_intensity = sum(i -> Float64(image[i]), selected) / length(selected)
        name = phase == OPTICAL_FRINGED ? "fringed" : "unfringed"
        println(io, join((label, name, identity.generation, identity.sequence,
            sample.pts, mean_intensity), ','))
        flush(io)
        if identity.sequence >= final_sequence
            return peak_correction
        end
    end
    error("timed out collecting $label exposures")
end

function verify(root, runtime, out, command_path)
    rt = RTC.SessionRuntime
    handle = rt.attach(runtime)
    held = rt.ready(handle)
    control(words...) = rt.control!(handle, RTC.RunnerCommands.parse(collect(words)))
    function closure()
        response = control("properties", GRAPH)
        response["ok"] || error("Property query failed: $(response["error"])")
        props = response["result"]["properties"]
        @assert props["pipewireao-recovery:version"]["value"] == 2
        @assert props["llowfs-correction:closed"]["value"] === false
        return props["correction:closed"]["value"]
    end
    mask = FITS(joinpath(root, REGION)) do file
        permutedims(read(file[1])) .!= 0
    end
    @assert size(mask) == (221, 221) && count(mask) == 12703
    metadata = (RTC.Common.ACQUISITION_METADATA...,
        MetadataRequirement(SPA.META_OPTICAL_CHOPPING; required=true))
    peer = HIL.PipeWireArrayStreamOptions(; node_name="spiders-dark-hole-observer",
        media_name="spiders dark-hole observation", schema="org.adaptiveopticssim.detector-electrons-f32/1",
        buffers=3, format=NdArrayFormat(NdArray.F32_LE, size(mask); layout=NdArray.ROW_MAJOR),
        metadata)
    command = FITS(joinpath(root, command_path)) do file
        vec(read(file[1]))
    end
    command_peer = HIL.PipeWireArrayStreamOptions(; node_name="spiders-dark-hole-command-observer",
        media_name="spiders dark-hole command observation",
        schema="pipewireao/demanded-pdm-command-f32/1",
        buffers=3, format=NdArrayFormat(NdArray.F32_LE, size(command); layout=NdArray.ROW_MAJOR))
    actual = similar(command)
    remote = held["observation_remote"]
    @assert isabspath(remote) && startswith(remote, runtime * "/") && ispath(remote)
    ENV["PIPEWIREAO_CONFIG_DIR"] = joinpath(held["private_runtime"], "session")
    try
        HIL.with_array_streams((peer, command_peer); remote, input=(true, true)) do wire
            registry = HIL.with_array_stream(_ -> Registry(wire.core), wire, 1)
            links = Link[]
            try
                push!(links, observe(wire, registry, CAMERA, "output_1", peer.node_name))
                push!(links, observe(wire, registry, GRAPH, "dm-command", command_peer.node_name))
                ready = rt.running!(handle)
                RTC.Common.write_json(joinpath(out, "ready.json"), ready; atomic=true)
                @assert closure() === false
                gpu = read(`nvidia-smi --query-compute-apps=pid,used_memory --format=csv`, String)
                pid = ready["processes"]["simulator"]["pid"]
                @assert any(startswith("$pid,"), split(gpu, '\n'))
                write(joinpath(out, "gpu.csv"), gpu)
                open(joinpath(out, "samples.csv"), "w") do io
                    println(io, "window,phase,generation,sequence,pts_ns,mean_electrons")
                    open_peak = collect_window!(io, "open", wire, mask, command, 1)
                    # The same source resets to the same deterministic trajectory.
                    launcher = joinpath(root, "bin", "pipewireao-rtc-session")
                    session = ready["ready"]["session_id"]
                    restart = read(`$launcher restart --session $session`, String)
                    write(joinpath(out, "restart.json"), restart)
                    result = control("property", GRAPH, "correction:closed", "bool", "true")
                    RTC.Common.write_json(joinpath(out, "close.json"), result; atomic=true)
                    result["ok"] || error("SCC close failed: $(result["error"])")
                    @assert closure() === true
                    closed_peak = collect_window!(io, "closed", wire, mask, command, 2)
                    @assert closed_peak > 0 && open_peak <= 1f-6 && closure() === true
                    RTC.Common.write_json(joinpath(out, "demand.json"),
                        (; open_peak, closed_peak); atomic=true)
                end
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

verify(ARGS...)
