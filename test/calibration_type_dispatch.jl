# Optional CPU interface checks using real prepared graph types, without a
# PipeWire core, optical propagation or device.
module CalibrationTypeDispatchTests
using Test, PipeWireAO, PipeWireAORTC, FilterGraphAlgorithms, FilterGraphPipeWire
using FilterGraphs
using AdaptiveOpticsSim, AdaptiveOpticsSimPipeWireHIL, AdaptiveOpticsCalibration
using AdaptiveOpticsSim.AlgorithmGraphs: hil_boundary_status, hil_frame_buffer

include("aos_graph_documents.jl")
const C = Base.get_extension(PipeWireAORTC, :PipeWireAORTCCalibrationExt)
const G = Base.get_extension(PipeWireAORTC, :PipeWireAORTCGraphExt)
const FGA = FilterGraphAlgorithms

@testset "calibration rates dispatch without changing native fractions or admission" begin
    format = NdArrayFormat(
        PipeWireAO.NdArray.F32_LE, (3,); layout = PipeWireAO.NdArray.ROW_MAJOR
    )
    fraction = PipeWireAO.SPA.Fraction(500, 1)
    @test C.calibration_rate(fraction) === fraction
    for rate in (fraction, 500//1, (500, 1), [500, 1])
        actual = C.calibration_probe_format(format, rate)
        @test (actual.rate.num, actual.rate.denom) == (500, 1)
        @test actual.shape == (3,) && actual.layout == PipeWireAO.NdArray.ROW_MAJOR
    end
    @test_throws ArgumentError C.calibration_probe_format(format, 0//1)
    @test_throws ArgumentError C.calibration_probe_format(
        NdArrayFormat(
            PipeWireAO.NdArray.F32_LE, (2, 3); layout = PipeWireAO.NdArray.ROW_MAJOR
        ),
        fraction,
    )
    @test_throws ArgumentError C.calibration_probe_format(
        NdArrayFormat(
            PipeWireAO.NdArray.I32_LE, (3,); layout = PipeWireAO.NdArray.ROW_MAJOR
        ),
        fraction,
    )
end

# Cold composition data exercises the warmup generator's input routing only;
# numerical chopped processing is covered by calibration_chopped.jl.
function independent_camera_configuration(directory; closed)
    node(name, label, config) =
        Dict("name" => name, "type" => "ndarray", "label" => label, "config" => config)
    port(name, endpoint) = Dict("name" => name, "endpoint" => endpoint)
    link(output, input) = Dict("output" => output, "input" => input)
    for name in ("left", "right")
        pixels = node(
            name * "-pixels",
            "pixel-selection-f32",
            Dict(
                "image_size" => [2, 3],
                "mask" => fill(true, 6),
                "input_schema" => "test/image/1",
                "output_schema" => FGA.CONTROLLER_RESIDUAL_ERROR_V1,
            ),
        )
        integrator = node(
            name * "-integrator", "closed-loop-integrator-f32", Dict("state_length" => 6)
        )
        integrator["props"] = Dict("closed" => closed)
        document = Dict(
            "filter.graph" => Dict(
                "nodes" => [pixels, integrator],
                "links" => [
                    link(
                        name * "-pixels:selected-pixels",
                        name * "-integrator:residual-error",
                    ),
                ],
                "inputs" => [
                    port(name * "-image", name * "-pixels:image"),
                    port(name * "-feedback", name * "-integrator:constraint-feedback"),
                ],
                "outputs" =>
                    [port(name * "-correction", name * "-integrator:correction")],
            ),
        )
        PipeWireAORTC.ScienceExport.write_spa_config(
            joinpath(directory, name * ".conf"), document
        )
    end
    combination(name, schema, left, right) = node(
        name,
        "vector-linear-combination-f32",
        Dict(
            "extent" => 6,
            "schema" => schema,
            "left_scale" => left,
            "right_scale" => right,
        ),
    )
    command_map(name, input_schema, output_schema) = node(
        name,
        "dense-vector-reconstructor-f32",
        Dict(
            "input_count" => 6,
            "output_count" => 6,
            "initial_reconstructor" => [Float32(row == column) for row in 1:6 for column in 1:6],
            "input_schema" => input_schema,
            "output_schema" => output_schema,
            "reconstructor_schema" => "test/coordinate-map/1",
        ),
    )
    shared = Dict(
        "filter.graph" => Dict(
            "nodes" => [
                combination("sum", FGA.CONTROLLER_COMMAND_V1, 1, 1),
                command_map(
                    "to-pdm", FGA.CONTROLLER_COMMAND_V1, FGA.REQUESTED_PDM_COMMAND_V1
                ),
                node(
                    "conditioner",
                    "pdm-command-f32",
                    Dict(
                        "actuator_count" => 6,
                        "command_limits" => [-1, 1],
                        "slew_limit" => nothing,
                        "initial_current" => nothing,
                        "quantization_origin" => nothing,
                        "quantization_step" => nothing,
                        "dither_seed" => nothing,
                    ),
                ),
                command_map(
                    "to-controller",
                    FGA.PDM_CONSTRAINT_FEEDBACK_V1,
                    FGA.CONTROLLER_CONSTRAINT_FEEDBACK_V1,
                ),
                combination("left-return", FGA.CONTROLLER_CONSTRAINT_FEEDBACK_V1, 0.5, 0),
                combination("right-return", FGA.CONTROLLER_CONSTRAINT_FEEDBACK_V1, 0.5, 0),
            ],
            "links" => [
                link("sum:output", "to-pdm:ordered-input"),
                link("to-pdm:output", "conditioner:requested"),
                link("conditioner:constraint-feedback", "to-controller:ordered-input"),
                (
                    link("to-controller:output", name * ":" * side) for
                    name in ("left-return", "right-return") for
                    side in ("left", "right")
                )...,
            ],
            "inputs" =>
                [port("left-command", "sum:left"), port("right-command", "sum:right")],
            "outputs" => [
                port("command", "conditioner:demanded"),
                port("left-returned", "left-return:output"),
                port("right-returned", "right-return:output"),
            ],
        ),
    )
    PipeWireAORTC.ScienceExport.write_spa_config(joinpath(directory, "shared.conf"), shared)
    path = joinpath(directory, "composition.conf")
    PipeWireAORTC.ScienceExport.write_spa_config(
        path,
        Dict(
            "filter.composition" => Dict(
                "branches" => [
                    Dict(
                        "name" => name,
                        "graph" => name * ".conf",
                        "input" => name * "-image",
                        "correction" => name * "-correction",
                        "feedback" => name * "-feedback",
                        "shared-input" => name * "-command",
                        "shared-feedback" => name * "-returned",
                    ) for name in ("left", "right")
                ],
                "shared" => "shared.conf",
            ),
        ),
    )
    return path
end

@testset "composition warmup dispatch preserves independent and simultaneous arrivals" begin
    mktempdir() do directory
        composition = FilterGraphs.prepare_composition(
            independent_camera_configuration(directory; closed = true); algorithms = FGA.algorithms()
        )
        try
            @test G.validate_owner_feedback(composition, nothing) === nothing
            @test_throws ArgumentError G.validate_owner_feedback(
                composition, :left_feedback => :right_feedback
            )
            formats = FilterGraphs.input_formats(composition)
            input = Symbol("left-image")
            other = Symbol("right-image")
            options = (;
                execution = "complete-frame", feedback = nothing, capture_backend = nothing
            )
            warmup = (;
                input, exposure_duration_ns = 10_000_000, trigger_high_is_fringed = true
            )
            @test G.chopped_warmup_input(composition, formats, input)
            @test !G.chopped_warmup_input(composition.graph, formats, input)
            samples = G.chopped_warmup_samples(composition, options, warmup)
            @test length(samples) == 5
            @test all(sample -> keys(sample.inputs) == (input,), samples[1:3])
            @test keys(samples[4].inputs) == (other,)
            @test keys(samples[5].inputs) == keys(formats)
            @test all(image -> image == ones(Float32, 2, 3), values(samples[5].inputs))
            @test samples[1].expected === FGA.SccPixelResidualIncompletePair
            @test samples[5].expected === nothing
            @test getproperty(samples[5].metadata, input).sequence == 4
            @test getproperty(samples[5].metadata, other).sequence == 2
            @test getproperty(samples[5].metadata, input).chopped_image_kind ==
                FGA.ChoppedImageUnfringed
            @test_throws ArgumentError G.chopped_warmup_samples(
                composition, options, merge(warmup, (; input = :absent))
            )
        finally
            FilterGraphPipeWire.close_execution(composition)
        end
    end
end

@testset "retained camera composition restores open controllers on a fresh attachment" begin
    mktempdir() do directory
        path = independent_camera_configuration(directory; closed = false)
        prefix = String(PipeWireAO.LibPipeWire.PipeWireAO_jll.artifact_dir)
        document, files, members = withenv("PIPEWIREAO_PREFIX" => prefix) do
            document = G.persistent_graph_document(path)
            files = PipeWireAORTC.GraphOwner.composition_files(document, path)
            return document, files, map(G.persistent_graph_document, files)
        end
        algorithms = FGA.algorithms()
        properties = ("left-integrator:closed", "right-integrator:closed")
        first_attachment = G.prepare_persistent_graph(document, members, algorithms)
        try
            @test G.check_persistent_corrections(first_attachment, properties) === nothing
            FilterGraphs.replace_properties!(first_attachment, first(properties) => true)
            @test_throws ArgumentError G.check_persistent_corrections(first_attachment, properties)
            foreach(rm, [path; files])
            next_attachment = G.prepare_persistent_graph(document, members, algorithms)
            try
                @test G.check_persistent_corrections(next_attachment, properties) === nothing
                @test FilterGraphs.composition_observation(next_attachment).sequence == 0
            finally
                FilterGraphPipeWire.close_execution(next_attachment)
            end
        finally
            FilterGraphPipeWire.close_execution(first_attachment)
        end
    end
end

@testset "detector warmup publishes a priming result" begin
    mktempdir() do directory
        path = joinpath(directory, "detector-difference.conf")
        write(
            path,
            """
            filter.graph = {
                nodes = [
                    { name = pair type = ndarray label = chopped-detector-difference-f32
                      config = { image_size = [ 2 3 ] input_schema = "test/image/1" } }
                ]
                inputs = [ { name = image endpoint = "pair:image" } ]
                outputs = [
                    { name = difference endpoint = "pair:difference" }
                    { name = pair-status endpoint = "pair:pair-status" }
                ]
            }
            """,
        )
        graph = FilterGraphPipeWire.prepare_service_graph(path; algorithms = FGA.algorithms())
        try
            options = (;
                execution = "complete-frame", feedback = nothing, capture_backend = nothing
            )
            warmup = (;
                input = :image, exposure_duration_ns = 10_000_000, trigger_high_is_fringed = true
            )
            samples = G.chopped_warmup_samples(graph, options, warmup)
            @test length(samples) == 3
            @test all(sample -> sample.expected === nothing, samples)
        finally
            FilterGraphPipeWire.close_execution(graph)
        end
    end
end

function named_calibration_document!(path, secondary_basis)
    common = PipeWireAORTC.Common
    document = common.read_yaml(path)
    graph = document["graphs"]["calibration"]
    secondary = deepcopy(only(graph["nodes"]))
    secondary["name"] = "secondary"
    secondary["config"]["mode_count"] = 1
    push!(graph["nodes"], secondary, Dict(
        "name" => "combined", "type" => "pupil_opd_composition_f32",
        "config" => Dict(
            "resolution" => 2, "uncompensated_opd_schema" => "test.export.opd/1",
            "surface_opd_schema" => "test.export.opd/1",
            "pupil_opd_schema" => "test.export.opd/1",
        ),
    ))
    push!(graph["inputs"], Dict(
        "name" => "secondary", "binding" => "secondary_command",
        "destination" => "secondary.coefficients",
    ))
    append!(graph["parameters"], [
        Dict("destination" => "secondary.basis", "binding" => "secondary_basis"),
        Dict("destination" => "secondary.pupil_support", "binding" => "support"),
    ])
    graph["links"] = [
        Dict("source" => "modal.opd", "destination" => "combined.uncompensated_opd"),
        Dict("source" => "secondary.opd", "destination" => "combined.surface_opd"),
    ]
    only(graph["outputs"])["source"] = "combined.pupil_opd"
    document["graphs"]["production"] = deepcopy(graph)
    document["hil"] = Dict(
        "command" => ["modal.coefficients", "secondary.coefficients"],
        "frame" => "combined.pupil_opd",
    )
    wire = only(document["wire_contracts"])
    for field in ("command_schema", "command_scale")
        wire[field] = Dict("command" => wire[field], "secondary" => wire[field])
    end
    bindings = document["bindings"]
    bindings["secondary_command"] = merge(bindings["command"], Dict("shape" => [1]))
    bindings["secondary_basis"] = merge(bindings["basis"], Dict(
        "path" => "secondary.fits", "shape" => [2, 2, 1],
    ))
    fits_path = joinpath(dirname(dirname(path)), "secondary.fits")
    PipeWireAORTC.Artifacts.FITSIO.FITS(fits_path, "w") do fits
        write(fits, secondary_basis)
    end
    common.write_yaml(path, document)
end

@testset "offline HIL calibration frames adopt scalar and named figures" begin
    mktempdir() do directory
        (; path, basis) = modal_simulation_source(directory)
        configuration = PipeWireAORTC.InstrumentConfiguration
        calibration_frame! = PipeWireAORTC.InstrumentCalibration.calibration_frame!
        support = Bool[1 0; 1 1]
        primary(figure) = (basis[:, :, 1] .* figure[1] .+ basis[:, :, 2] .* figure[2]) .* support
        first = Float32[1, -2]
        second = Float32[-3, 4]

        scalar = configuration.prepare_system(path; calibration = true)
        @test_throws "first calibration frame must be flat" calibration_frame!(scalar, first)
        @test hil_boundary_status(scalar.boundary).frame_sequence == 0
        flat = calibration_frame!(scalar, zeros(Float32, 2))
        @test flat === hil_frame_buffer(scalar.boundary) && all(iszero, flat)
        for (sequence, figure) in enumerate((first, second))
            frame = calibration_frame!(scalar, figure)
            @test frame === flat && frame == primary(figure)
            status = hil_boundary_status(scalar.boundary)
            @test (status.frame_sequence, status.active_command_sequence) == (sequence + 1, sequence)
        end

        secondary_basis = -2 .* basis[:, :, 1:1]
        named_calibration_document!(path, secondary_basis)
        named = configuration.prepare_system(path; calibration = true)
        @test_throws "initial calibration frame must be flat" calibration_frame!(
            named, (command = zeros(Float32, 2), secondary = Float32[1]),
        )
        @test hil_boundary_status(named.boundary).frame_sequence == 0
        flat = calibration_frame!(named, (command = zeros(Float32, 2), secondary = Float32[0]))
        @test flat === hil_frame_buffer(named.boundary) && all(iszero, flat)
        for (sequence, figure, secondary) in ((1, first, 2f0), (2, second, -1f0))
            # Reverse the literal field order to prove the boundary adopts by name.
            frame = calibration_frame!(named, (secondary = [secondary], command = figure))
            expected = primary(figure) .+ secondary .* secondary_basis[:, :, 1] .* support
            @test frame === flat && frame == expected
            status = hil_boundary_status(named.boundary)
            @test (status.frame_sequence, status.active_command_sequence) == (sequence + 1, sequence)
        end
    end
end
end
