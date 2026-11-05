# Optional CPU selector: real linear numerical calibration, no core or service.
using Test, LinearAlgebra, PipeWireAORTC, PipeWireAO
using AdaptiveOpticsSim, AdaptiveOpticsSimPipeWireHIL, AdaptiveOpticsCalibration
using FilterGraphAlgorithms, FilterGraphIsland, FilterGraphPipeWire, JuliaFilterGraph

const E = PipeWireAORTC.InstrumentExport
const C = PipeWireAORTC.Common
const D = PipeWireAORTC.DeploymentConfiguration
const Calibration = PipeWireAORTC.InstrumentCalibration
const Implementation = Base.get_extension(PipeWireAORTC, :PipeWireAORTCCalibrationExt)
const PREFIX = String(PipeWireAO.LibPipeWire.PipeWireAO_jll.artifact_dir)
ENV["PIPEWIREAO_PREFIX"] = PREFIX
include("composition_documents.jl")

function optical_template(name)
    reference(path) = Dict("\$ref"=>path)
    node(name, label, config) =
        Dict("name"=>name, "type"=>"ndarray", "label"=>label, "config"=>config)
    dense = Dict(
        "input_count"=>4,
        "output_count"=>4,
        "initial_reconstructor"=>nothing,
        "input_schema"=>"test/modes/1",
        "output_schema"=>"test/modes/1",
        "reconstructor_schema"=>"test/matrix/1",
    )
    reconstruction = merge(dense, Dict("input_schema"=>"test/pixels/1"))
    nodes = [
        node(
            "pixels",
            "pixel-selection-f32",
            Dict(
                "image_size"=>[2, 3],
                "mask"=>reference("/calibration/pixel_selection_mask"),
                "input_schema"=>reference("/calibration/"*name*"/frame_schema"),
                "output_schema"=>"test/pixels/1",
            ),
        ),
        node("reconstruction", "dense-vector-reconstructor-f32", reconstruction),
        node("reference", "vector-offset-f32", Dict("extent"=>4, "schema"=>"test/modes/1")),
        node("projection", "dense-vector-reconstructor-f32", dense),
    ]
    link(output, input) = Dict("output"=>output, "input"=>input)
    port(name, endpoint) = Dict("name"=>name, "endpoint"=>endpoint)
    return Dict(
        "node.name"=>name*"-controller",
        "filter.graph"=>Dict(
            "nodes"=>nodes,
            "links"=>[
                link("pixels:selected-pixels", "reconstruction:ordered-input"),
                link("reconstruction:output", "reference:requested"),
                link("reference:output", "projection:ordered-input"),
            ],
            "inputs"=>[
                port("image", "pixels:image"),
                port(name*"-reconstructor", "reconstruction:reconstructor"),
                port(name*"-modal-reference", "reference:offset"),
                port("command-projection", "projection:reconstructor"),
            ],
            "outputs"=>[port("physical-offset", "projection:output")],
        ),
    )
end

@testset "measured optical contexts publish real typed graph inputs" begin
    response = Float32[1 0 0 0; 0 2 0 0; 0 0 3 0; 0 0 0 4; -1 -2 0 0; 0 0 -3 -4]
    observation = Float32[
        1 2 3 4 0 0;
        0 1 2 3 4 0;
        0 0 1 2 3 4;
        4 0 0 1 2 3;
        3 4 0 0 1 2;
        2 3 4 0 0 1
    ]
    surface = command -> reshape(response*command, 2, 3)
    observe =
        opd -> (
            llowfs = reshape(10.0f0 .+ observation*vec(opd), 2, 3),
            scc = reshape(12.0f0 .+ reverse(observation; dims = 1)*vec(opd), 2, 3),
        )
    mask = Bool[1 0 1; 0 1 1]
    calibration = Calibration.calibrate_optical(
        surface,
        observe,
        Matrix{Float32}(I, 4, 4);
        pupil_support = trues(2, 3),
        branch_modes = (llowfs = 1:2, scc = 3:4),
        pixel_masks = (llowfs = mask, scc = mask),
        poke_m = 0.01f0,
        tsvd_rtol = 1.0f-5,
        derivative_tolerance = 0.01,
        reconstruction_tolerance = 0.01,
    )
    @test calibration.report["status"] == "accepted"
    @test calibration.command_coordinates === Implementation.PhysicalCommandCoordinates()
    dimensions = Dict(
        "image_rows"=>2,
        "image_columns"=>3,
        "selected_pixel_count"=>4,
        "controller_command_count"=>4,
        "physical_command_count"=>4,
    )
    plan = (;
        rtc = (
            document = Dict("dimensions"=>dimensions),
            controls = Dict("deformable_mirrors"=>Dict()),
        ),
        frames = Dict(
            "llowfs"=>Dict("frame_schema"=>"test/llowfs/1"),
            "scc"=>Dict("frame_schema"=>"test/scc/1"),
        ),
        templates = (llowfs = optical_template("llowfs"), scc = optical_template("scc")),
        instrument = Dict("deformable_mirrors"=>Dict(), "wavefront_sensors"=>Dict()),
    )
    prepared = Implementation.optical_publication_graphs(plan, calibration)
    # Completion-shaped diagnostics cannot switch a physical calibration into
    # active VDM coordinates or make its absent active_vdm_count required.
    incidental = merge(calibration, (completion = Matrix{Float32}(I, 4, 4),))
    @test Implementation.optical_publication_graphs(plan, incidental) == prepared
    mktempdir() do directory
        report = Dict(
            "recipe"=>Dict("kind"=>"linear-test"),
            "source_prescription_identity"=>"test",
            "source_graph_sha256"=>repeat("a", 64),
        )
        Calibration.calibrate_optical(
            incidental,
            joinpath(directory, "physical");
            report,
            context = Dict(),
            concrete_graph = Dict("filter.graph"=>Dict("nodes"=>[])),
        )
        artifacts = Calibration.read_bundle(joinpath(directory, "physical")).artifacts
        @test haskey(artifacts, "physical-to-modes.fits")
        @test !haskey(artifacts, "vdm-to-modes.fits") &&
              !haskey(artifacts, "active-to-full.fits")
    end
    @test first(prepared.graphs.llowfs["filter.graph"]["nodes"])["config"]["mask"] ==
          Bool[1, 0, 1, 0, 1, 1]
    @test prepared.contexts.scc["scc"]["frame_schema"] == "test/scc/1"
    @test haskey(
        first(plan.templates.llowfs["filter.graph"]["nodes"])["config"]["mask"],
        "\$ref",
    )
    invalid = deepcopy(plan)
    invalid.rtc.document["dimensions"]["selected_pixel_count"] = 6
    @test_throws DimensionMismatch Implementation.optical_publication_graphs(
        invalid,
        calibration,
    )
    @test_throws ArgumentError Implementation.validate_optical_graphs(
        prepared.graphs,
        nothing,
        (:llowfs, :scc),
    )
    mktempdir() do directory
        report = merge(
            Dict(
                "recipe"=>Dict("kind"=>"linear-test"),
                "source_prescription_identity"=>"linear-test",
                "source_graph_sha256"=>repeat("a", 64),
            ),
            calibration.report,
        )
        result = (; calibration, report)
        output = Implementation.publish_optical_bundles(
            result,
            joinpath(directory, "accepted"),
            prepared.graphs,
            prepared.contexts,
        )
        @test keys(output.reports) == (:llowfs, :scc)
        bundle = Calibration.read_bundle(joinpath(output.directory, "llowfs"))
        @test Set(bundle.parameter_names) ==
              Set(["command-projection", "llowfs-reconstructor", "llowfs-modal-reference"])
        @test PipeWireAORTC.InstrumentConfiguration.calibration_context(
            bundle.context,
            joinpath(output.directory, "llowfs"),
        )["pixel_selection_mask"] == Bool[1, 0, 1, 0, 1, 1]
        @test bundle.report["held_out"]["accepted"]
        invalid_graphs = deepcopy(prepared.graphs)
        first(invalid_graphs.scc["filter.graph"]["nodes"])["label"] = "unsupported-optical-node"
        @test_throws JuliaFilterGraph.GraphConfigurationError Implementation.publish_optical_bundles(
            result,
            joinpath(directory, "unsupported"),
            invalid_graphs,
            prepared.contexts,
        )
        @test !ispath(joinpath(directory, "unsupported"))
        rejected = merge(
            calibration,
            (report = merge(calibration.report, Dict("status"=>"rejected")),),
        )
        @test_throws ArgumentError Implementation.publish_optical_bundles(
            (; calibration = rejected, report),
            joinpath(directory, "rejected"),
            prepared.graphs,
            prepared.contexts,
        )
        @test !ispath(joinpath(directory, "rejected"))
    end
end

@testset "optical publication validates both application seals before acquisition" begin
    mktempdir() do directory
        upstream = composition_fixture(
            joinpath(directory, "upstream"),
            "upstream",
            "simulator",
            "pupil",
        )
        optical = composition_fixture(
            joinpath(directory, "optical"),
            "optical",
            "simulator",
            "sensor",
        )
        write(joinpath(optical, "graph.conf"), "changed after sealing")
        @test_throws D.DeploymentError Calibration.calibrate_optical(
            upstream,
            optical,
            joinpath(directory, "output");
            prefix = PREFIX,
        )
        @test !ispath(joinpath(directory, "output"))
        write(joinpath(optical, "graph.conf"), "{}")
        E.seal!(optical)
        write(joinpath(upstream, "graph.conf"), "changed upstream after sealing")
        @test_throws D.DeploymentError Calibration.calibrate_optical(
            upstream,
            optical,
            joinpath(directory, "output");
            prefix = PREFIX,
        )
    end
    @test !any(id->id.name in ("CUDA", "AMDGPU"), keys(Base.loaded_modules))
end

@testset "CoG and pixel branches publish independent graphs with distinct masks" begin
    surface = command -> reshape(vcat(command, -sum(command), 0.0f0), 3, 4)
    mask = Bool[1 0 1; 1 1 0]
    observe = opd -> begin
        x, y = opd[1], opd[2]
        (; llowfs = Float32[1-x-y 100 1+x; 1+y 1 200], scc = 10.0f0 .+ opd)
    end
    calibration = Calibration.calibrate_optical(
        surface,
        observe,
        Matrix{Float32}(I, 10, 10);
        pupil_support = trues(3, 4),
        branch_modes = (llowfs = 1:2, scc = 3:10),
        pixel_masks = (llowfs = mask, scc = trues(3, 4)),
        centroid_measurements = (:llowfs,),
        poke_m = 0.01f0,
        tsvd_rtol = 1.0f-5,
        derivative_tolerance = 0.001,
        reconstruction_tolerance = 0.001,
    )
    # Identity completion is sufficient to exercise shared physical mappings:
    # they belong in the suffix bundle artifacts, not every branch's inputs.
    calibration = merge(
        calibration,
        (
            command_coordinates = Implementation.CompletedVDMCoordinates(),
            completion = Matrix{Float32}(I, 10, 10),
            physical_feedback_to_modes = calibration.physical_to_modes,
        ),
    )
    node(name, label, config) =
        Dict("name"=>name, "type"=>"ndarray", "label"=>label, "config"=>config)
    link(output, input) = Dict("output"=>output, "input"=>input)
    port(name, endpoint) = Dict("name"=>name, "endpoint"=>endpoint)
    reference(path) = Dict("\$ref"=>path)
    templates = map(("llowfs", "scc")) do name
        centroid = name == "llowfs"
        schema =
            centroid ? FilterGraphAlgorithms.CENTER_OF_GRAVITY_PIXELS_V1 : "test/pixels/1"
        nodes = Dict{String,Any}[node(
            "pixels",
            "pixel-selection-f32",
            Dict(
                "image_size"=>centroid ? [2, 3] : [3, 4],
                "mask"=>reference("/calibration/"*name*"/pixel_selection_mask"),
                "input_schema"=>"test/image/1",
                "output_schema"=>schema,
            ),
        )]
        links = Dict{String,String}[]
        inputs = [port("image", "pixels:image")]
        measured_endpoint = "pixels:selected-pixels"
        if centroid
            push!(
                nodes,
                node(
                    "centroid",
                    "center-of-gravity-f32",
                    Dict(
                        "pixel_count"=>4,
                        "initial_coordinates"=>[Float32[0, 0] for _ = 1:4],
                    ),
                ),
            )
            push!(links, link(measured_endpoint, "centroid:pixels"))
            measured_endpoint = "centroid:centroid-offset"
            push!(inputs, port("llowfs-coordinates", "centroid:coordinates"))
        end
        measured_schema =
            centroid ? FilterGraphAlgorithms.CENTER_OF_GRAVITY_OFFSET_V1 : schema
        push!(
            nodes,
            node(
                "reconstruction",
                "dense-vector-reconstructor-f32",
                Dict(
                    "input_count"=>centroid ? 2 : 12,
                    "output_count"=>10,
                    "initial_reconstructor"=>nothing,
                    "input_schema"=>measured_schema,
                    "output_schema"=>"test/modes/1",
                    "reconstructor_schema"=>"test/matrix/1",
                ),
            ),
        )
        push!(
            nodes,
            node(
                "reference",
                "vector-offset-f32",
                Dict("extent"=>10, "schema"=>"test/modes/1"),
            ),
        )
        push!(
            nodes,
            node(
                "projection",
                "dense-vector-reconstructor-f32",
                Dict(
                    "input_count"=>10,
                    "output_count"=>10,
                    "initial_reconstructor"=>nothing,
                    "input_schema"=>"test/modes/1",
                    "output_schema"=>"test/physical/1",
                    "reconstructor_schema"=>"test/matrix/1",
                ),
            ),
        )
        append!(
            links,
            [
                link(measured_endpoint, "reconstruction:ordered-input"),
                link("reconstruction:output", "reference:requested"),
                link("reference:output", "projection:ordered-input"),
            ],
        )
        append!(
            inputs,
            [
                port(name*"-reconstructor", "reconstruction:reconstructor"),
                port(name*"-modal-reference", "reference:offset"),
                port(
                    centroid ? "llowfs-command-projection" : "command-projection",
                    "projection:reconstructor",
                ),
            ],
        )
        Dict(
            "filter.graph"=>Dict(
                "nodes"=>nodes,
                "links"=>links,
                "inputs"=>inputs,
                "outputs"=>[
                    port("modes", "reference:output"),
                    port("physical-command", "projection:output"),
                ],
            ),
        )
    end
    dimensions = Dict(
        "image_rows"=>3,
        "image_columns"=>4,
        "selected_pixel_count"=>12,
        "controller_command_count"=>10,
        "physical_command_count"=>10,
        "active_vdm_count"=>10,
    )
    plan = (;
        rtc = (
            document = Dict("dimensions"=>dimensions),
            controls = Dict("deformable_mirrors"=>Dict()),
        ),
        frames = Dict(
            "llowfs"=>Dict("frame_schema"=>"test/image/1", "image_shape"=>[2, 3]),
            "scc"=>Dict("frame_schema"=>"test/image/1", "image_shape"=>[3, 4]),
        ),
        templates = (llowfs = templates[1], scc = templates[2]),
        instrument = Dict("deformable_mirrors"=>Dict(), "wavefront_sensors"=>Dict()),
    )
    prepared = Implementation.optical_publication_graphs(plan, calibration)
    @test calibration.command_coordinates === Implementation.CompletedVDMCoordinates()
    @test Implementation.optical_command_count(
        calibration.command_coordinates,
        Dict("physical_command_count"=>12, "active_vdm_count"=>10),
    ) == 10
    @test prepared.contexts.scc["llowfs"]["selected_pixel_count"] == 4
    @test prepared.contexts.llowfs["scc"]["selected_pixel_count"] == 12
    @test prepared.graphs.llowfs != prepared.graphs.scc
    invalid = deepcopy(prepared.graphs.llowfs)
    only(node for node in invalid["filter.graph"]["nodes"] if node["name"] == "centroid")["props"] =
        Dict("reference-centroid-x"=>1)
    @test_throws ArgumentError Implementation.validate_optical_centroid_graph(
        invalid,
        :llowfs,
        calibration.branches.llowfs,
    )
    for (input, output) in (
        ("reconstruction:ordered-input", "pixels:selected-pixels"),
        ("reference:requested", "centroid:centroid-offset"),
    )
        invalid = deepcopy(prepared.graphs.llowfs)
        only(link for link in invalid["filter.graph"]["links"] if link["input"] == input)["output"] =
            output
        @test_throws ArgumentError Implementation.validate_optical_centroid_graph(
            invalid,
            :llowfs,
            calibration.branches.llowfs,
        )
    end
    mktempdir() do directory
        report = merge(
            Dict(
                "recipe"=>Dict("kind"=>"linear-test"),
                "source_prescription_identity"=>"test",
                "source_graph_sha256"=>repeat("a", 64),
            ),
            calibration.report,
        )
        output = Implementation.publish_optical_bundles(
            (; calibration, report),
            joinpath(directory, "accepted"),
            prepared.graphs,
            prepared.contexts,
        )
        @test Set(keys(output.index["physical_projection"])) == Set([
            "command-projection",
            "vdm-to-modes",
            "active-to-full",
            "vdm-to-pdm",
            "physical-to-modes",
        ])
        without_feedback = merge(calibration, (physical_feedback_to_modes = nothing,))
        no_feedback = Implementation.publish_optical_bundles(
            (calibration = without_feedback, report = report),
            joinpath(directory, "without-feedback"),
            prepared.graphs,
            prepared.contexts,
        )
        @test Set(keys(no_feedback.index["physical_projection"])) ==
              Set(["command-projection", "vdm-to-modes", "active-to-full", "vdm-to-pdm"])
        @test !haskey(
            Calibration.read_bundle(joinpath(no_feedback.directory, "llowfs")).artifacts,
            "physical-to-modes.fits",
        )
        for name in (:llowfs, :scc)
            bundle_path = joinpath(output.directory, string(name))
            bundle = Calibration.read_bundle(bundle_path)
            expected = Set([
                name == :llowfs ? "llowfs-command-projection" : "command-projection",
                string(name)*"-reconstructor",
                string(name)*"-modal-reference",
            ])
            name == :llowfs && push!(expected, "llowfs-coordinates")
            @test Set(bundle.parameter_names) == expected
            @test haskey(bundle.artifacts, string(name)*"-feedback-selection.fits")
            @test haskey(bundle.artifacts, "active-to-full.fits")
            if name == :llowfs
                centroid = only(
                    node for node in prepared.graphs.llowfs["filter.graph"]["nodes"] if
                    node["name"] == "centroid"
                )
                @test centroid["props"]["reference-centroid-x"] ==
                      calibration.branches.llowfs.reference_centroid[1]
                @test centroid["props"]["reference-centroid-y"] ==
                      calibration.branches.llowfs.reference_centroid[2]
                source = PipeWireAORTC.Artifacts.FITSArtifact(
                    bundle.artifacts["llowfs-modal-reference.fits"],
                )
                @test all(
                    iszero,
                    PipeWireAORTC.Artifacts.prepare(source, Float32, (10,)).data,
                )
            end
            # Exercise the exact published graph and FITS bindings. Its modes
            # must equal measured-minus-reference, with X=column and Y=row.
            GraphOwner = PipeWireAORTC.GraphOwner
            entries = [
                Dict(
                    "port"=>parameter,
                    "path"=>joinpath(bundle_path, "artifacts", file),
                    "hdu"=>1,
                    "axes"=>endswith(parameter, "-modal-reference") ? [1] : [2, 1],
                ) for (parameter, file) in bundle.report["parameter_files"]
            ]
            bindings = joinpath(directory, string(name)*"-parameters.conf")
            C.write_json(bindings, Dict("parameters"=>entries))
            formats =
                GraphOwner.read_bindings(joinpath(bundle_path, "graph.conf"), bindings)
            options = FilterGraphIsland.parse_arguments([
                "--graph",
                joinpath(bundle_path, "graph.conf"),
                "--check",
                "--execution",
                "complete-frame",
            ])
            graph = FilterGraphIsland.prepare_service_graph(
                options;
                initial_parameters = _ -> collect(formats),
            )
            try
                branch = getproperty(calibration.branches, name)
                outputs =
                    (modes = zeros(Float32, 10), var"physical-command" = zeros(Float32, 10))
                @test all(
                    values(
                        JuliaFilterGraph.process!(
                            outputs,
                            graph,
                            (image = branch.reference,),
                        ),
                    ),
                )
                @test all(iszero, outputs.modes)
                coefficients = Float32[0.001, -0.002, zeros(8)...]
                image =
                    getproperty(observe(surface(calibration.projection*coefficients)), name)
                @test all(
                    values(JuliaFilterGraph.process!(outputs, graph, (image = image,))),
                )
                expected_modes =
                    branch.reconstructor*(
                        Implementation.optical_measurement(image, branch)-Implementation.optical_measurement(
                            branch.reference,
                            branch,
                        )
                    )
                if name == :llowfs
                    @test outputs.modes ≈ expected_modes rtol=10eps(Float32) atol=1e-9
                else
                    @test outputs.modes ≈ expected_modes atol=1e-6
                end
                @test outputs.var"physical-command" ≈ calibration.projection*expected_modes atol=1e-6
                name == :llowfs && @test outputs.modes[1:2] ≈ coefficients[1:2] atol=1e-6
            finally
                FilterGraphIsland.close_execution(graph)
            end
        end
    end
end

@testset "full-size optical masks use compact hashed contexts" begin
    surface =
        command -> reshape(Float32[command[1], -command[1], command[2], -command[2]], 2, 2)
    observe = opd -> begin
        llowfs = fill(10.0f0, 256, 320)
        scc = fill(10.0f0, 221, 221)
        for image in (llowfs, scc)
            image[1, 1] += opd[1]
            image[1, 2] += opd[3]
        end
        (; llowfs, scc)
    end
    llowfs_mask = falses(256, 320)
    llowfs_mask[:, 1:160] .= true
    masks = (llowfs = llowfs_mask, scc = trues(221, 221))
    calibration = Calibration.calibrate_optical(
        surface,
        observe,
        Matrix{Float32}(I, 2, 2);
        pupil_support = trues(2, 2),
        branch_modes = (llowfs = 1:1, scc = 2:2),
        pixel_masks = masks,
        poke_m = 0.01f0,
        tsvd_rtol = 1.0f-5,
    )
    context = Dict(
        string(name)=>Dict(
            "pixel_selection_mask"=>vec(permutedims(mask, (2, 1))),
            "selected_pixel_count"=>count(mask),
        ) for (name, mask) in pairs(masks)
    )
    mktempdir() do directory
        report = Dict(
            "recipe"=>Dict("kind"=>"linear-test"),
            "source_prescription_identity"=>"test",
            "source_graph_sha256"=>repeat("a", 64),
        )
        for branch in keys(masks)
            output = joinpath(directory, string(branch))
            Calibration.calibrate_optical(
                calibration,
                output;
                report,
                context,
                concrete_graph = Dict("filter.graph"=>Dict("nodes"=>[])),
                branch,
            )
            bundle = Calibration.read_bundle(output)
            @test filesize(joinpath(output, "context.yaml")) < 16*1024
            resolved = PipeWireAORTC.InstrumentConfiguration.calibration_context(
                bundle.context,
                output,
            )
            for (name, mask) in pairs(masks)
                binding = bundle.context[string(name)]["pixel_selection_mask"]
                @test binding["kind"] == "fits"
                @test binding["path"] == "artifacts/"*string(name)*"-pixel-mask.fits"
                @test binding["sha256"] ==
                      bundle.report["artifact_sha256"][string(name)*"-pixel-mask.fits"]
                @test resolved[string(name)]["pixel_selection_mask"] ==
                      vec(permutedims(mask, (2, 1)))
            end
        end
        @test context["llowfs"]["pixel_selection_mask"] isa AbstractVector
    end
end
