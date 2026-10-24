# Optional cold-contract and CPU-product checks; requires the JFG and AOS/HIL stacks.
using Test, Libdl
using PipeWireAORTC
using FilterGraphIsland, FilterGraphPipeWire, JuliaFilterGraph
using AdaptiveOpticsSim, AdaptiveOpticsSimPipeWireHIL
using AdaptiveOpticsSim.AlgorithmGraphs

const E = PipeWireAORTC.InstrumentExport
const C = PipeWireAORTC.Common
const D = PipeWireAORTC.DeploymentConfiguration
const Observation = Base.get_extension(PipeWireAORTC, :PipeWireAORTCAOSExt).OpticalObservation
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
