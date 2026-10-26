# Optional cold-contract and CPU-product checks; requires the JFG and AOS/HIL stacks.
using Test, Libdl
using PipeWireAORTC
using FilterGraphIsland, FilterGraphPipeWire, JuliaFilterGraph
using AdaptiveOpticsSim, AdaptiveOpticsSimPipeWireHIL
using AdaptiveOpticsSim.AlgorithmGraphs

const E = PipeWireAORTC.InstrumentExport
const C = PipeWireAORTC.Common
const D = PipeWireAORTC.DeploymentConfiguration
const AOS = Base.get_extension(PipeWireAORTC, :PipeWireAORTCAOSExt)
const Observation = AOS.OpticalObservation
completed_timing_bytes(timings) = @allocated AOS.completed_frame_timing(timings)
const PREFIX = get(ENV, "PIPEWIREAO_PREFIX", "/opt/pipewireao")
reference(pointer) = Dict("\$ref" => pointer)

@testset "session contracts come from the typed rectangular JFG boundary" begin
    mktempdir() do directory
        graph_path = joinpath(directory, "graph.conf")
        write(graph_path, """
            node.name = arbitrary-rectangular-science
            filter.graph = {
                nodes = [
                    { type = ndarray name = calibrate label = pixel-calibration-u16-f32
                      config = { image_size = [ 3 7 ]
                        initial_flat = null initial_background = null } }
                    { type = ndarray name = select label = pixel-selection-f32
                      config = { image_size = [ 3 7 ]
                        input_schema = pipewireao/calibrated-pixels-f32/1
                        output_schema = test.selected-pixels/1
                        mask = [ true true true true true true true
                                 false false false false false false false
                                 true true true true true true true ] } }
                ]
                links = [ { output = "calibrate:calibrated" input = "select:image" } ]
                inputs = [ "calibrate:raw" "calibrate:background" "calibrate:flat" "select:mask" ]
                outputs = [ "calibrate:calibrated" "select:selected-pixels" ]
            }
            """)
        # Artifact ownership is separate: even invalid FITS data is irrelevant
        # to inspecting the prepared boundary's defaults and parameter formats.
        write(joinpath(directory, "mask.fits"), "not a FITS file")
        C.write_json(joinpath(directory, "parameters.conf"), Dict("parameters" =>
            [Dict("port" => "mask", "path" => "mask.fits", "axes" => [2, 1])]))
        contracts = E.graph_port_contracts(graph_path)
        @test contracts["inputs"]["raw"] == Dict("shape" => [3, 7], "element-type" => "U16_LE")
        @test contracts["parameters"]["background"] == Dict("shape" => [3, 7], "element-type" => "F32_LE")
        @test contracts["parameters"]["mask"] == Dict("shape" => [3, 7], "element-type" => "BOOL8")
        @test contracts["outputs"]["calibrated"] == Dict("shape" => [3, 7], "element-type" => "F32_LE")
        @test contracts["outputs"]["selected-pixels"]["shape"] == [14]
        spec = Dict("session" => "session.conf", "core" => "core.conf")
        port = Dict("name" => "applied", "shape" => reference("/graphs/arbitrary-rectangular-science/outputs/selected-pixels/shape"),
            "element-type" => reference("/graphs/arbitrary-rectangular-science/outputs/selected-pixels/element-type"),
            "schema" => "test.applied-quantity/1", "layout" => "row-major", "rate" => "20/1")
        C.write_json(joinpath(directory, "session.conf"), Dict("queues" => [Dict("ports" => [port])]))
        C.write_json(joinpath(directory, "core.conf"), Dict("context.modules" => []))
        C.write_json(joinpath(directory, "instrument.json"), Dict("deformable_mirrors" => Dict(),
            "wavefront_sensors" => Dict()))
        declarations = [Dict("path" => "graph.conf")]
        E.prepare_session_configuration!(directory, spec, declarations, "instrument.json", PREFIX)
        resolved = D.decode(joinpath(directory, "session.conf"), PREFIX)["queues"][1]["ports"][1]
        @test resolved == merge(port, Dict("shape" => [14], "element-type" => "F32_LE"))
        @test !occursin("\$ref", read(joinpath(directory, "session.conf"), String))
        # Invalid port lookup leaves the complete authoring document untouched.
        port["shape"] = reference("/graphs/arbitrary-rectangular-science/outputs/missing/shape")
        C.write_json(joinpath(directory, "session.conf"), Dict("queues" => [Dict("ports" => [port])]))
        before = read(joinpath(directory, "session.conf"))
        @test_throws ArgumentError E.prepare_session_configuration!(directory, spec, declarations,
            "instrument.json", PREFIX)
        @test read(joinpath(directory, "session.conf")) == before
        # A second metadata preparation succeeds after the failure's cleanup.
        @test E.graph_port_contracts(graph_path) == contracts
    end
end

function observation_definition(sensor, resolution)
    schema = "test.observation.pupil-opd/1"
    atmosphere = pupil_opd_composition_node(:atmosphere; resolution,
        uncompensated_opd_schema=schema, surface_opd_schema=schema, pupil_opd_schema=schema)
    pupil = pupil_opd_composition_node(:pupil; resolution,
        uncompensated_opd_schema=schema, surface_opd_schema=schema, pupil_opd_schema=schema)
    return algorithm_graph((atmosphere, pupil, sensor);
        inputs=(graph_input(:uncorrected, :atmosphere => :uncompensated_opd, zeros(Float32, resolution, resolution)),
            graph_input(:flat_atmosphere, :atmosphere => :surface_opd, zeros(Float32, resolution, resolution)),
            graph_input(:surface, :pupil => :surface_opd, zeros(Float32, resolution, resolution))),
        links=(link(:atmosphere => :pupil_opd, :pupil => :uncompensated_opd),
            link(:pupil => :pupil_opd, :sensor => :opd)),
        outputs=(graph_output(:pupil_opd, :pupil => :pupil_opd),
            graph_output(:atmosphere_opd, :atmosphere => :pupil_opd),
            graph_output(:frame, :sensor => :photon_rate)))
end

@testset "cold SH and Pyramid observation contracts match actual CPU products" begin
    sensors = ((16, shack_hartmann_rate_node(:sensor; resolution=16,
            telescope_diameter_m=8.0, n_lenslets=4, n_pix_subap=4,
            pixel_scale_arcsec=0.1, source_wavelength_m=0.75e-6,
            source_photon_irradiance_m2_s=1.0, opd_schema="test.observation.pupil-opd/1",
            photon_rate_schema="test.observation.frame/1")),
        (8, pyramid_rate_node(:sensor; resolution=8, telescope_diameter_m=1.22,
            pupil_samples=4, modulation=2, modulation_points=4,
            n_pix_separation=2, n_pix_edge=1, source_wavelength_m=0.55e-6,
            source_photon_irradiance_m2_s=1.0, opd_schema="test.observation.pupil-opd/1",
            photon_rate_schema="test.observation.frame/1")))
    for (resolution, sensor) in sensors
        definition = observation_definition(sensor, resolution)
        contracts = Observation.port_contracts(definition)
        @test contracts["focal-image"]["shape"] == [2resolution, 2resolution]
        @test contracts["residual-wavefront"]["shape"] == [resolution, resolution]
        @test contracts["wavefront-rms"]["shape"] == [1, 2]
        graph = prepare_algorithm_graph(definition)
        observation = Observation.prepare(definition, graph)
        try
            sources = Observation.source_options(observation)
            @test length(sources) == 3
            for (index, product, values) in ((1, "focal-image", observation.values),
                    (2, "residual-wavefront", observation.wavefront), (3, "wavefront-rms", observation.rms))
                @test collect(sources[index].shape) == contracts[product]["shape"]
                @test E.wire_element_type(eltype(values)) == contracts[product]["element-type"]
            end
            @test_throws DimensionMismatch Observation.verify_product(zeros(Float32, resolution, resolution),
                contracts["focal-image"])
        finally
            Observation.close!(observation)
        end
        @test !haskey(Observation.port_contracts(definition.nodes; atmosphere=false), "wavefront-rms")
    end
    @test !any(id -> id.name in ("CUDA", "AMDGPU", "GPUCompiler"), keys(Base.loaded_modules))
    @test isempty(filter(path -> occursin(r"(?i)(libcuda|libcudart|libcublas|libcufft|libamdhip|libhsa-runtime)", path), Libdl.dllist()))
end

@testset "pyramid raw camera and named corrector session contracts remain distinct" begin
    mktempdir() do directory
        shape = [8, 12]
        pixel = Dict("type" => "ndarray", "name" => "pixels", "label" => "pixel-calibration-u16-f32",
            "config" => Dict("image_size" => shape, "initial_flat" => nothing, "initial_background" => nothing))
        pyramid = Dict("type" => "ndarray", "name" => "pyramid", "label" => "pyramid-pupil-image-f32",
            "config" => Dict("image_size" => shape, "pupil_size" => [2, 3],
                "pupil_origins" => [[1, 1], [5, 1], [1, 8], [5, 8]], "pupil_mask" => fill(true, 6)))
        counts = (woofer=97, tweeter=2304, tiptilt=2)
        correctors = [Dict("type" => "ndarray", "name" => string(name), "label" => "vector-conditioning-f32",
            "config" => Dict("count" => counts[name], "requested_schema" => "test.$name/1",
                "demanded_schema" => "test.$name/1", "feedback_schema" => "test.$name.feedback/1",
                "command_limits" => [-1, 1], "slew_limit" => nothing, "initial_current" => nothing,
                "quantization_origin" => nothing, "quantization_step" => nothing, "dither_seed" => nothing))
            for name in keys(counts)]
        inputs = [Dict("name" => "raw", "endpoint" => "pixels:raw");
            [Dict("name" => string(name) * "-request", "endpoint" => string(name) * ":requested") for name in keys(counts)]]
        outputs = [Dict("name" => string(name), "endpoint" => string(name) * ":demanded") for name in keys(counts)]
        push!(outputs, Dict("name" => "mean-pupil-intensity", "endpoint" => "pyramid:mean-pupil-intensity"))
        declaration = Dict("node.name" => "named-pyramid-science", "filter.graph" => Dict(
            "nodes" => [pixel, pyramid, correctors...], "inputs" => inputs, "outputs" => outputs,
            "links" => [Dict("output" => "pixels:calibrated", "input" => "pyramid:image")]))
        graph = joinpath(directory, "graph.conf")
        PipeWireAORTC.ScienceExport.write_spa_config(graph, declaration)
        contracts = E.graph_port_contracts(graph)
        @test contracts["inputs"]["raw"] == Dict("shape" => shape, "element-type" => "U16_LE")
        @test contracts["outputs"]["mean-pupil-intensity"]["element-type"] == "F32_LE"
        queues = [Dict("name" => string(name), "shape" => reference("/graphs/named-pyramid-science/outputs/$name/shape"),
            "element-type" => reference("/graphs/named-pyramid-science/outputs/$name/element-type")) for name in keys(counts)]
        C.write_json(joinpath(directory, "session.conf"), Dict("queues" => queues))
        C.write_json(joinpath(directory, "core.conf"), Dict())
        C.write_json(joinpath(directory, "instrument.json"), Dict("deformable_mirrors" => Dict(),
            "wavefront_sensors" => Dict("pyramid" => Dict("layout" => Dict("kind" => "pyramid", "detector_shape" => shape)))))
        E.prepare_session_configuration!(directory, Dict("session" => "session.conf", "core" => "core.conf"),
            [Dict("path" => "graph.conf")], "instrument.json", PREFIX)
        resolved = D.decode(joinpath(directory, "session.conf"), PREFIX)["queues"]
        @test [row["shape"] for row in resolved] == [[97], [2304], [2]]
        @test all(row["element-type"] == "F32_LE" for row in resolved)
        @test !occursin("\$ref", read(joinpath(directory, "session.conf"), String))
    end
end

@testset "named simulator warmup and diagnostics use every command" begin
    extension = Base.get_extension(PipeWireAORTC, :PipeWireAORTCAOSExt)
    commands = (; tweeter=fill(1.0f0, 5), woofer=fill(2.0f0, 3), tiptilt=fill(3.0f0, 2))
    @test isnothing(extension.validate_command_buffers(commands, (; woofer=3, tweeter=5, tiptilt=2)))
    @test_throws DimensionMismatch extension.validate_command_buffers(commands, (; woofer=3, tweeter=5, tiptilt=3))
    @test_throws ArgumentError extension.validate_command_buffers(commands, (; woofer=3, tweeter=5))
    extension.zero_command_buffers!(commands)
    @test all(command -> all(iszero, command), values(commands))
    timing = AdaptiveOpticsSimPipeWireHIL.PipeWireFrameCommandTiming
    timings = (; woofer=timing(UInt64(2), Int64(100), Int64(110)),
        tweeter=timing(UInt64(2), Int64(100), Int64(135)), tiptilt=timing(UInt64(2), Int64(100), Int64(120)))
    completed = extension.completed_frame_timing(timings)
    @test completed.sequence == 2
    @test completed.source_published_nanoseconds == 100
    @test completed.command_received_nanoseconds == 135
    completed_timing_bytes(timings) # warm the concrete successful call and measurement
    @test completed_timing_bytes(timings) == 0
    @test_throws ErrorException extension.completed_frame_timing(merge(timings,
        (; woofer=timing(UInt64(3), Int64(100), Int64(110)))))
    @test extension.applied_command_names((; woofer="woofer", tweeter="tweeter", tiptilt="tiptilt"), true) ==
        (; woofer="woofer-applied", tweeter="tweeter-applied", tiptilt="tiptilt-applied")
    @test extension.applied_command_names("command", true) == "simulator-applied-command"
    @test extension.applied_command_names((; woofer="woofer"), false) === nothing
end

@testset "explicit science imaging keeps guide fallback and composed OPD direction" begin
    Optics = AdaptiveOpticsSim.Optics
    source = Dict{String,Any}("source_band" => "R", "source_magnitude" => 2.0,
        "source_wavelength_m" => 0.8e-6, "source_separation_arcsec" => 0.0, "source_position_angle_deg" => 0.0)
    document = Dict("sources" => Dict("science" => source), "imaging" => Dict("source" => "science", "zero_padding" => 2))
    sensor = shack_hartmann_rate_node(:sensor; resolution=16, telescope_diameter_m=8.0,
        n_lenslets=4, n_pix_subap=4, pixel_scale_arcsec=0.1,
        source_band=:R, source_magnitude=2.0, source_wavelength_m=0.8e-6,
        opd_schema="test.observation.pupil-opd/1", photon_rate_schema="test.observation.frame/1")
    definition = observation_definition(sensor, 16)
    graph = prepare_algorithm_graph(definition)
    imaging = Observation.imaging_configuration((; document))
    @test Observation.imaging_configuration((;document=Dict())).source === nothing
    @test Observation.owner_imaging_configuration((;version=1)) == Observation.default_imaging()
    function image(imaging)
        observation = Observation.prepare(definition, graph; imaging)
        try
            fill!(Observation.snapshot_values(observation.snapshot), 0)
            fill!(Observation.snapshot_values(observation.atmosphere_snapshot), 0)
            Observation.form_products!(observation)
            output = Optics.direct_imaging_output(observation.imaging)
            return copy(observation.values), output.metadata
        finally
            Observation.close!(observation)
        end
    end
    fallback, fallback_metadata = image(Observation.default_imaging())
    source["source_position_angle_deg"] = 123.0 # On-axis position angle does not alter direction.
    imaging = Observation.imaging_configuration((; document))
    explicit, metadata = image(imaging)
    @test explicit == fallback
    @test metadata == fallback_metadata
    source["source_wavelength_m"] = 1.65e-6
    source["source_magnitude"] = 3.0
    document["imaging"]["zero_padding"] = 3
    science = Observation.imaging_configuration((; document))
    values, metadata = image(science)
    @test size(values) == (48, 48)
    @test Observation.port_contracts(definition; imaging=science)["focal-image"]["shape"] == [48, 48]
    @test metadata.spectral.wavelength_m == Float32(1.65e-6)
    @test metadata.normalization isa Optics.PhotonRateNormalization
    @test sum(values) / sum(fallback) ≈ 10.0^(-0.4) rtol=2e-6
    @test metadata.sampling != fallback_metadata.sampling
    source["source_separation_arcsec"] = 1.0
    mismatched = Observation.imaging_configuration((; document))
    @test_throws ArgumentError Observation.port_contracts(definition; imaging=mismatched)
    @test_throws ArgumentError Observation.prepare(definition, graph; imaging=mismatched)
    positive = Optics.Source(band=:R, separation_arcsec=2, position_angle_deg=210, T=Float32)
    signed = Optics.Source(band=:R, separation_arcsec=-2, position_angle_deg=30, T=Float32)
    periodic = Optics.Source(band=:R, separation_arcsec=-2, position_angle_deg=390, T=Float32)
    @test Observation.imaging_source(signed, (;source=positive)) === signed
    @test Observation.imaging_source(periodic, (;source=signed)) === periodic
    @test !any(id -> id.name in ("CUDA", "AMDGPU"), keys(Base.loaded_modules))
end
