# The external pupil input of the standalone installed CAL2 development profile.
using AdaptiveOpticsSim: AlgorithmGraphs
using AdaptiveOpticsSimPipeWireHIL: PipeWireArrayStreamOptions, array_stream_status,
    stage_pipewire_array!, with_array_stream, with_array_streams
using UUIDs

function synthetic_pupil(pixels)
    pupil = zeros(Float32, 2, pixels, pixels)
    for col in 1:pixels, row in 1:pixels
        x = (col - fld(pixels, 2) - 1) / (pixels / 2)
        y = (row - fld(pixels, 2) - 1) / (pixels / 2)
        x^2 + y^2 <= 1 || continue
        pupil[1, row, col] = 30f-9 * (x^2 - y^2)
        pupil[2, row, col] = 1
    end
    return pupil
end

function pupil_source(application, session)
    simulation = RTC.Common.read_json(joinpath(application, "simulation.conf"))
    simulation["version"] == 4 && simulation["mode"] == "external-pupil" ||
        error("Expected the CAL2 external-pupil owner")
    node = simulation["pupil_node"]
    sink = only(row for row in session["sinks"] if row["node.name"] == node)
    port = only(sink["ports"])
    port["element-type"] == "F32_LE" && port["layout"] == "ROW_MAJOR" ||
        error("Unexpected CAL2 pupil wire format")
    optical = RTC.Common.read_yaml(joinpath(application, "instrument.yaml"))["optical_input"]
    shape = Tuple(Int.(port["shape"]))
    contract = AlgorithmGraphs.external_pupil_contract(;
        pupil_resolution = last(shape), diameter_m = optical["diameter_m"],
        plane = optical["plane"], curvature = optical["curvature"],
        registration = optical["registration"],
    )
    contract.shape == shape && contract.schema == port["schema"] ||
        error("CAL2 pupil contract differs from the sealed input port")
    address = node * ":" * port["name"]
    all(row -> row["input"] != address, session["links"]) ||
        error("CAL2 pupil input already has a declared producer")
    options = PipeWireArrayStreamOptions(;
        node_name = "rtc-flow-pupil-$(getpid())", media_name = "External pupil field",
        schema = contract.schema, properties = contract.properties,
        metadata = RTC.Common.ACQUISITION_METADATA,
        format = NdArrayFormat(NdArray.F32_LE, shape; layout = NdArray.ROW_MAJOR),
    )
    return options, node, port["name"]
end

function with_pupil_source(f, application, session, remote)
    options, node_name, port_name = pupil_source(application, session)
    with_array_streams((options,); remote, input = (false,)) do owner
        registry = with_array_stream(_ -> Registry(owner.core), owner, 1)
        link = tracker = nothing
        try
            ends = Ref{Any}(nothing)
            if timedwait(30; pollint = 0.01) do
                    with_array_stream(owner, 1) do stream
                        nodes = find_globals(registry; interface = "PipeWire:Interface:Node",
                            properties = ("node.name" => node_name,))
                        isempty(nodes) && return false
                        node = only(nodes)
                        inputs = find_globals(registry; interface = "PipeWire:Interface:Port",
                            properties = ("node.id" => string(node.id),
                                "port.direction" => "in", "port.name" => port_name))
                        outputs = find_globals(registry; interface = "PipeWire:Interface:Port",
                            properties = ("node.id" => string(node_id(stream)), "port.direction" => "out"))
                        (isempty(inputs) || isempty(outputs)) && return false
                        input = only(inputs)
                        attached = find_globals(registry; interface = "PipeWire:Interface:Link",
                            properties = ("link.input.port" => string(input.id),))
                        isempty(attached) || error("CAL2 pupil input already has a producer")
                        ends[] = (node_id(stream), only(outputs).id, node.id, input.id)
                        return true
                    end
                end != :ok
                error("CAL2 pupil probe ports did not register")
            end
            output_node, output_port, input_node, input_port = ends[]
            with_array_stream(owner, 1) do _
                link = create_object(owner.core, "link-factory", Link; properties = Dict(
                    "link.output.node" => string(output_node), "link.output.port" => string(output_port),
                    "link.input.node" => string(input_node), "link.input.port" => string(input_port),
                    "object.linger" => "false",
                ))
                tracker = track_info!(link)
            end
            timedwait(30; pollint = 0.01) do
                with_array_stream(owner, 1) do _
                    has_current_info(tracker) || return false
                    info = current_info(tracker)
                    info.state == PipeWireAO.LINK_STATE_ERROR && error("CAL2 pupil link: $(info.error)")
                    return info.state in (PipeWireAO.LINK_STATE_PAUSED, PipeWireAO.LINK_STATE_ACTIVE)
                end
            end == :ok || error("CAL2 pupil link did not negotiate")
            return f(owner, synthetic_pupil(last(options.format.shape)))
        finally
            with_array_stream(owner, 1) do _
                tracker === nothing || close(tracker)
                link === nothing || close(link)
                close(registry)
            end
        end
    end
end

function inject_pupil!(owner, pupil, llowfs_sequence, cancelled; packets = 30)
    # Separate from RTC's control token space. Each staged pupil covers one
    # 2 ms LLOWFS exposure. Allow the downstream queue to acknowledge delivery
    # before staging its successor so the source's single slot cannot overwrite.
    uuid = uuid4().value
    domain = AcquisitionDomain(ntuple(i -> UInt8((uuid >> (8 * (i - 1))) & 0xff), 16))
    duration = UInt64(2_000_000)
    for sequence in UInt64(1):UInt64(packets)
        cancelled[] && return nothing
        identity = AcquisitionIdentity(domain, UInt64(1), sequence)
        pts = Int64((sequence - 1) * duration)
        stage_pipewire_array!(owner, 1, pupil; identity, pts, duration) ||
            error("CAL2 pupil $sequence was rejected by the local staging slot")
        limit = _classic_now() + 120
        while llowfs_sequence[] < sequence && !cancelled[]
            _classic_now() < limit ||
                error("CAL2 pupil $sequence had no LLOWFS delivery (last sequence $(llowfs_sequence[]))")
            trigger_process!(owner)
            sleep(0.005)
        end
    end
    cancelled[] && return nothing
    status = array_stream_status(owner, 1)
    !status.failed && !status.pending && status.rejected == status.dropped == status.gaps == 0 ||
        error("CAL2 pupil source reported loss or rejection: $status")
    return Dict(
        "packet_count" => packets,
        "input_domain" => bytes2hex(collect(domain.bytes)),
        "duration_per_packet_ns" => duration,
        "model_coverage_ns" => packets * duration,
        "maximum_astigmatic_opd_m" => 30f-9,
        "last_paced_llowfs_sequence" => llowfs_sequence[],
        "local_source_status" => status,
    )
end
