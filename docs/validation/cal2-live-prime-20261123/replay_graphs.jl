# Replay captured CAL2 cameras with the sealed application's own FITS bindings.
using Test, LinearAlgebra, FilterGraphs, FilterGraphPipeWire, FilterGraphAlgorithms, PipeWireAORTC
const FG = FilterGraphs
const FA = FilterGraphAlgorithms
BLAS.set_num_threads(1)
length(ARGS) in (2, 3) && (length(ARGS) == 2 || ARGS[3] == "--corrupted-header") ||
    error("expected APPLICATION CAPTURE [--corrupted-header]")
application, capture = ARGS[1:2]
corrupted_header = length(ARGS) == 3
records = PipeWireAORTC.Common.read_json(joinpath(capture, "cal2-samples.json"))

function branch(name, test)
    graph_path = joinpath(application, "rtc", name * "-graph.conf")
    graph = FG.prepare_graph(graph_path; algorithms=FA.algorithms())
    try
        parameters = PipeWireAORTC.GraphOwner.read_bindings(graph_path,
            joinpath(application, "rtc", name * "-parameters.conf"))
        FG.replace_parameters!(graph, pairs(parameters)...)
        outputs = map(format -> zeros(format.element_type, format.shape), FG.output_formats(graph))
        stream = records[name * "-image"]
        bytes = reinterpret(Float32, read(joinpath(capture, stream["payload"])))
        rows, columns = stream["shape"]
        image = zeros(Float32, rows, columns)
        physical = getproperty(outputs, Symbol("physical-offset"))
        residual = getproperty(outputs, Symbol("modal-residual"))
        function step(frame; index=frame, generation=nothing, finite=true, corrupted=false)
            raw = @view bytes[(frame - 1) * length(image) + 1:frame * length(image)]
            copyto!(image, transpose(reshape(raw, columns, rows)))
            finite || fill!(image, NaN32)
            receipt = stream["frames"][frame]
            key = receipt["identity"]
            generation === nothing && (generation = key["generation"])
            identity = FA.SampleAcquisitionIdentity(Tuple(hex2bytes(key["domain"])), generation, index)
            role = receipt["optical"] == "OPTICAL_FRINGED" ? FA.ChoppedImageFringed :
                receipt["optical"] == "OPTICAL_UNFRINGED" ? FA.ChoppedImageUnfringed : nothing
            metadata = FA.SampleMetadata(index;
                timestamp_nanoseconds=receipt["pts"], terminal=true, corrupted,
                exposure_duration_nanoseconds=receipt["duration_ns"], chopped_image_kind=role,
                acquisition_identity=identity)
            return FG.process!(outputs, graph, (; image), (; image=metadata))
        end
        close_loop() = FG.replace_properties!(graph, "correction:closed" => true)
        projection = parameters[Symbol("command-projection")]
        expected() = projection * (-0.05f0 .* residual)
        return test(step, close_loop, physical, residual, expected)
    finally
        FilterGraphPipeWire.close_execution(graph)
    end
end

@testset "CAL2 captured camera frame replay with sealed calibration" begin
    for name in ("llowfs", "scc")
        @testset "$name explicit close" begin
            branch(name, (step, close_loop, physical, residual, expected) -> begin
                if name == "scc"
                    @test step(1) === FA.SccPixelResidualIncompletePair
                else
                    @test all(values(step(1)))
                    @test all(iszero, physical)
                end
                @test all(values(step(2)))
                @test all(isfinite, residual)
                @test any(!iszero, residual)
                @test all(iszero, physical)
                open_residual_peak = maximum(abs, residual)
                close_loop()
                @test all(iszero, physical)
                @test all(values(step(3)))
                @test any(!iszero, physical)
                @test physical ≈ expected() rtol=2eps(Float32)
                @info "Captured replay result" branch=name open_residual_peak peak_physical_m=maximum(abs, physical) first_closed_sequence=3
            end)
        end
    end
    @testset "SCC missing partner and camera restart" begin
        branch("scc", (step, close_loop, physical, residual, expected) -> begin
            @test step(1) === FA.SccPixelResidualIncompletePair
            @test all(values(step(2)))
            @test all(iszero, physical)
            close_loop()
            @test step(3;index=5) === FA.SccPixelResidualIncompletePair
            @test all(iszero, physical)
            @test step(4;index=1,generation=2) === FA.SccPixelResidualIncompletePair
            @test all(iszero, physical)
            @test all(values(step(5;index=2,generation=2)))
            @test physical ≈ expected() rtol=2eps(Float32)
        end)
    end
    @testset "LLOWFS invalid measurement before the first correction" begin
        branch("llowfs", (step, close_loop, physical, residual, expected) -> begin
            @test all(values(step(1)))
            close_loop()
            if corrupted_header
                @test all(values(step(2; corrupted=true)))
            else
                @test step(2; finite=false) === FA.DenseReconstructionNonFiniteInput
            end
            @test all(iszero, physical)
            @test all(values(step(3)))
            @test physical ≈ expected() rtol=2eps(Float32)
        end)
    end
end
