# Optional science boundary check; run in an environment containing
# FilterGraphs.
using Test
using PipeWireAORTC

@test !any(
    id -> id.name in ("FilterGraphPipeWire", "FilterGraphs", "CUDA"),
    keys(Base.loaded_modules),
)

using FilterGraphPipeWire
using FilterGraphs
using FilterGraphAlgorithms

@test Base.get_extension(PipeWireAORTC, :PipeWireAORTCGraphExt) !== nothing
@test hasmethod(PipeWireAORTC.GraphOwner.run_owner, Tuple{Any,Any,Any})
@test hasmethod(PipeWireAORTC.InstrumentCalibration.controller_graph, (String,))
@test Base.get_extension(PipeWireAORTC, :PipeWireAORTCCalibrationExt) === nothing
@test !any(
    id -> id.name in ("AdaptiveOpticsSim", "AdaptiveOpticsSimPipeWireHIL", "CUDA", "AMDGPU"),
    keys(Base.loaded_modules),
)

module GraphOwnerStartupProbe
using PipeWireAORTC, FilterGraphPipeWire

const Extensions = Base.get_extension(PipeWireAORTC, :PipeWireAORTCGraphExt)
const Bootstrap = PipeWireAORTC.OwnerBootstrapRuntime
const StartupTiming = PipeWireAORTC.Common.StartupTiming

struct Runtime{T}
    transport::T
    events::Vector{Symbol}
end

struct Graph
    events::Vector{Symbol}
end

Extensions.graph_node(options, graph::Graph, instance, ::Union{Nothing,StartupTiming}) =
    (; node = graph, observer = nothing, offset_receiver = nothing,
       offset_clock = nothing, display = nothing)
Bootstrap.preparation_check!(::Runtime) = nothing
Bootstrap.prepared!(runtime::Runtime) = push!(runtime.events, :prepared)
Bootstrap.take_connect!(::Runtime) = :connect_ticket
Bootstrap.connecting!(::Runtime, ticket; ready, quit) = nothing
Bootstrap.check_connect!(::Runtime, ticket) = nothing
Bootstrap.fault!(runtime::Runtime, ::Exception) = push!(runtime.events, :faulted)
Bootstrap.finishing!(runtime::Runtime) = push!(runtime.events, :finishing)
FilterGraphPipeWire.prepare!(::Graph; kwargs...) = error("synthetic frames reached the live owner")
FilterGraphPipeWire.connect!(graph::Graph) = push!(graph.events, :connect)
FilterGraphPipeWire.run!(graph::Graph) = push!(graph.events, :run)
Base.close(graph::Graph) = push!(graph.events, :close)
end

@testset "Live graph owners connect with no synthetic scientific frames" begin
    P = GraphOwnerStartupProbe
    for execution in ("complete-frame", "row-block")
        events = Symbol[]
        runtime = P.Runtime((; endpoint = (; instance = Int64(1))), events)
        options = (; name = "live-owner", capture_backend = nothing, execution,
                   qualify_at_install = false, warmup_outputs = (:residual,))
        @test P.Extensions.run_prepared(options, runtime, P.Graph(events), nothing) === nothing
        @test events == [:prepared, :connect, :run, :finishing, :close]
    end
end

@testset "Correction priming observes accepted open-loop acquisitions" begin
    extension = Base.get_extension(PipeWireAORTC, :PipeWireAORTCGraphExt)
    graph = mktemp() do path, io
        write(io, """
filter.graph = {
    nodes = [ { name=correction type=ndarray label=leaky-integrator-f32
        config={ extent=2 initial_state=0 input_schema=test/cal2-residual/1
            output_schema=test/cal2-command/1 }
        props={ gain=-0.05 pole=1 closed=false } } ]
    links=[]
    inputs=[ { name=residual endpoint="correction:input" } ]
    outputs=[ { name=offset endpoint="correction:output" } ]
}
""")
        flush(io)
        FilterGraphs.prepare_graph(path; algorithms = FilterGraphAlgorithms.algorithms())
    end
    try
        options = (;
            prime_on_output = :offset, session_run_control = true,
            capture_backend = nothing, execution = "complete-frame",
            correction_properties = ["correction:closed"],
        )
        observer = only(extension.prepare_priming(options, graph))
        @test !observer.ready[]
        @test_throws ArgumentError extension.prepare_priming(
            merge(options, (; prime_on_output = :absent)), graph,
        )
        @test_throws ArgumentError extension.prepare_priming(
            merge(options, (; local_output = (; port = :offset))), graph,
        )
        domain = ntuple(index -> UInt8(index), 16)
        identity = FilterGraphAlgorithms.SampleAcquisitionIdentity(domain, 1, 1)
        sample = FilterGraphAlgorithms.SampleMetadata(
            1; exposure_duration_nanoseconds = 2_000_000, acquisition_identity = identity,
        )
        observe(sample, offset = zeros(Float32, 2); present = true) =
            observer(Val(:frame), (; offset), (;
                offset = FilterGraphAlgorithms.AdmittedSampleMetadata(present, sample),
            ))
        observe(sample; present = false)
        @test !observer.ready[]
        observe(sample, Float32[NaN, 0])
        @test !observer.ready[]
        observe(sample)
        @test observer.ready[]
        @test !observer.controller.plan.closed
        @test !extension.priming_measurement(Float32[0, 0], Val(true))
        @test !extension.priming_measurement(Float32[1, -1], Val(true))
        @test !extension.priming_measurement(Float32[1, NaN], Val(true))
        @test extension.priming_measurement(Float32[1, 0], Val(true))
        @test extension.priming_measurement(Float32[0, 0], Val(false))
        @test !extension.active_subaperture_valid([false, true, true], [true, false, false])
        @test extension.active_subaperture_valid([false, true, true], [false, false, true])
        low_order = extension.CorrectionPriming{
            :offset, :low_order, :valid, false, typeof(observer.controller), Nothing
        }(observer.controller, nothing, "primed", Threads.Atomic{Bool}(false))
        outputs = (; offset = zeros(Float32, 2), valid = [true])
        receipt = FilterGraphAlgorithms.AdmittedSampleMetadata(true, sample)
        metadata = (; offset = receipt, valid = receipt)
        available = (; offset = true, valid = true)
        low_order(Val(:frame), outputs, metadata, (; low_order = true), available)
        @test low_order.ready[]
        low_order(Val(:frame), outputs, metadata, (; low_order = false), (; offset = false, valid = false))
        @test low_order.ready[]
        outputs.valid[1] = false
        low_order(Val(:frame), outputs, metadata, (; low_order = true), available)
        @test !low_order.ready[]
        outputs.valid[1] = true
        other = FilterGraphAlgorithms.SampleMetadata(
            2; exposure_duration_nanoseconds = 2_000_000,
            acquisition_identity = FilterGraphAlgorithms.SampleAcquisitionIdentity(domain, 1, 2),
        )
        stale = (; offset = receipt, valid = FilterGraphAlgorithms.AdmittedSampleMetadata(true, other))
        low_order(Val(:frame), outputs, stale, (; low_order = true), available)
        @test !low_order.ready[]
        low_order(Val(:frame), outputs, metadata, (; low_order = true), available)
        @test low_order.ready[]
        low_order(Val(:frame), outputs, metadata, (; low_order = true), (; offset = false, valid = false))
        @test !low_order.ready[]
        native_storage = zeros(Float32, 2)
        metadata = (; offset = FilterGraphAlgorithms.AdmittedSampleMetadata(true, sample))
        check_allocations(observer, storage, metadata) = GC.@preserve storage begin
            offset = FilterGraphPipeWire.RowMajorBorrowedArray{Float32,1,false}(
                pointer(storage), size(storage), length(storage),
            )
            observer(Val(:frame), (; offset), metadata)
            return @allocated observer(Val(:frame), (; offset), metadata)
        end
        @test check_allocations(observer, native_storage, metadata) == 0
        loops = PipeWireAORTC.CorrectionLoops.Observer(options.correction_properties, Int64(1))
        try
            callback = extension.correction_observation(loops, nothing, (observer,)).frame_observer
            @test check_allocations(callback, native_storage, metadata) == 0
        finally
            close(loops)
        end
        observe(FilterGraphAlgorithms.SampleMetadata(sample; corrupted = true))
        @test !observer.ready[]
        observe(sample)
        observer(Val(:invalidated))
        @test !observer.ready[]
        observe(sample)
        observer(Val(:reset))
        @test !observer.ready[]
        observe(sample)
        FilterGraphs.replace_properties!(graph, "correction:closed" => true)
        observe(sample)
        @test !observer.ready[]
        @test check_allocations(observer, native_storage, metadata) == 0
        @test_throws ArgumentError extension.prepare_priming(options, graph)
    finally
        FilterGraphPipeWire.close_execution(graph)
    end
end

@testset "FITS graph initial parameters adopt before node publication" begin
    mktempdir() do directory
        background = reshape(Float32.(1:48), 8, 6)
        path = joinpath(directory, "background.fits")
        PipeWireAORTC.Artifacts.FITS(path, "w") do fits
            PipeWireAORTC.Artifacts.write(fits, permutedims(background))
        end
        manifest = joinpath(directory, "bindings.conf")
        write(
            manifest,
            """
parameters = [
    { port = background path = background.fits hdu = 1
      axes = [ 2 1 ] }
]
""",
        )
        entries = PipeWireAORTC.GraphOwner.bindings(manifest)
        graph_path = joinpath(directory, "graph.conf")
        write(
            graph_path,
            """
filter.graph = {
    nodes = [ { type = ndarray name = calibrate
        label = pixel-calibration-row-u16-f32
        config = { image_size = [ 8 6 ] row_block_rows = 2
            initial_flat = null initial_background = null } } ]
    links = []
    inputs = [ "calibrate:raw" "calibrate:background" "calibrate:flat" ]
    outputs = [ "calibrate:calibrated" ]
}
""",
        )
        for execution in ("complete-frame", "row-block")
            options = FilterGraphPipeWire.parse_arguments([
                "--graph", graph_path, "--check", "--execution", execution
            ])
            arrays = Ref{Any}(nothing)
            graph = FilterGraphPipeWire.prepare_service_graph(
                options.graph;
                execution = execution == "row-block" ? :row_block : :complete_frame,
                initial_parameters = formats -> begin
                    arrays[] = PipeWireAORTC.GraphOwner.prepare_bindings(entries, formats)
                    arrays[]
                end,
            )
            try
                checked = execution == "row-block" ? graph.graph : graph
                @test checked.nodes[1].prepared.plan.background == background
                last(only(arrays[]))[1] = -1
                @test checked.nodes[1].prepared.plan.background[1] == 1
                @test FilterGraphs.parameter_formats(graph).background.shape == (8, 6)
                outputs = (; calibrated = zeros(Float32, 2, 6))
                inputs = (; raw = fill(UInt16(100), 2, 6))
                for block in 0:3
                    metadata = (;
                        raw = FilterGraphAlgorithms.SampleMetadata(
                            0, 2block; terminal = block == 3
                        )
                    )
                    FilterGraphs.process!(outputs, graph, inputs, metadata)
                    @test outputs.calibrated ==
                        100.0f0 .- background[(2block+1):(2block+2), :]
                end
            finally
                FilterGraphPipeWire.close_execution(graph)
            end
        end
        @test PipeWireAORTC.GraphOwner.read_bindings(graph_path, manifest)[:background] ==
            background
        options = FilterGraphPipeWire.parse_arguments(["--graph", graph_path, "--check"])
        for (array, axes) in (
            (zeros(Float32, 8, 5), (2, 1)),
            (background, (1, 2)),
            (fill(Inf32, 8, 6), (2, 1)),
        )
            PipeWireAORTC.InstrumentCalibration.write_fits(path, array)
            source = PipeWireAORTC.Artifacts.FITSArtifact(path; axes)
            invalid = [PipeWireAORTC.GraphOwner.FITSBinding(:background, source)]
            expected = all(isfinite, array) ? DimensionMismatch : ArgumentError
            @test_throws expected FilterGraphPipeWire.prepare_service_graph(
                options.graph;
                initial_parameters = formats ->
                    PipeWireAORTC.GraphOwner.prepare_bindings(invalid, formats),
            )
        end
        @test sort(readdir(directory)) == ["background.fits", "bindings.conf", "graph.conf"]
    end
end

@testset "typed Boolean and integer FITS initialization" begin
    mktempdir() do directory
        graph_path = joinpath(directory, "graph.conf")
        write(
            graph_path,
            """
filter.graph = {
    nodes = [
        { type = ndarray name = select label = pixel-selection-f32
          config = { image_size = [ 2 3 ]
            mask = [ true false true false true false ]
            input_schema = pipewireao/calibrated-pixels-f32/1
            output_schema = pipewireao/test.selected-pixels/1 } }
        { type = ndarray name = extract label = region-extraction-f32
          config = { image_size = [ 2 3 ] region_size = [ 1 1 ]
            origins = [ [ 0 0 ] ] } }
    ]
    links = []
    inputs = [ "select:image" "select:mask" "extract:calibrated" "extract:origins" ]
    outputs = [ "select:selected-pixels" "extract:regions" ]
}
""",
        )
        manifest = joinpath(directory, "parameters.conf")
        write(
            manifest,
            """
parameters = [
    { port = mask path = mask.fits axes = [ 2 1 ] }
    { port = origins path = origins.fits axes = [ 2 1 ] }
]
""",
        )
        entries = PipeWireAORTC.GraphOwner.bindings(manifest)
        mask = Bool[false true false; true false true]
        mask_path = joinpath(directory, "mask.fits")
        origins_path = joinpath(directory, "origins.fits")
        write_fits = PipeWireAORTC.InstrumentCalibration.write_fits
        write_fits(mask_path, mask)
        write_fits(origins_path, UInt32[0 0])
        options = FilterGraphPipeWire.parse_arguments(["--graph", graph_path, "--check"])
        prepare() = FilterGraphPipeWire.prepare_service_graph(
            options.graph;
            initial_parameters = formats ->
                PipeWireAORTC.GraphOwner.prepare_bindings(entries, formats),
        )
        graph = prepare()
        try
            image = Float32[1 2 3; 4 5 6]
            selected = zeros(Float32, 3)
            regions = zeros(Float32, 1, 1, 1)
            outputs = NamedTuple{(Symbol("selected-pixels"), :regions)}((selected, regions))
            @test all(
                values(FilterGraphs.process!(outputs, graph, (; image, calibrated = image)))
            )
            @test selected == Float32[2, 4, 6]
            @test regions == ones(Float32, 1, 1, 1)
        finally
            FilterGraphPipeWire.close_execution(graph)
        end
        @test eltype(
            PipeWireAORTC.GraphOwner.read_bindings(graph_path, manifest)[:mask]
        ) === Bool
        write_fits(mask_path, UInt8[0 2 0; 1 0 1])
        @test_throws ArgumentError prepare()
        write_fits(mask_path, mask)
        write_fits(origins_path, Float32[0.5 0])
        @test_throws ArgumentError prepare()
    end
end
