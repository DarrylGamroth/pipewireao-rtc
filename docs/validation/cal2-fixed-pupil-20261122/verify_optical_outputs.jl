# Run in the installed CAL2 optical startup environment with the ordinary
# reference buffers from ../hil-installed-startup-20261122/cal2-warmup.tar.zst.
using PipeWireAOOpticalStartup
using AdaptiveOpticsSim, AdaptiveOpticsSimPipeWireHIL, PipeWireAO, PipeWireAORTC
using Proper, SHA, Serialization
using AdaptiveOpticsSim.AlgorithmGraphs: graph_step_sequence

const HIL = AdaptiveOpticsSimPipeWireHIL
const EP = HIL.ExternalPupil

function graph_steps(plant)
    return map(graph_step_sequence,
        (plant.graphs.llowfs, plant.graphs.scc, plant.observations.scc.chopping.unfringed))
end

function verify_emissions(run, execution, reference, expected_steps)
    expected = deserialize(reference)
    seen = Ref(0)
    last_steps = Ref((UInt64(0), UInt64(0), UInt64(0)))
    function observe(name, image, metadata)
        index, sequence, trigger = EP.copy_exposure!(execution, name, image, metadata)
        pixels = execution.buffers[index]
        optical = EP.sensor_optical_classification(execution.science, name, metadata)
        record = (; name, metadata, sequence, trigger, optical, shape = size(pixels),
            pixel_type = eltype(pixels), bytes = reinterpret(UInt8, vec(pixels)))
        seen[] += 1
        @assert isequal(record, expected[seen[]]) "reference mismatch at $name PTS $(metadata.pts)"
        last_steps[] = graph_steps(execution.science.plant)
        println((; name, metadata.pts, sequence, trigger, optical,
            sha256 = bytes2hex(sha256(record.bytes))))
        return nothing
    end
    run(observe)
    @assert seen[] == length(expected)
    @assert last_steps[] == expected_steps
    println((; reference = basename(reference), matched = seen[], graph_steps = last_steps[]))
    return nothing
end

function main(app, reference)
    @assert VERSION == v"1.13.3"
    @assert Base.pkgversion(AdaptiveOpticsSim) == v"0.3.30"
    @assert Base.pkgversion(HIL) == v"0.5.13"
    image_depot = joinpath(app, "optical-startup", "simulator", "depot")
    @assert first(DEPOT_PATH) == image_depot
    @assert any(line -> occursin(image_depot, line) && occursin("/PipeWireAOOpticalStartup/", line),
        eachline("/proc/self/maps"))
    options = PipeWireAORTC.AOSOwner.configuration(joinpath(app, "simulation.conf"))
    @assert options.version == 4 && options.backend === :cpu
    extension = Base.get_extension(HIL, :PipeWireAORTCExt)
    execution = extension.prepare_optical_startup(merge(options, (; control_node = "optical comparison")),
        Val(4), Returns(nothing); warmup = false)
    plant = execution.science.plant
    packet = execution.packet
    println((; julia = VERSION, fftw_threads = Proper.FFTW.get_num_threads(),
        manifest_sha256 = bytes2hex(sha256(read(joinpath(app, "Manifest.toml"))))))
    checks = Ref(0)
    verify_emissions(execution, reference * ".synthetic", (1, 1, 1)) do observe
        EP.warmup!(observe, execution.science, packet, execution.frames, execution.buffers;
            check = () -> (checks[] += 1))
    end
    @assert checks[] == 10
    @assert plant.state.domain === nothing && plant.state.sequence == 0 && plant.state.last_end_ns == -1
    @assert all(iszero, packet) && all(frame -> all(iszero, frame), (execution.frames..., execution.buffers...))
    # Reproduce the ordinary five varying inputs used to generate the reference.
    domain = AcquisitionDomain(ntuple(i -> UInt8(i + 16), 16))
    verify_emissions(execution, reference * ".varying", (5, 5, 0)) do observe
        for sequence in 1:5
            for row in axes(packet, 2), col in axes(packet, 3)
                packet[1, row, col] = 2.5f-8 * (mod(row + 2col + 3sequence, 13) - 6)
                packet[2, row, col] = (row - 120)^2 + (col - 120)^2 > 110^2 ?
                    0.0f0 : 0.84f0 + 0.01f0 * mod(row + col + sequence, 9)
            end
            identity = AcquisitionIdentity(domain, UInt64(7), UInt64(sequence))
            receipt = HIL.PipeWireArrayReceipt(Int64(2_000_000 * (sequence - 1)),
                UInt64(2_000_000), identity, UInt64(0))
            @assert EP.feed!(observe, plant, packet, receipt)
        end
    end
    @assert plant.state.generation == 7 && plant.state.sequence == 5 && plant.state.rejected == 0
end

main(abspath(ARGS[1]), abspath(ARGS[2]))
