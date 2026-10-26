# Existing JFG projection coordinates, derived from the parent's RMS-weighted TSVD.
"""
    InstrumentCalibration.calibrate_hidden_modes(calibration, output)

Derive `shape-to-hidden.fits` and `hidden-to-shape.fits` from a saved modal
calibration into a fresh directory. Hidden coordinates span the discarded right
singular vectors of the pupil-RMS-weighted interaction matrix. These are weak
TSVD modes; a discarded mode need not be an exact optical null.

The saved reconstructor and all parent artifacts remain unchanged. Preparation
requires at least as many measurements as shape coordinates, because the public
calibration API provides compact singular vectors.
"""
function Calibration.calibrate_hidden_modes(calibration, output)
    ispath(output) && throw(ArgumentError("hidden-mode calibration output must be fresh"))
    receipt_path = joinpath(calibration, "result.yaml")
    receipt_hash = Calibration.digest(receipt_path)
    receipt = PipeWireAORTC.Common.read_yaml(receipt_path)
    graph_hash = Calibration.digest(joinpath(calibration, "graph.conf"))
    graph_hash == receipt["graph_sha256"] || throw(ArgumentError("calibration graph changed"))
    n, m = receipt["mode_count"], receipt["measurement_count"]
    IC.ispositive_integer(n) && IC.ispositive_integer(m) ||
        throw(ArgumentError("calibration dimensions must be positive integers"))
    m >= n || throw(DimensionMismatch("compact TSVD hidden modes require measurement_count >= mode_count"))
    receipt["dimensions"]["controller_command_count"] == n ||
        throw(DimensionMismatch("controller command count differs from modal calibration"))
    rms = receipt["mode_rms"]
    length(rms) == n || throw(DimensionMismatch("mode_rms length differs from mode_count"))
    all(value -> IC.isfinite_real(value) && value > 0, rms) ||
        throw(ArgumentError("mode_rms must contain positive finite values"))
    mode_rms = Float32.(rms)
    all(value -> isfinite(value) && value > 0, mode_rms) ||
        throw(ArgumentError("mode_rms must remain positive and finite in Float32"))
    all(value -> value > sqrt(eps(Float32)), mode_rms) ||
        throw(ArgumentError("hidden-mode calibration requires nonzero parent TSVD weights"))
    weights = inv.(mode_rms)
    all(isfinite, weights) || throw(ArgumentError("inverse mode_rms must be finite in Float32"))
    rtol = receipt["recipe"]["tsvd_rtol"]
    IC.isfinite_real(rtol) && 0 <= rtol < 1 ||
        throw(ArgumentError("tsvd_rtol must be finite and in [0, 1)"))
    get(receipt, "tsvd_rtol", rtol) == rtol ||
        throw(ArgumentError("saved TSVD tolerance differs from recipe"))
    IC.ispositive_integer(receipt["retained_rank"]) ||
        throw(ArgumentError("saved retained rank must be a positive integer"))

    # Hash and read exactly the same bytes through the existing FITS reader.
    snapshots = Dict{String,Vector{UInt8}}()
    for (name, expected) in receipt["artifact_sha256"]
        name == basename(name) && !isempty(name) ||
            throw(ArgumentError("calibration artifact must be a file name"))
        path = joinpath(calibration, "artifacts", name)
        bytes = PipeWireAORTC.Artifacts.snapshot(path; check=()->nothing)
        bytes2hex(Calibration.sha256(bytes)) == expected ||
            throw(ArgumentError("calibration artifact changed: $name"))
        name in ("interaction-matrix.fits", "reconstructor.fits") && (snapshots[name] = bytes)
    end
    function matrix(name, shape)
        haskey(snapshots, name) || throw(ArgumentError("missing calibration artifact hash: $name"))
        source = PipeWireAORTC.Artifacts.FITSArtifact(joinpath(calibration, "artifacts", name); axes=(2, 1))
        return PipeWireAORTC.Artifacts.prepare_snapshot(source, Float32, shape, snapshots[name]).data
    end
    interaction = matrix("interaction-matrix.fits", (m, n))
    stored_reconstructor = matrix("reconstructor.fits", (n, m))
    inverse = AdaptiveOpticsCalibration.process(AdaptiveOpticsCalibration.prepare(
        AdaptiveOpticsCalibration.Reconstructors.TSVDInverse(; rtol=Float32(rtol)),
        AdaptiveOpticsCalibration.Reconstructors.ReconstructorSpecification(m, n, Float32)),
        AdaptiveOpticsCalibration.Reconstructors.SVDReconstructorInputs(interaction .* transpose(weights)))
    rank = AdaptiveOpticsCalibration.Reconstructors.effective_rank(inverse)
    rank == receipt["retained_rank"] || throw(ArgumentError("recomputed TSVD rank differs from saved calibration"))
    0 < rank < n || throw(ArgumentError("hidden modes require nonempty retained and discarded TSVD components"))
    reconstructor = weights .* AdaptiveOpticsCalibration.Reconstructors.reconstructor(inverse)
    # Cross-process Float32 SVD/BLAS roundoff is allowed, with no absolute floor.
    reconstructor_rtol = 1e-5
    reconstructor_error = LA.norm(Float64.(reconstructor) - stored_reconstructor) / LA.norm(Float64.(stored_reconstructor))
    reconstructor_error <= reconstructor_rtol ||
        throw(ArgumentError("recomputed reconstructor differs from saved calibration: relative error $reconstructor_error"))

    vectors = AdaptiveOpticsCalibration.Reconstructors.corrector_singular_vectors(inverse)
    discarded = vectors[:, rank+1:n]
    shape_to_hidden = Matrix{Float32}(transpose(discarded) .* transpose(mode_rms))
    hidden_to_shape = weights .* discarded
    all(isfinite, shape_to_hidden) && all(isfinite, hidden_to_shape) ||
        throw(ArgumentError("hidden-mode projections must be finite"))
    H, B = Float64.(shape_to_hidden), Float64.(hidden_to_shape)
    projection = B * H
    retained = Float64.(weights .* vectors[:, 1:rank])
    projection_rtol = 1e-4
    checks = Dict(
        "hidden_inverse_relative_error" => LA.norm(H * B - LA.I) / sqrt(n-rank),
        "shape_projection_idempotence_relative_error" => LA.norm(projection * projection - projection) / LA.norm(projection),
        "retained_projection_annihilation_relative_error" => LA.norm(H * retained) / (LA.norm(H) * LA.norm(retained)),
        "discarded_measurement_relative_response" => LA.norm(Float64.(interaction) * B) / (LA.norm(Float64.(interaction)) * LA.norm(B)))
    all(name -> isfinite(checks[name]) && checks[name] <= projection_rtol,
        ("hidden_inverse_relative_error", "shape_projection_idempotence_relative_error",
            "retained_projection_annihilation_relative_error")) ||
        throw(ArgumentError("hidden-mode projection checks failed"))
    labels = ["tsvd-component-$index" for index in rank+1:n]
    report = Dict(
        "parent_calibration" => relpath(abspath(calibration), abspath(output)),
        "parent_calibration_sha256" => receipt_hash,
        "source_prescription_identity" => receipt["source_prescription_identity"],
        "parent_graph_sha256" => graph_hash,
        "parent_artifact_sha256" => receipt["artifact_sha256"],
        "mode_count" => n, "measurement_count" => m, "retained_rank" => rank,
        "hidden_mode_count" => n-rank, "hidden_modes" => labels,
        "normalization" => receipt["normalization"],
        "mode_rms" => mode_rms,
        "tsvd_rtol" => Float32(rtol),
        "singular_value_cutoff" => Float32(rtol) * first(AdaptiveOpticsCalibration.Reconstructors.singular_values(inverse)),
        "projection_equations" => "W = diag(1 / mode_rms); Vd = discarded right singular vectors of J * W; shape-to-hidden = Vd' * inv(W); hidden-to-shape = W * Vd",
        "reconstructor_relative_error" => reconstructor_error,
        "reconstructor_relative_tolerance" => reconstructor_rtol,
        "projection_relative_tolerance" => projection_rtol,
        "projection_checks" => checks,
        "scope" => "parent calibration TSVD cutoff only; discarded weak modes, not necessarily exact optical nulls; no controller gain or parent reconstructor change")
    # Reject changes during preparation before creating any derived artifacts.
    Calibration.digest(receipt_path) == receipt_hash || throw(ArgumentError("calibration receipt changed during preparation"))
    Calibration.digest(joinpath(calibration, "graph.conf")) == graph_hash ||
        throw(ArgumentError("calibration graph changed during preparation"))
    for (name, expected) in receipt["artifact_sha256"]
        Calibration.digest(joinpath(calibration, "artifacts", name)) == expected ||
            throw(ArgumentError("calibration artifact changed during preparation: $name"))
    end
    mkdir(output)
    for (name, values) in (("shape-to-hidden.fits", shape_to_hidden), ("hidden-to-shape.fits", hidden_to_shape))
        Calibration.write_fits(joinpath(output, name), values)
    end
    report["artifact_sha256"] = Dict(name => Calibration.digest(joinpath(output, name))
        for name in ("shape-to-hidden.fits", "hidden-to-shape.fits"))
    PipeWireAORTC.Common.write_yaml(joinpath(output, "result.yaml"), report;
        header="Generated hidden-mode calibration receipt; do not edit.")
    return report
end
