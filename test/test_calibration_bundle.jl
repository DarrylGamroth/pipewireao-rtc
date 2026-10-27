module CalibrationBundleTests
using Test, PipeWireAORTC
const C = PipeWireAORTC.InstrumentCalibration
const Common = PipeWireAORTC.Common

function bundle(directory)
    report = Dict{String,Any}("recipe" => Dict("kind" => "interaction"),
        "source_prescription_identity" => "synthetic-optical-prescription",
        "source_graph_sha256" => repeat("a", 64), "measurement_count" => 2)
    context = Dict("dimensions" => Dict("measurement_count" => 2))
    graph = Dict("filter.graph" => Dict("nodes" => Any[], "links" => Any[]))
    parameters = Dict(Symbol("reconstructor") => Float32[1 2; 3 4])
    result = C.write_bundle(directory, report, context, graph, parameters;
        diagnostics=Dict("singular-values" => Float32[2, 1]))
    return (; report, context, graph, parameters, result)
end

@testset "Cold calibration bundle integrity" begin
    mktempdir() do root
        directory = joinpath(root, "calibration")
        saved = bundle(directory)
        loaded = C.read_bundle(directory)
        @test loaded.report == saved.result
        @test loaded.context == saved.context
        @test loaded.parameter_names == ["reconstructor"]
        @test loaded.parameter_files == Dict("reconstructor"=>"reconstructor.fits")
        @test Set(keys(loaded.artifacts)) == Set(["reconstructor.fits", "singular-values.fits"])
        @test loaded.graph == joinpath(directory, "graph.conf")
        @test saved.report["measurement_count"] == 2
        @test !haskey(saved.report, "version")
        matrix = PipeWireAORTC.Artifacts.prepare(PipeWireAORTC.Artifacts.FITSArtifact(
            loaded.artifacts["reconstructor.fits"]; axes=(2, 1)), Float32, (2, 2)).data
        @test matrix == saved.parameters[Symbol("reconstructor")]
        before = read(joinpath(directory, "result.yaml"))
        @test_throws ArgumentError bundle(directory)
        @test read(joinpath(directory, "result.yaml")) == before
        @test Set(readdir(root)) == Set(["calibration"])
        push!(saved.result["parameter_names"],"shape-reconstructor")
        saved.result["parameter_files"]["shape-reconstructor"]="reconstructor.fits"
        Common.write_yaml(joinpath(directory,"result.yaml"),saved.result)
        @test C.read_bundle(directory).parameter_files["shape-reconstructor"]=="reconstructor.fits"
        @test Set(readdir(joinpath(directory,"artifacts")))==Set(["reconstructor.fits","singular-values.fits"])
    end

    # Every mutation starts from the same valid bundle; the reader is CPU-only.
    mutations = [
        "graph bytes" => d -> open(io -> write(io, "# changed\n"), joinpath(d, "graph.conf"), "a"),
        "context bytes" => d -> Common.write_yaml(joinpath(d, "context.yaml"), Dict("changed" => true)),
        "artifact bytes" => d -> open(io -> write(io, UInt8[0xff]), joinpath(d, "artifacts", "reconstructor.fits"), "a"),
        "missing artifact" => d -> rm(joinpath(d, "artifacts", "reconstructor.fits")),
        "extra artifact" => d -> write(joinpath(d, "artifacts", "extra.fits"), "extra"),
        "unknown artifact filename" => d -> write(joinpath(d, "artifacts", "notes.txt"), "extra"),
        "unknown bundle filename" => d -> write(joinpath(d, "notes.txt"), "extra"),
        "linked graph" => d -> begin
            mv(joinpath(d, "graph.conf"), joinpath(dirname(d), "graph.conf"))
            symlink(joinpath(dirname(d), "graph.conf"), joinpath(d, "graph.conf"))
        end,
        "linked artifact" => d -> begin
            path = joinpath(d, "artifacts", "reconstructor.fits")
            target = joinpath(dirname(d), "reconstructor.fits")
            mv(path, target)
            symlink(target, path)
        end,
        "linked artifact directory" => d -> begin
            target = joinpath(dirname(d), "other-artifacts")
            mv(joinpath(d, "artifacts"), target)
            symlink(target, joinpath(d, "artifacts"))
        end,
        "duplicate YAML keys" => d -> write(joinpath(d, "result.yaml"), "version: 1\nversion: 1\n"),
        "oversized YAML" => d -> write(joinpath(d, "result.yaml"), repeat("x", 1024^2 + 1)),
    ]
    for (label, mutate!) in mutations
        @testset "$label" begin
            mktempdir() do root
                directory = joinpath(root, "calibration")
                bundle(directory)
                mutate!(directory)
                @test_throws ArgumentError C.read_bundle(directory)
            end
        end
    end

    report_mutations = [
        "missing integrity field" => r -> delete!(r, "context_sha256"),
        "unknown version" => r -> (r["version"] = 2),
        "Boolean version" => r -> (r["version"] = true),
        "missing scientific identity" => r -> delete!(r, "source_prescription_identity"),
        "invalid source hash" => r -> (r["source_graph_sha256"] = "bad"),
        "invalid context hash" => r -> (r["context_sha256"] = "bad"),
        "manifest list" => r -> (r["artifact_sha256"] = ["reconstructor.fits"]),
        "manifest traversal" => r -> (r["artifact_sha256"]["../outside.fits"] = repeat("b", 64)),
        "manifest absolute path" => r -> (r["artifact_sha256"]["/outside.fits"] = repeat("b", 64)),
        "manifest unknown extension" => r -> (r["artifact_sha256"]["notes.txt"] = repeat("b", 64)),
        "missing manifest entry" => r -> delete!(r["artifact_sha256"], "reconstructor.fits"),
        "invalid artifact hash" => r -> (r["artifact_sha256"]["reconstructor.fits"] = "bad"),
        "duplicate parameter" => r -> push!(r["parameter_names"], "reconstructor"),
        "missing binding" => r -> delete!(r["parameter_files"],"reconstructor"),
        "binding traversal" => r -> (r["parameter_files"]["reconstructor"]="../outside.fits"),
        "missing parameter artifact" => r -> push!(r["parameter_names"], "absent"),
        "parameter traversal" => r -> push!(r["parameter_names"], "../outside"),
    ]
    for (label, mutate!) in report_mutations
        @testset "$label" begin
            mktempdir() do root
                directory = joinpath(root, "calibration")
                saved = bundle(directory)
                mutate!(saved.result)
                Common.write_yaml(joinpath(directory, "result.yaml"), saved.result)
                @test_throws ArgumentError C.read_bundle(directory)
            end
        end
    end
end

@testset "Authored inputs and preserved calibration history" begin
    mktempdir() do root
        directory = joinpath(root, "calibration")
        saved = bundle(directory)
        Common.write_yaml(joinpath(directory, "recipe.yaml"), saved.report["recipe"])
        write(joinpath(directory,"recipe.conf"),"{}\n")
        mkdir(joinpath(directory, "inputs"))
        write(joinpath(directory, "README.md"), "Preserved calibration inputs.\n")
        history = mkpath(joinpath(directory, "history", "original"))
        path = joinpath(history, "result.toml")
        write(path, "version = 0\n")
        saved.result["history_sha256"] = Dict("history/original/result.toml" => Common.sha256_file(path))
        receipt = joinpath(directory, "result.yaml")
        Common.write_yaml(receipt, saved.result)
        @test C.read_bundle(directory).report == saved.result
        write(path, "version = 2\n")
        @test_throws ArgumentError C.read_bundle(directory)
        write(path, "version = 0\n")
        for name in ("../result.yaml", "history/../result.yaml", "history//result.toml",
                "/history/result.toml", "history/original/../../result.yaml")
            report = copy(saved.result)
            report["history_sha256"] = Dict(name => repeat("a", 64))
            Common.write_yaml(receipt, report)
            @test_throws ArgumentError C.read_bundle(directory)
        end
        Common.write_yaml(receipt, saved.result)
        mv(history, joinpath(root, "old-history"))
        symlink(joinpath(root, "old-history"), history)
        @test_throws ArgumentError C.read_bundle(directory)
    end
end

@testset "Fresh calibration publication and failure cleanup" begin
    mktempdir() do root
        saved = bundle(joinpath(root, "original"))
        for key in ("version", "graph_sha256", "context_sha256", "artifact_sha256", "parameter_names")
            report = copy(saved.report)
            report[key] = "caller override"
            @test_throws ArgumentError C.write_bundle(joinpath(root, "invalid"), report,
                saved.context, saved.graph, saved.parameters)
            @test !ispath(joinpath(root, "invalid"))
        end
        @test_throws ArgumentError C.write_bundle(joinpath(root, "invalid"), saved.report,
            saved.context, saved.graph, saved.parameters;
            diagnostics=Dict("reconstructor" => Float32[1]))
        @test_throws ArgumentError C.write_bundle(joinpath(root, "invalid"), saved.report,
            saved.context, saved.graph, Dict("../outside" => Float32[1]))
        @test_throws ArgumentError C.write_bundle(joinpath(root, "invalid"), saved.report,
            saved.context, Dict("invalid" => NaN), saved.parameters)
        @test Set(readdir(root)) == Set(["original"])
        symlink(joinpath(root, "absent"), joinpath(root, "linked"))
        @test_throws ArgumentError bundle(joinpath(root, "linked"))
        @test islink(joinpath(root, "linked"))
        symlink(joinpath(root, "original"), joinpath(root, "bundle-link"))
        @test_throws ArgumentError C.read_bundle(joinpath(root, "bundle-link"))
    end
end
end
