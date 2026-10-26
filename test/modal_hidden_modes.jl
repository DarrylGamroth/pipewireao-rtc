module ModalHiddenModesTests
using Test, LinearAlgebra, PipeWireAORTC
import AdaptiveOpticsCalibration
for dependency in (:FilterGraphAlgorithms, :AdaptiveOpticsSim, :AdaptiveOpticsSimPipeWireHIL,
        :FilterGraphIsland, :FilterGraphPipeWire, :JuliaFilterGraph)
    Base.require(Main, dependency)
end
const C = PipeWireAORTC.InstrumentCalibration
const A = PipeWireAORTC.Artifacts
const R = AdaptiveOpticsCalibration.Reconstructors
const Common = PipeWireAORTC.Common

function saved_calibration(directory; rtol=0.05f0)
    mkdir(directory)
    artifacts = mkdir(joinpath(directory, "artifacts"))
    mode_rms = Float32[0.5, 2, 4]
    vectors = Matrix(qr(Float32[1 2 3; 2 -1 1; 1 1 -1]).Q)
    weighted = vcat(Diagonal(Float32[4, 1, 0.02]) * transpose(vectors), zeros(Float32, 1, 3))
    interaction = weighted .* transpose(mode_rms)
    weights = inv.(mode_rms)
    inverse = AdaptiveOpticsCalibration.process(AdaptiveOpticsCalibration.prepare(
        R.TSVDInverse(; rtol), R.ReconstructorSpecification(4, 3, Float32)),
        R.SVDReconstructorInputs(interaction .* transpose(weights)))
    reconstructor = weights .* R.reconstructor(inverse)
    for (name, matrix) in (("interaction-matrix", interaction), ("reconstructor", reconstructor),
            ("singular-values", R.singular_values(inverse)), ("unrelated", Float32[7, 11]))
        C.write_fits(joinpath(artifacts, name * ".fits"), matrix)
    end
    write(joinpath(directory, "graph.conf"), "# preserved parent graph\n")
    receipt = Dict("source_prescription_identity" => "synthetic-optical-prescription",
        "graph_sha256" => C.digest(joinpath(directory, "graph.conf")),
        "mode_count" => 3, "measurement_count" => 4, "retained_rank" => R.effective_rank(inverse),
        "dimensions" => Dict("controller_command_count" => 3),
        "mode_rms" => mode_rms, "normalization" => "piston-removed pupil RMS OPD",
        "tsvd_rtol" => rtol, "recipe" => Dict("tsvd_rtol" => rtol),
        "artifact_sha256" => Dict(name => C.digest(joinpath(artifacts, name)) for name in readdir(artifacts)))
    Common.write_yaml(joinpath(directory, "result.yaml"), receipt)
    return (; receipt, interaction, reconstructor, inverse, mode_rms)
end

read_matrix(directory, name, shape) = A.prepare(A.FITSArtifact(joinpath(directory, name); axes=(2, 1)), Float32, shape).data
function original_bytes(directory)
    paths = vcat(["graph.conf", "result.yaml"], [joinpath("artifacts", name) for name in readdir(joinpath(directory, "artifacts"))])
    return Dict(path => read(joinpath(directory, path)) for path in paths)
end

@testset "Saved RMS-weighted TSVD hidden projections" begin
    mktempdir() do directory
        parent = joinpath(directory, "modal")
        saved = saved_calibration(parent)
        before = original_bytes(parent)
        output = joinpath(directory, "hidden")
        report = Base.invokelatest(C.calibrate_hidden_modes, parent, output)
        H = read_matrix(output, "shape-to-hidden.fits", (1, 3))
        B = read_matrix(output, "hidden-to-shape.fits", (3, 1))
        @test eltype(H) == eltype(B) == Float32
        @test H * B ≈ ones(Float32, 1, 1) atol=2e-6
        @test (B * H)^2 ≈ B * H atol=2e-6
        retained = inv.(saved.mode_rms) .* R.corrector_singular_vectors(saved.inverse)[:, 1:2]
        @test H * retained ≈ zeros(Float32, 1, 2) atol=2e-6
        @test H * (saved.reconstructor * saved.interaction) ≈ zeros(Float32, 1, 3) atol=2e-6
        @test norm(saved.interaction * B) > 0.01 # Weak discarded component, no exact null claim.
        @test norm((saved.interaction * B) ./ norm(saved.mode_rms .* B)) ≈ 0.02f0 atol=2e-6
        @test report["hidden_mode_count"] == 1
        @test report["retained_rank"] == 2
        @test report["hidden_modes"] == ["tsvd-component-3"]
        @test report["parent_calibration_sha256"] == C.digest(joinpath(parent, "result.yaml"))
        @test report["source_prescription_identity"] == saved.receipt["source_prescription_identity"]
        @test report["projection_checks"]["discarded_measurement_relative_response"] > 0
        @test report["reconstructor_relative_error"] <= report["reconstructor_relative_tolerance"]
        @test readdir(output) == ["hidden-to-shape.fits", "result.yaml", "shape-to-hidden.fits"]
        for (name, expected) in report["artifact_sha256"]
            @test C.digest(joinpath(output, name)) == expected
        end
        @test Common.read_yaml(joinpath(output, "result.yaml"))["hidden_modes"] == report["hidden_modes"]
        @test original_bytes(parent) == before
        @test_throws ArgumentError Base.invokelatest(C.calibrate_hidden_modes, parent, output)
        @test original_bytes(parent) == before
    end
    mktempdir() do directory
        parent, output = joinpath(directory, "modal"), joinpath(directory, "hidden")
        saved = saved_calibration(parent; rtol=0.3f0)
        report = Base.invokelatest(C.calibrate_hidden_modes, parent, output)
        H = read_matrix(output, "shape-to-hidden.fits", (2, 3))
        B = read_matrix(output, "hidden-to-shape.fits", (3, 2))
        @test report["hidden_modes"] == ["tsvd-component-2", "tsvd-component-3"]
        @test H * B ≈ Matrix{Float32}(I, 2, 2) atol=2e-6
        @test (B * H)^2 ≈ B * H atol=2e-6
        @test H * (saved.reconstructor * saved.interaction) ≈ zeros(Float32, 2, 3) atol=2e-6
    end
end

@testset "Reject invalid or stale saved calibration before creating output" begin
    mutations = [
        ("zero RMS", ArgumentError, saved -> (saved.receipt["mode_rms"][2] = 0f0)),
        ("negative RMS", ArgumentError, saved -> (saved.receipt["mode_rms"][2] = -1f0)),
        ("zero parent weight", ArgumentError, saved -> (saved.receipt["mode_rms"][2] = eps(Float32))),
        ("infinite RMS", ArgumentError, saved -> (saved.receipt["mode_rms"][2] = Inf32)),
        ("NaN RMS", ArgumentError, saved -> (saved.receipt["mode_rms"][2] = NaN32)),
        ("RMS dimensions", DimensionMismatch, saved -> pop!(saved.receipt["mode_rms"])),
        ("retained rank", ArgumentError, saved -> (saved.receipt["retained_rank"] = 1)),
        ("controller dimensions", DimensionMismatch, saved -> (saved.receipt["dimensions"]["controller_command_count"] = 4)),
        ("invalid cutoff", ArgumentError, saved -> (saved.receipt["recipe"]["tsvd_rtol"] = NaN32)),
        ("inconsistent cutoff", ArgumentError, saved -> (saved.receipt["tsvd_rtol"] = 0.1f0)),
        ("wide compact SVD", DimensionMismatch, saved -> (saved.receipt["measurement_count"] = 2)),
        ("missing artifact hash", ArgumentError, saved -> delete!(saved.receipt["artifact_sha256"], "reconstructor.fits"))]
    for (name, exception, mutate!) in mutations
        @testset "$name" begin
            mktempdir() do directory
                parent, output = joinpath(directory, "modal"), joinpath(directory, "hidden")
                saved = saved_calibration(parent)
                mutate!(saved)
                # Deliberately malformed receipts bypass the finite writer.
                C.YAML.write_file(joinpath(parent, "result.yaml"), saved.receipt)
                @test_throws exception Base.invokelatest(C.calibrate_hidden_modes, parent, output)
                @test !ispath(output)
            end
        end
    end
    for name in ("graph.conf", joinpath("artifacts", "unrelated.fits"))
        mktempdir() do directory
            parent, output = joinpath(directory, "modal"), joinpath(directory, "hidden")
            saved_calibration(parent)
            open(io -> write(io, UInt8(0)), joinpath(parent, name), "a")
            @test_throws ArgumentError Base.invokelatest(C.calibrate_hidden_modes, parent, output)
            @test !ispath(output)
        end
    end
    for (name, values, exception) in (("interaction-matrix.fits", zeros(Float32, 4, 2), DimensionMismatch),
            ("reconstructor.fits", zeros(Float32, 3, 4), ArgumentError))
        mktempdir() do directory
            parent, output = joinpath(directory, "modal"), joinpath(directory, "hidden")
            saved = saved_calibration(parent)
            path = joinpath(parent, "artifacts", name)
            C.write_fits(path, values)
            saved.receipt["artifact_sha256"][name] = C.digest(path)
            Common.write_yaml(joinpath(parent, "result.yaml"), saved.receipt)
            @test_throws exception Base.invokelatest(C.calibrate_hidden_modes, parent, output)
            @test !ispath(output)
        end
    end
    mktempdir() do directory
        parent, output = joinpath(directory, "modal"), joinpath(directory, "hidden")
        saved_calibration(parent; rtol=0.001f0)
        @test_throws ArgumentError Base.invokelatest(C.calibrate_hidden_modes, parent, output)
        @test !ispath(output)
    end
end

@testset "Explicit Float32 reconstructor comparison tolerance" begin
    for (relative_change, accepted) in ((4f-6, true), (2f-5, false))
        mktempdir() do directory
            parent, output = joinpath(directory, "modal"), joinpath(directory, "hidden")
            saved = saved_calibration(parent)
            path = joinpath(parent, "artifacts", "reconstructor.fits")
            C.write_fits(path, saved.reconstructor .* (1f0 + relative_change))
            saved.receipt["artifact_sha256"]["reconstructor.fits"] = C.digest(path)
            Common.write_yaml(joinpath(parent, "result.yaml"), saved.receipt)
            before = original_bytes(parent)
            if accepted
                report = Base.invokelatest(C.calibrate_hidden_modes, parent, output)
                @test 3e-6 < report["reconstructor_relative_error"] < 5e-6
                @test report["reconstructor_relative_tolerance"] == 1e-5
            else
                @test_throws ArgumentError Base.invokelatest(C.calibrate_hidden_modes, parent, output)
                @test !ispath(output)
            end
            @test original_bytes(parent) == before
        end
    end
end
end
