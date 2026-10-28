# Optional scientific publisher selector, isolated from desktop PipeWire cores.
# julia --threads=3,0 --project=/path/to/science-env test/aos_pupil_output.jl [cuda]
using Test, PipeWireAORTC, AdaptiveOpticsSim, AdaptiveOpticsSimPipeWireHIL, PipeWireAO
using AdaptiveOpticsSim.AlgorithmGraphs
using AdaptiveOpticsSim.AlgorithmGraphs: external_pupil_contract, snapshot_values,
    poll_graph_output_snapshot!, release_graph_output_snapshot!
include("native_control_private_core.jl")

const Pupil = Base.get_extension(PipeWireAORTC, :PipeWireAORTCAOSExt).PupilOutput
const CUDA_TEST = "cuda" in ARGS
if CUDA_TEST
    using CUDA
    CUDA.functional() || error("CUDA publisher selector requires a functional device")
    CUDA.allowscalar(false)
end

include("aos_graph_documents.jl")

function boundary()
    return external_pupil_contract(pupil_resolution=4, diameter_m=0.012,
        plane="upstream_of_apodizer", curvature="collimated")
end

@testset "generated scientific source belongs to the existing owner" begin
    mktempdir() do directory
        (;document,path) = aos_graph_documents(directory)
        C = PipeWireAORTC.Common
        physical = C.read_yaml(joinpath(directory,"instrument.yaml"))
        physical["optical_output"] = deepcopy(physical["optical_input"])
        physical["optical_output"]["registration"] = "provisional"
        C.write_yaml(joinpath(directory,"instrument.yaml"),physical)
        simulation = C.read_yaml(path)
        simulation["pupil_output"] = Dict("opd"=>"pupil_opd", "amplitude"=>"pupil_amplitude")
        simulation["bindings"]["pupil_amplitude"] = Dict("kind"=>"pupil_amplitude", "resolution"=>"pupil_resolution", "type"=>"Float32")
        for graph in values(simulation["graphs"])
            push!(graph["nodes"],Dict("name"=>"pupil", "type"=>"pupil_opd_composition_f32",
                "config"=>Dict("resolution"=>4,"uncompensated_opd_schema"=>"example.pupil-opd/1",
                    "surface_opd_schema"=>"example.pupil-opd/1","pupil_opd_schema"=>"example.pupil-opd/1")))
            push!(graph["outputs"],Dict("name"=>"pupil_opd","source"=>"pupil.pupil_opd"))
        end
        C.write_yaml(path,simulation)
        document["pupil_output"] = true
        C.write_json(joinpath(directory,"simulation.conf"),document)
        @test PipeWireAORTC.AOSOwner.configuration(joinpath(directory,"simulation.conf")).pupil_output
        C.write_json(joinpath(directory,"session.conf"),Dict("sources"=>[],"links"=>[]))
        C.write_json(joinpath(directory,"core.conf"),Dict("context.modules"=>[]))
        owner = Dict("role"=>"plant", "argv"=>["julia","--threads=2,0"])
        spec = Dict("session"=>"session.conf","core"=>"core.conf", "source-owner"=>"plant",
            "owners"=>[owner],"node-owners"=>Dict{String,String}())
        E = PipeWireAORTC.InstrumentExport
        prefix = String(PipeWireAO.LibPipeWire.PipeWireAO_jll.artifact_dir)
        @test_throws ArgumentError E.prepare_session_configuration!(directory,spec,[],"instrument.json",prefix)
        owner["argv"] = ["julia","--threads=3,0","--pupil-output-cpu","4"]
        E.prepare_session_configuration!(directory,spec,[],"instrument.json",prefix)
        session = PipeWireAORTC.DeploymentConfiguration.decode(joinpath(directory,"session.conf"),prefix)
        source = only(session["sources"])
        @test source["node.name"] == "simulator-pupil-output"
        @test spec["node-owners"][source["node.name"]] == "plant"
        port = only(source["ports"])
        @test port["shape"] == [2,4,4] && port["element-type"] == "F32_LE"
        @test port["layout"] == "ROW_MAJOR"
        @test port["schema"] == boundary().schema
        @test isempty(session["links"])
    end
end

function pupil_graph()
    p = 4
    node = pupil_opd_composition_node(:pupil; resolution=p,
        uncompensated_opd_schema="test.pupil-opd/1", surface_opd_schema="test.pupil-opd/1",
        pupil_opd_schema="test.pupil-opd/1")
    allocate() = CUDA_TEST ? CUDA.zeros(Float32,p,p) : zeros(Float32,p,p)
    definition = algorithm_graph((node,);
        inputs=(graph_input(:upstream, :pupil => :uncompensated_opd, allocate()),
            graph_input(:surface, :pupil => :surface_opd, allocate())),
        outputs=(graph_output(:pupil_opd, :pupil => :pupil_opd),))
    if CUDA_TEST
        return prepare_algorithm_graph(definition;
            target=AdaptiveOpticsSim.Backends.AcceleratorComputeDevice(AdaptiveOpticsSim.Backends.CUDABackend(), 0),
            execution=CapturedGraphExecution())
    end
    return prepare_algorithm_graph(definition)
end

struct ZeroBasedPupil <: AbstractMatrix{Float32}
    values::Matrix{Float32}
end
Base.size(values::ZeroBasedPupil) = size(values.values)
Base.axes(values::ZeroBasedPupil) = map(n -> 0:(n-1), size(values))
Base.getindex(values::ZeroBasedPupil,x::Int,y::Int) = values.values[x+1,y+1]
sample_bytes(p) = @allocated Pupil.sample!(p;generation=UInt64(1),model_ns=Int64(0))
pack_bytes(p,values) = @allocated Pupil.pack!(p.packet,values,p.amplitude)

@testset "raw asymmetric completed pupil snapshots" begin
    graph = pupil_graph()
    opd = Float32[1 2 3 4; 5 6 7 8; 9 10 11 12; 13 14 15 16] .* 1f-9
    amplitude = Float32[0 0.1 0.2 0; 0.3 0.4 0.5 0.6; 0.7 0.8 0.9 1; 0 0.2 0.4 0]
    publisher = Pupil.prepare(graph, :pupil_opd, amplitude, boundary(); period_ns=UInt64(500_000))
    try
        copyto!(graph_input(graph, :upstream), opd)
        step_graph!(graph)
        @test Pupil.sample!(publisher; generation=UInt64(1), model_ns=Int64(123))
        @test !Pupil.sample!(publisher; generation=UInt64(1), model_ns=Int64(124))
        @test publisher.dropped[] == 1
        wait_proof(() -> poll_graph_output_snapshot!(publisher.snapshot), 10, "completed pupil snapshot")
        values = snapshot_values(publisher.snapshot)
        @test Pupil.pack!(publisher.packet, values, publisher.amplitude) === publisher.packet
        @test publisher.packet[1,:,:] == permutedims(opd)
        @test publisher.packet[2,:,:] == permutedims(amplitude)
        @test all(isfinite, publisher.packet)
        @test publisher.packet[1,1,4] == opd[4,1] # Distinguishes transpose from the diagnostic Y flip.
        @test publisher.packet[1,1,1] != 0 # Preserve raw piston even outside the amplitude support.
        release_graph_output_snapshot!(publisher.snapshot)
        if !CUDA_TEST
            sample_bytes(publisher)
            wait_proof(() -> poll_graph_output_snapshot!(publisher.snapshot),10,"allocation warmup")
            release_graph_output_snapshot!(publisher.snapshot)
            @test sample_bytes(publisher) == 0
            wait_proof(() -> poll_graph_output_snapshot!(publisher.snapshot),10,"allocation sample")
            pack_bytes(publisher,values)
            @test pack_bytes(publisher,values) == 0
            release_graph_output_snapshot!(publisher.snapshot)
        end
        @test Pupil.pack!(publisher.packet, @view(opd[:,:]), amplitude) === publisher.packet
        @test_throws ArgumentError Pupil.pack!(publisher.packet,ZeroBasedPupil(opd),amplitude)
        @test_throws DimensionMismatch Pupil.pack!(zeros(Float32,2,3,4), opd, amplitude)
        invalid = copy(opd); invalid[1] = NaN32
        @test_throws ArgumentError Pupil.pack!(publisher.packet, invalid, amplitude)
    finally
        Pupil.close!(publisher)
    end
end

@testset "dedicated scientific source, late consumer and stable reset" begin
    with_control_private_core(;telemetry_loop=true) do remote, directory, daemon
        graph = pupil_graph()
        opd = Float32[1 2 3 4; 5 6 7 8; 9 10 11 12; 13 14 15 16] .* 1f-9
        amplitude = Float32[0 0.1 0.2 0; 0.3 0.4 0.5 0.6; 0.7 0.8 0.9 1; 0 0.2 0.4 0]
        publisher = Pupil.prepare(graph, :pupil_opd, amplitude, boundary(); period_ns=UInt64(500_000))
        try
            Pupil.start!(publisher; remote)
            @test Pupil.registered(publisher)
            @test !Pupil.status(publisher).failed
            # No consumer: completed snapshots and native pending overwrite remain healthy.
            for sequence in 1:3
                copyto!(graph_input(graph,:upstream), sequence .* opd)
                step_graph!(graph)
                @test Pupil.sample!(publisher; generation=UInt64(1), model_ns=Int64((sequence-1)*500_000))
                wait_proof(() -> publisher.completed[] == sequence, 10, "unlinked snapshot")
            end
            @test !publisher.failed[]
            wait_proof(() -> publisher.transport_dropped[] >= 2, 10, "visible pending overwrite")
            sinkoption = PipeWireArrayStreamOptions(node_name="test-pupil-consumer",media_name="test pupil",
                schema=boundary().schema,format=NdArrayFormat(NdArray.F32_LE,(2,4,4);layout=NdArray.ROW_MAJOR))
            with_array_streams((sinkoption,); remote, input=(true,)) do sinkowner
                sink = sinkowner.streams[1].stream
                registry = with_array_stream(sinkowner,1) do _; Registry(sinkowner.core); end
                link = sourceproxy = sourceinfo = linkinfo = nothing
                try
                    wait_proof(10,"scientific source registration") do
                        roundtrip(registry)
                        length(find_globals(registry;interface="PipeWire:Interface:Node",
                            properties=("node.name"=>Pupil.NODE_NAME,))) == 1 && node_id(sink) != typemax(UInt32)
                    end
                    sourceglobal = only(find_globals(registry;interface="PipeWire:Interface:Node",
                        properties=("node.name"=>Pupil.NODE_NAME,)))
                    sourceid = sourceglobal.id
                    sourceproxy, sourceinfo = with_array_stream(sinkowner,1) do _
                        proxy = bind(registry,sourceglobal,Node)
                        proxy, track_info!(proxy)
                    end
                    # Link by discovered native ids, without touching publisher-owned output locks.
                    wait_proof(10,"scientific source ports") do
                        roundtrip(registry)
                        length(find_globals(registry;interface="PipeWire:Interface:Port",
                            properties=("node.id"=>string(sourceid),"port.direction"=>"out"))) == 1 &&
                        length(find_globals(registry;interface="PipeWire:Interface:Port",
                            properties=("node.id"=>string(node_id(sink)),"port.direction"=>"in"))) == 1
                    end
                    output = only(find_globals(registry;interface="PipeWire:Interface:Port",
                        properties=("node.id"=>string(sourceid),"port.direction"=>"out")))
                    input = only(find_globals(registry;interface="PipeWire:Interface:Port",
                        properties=("node.id"=>string(node_id(sink)),"port.direction"=>"in")))
                    link = with_array_stream(sinkowner,1) do _
                        create_object(sinkowner.core,"link-factory",Link;properties=Dict(
                            "link.output.node"=>string(sourceid),"link.output.port"=>string(output.id),
                            "link.input.node"=>string(node_id(sink)),"link.input.port"=>string(input.id),"object.linger"=>"false"))
                    end
                    linkinfo = track_info!(link)
                    destination=zeros(Float32,2,4,4)
                    receipt=Ref{Any}(nothing)
                    try
                        wait_proof(10,"late consumer delivery") do
                            receipt[] = drain_pipewire_array!(destination,sinkowner,1)
                            receipt[] !== nothing
                        end
                    catch
                        roundtrip(registry)
                        @error "Pupil delivery state" publisher=Pupil.status(publisher) sink=stream_state(sink) source=current_info(sourceinfo) link=current_info(linkinfo)
                        rethrow()
                    end
                    @test destination[1,:,:] == permutedims(3 .* opd)
                    @test destination[2,:,:] == permutedims(amplitude)
                    @test receipt[].identity.domain == publisher.domain
                    @test receipt[].identity.generation == 1 && receipt[].identity.sequence == 3
                    @test receipt[].pts == 1_000_000 && receipt[].duration == 500_000
                    step_graph!(graph) # An intentionally unsampled completed source frame.
                    step_graph!(graph)
                    @test Pupil.sample!(publisher;generation=UInt64(1),model_ns=Int64(2_000_000))
                    wait_proof(10,"observable source sequence gap") do
                        candidate=drain_pipewire_array!(destination,sinkowner,1)
                        candidate === nothing && return false
                        candidate.identity.sequence == 5
                    end
                    @test publisher.gaps[] == 1
                    Pupil.drain!(publisher)
                    reset_graph!(graph)
                    Pupil.reset!(publisher,UInt64(2))
                    copyto!(graph_input(graph,:upstream),7 .* opd)
                    step_graph!(graph)
                    @test Pupil.sample!(publisher;generation=UInt64(2),model_ns=Int64(0))
                    wait_proof(10,"new generation receipt") do
                        candidate=drain_pipewire_array!(destination,sinkowner,1)
                        candidate === nothing && return false
                        receipt[]=candidate
                        candidate.identity.generation == 2
                    end
                    @test receipt[].identity.sequence == 1 && receipt[].pts == 0
                    @test destination[1,:,:] == permutedims(7 .* opd)
                    for generation in 3:5
                        # Drain immediately after submission, including an in-flight CUDA host transfer.
                        step_graph!(graph)
                        @test Pupil.sample!(publisher;generation=UInt64(generation-1),model_ns=Int64(500_000))
                        Pupil.drain!(publisher)
                        reset_graph!(graph)
                        Pupil.reset!(publisher,UInt64(generation))
                        copyto!(graph_input(graph,:upstream),generation .* opd)
                        step_graph!(graph)
                        @test Pupil.sample!(publisher;generation=UInt64(generation),model_ns=Int64(0))
                        wait_proof(10,"repeated reset receipt") do
                            candidate=drain_pipewire_array!(destination,sinkowner,1)
                            candidate === nothing && return false
                            receipt[]=candidate
                            candidate.identity.generation == generation
                        end
                        @test receipt[].identity.sequence == 1 && receipt[].pts == 0
                        @test destination[1,:,:] == permutedims(generation .* opd)
                    end
                    roundtrip(registry)
                    @test only(find_globals(registry;interface="PipeWire:Interface:Node",
                        properties=("node.name"=>Pupil.NODE_NAME,))).id == sourceid
                    # A bad scientific frame disables publication, retaining the registered node and link.
                    copyto!(graph_input(graph,:upstream),fill(NaN32,4,4)); step_graph!(graph)
                    @test Pupil.sample!(publisher;generation=UInt64(5),model_ns=Int64(500_000))
                    wait_proof(() -> publisher.failed[],10,"isolated invalid pupil")
                    @test !istaskdone(publisher.task)
                    @test !Pupil.sample!(publisher;generation=UInt64(5),model_ns=Int64(1_000_000))
                    wait_proof(10,"native publisher failure property") do
                        roundtrip(registry)
                        get(current_info(sourceinfo).properties,"aos.pupil-output.failed",nothing) == "true"
                    end
                    @test occursin("OPD must be finite",current_info(sourceinfo).properties["aos.pupil-output.failure"])
                    roundtrip(registry)
                    @test length(find_globals(registry;interface="PipeWire:Interface:Node",
                        properties=("node.name"=>Pupil.NODE_NAME,))) == 1
                finally
                    with_array_stream(sinkowner,1) do _
                        sourceinfo === nothing || close(sourceinfo)
                        sourceproxy === nothing || close(sourceproxy)
                        linkinfo === nothing || close(linkinfo)
                        link === nothing || close(link)
                        close(registry)
                    end
                end
            end
        finally
            Pupil.close!(publisher)
        end
        @test istaskdone(publisher.task)
    end
end
