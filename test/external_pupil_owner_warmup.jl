# CPU runtime warmup checks; no core or transport publication.
using Test, PipeWireAORTC, AdaptiveOpticsSim, AdaptiveOpticsSimPipeWireHIL, Proper, PipeWireAO
using AdaptiveOpticsSim.AlgorithmGraphs
include(joinpath(@__DIR__, "external_pupil_owner_documents.jl"))
const WarmOwner = Base.get_extension(PipeWireAORTC, :PipeWireAORTCAOSExt).ExternalPupilOwner

function warm_science(directory; chopped=false, response=false)
    (;document, config, path, physical, simulation) = external_pupil_owner_documents(directory)
    if chopped
        physical["wavefront_sensors"]["scc"]["acquisition"]["exposure_duration_s"] = 0.01
        simulation["graphs"]["scc_unfringed"] = deepcopy(simulation["graphs"]["scc"])
        document["plant"]["chopping"] = Dict("scc" => Dict("unfringed_graph" => "scc_unfringed",
            "initial_phase" => "fringed", "trigger_high_is_fringed" => true))
    end
    if response
        authored_response!(directory, physical, simulation)
        simulation["observations"]["llowfs"] = pop!(simulation["observations"], "low_order")
        simulation["observations"]["llowfs"]["graph"] = "llowfs_response"
        simulation["graphs"] = Dict{String,Any}(simulation["graphs"])
        simulation["graphs"]["llowfs_response"] = "simulation/low_order_response.yaml"
        simulation["components"]["low_order_detector"]["config"]["pixel_sampling_m"] = [0.003,0.003]
        # Nonzero read noise makes RNG advancement observable even at dark pixels.
        simulation["components"]["low_order_detector"]["config"]["readout_noise"] = true
        simulation["components"]["low_order_detector"]["config"]["readout_noise_e"] = 3.0
    end
    write_external_optical_documents(directory, physical, simulation)
    PipeWireAORTC.Common.write_json(config, document)
    science = PipeWireAORTC.AOSOwner.prepare_external_pupil_science(
        PipeWireAORTC.AOSOwner.configuration(config))
    packet = zeros(Float32, science.pupil.shape)
    frames = map(sensor -> zeros(eltype(sensor.image), size(sensor.image)), values(science.sensors))
    buffers = map(sensor -> zeros(Float32, size(sensor.image)), values(science.sensors))
    return (;science, packet, frames, buffers)
end

function warm_emitter(science, frames, buffers, records)
    names = keys(science.sensors)
    return function (name, image, metadata)
        index = findfirst(==(name), names)
        copyto!(frames[index], image)
        buffers[index] .= frames[index]
        all(isfinite, buffers[index]) || error("nonfinite sensor")
        sequence = WarmOwner.sensor_sequence(metadata, hasproperty(science.chopping, name))
        trigger = WarmOwner.trigger_state(science, name, metadata)
        push!(records, (;name, sequence, trigger, metadata, image=copy(buffers[index])))
    end
end

function live_packet!(emit, science, packet, sequence)
    packet[2,:,:] .= 1f0
    receipt = PipeWireArrayReceipt(Int64((sequence-1)*2_000_000),UInt64(2_000_000),
        AcquisitionIdentity(AcquisitionDomain(ntuple(i->UInt8(i),16)),UInt64(7),UInt64(sequence)),UInt64(0))
    return WarmOwner.feed!(emit, science.plant, packet, receipt)
end

@testset "runtime warmup covers both chopped phases then restores pristine acquisition" begin
    mktempdir() do directory
        (;science, packet, frames, buffers) = warm_science(directory; chopped=true)
        records = NamedTuple[]
        emit = warm_emitter(science, frames, buffers, records)
        checks = Ref(0)
        WarmOwner.warmup!(emit, science, packet, frames, buffers; check=()->(checks[]+=1))
        @test checks[] == 10
        @test count(r->r.name===:llowfs, records) == 10
        scc = filter(r->r.name===:scc, records)
        @test [r.metadata.chopped_image_kind for r in scc] == [:fringed, :unfringed]
        @test [r.sequence for r in scc] == [1,2]
        @test science.plant.state.domain === nothing
        @test science.plant.state.sequence == science.plant.state.generation == 0
        @test all(e->e.sequence==0 && e.covered_ns==0 && e.incomplete==0, values(science.plant.exposures))
        @test all(iszero, packet) && all(x->all(iszero,x), frames) && all(x->all(iszero,x), buffers)
        empty!(records)
        for sequence in 1:5
            @test live_packet!(emit, science, packet, sequence)
        end
        @test first(records).sequence == 1 && first(records).metadata.pts == 0
        @test only(filter(r->r.name===:scc,records)).metadata.chopped_image_kind === :fringed
        @test only(filter(r->r.name===:scc,records)).metadata.pts == 0
    end
end

@testset "runtime warmup cancellation resets partial exposures and host storage" begin
    mktempdir() do directory
        (;science, packet, frames, buffers) = warm_science(directory)
        records = NamedTuple[]
        emit = warm_emitter(science, frames, buffers, records)
        checks = Ref(0)
        check = () -> ((checks[]+=1) == 3 && throw(InterruptException()))
        @test_throws InterruptException WarmOwner.warmup!(emit, science, packet, frames, buffers; check)
        @test science.plant.state.domain === nothing
        @test all(e->e.sequence==0 && e.covered_ns==0, values(science.plant.exposures))
        @test all(iszero,packet) && all(x->all(iszero,x),frames) && all(x->all(iszero,x),buffers)
        huge = merge(science, (;plant=(;exposures=(a=(;duration_ns=1), b=(;duration_ns=10_000)))))
        @test_throws ArgumentError WarmOwner.warmup!(emit, huge, packet, frames, buffers)
    end
end

@testset "runtime warmup restores seeded detector response draws" begin
    mktempdir() do directory
        (;science, packet, frames, buffers) = warm_science(directory; response=true)
        records = NamedTuple[]
        emit = warm_emitter(science, frames, buffers, records)
        @test live_packet!(emit, science, packet, 1)
        baseline = copy(first(filter(r->r.name===:llowfs,records)).image)
        @test live_packet!(emit, science, packet, 2)
        @test last(filter(r->r.name===:llowfs,records)).image != baseline
        reset_external_pupil!(science.plant)
        empty!(records)
        WarmOwner.warmup!(emit, science, packet, frames, buffers)
        @test all(x->all(iszero,x),buffers)
        empty!(records)
        @test live_packet!(emit, science, packet, 1)
        @test first(filter(r->r.name===:llowfs,records)).image == baseline
        @test science.plant.state.generation == 7
    end
    @test !any(id->id.name in ("CUDA","AMDGPU"),keys(Base.loaded_modules))
end
