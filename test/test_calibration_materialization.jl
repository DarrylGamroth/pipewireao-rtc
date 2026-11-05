using Test, PipeWireAORTC, PipeWireAO
Base.include(@__MODULE__, joinpath(@__DIR__, "external_pupil_owner_documents.jl"))
const E = PipeWireAORTC.InstrumentExport
const C = PipeWireAORTC.Common
const D = PipeWireAORTC.DeploymentConfiguration
const Calibration = PipeWireAORTC.InstrumentCalibration
const PREFIX = PipeWireAO.LibPipeWire.PipeWireAO_jll.artifact_dir

@testset "accepted branch calibration materialization preserves authored recipe" begin
    for (llowfs_shape, scc_shape) in (((2, 2), (2, 2)), ((256, 320), (221, 221)))
        mktempdir() do temporary
            source = joinpath(temporary, "source")
            mkpath(source)
            fixture = external_pupil_owner_documents(source)
            recipe = Dict(
                "kind" => "relative-intensity-optical",
                "optical_simulation" => "simulation/definition.yaml",
            )
            mkpath(joinpath(source, "calibration"))
            C.write_yaml(joinpath(source, "calibration/optical.yaml"), recipe)
            graphs = Dict(name => "rtc/" * name * ".conf" for name in ("llowfs", "scc"))
            graph = Dict("filter.graph" => Dict("nodes" => []))
            for path in values(graphs)
                C.write_json(joinpath(source, path), graph)
            end
            entry(path) =
                Dict("path" => path, "sha256" => C.sha256_file(joinpath(source, path)))
            C.write_yaml(
                joinpath(source, "provenance.yaml"),
                Dict(
                    "sources" => [entry("instrument.yaml")],
                    "graphs" => [],
                    "execution" => entry("simulation/definition.yaml"),
                ),
            )
            built = joinpath(temporary, "built")
            cp(source, built)
            for path in ("session.conf", "core.conf", "client.conf")
                C.write_json(joinpath(built, path), Dict())
            end
            placement = Dict(
                role => Dict(
                    "cpus" => [2],
                    "leader-cpu" => 2,
                    "rt-priority" => 0,
                    "threads" => [],
                    "locked-bytes" => 0,
                ) for role in ("core", "rtc")
            )
            C.write_json(
                joinpath(built, "deployment.conf"),
                Dict(
                    "version" => 1,
                    "name" => "calibration-fixture",
                    "session" => "session.conf",
                    "core" => "core.conf",
                    "client" => Dict(role => "client.conf" for role in keys(placement)),
                    "placement" => placement,
                    "owners" => [],
                    "environment" => Dict(),
                    "artifacts" => Dict(),
                    "cpu-latency-us" => nothing,
                ),
            )
            E.seal!(built)
            results = joinpath(temporary, "results")
            mkpath(results)
            identity = "sha256:" * repeat("c", 64)
            reports = Dict{String,Any}()
            centroid_results = joinpath(temporary, "centroid-results")
            centroid_graph = Dict(
                "filter.graph" => Dict(
                    "nodes" => [
                        Dict(
                            "name" => "centroid",
                            "type" => "ndarray",
                            "label" => "center-of-gravity-f32",
                            "config" => Dict(
                                "pixel_count" => 4,
                                "initial_coordinates" => [
                                    [1.0, 1.0],
                                    [2.0, 1.0],
                                    [1.0, 2.0],
                                    [2.0, 2.0],
                                ],
                            ),
                        ),
                    ],
                    "inputs" => [
                        Dict("name" => "pixels", "endpoint" => "centroid:pixels"),
                        Dict(
                            "name" => "llowfs-coordinates",
                            "endpoint" => "centroid:coordinates",
                        ),
                    ],
                    "outputs" => [
                        Dict(
                            "name" => "centroid",
                            "endpoint" => "centroid:centroid-offset",
                        ),
                    ],
                ),
            )
            masks = Dict("llowfs" => falses(llowfs_shape), "scc" => falses(scc_shape))
            masks["llowfs"][1:2, 1:2] .= true
            masks["scc"][1, 1:2] .= true
            masks["scc"][2, 1] = true
            mask_bindings = Dict{String,Any}()
            for (name, mask) in masks
                path = joinpath(temporary, name * "-pixel-mask.fits")
                Calibration.write_fits(path, mask)
                mask_bindings[name] = Dict(
                    "kind" => "fits",
                    "path" => "artifacts/" * name * "-pixel-mask.fits",
                    "sha256" => C.sha256_file(path),
                    "hdu" => 1,
                    "axes" => [2, 1],
                    "shape" => collect(size(mask)),
                    "type" => "Bool",
                    "storage_order" => "row-major",
                )
            end
            for name in keys(graphs)
                mask = masks[name]
                diagnostics = Dict(
                    "selection-mask" => mask,
                    "physical-to-modes" => ones(Float32, 2, 2),
                    "llowfs-pixel-mask" => masks["llowfs"],
                    "scc-pixel-mask" => masks["scc"],
                )
                maskpath = joinpath(temporary, name * "-mask.fits")
                Calibration.write_fits(maskpath, mask)
                context = Dict(
                    "pixel_selection_mask" => Dict(
                        "kind" => "fits",
                        "path" => "artifacts/selection-mask.fits",
                        "sha256" => C.sha256_file(maskpath),
                        "hdu" => 1,
                        "axes" => [2, 1],
                        "shape" => collect(size(mask)),
                        "type" => "Bool",
                        "storage_order" => "row-major",
                    ),
                )
                context["llowfs"] = Dict(
                    "pixel_selection_mask" => deepcopy(mask_bindings["llowfs"]),
                    "selected_pixel_count" => 4,
                )
                context["scc"] = Dict(
                    "pixel_selection_mask" => deepcopy(mask_bindings["scc"]),
                    "selected_pixel_count" => 3,
                )
                if name == "scc"
                    # The same logical mask may use a different valid artifact path.
                    context["scc"]["pixel_selection_mask"]["path"] = "artifacts/selection-mask.fits"
                    llowfs_shape == (2, 2) && (
                        context["llowfs"]["pixel_selection_mask"] = vec(
                            permutedims(masks["llowfs"], (2, 1))
                        )
                    )
                end
                report = Dict(
                    "recipe" => recipe,
                    "recipe_sha256" =>
                        C.sha256_file(joinpath(built, "calibration/optical.yaml")),
                    "source_prescription_identity" =>
                        fixture.document["prescription_identity"],
                    "source_graph_sha256" =>
                        C.sha256_file(joinpath(built, "simulation/definition.yaml")),
                    "status" => "accepted",
                    "built_application_calibration" => true,
                    "application_accepted" => false,
                    "deployable" => true,
                    "diagnostic" => false,
                    "command_count" => 2,
                    "held_out" => Dict("accepted" => true),
                    "calibration_identity" => identity,
                    "branch" => name,
                    "branches" => Dict(name => Dict("accepted" => true)),
                )
                reports[name] = Calibration.write_bundle(
                    joinpath(results, name),
                    report,
                    context,
                    graph,
                    Dict("command-projection" => ones(Float32, 2, 2));
                    diagnostics,
                )
                @test filesize(joinpath(results, name, "context.yaml")) < 16 * 1024
                invalid_hash = deepcopy(context)
                invalid_hash["scc"]["pixel_selection_mask"]["sha256"] = repeat("f", 64)
                @test_throws ArgumentError Calibration.write_bundle(
                    joinpath(temporary, name * "-invalid-nested-hash"),
                    report,
                    invalid_hash,
                    graph,
                    Dict("command-projection" => ones(Float32, 2, 2));
                    diagnostics,
                )
                invalid_path = deepcopy(context)
                invalid_path["scc"]["pixel_selection_mask"]["path"] = "artifacts/physical-to-modes.fits"
                @test_throws ArgumentError Calibration.write_bundle(
                    joinpath(temporary, name * "-invalid-nested-path"),
                    report,
                    invalid_path,
                    graph,
                    Dict("command-projection" => ones(Float32, 2, 2));
                    diagnostics,
                )
                centroid_context = deepcopy(context)
                centroid_context["llowfs"]["reference_centroid"] = [1.25, 1.5]
                calibrated_graph =
                    name == "llowfs" ?
                    E.calibrated_centroid_references(centroid_graph, centroid_context) :
                    graph
                Calibration.write_bundle(
                    joinpath(centroid_results, name),
                    report,
                    centroid_context,
                    calibrated_graph,
                    Dict("command-projection" => ones(Float32, 2, 2));
                    diagnostics,
                )
                if name == "scc"
                    inconsistent = deepcopy(context)
                    inconsistent["scc"]["selected_pixel_count"] = 4
                    Calibration.write_bundle(
                        joinpath(temporary, "inconsistent", name),
                        report,
                        inconsistent,
                        graph,
                        Dict("command-projection" => ones(Float32, 2, 2));
                        diagnostics,
                    )
                end
            end
            shared = Dict(
                name => Dict(
                    "path" => "llowfs/artifacts/" * name * ".fits",
                    "sha256" => reports["llowfs"]["artifact_sha256"][name*".fits"],
                ) for name in ("command-projection", "physical-to-modes")
            )
            C.write_yaml(
                joinpath(results, "calibration.yaml"),
                Dict(
                    "version" => 1,
                    "kind" => "optical-calibration-index",
                    "calibration_identity" => identity,
                    "physical_projection" => shared,
                    "branches" => Dict(
                        name => Dict(
                            "path" => name,
                            "result_sha256" => C.sha256_file(
                                joinpath(results, name, "result.yaml")
                            ),
                        ) for name in keys(graphs)
                    ),
                ),
            )
            recipehash = C.sha256_file(joinpath(source, "calibration/optical.yaml"))
            options = (; graphs, prefix = PREFIX, provenance = "provenance.yaml")
            centroid_source = joinpath(temporary, "centroid-source")
            cp(source, centroid_source)
            C.write_json(joinpath(centroid_source, graphs["llowfs"]), centroid_graph)
            centroid_authored = read(joinpath(centroid_source, graphs["llowfs"]))
            centroid_index = C.read_yaml(joinpath(results, "calibration.yaml"))
            for name in keys(graphs)
                centroid_index["branches"][name]["result_sha256"] = C.sha256_file(
                    joinpath(centroid_results, name, "result.yaml")
                )
            end
            C.write_yaml(joinpath(centroid_results, "calibration.yaml"), centroid_index)
            centroid_output = E.materialize_calibration(
                centroid_source, built, centroid_results; options...
            )
            frozen_centroid = D.decode(
                joinpath(centroid_output, "llowfs/graph.conf"), PREFIX
            )
            @test only(frozen_centroid["filter.graph"]["nodes"])["props"] ==
                Dict("reference-centroid-x" => 1.25, "reference-centroid-y" => 1.5)
            @test read(joinpath(centroid_source, graphs["llowfs"])) == centroid_authored
            centroid_rebuilt = joinpath(temporary, "centroid-rebuilt")
            cp(centroid_source, centroid_rebuilt)
            centroid_selected = joinpath(centroid_rebuilt, "generated/calibration")
            centroid_frozen = read(joinpath(centroid_selected, "llowfs/graph.conf"))
            centroid_context = PipeWireAORTC.InstrumentConfiguration.calibration_context(
                C.read_yaml(joinpath(centroid_selected, "context.yaml")), centroid_selected
            )
            @test E.prepare_graph_configurations!(
                centroid_rebuilt,
                [Dict("path" => path) for path in values(graphs)],
                "instrument.json",
                PREFIX;
                configuration = "generated/calibration/rtc.yaml",
                calibration = centroid_context,
            ) === nothing
            executed_centroid = D.decode(
                joinpath(centroid_rebuilt, graphs["llowfs"]), PREFIX
            )
            @test only(executed_centroid["filter.graph"]["nodes"])["props"] ==
                only(frozen_centroid["filter.graph"]["nodes"])["props"]
            @test read(joinpath(centroid_selected, "llowfs/graph.conf")) == centroid_frozen
            @test read(joinpath(centroid_source, graphs["llowfs"])) == centroid_authored
            # Re-sign an otherwise valid bundle through the standard writer. Its
            # branch selection must still agree with its measured root FITS mask.
            inconsistent = joinpath(temporary, "inconsistent")
            cp(joinpath(results, "llowfs"), joinpath(inconsistent, "llowfs"))
            inconsistent_index = C.read_yaml(joinpath(results, "calibration.yaml"))
            inconsistent_index["branches"]["scc"]["result_sha256"] = C.sha256_file(
                joinpath(inconsistent, "scc/result.yaml")
            )
            C.write_yaml(joinpath(inconsistent, "calibration.yaml"), inconsistent_index)
            @test_throws ArgumentError E.materialize_calibration(
                source, built, inconsistent; options...
            )
            # Rejected numerical evidence must not create a generated selection.
            invalid = joinpath(temporary, "invalid")
            cp(results, invalid)
            write(joinpath(invalid, "llowfs/result.yaml"), "status: rejected\n")
            @test_throws ArgumentError E.materialize_calibration(
                source, built, invalid; options...
            )
            @test !ispath(joinpath(source, "generated/calibration"))
            rejected = joinpath(temporary, "rejected")
            cp(results, rejected)
            rejected_report = C.read_yaml(joinpath(rejected, "llowfs/result.yaml"))
            rejected_report["status"] = "rejected"
            C.write_yaml(joinpath(rejected, "llowfs/result.yaml"), rejected_report)
            rejected_index = C.read_yaml(joinpath(rejected, "calibration.yaml"))
            rejected_index["branches"]["llowfs"]["result_sha256"] = C.sha256_file(
                joinpath(rejected, "llowfs/result.yaml")
            )
            C.write_yaml(joinpath(rejected, "calibration.yaml"), rejected_index)
            @test_throws ArgumentError E.materialize_calibration(
                source, built, rejected; options...
            )
            @test !ispath(joinpath(source, "generated/calibration"))
            authored_bytes = read(joinpath(source, "rtc/configuration.yaml"))
            output = E.materialize_calibration(source, built, results; options...)
            @test C.sha256_file(joinpath(source, "calibration/optical.yaml")) == recipehash
            @test read(joinpath(source, "rtc/configuration.yaml")) == authored_bytes
            selected_rtc = joinpath(output, "rtc.yaml")
            @test C.read_yaml(selected_rtc)["calibration_identity"] == identity
            @test C.read_yaml(selected_rtc)["calibration"] ==
                "generated/calibration/context.yaml"
            @test C.read_yaml(selected_rtc)["instrument"] == "../../instrument.yaml"
            @test C.read_yaml(joinpath(output, "context.yaml"))["pixel_selection_mask"]["path"] ==
                "llowfs/artifacts/selection-mask.fits"
            @test C.sha256_file(joinpath(output, "scc/result.yaml")) ==
                C.sha256_file(joinpath(results, "scc/result.yaml"))
            @test C.read_yaml(joinpath(output, "selection.yaml"))["application_accepted"] ===
                false
            zero = C.read_yaml(joinpath(output, "selection.yaml"))["zero_command"]
            @test zero["shape"] == [2] &&
                zero["sha256"] == C.sha256_file(joinpath(output, zero["path"]))
            @test zero["units"] == "m OPD"
            PipeWireAORTC.Artifacts.FITSIO.FITS(joinpath(output, zero["path"]), "r") do fits
                @test PipeWireAORTC.Artifacts.FITSIO.read_header(fits[1])["BUNIT"] ==
                    "m OPD"
            end
            @test PipeWireAORTC.Artifacts.prepare(
                PipeWireAORTC.Artifacts.FITSArtifact(joinpath(output, zero["path"])),
                Float32,
                (2,),
            ).data == zeros(Float32, 2)
            @test PipeWireAORTC.InstrumentConfiguration.load_rtc(selected_rtc).calibration["pixel_selection_mask"] ==
                vec(permutedims(masks["llowfs"], (2, 1)))
            selected_context = C.read_yaml(joinpath(output, "context.yaml"))
            @test selected_context["llowfs"]["selected_pixel_count"] == 4
            @test selected_context["scc"]["pixel_selection_mask"]["path"] ==
                "llowfs/artifacts/scc-pixel-mask.fits"
            @test filesize(joinpath(output, "context.yaml")) < 16 * 1024
            resolved = PipeWireAORTC.InstrumentConfiguration.calibration_context(
                selected_context, output
            )
            for (name, mask) in masks
                @test resolved[name]["pixel_selection_mask"] ==
                    vec(permutedims(mask, (2, 1)))
                @test Calibration.read_bundle(joinpath(output, name)).report ==
                    Calibration.read_bundle(joinpath(results, name)).report
            end
            invalid_hash = deepcopy(selected_context)
            invalid_hash["scc"]["pixel_selection_mask"]["sha256"] = repeat("f", 64)
            @test_throws ArgumentError PipeWireAORTC.InstrumentConfiguration.calibration_context(
                invalid_hash, output
            )
            invalid_path = deepcopy(selected_context)
            invalid_path["scc"]["pixel_selection_mask"]["path"] = "llowfs/artifacts/physical-to-modes.fits"
            @test_throws ArgumentError PipeWireAORTC.InstrumentConfiguration.calibration_context(
                invalid_path, output
            )
            selected_configuration = C.read_yaml(joinpath(output, "selection.yaml"))["rtc_configuration"]
            @test selected_configuration ==
                Dict("path" => "rtc.yaml", "sha256" => C.sha256_file(selected_rtc))
            # The existing exporter selects this generated configuration without
            # changing the authored optical-calibration configuration.
            rebuilt = joinpath(temporary, "rebuilt")
            cp(source, rebuilt)
            selected_path = "generated/calibration/rtc.yaml"
            IC = PipeWireAORTC.InstrumentConfiguration
            @test C.read_json(
                IC.prepare_publication(rebuilt; configuration = selected_path)
            )["calibration_identity"] == identity
            IC.prepare_simulation_configuration!(rebuilt; configuration = selected_path)
            execution = D.decode(joinpath(rebuilt, "simulation.conf"), PREFIX)
            @test execution["rtc_configuration"] == selected_path &&
                execution["calibration_identity"] == identity
            @test read(joinpath(rebuilt, "rtc/configuration.yaml")) == authored_bytes
            # The ordinary build stage checks frozen bundles again, even when the
            # original selection predates output-export receipts.
            declarations = [Dict("path" => path) for path in values(graphs)]
            frozen_bytes = Dict(
                name => read(joinpath(output, name, "graph.conf")) for name in keys(graphs)
            )
            E.prepare_graph_configurations!(
                source,
                declarations,
                "instrument.json",
                PREFIX;
                configuration = "generated/calibration/rtc.yaml",
            )
            proof = C.read_yaml(joinpath(output, "graph-exports.yaml"))
            @test proof["application_accepted"] === false
            for (name, path) in graphs
                @test proof["graphs"][name]["executed_graph_sha256"] ==
                    C.sha256_file(joinpath(source, path))
                @test proof["graphs"][name]["calibrated_graph_sha256"] ==
                    C.sha256_file(joinpath(output, name, "graph.conf"))
                @test isempty(proof["graphs"][name]["added_outputs"])
                @test read(joinpath(output, name, "graph.conf")) == frozen_bytes[name]
            end
            @test_throws ArgumentError E.prepare_graph_configurations!(
                source,
                declarations[1:1],
                "instrument.json",
                PREFIX;
                configuration = "generated/calibration/rtc.yaml",
            )
            C.write_json(joinpath(source, "extra.conf"), graph)
            @test_throws ArgumentError E.prepare_graph_configurations!(
                source,
                vcat(declarations, [Dict("path" => "extra.conf")]),
                "instrument.json",
                PREFIX;
                configuration = "generated/calibration/rtc.yaml",
            )
            firstpath = joinpath(source, first(values(graphs)))
            before = read(firstpath)
            changed = deepcopy(graph)
            changed["filter.graph"]["nodes"] = [Dict("name" => "changed")]
            C.write_json(firstpath, changed)
            @test_throws ArgumentError E.prepare_graph_configurations!(
                source,
                declarations,
                "instrument.json",
                PREFIX;
                configuration = "generated/calibration/rtc.yaml",
            )
            @test D.decode(firstpath, PREFIX) == changed
            write(firstpath, before)
            selectionpath = joinpath(output, "selection.yaml")
            selectionbytes = read(selectionpath)
            selection = C.read_yaml(selectionpath)
            firstbranch = first(keys(graphs))
            selection["graphs"][firstbranch] =
                "generated/calibration/" * firstbranch * "/graph.conf"
            C.write_yaml(selectionpath, selection)
            @test_throws ArgumentError E.prepare_graph_configurations!(
                source,
                declarations,
                "instrument.json",
                PREFIX;
                configuration = "generated/calibration/rtc.yaml",
            )
            @test read(joinpath(output, firstbranch, "graph.conf")) ==
                frozen_bytes[firstbranch]
            write(selectionpath, selectionbytes)
            rm(selectionpath)
            @test_throws ArgumentError E.prepare_graph_configurations!(
                source,
                declarations,
                "instrument.json",
                PREFIX;
                configuration = "generated/calibration/rtc.yaml",
            )
            write(selectionpath, selectionbytes)
            bundlegraph = joinpath(output, first(keys(graphs)), "graph.conf")
            write(bundlegraph, "tampered\n")
            @test_throws ArgumentError E.prepare_graph_configurations!(
                source,
                declarations,
                "instrument.json",
                PREFIX;
                configuration = "generated/calibration/rtc.yaml",
            )
            @test_throws ArgumentError E.materialize_calibration(
                source, built, results; options...
            )
        end
    end
end

@testset "localized mirror identity preserves exact physical data" begin
    mktempdir() do root
        source = joinpath(root, "source")
        built = joinpath(root, "built")
        mkpath(source)
        mkpath(joinpath(root, "mirrors"))
        mkpath(joinpath(built, "mirrors"))
        write(joinpath(root, "mirrors", "dm.yaml"), "model: measured\n")
        cp(joinpath(root, "mirrors", "dm.yaml"), joinpath(built, "mirrors", "dm.yaml"))
        instrument = Dict(
            "id" => "test",
            "deformable_mirrors" => Dict(
                "dm" => Dict("description" => "../mirrors/dm.yaml", "units" => "native")
            ),
        )
        C.write_yaml(joinpath(source, "instrument.yaml"), instrument)
        localized = deepcopy(instrument)
        localized["deformable_mirrors"]["dm"]["description"] = "mirrors/dm.yaml"
        C.write_yaml(joinpath(built, "instrument.yaml"), localized)
        @test E.calibration_physical_instrument(source) ==
            E.calibration_physical_instrument(built)
        write(joinpath(built, "mirrors", "dm.yaml"), "model: changed\n")
        @test E.calibration_physical_instrument(source) !=
            E.calibration_physical_instrument(built)
    end
end
