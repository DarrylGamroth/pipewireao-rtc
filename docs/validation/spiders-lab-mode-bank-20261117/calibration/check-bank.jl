using LinearAlgebra, PipeWireAORTC

const RTC = PipeWireAORTC
const C = RTC.Common
const FITS = RTC.InstrumentConfiguration.FITSIO.FITS

function read_fits(path)
    FITS(path) do file
        image = read(file[1])
        ndims(image) == 2 ? permutedims(image) : image
    end
end

function effective_llowfs(root, staged)
    base = staged ? "source-filtered-144/generated/dual-calibration" : "source-filtered-112/generated/dual-calibration"
    asset(branch, name) = read_fits(joinpath(root, base, branch, "artifacts", name * ".fits"))
    R = asset("llowfs", "llowfs-reconstructor")
    P = asset("llowfs", "llowfs-command-projection")
    S = asset("scc", "llowfs-feedback-selection")
    F = asset("scc", "physical-to-modes")
    M = asset("llowfs", "llowfs-modal-reference")
    completion = asset("scc", "vdm-to-pdm") * asset("scc", "active-to-full")
    n = size(R, 1)
    @assert size(S) == (n, n) && diag(S)[1:2] == [1, 1]
    @assert iszero(R[3:end, :]) && iszero(M) && iszero(S[3:end, :]) && iszero(S[:, 3:end])
    return (;
        reconstructor = R[1:2, :],
        projection = P[:, 1:2],
        feedback_selection = S[1:2, 1:2],
        native_command_from_centroid = Float64.(completion) * Float64.(P[:, 1:2]) * Float64.(R[1:2, :]),
        effective_feedback = Float64.(S[1:2, 1:2]) * Float64.(F[1:2, :]),
        coordinates = asset("llowfs", "llowfs-coordinates"),
        reference_centroid = asset("llowfs", "llowfs-reference-centroid"),
        selection_mask = asset("llowfs", "llowfs-pixel-mask"),
        joint_reconstructor_shape = size(R),
        joint_projection_shape = size(P),
        joint_feedback_selection_shape = size(S),
    )
end

function compare_llowfs(narrow, wide)
    a = effective_llowfs(narrow, false)
    b = effective_llowfs(wide, true)
    results = Dict{String,Any}()
    for name in (:reconstructor, :projection, :feedback_selection, :native_command_from_centroid,
                 :effective_feedback, :coordinates, :reference_centroid, :selection_mask)
        x, y = a[name], b[name]
        @assert size(x) == size(y)
        rel = norm(Float64.(x) - Float64.(y)) / norm(Float64.(x))
        results[string(name)] = (; shape = size(x), relative_difference = rel, exact = x == y)
    end
    return (; measurements = results,
        reconstructor_shapes = (a.joint_reconstructor_shape, b.joint_reconstructor_shape),
        projection_shapes = (a.joint_projection_shape, b.joint_projection_shape),
        feedback_selection_shapes = (a.joint_feedback_selection_shape, b.joint_feedback_selection_shape))
end

function check_bank(narrow, wide)
    path(root, pieces...) = joinpath(root, pieces...)
    recipe(root) = C.read_yaml(path(root, "calibration-input/calibration/optical-dark-hole.yaml"))
    asset(root, name) = read_fits(path(root, "calibration/scc/artifacts", name * ".fits"))
    f112 = recipe(narrow)["spatial_frequencies"]
    f144 = recipe(wide)["spatial_frequencies"]
    @assert length(f112) == 56 && length(f144) == 72
    @assert f144[1:56] == f112
    @assert !haskey(recipe(wide), "system_flat")
    @assert recipe(wide)["poke_m"] == recipe(narrow)["poke_m"] == 5e-9
    @assert recipe(wide)["branch_modes"]["llowfs"] == [1, 2]
    @assert recipe(wide)["branch_modes"]["scc"] == collect(3:146)
    radii = [2hypot(f...) for f in f144]
    @assert all(r -> 9 <= r < 12, radii[57:end])
    measurements = Dict{String,Any}()
    for name in ("scc-interaction-matrix", "scc-half-interaction-matrix", "pupil-modes", "command-projection",
                 "llowfs-interaction-matrix", "llowfs-half-interaction-matrix", "vdm-to-pdm", "active-to-full",
                 "scc-pixel-mask", "scc-flat-fringed", "scc-flat-unfringed", "scc-reference-difference")
        a = asset(narrow, name)
        b = asset(wide, name)
        overlap = view(b, axes(a)...)
        rel = norm(Float64.(overlap) - Float64.(a)) / norm(Float64.(a))
        @assert rel < 1e-4 (name, rel)
        measurements[name] = (; narrow_shape = size(a), wide_shape = size(b), relative_overlap_error = rel)
    end
    mask = asset(wide, "scc-pixel-mask") .!= 0
    @assert size(mask) == (221, 221) && count(mask) == 12703
    sky = C.read_yaml(path(wide, "calibration-input/optics/generated/fitted/sky.yaml"))
    @assert sky["lod"] == 7.86 && sky["configuration"] == "reference"
    projected = read_fits(path(wide, "source-filtered-144/generated/dual-calibration/dm-native-zero.fits"))
    @assert all(iszero, projected)
    basis = Float64.(asset(wide, "command-projection"))
    native_completion = Float64.(asset(wide, "vdm-to-pdm") * asset(wide, "active-to-full"))
    selected = Float64.(read_fits(path(wide, "lab-direct-projection.fits")))
    tip_tilt = basis[:, 1:2]
    q = svd(tip_tilt).U
    reject_tilt(a) = a - q * (q' * a)
    expected = reject_tilt(selected)
    transferred = reject_tilt(basis[:, 115:end])
    similarities = [dot(a, b) / (norm(a) * norm(b)) for (a, b) in zip(eachcol(expected), eachcol(transferred))]
    @assert minimum(similarities) > 0.99999
    physical_condition = cond(basis)
    pupil_basis = Float64.(asset(wide, "pupil-modes"))
    @assert size(pupil_basis, 2) == 146
    @assert rank(pupil_basis) == rank(native_completion * basis) == size(basis, 2) == 146
    @assert physical_condition < 100
    llowfs = compare_llowfs(narrow, wide)
    for key in ("reconstructor", "projection", "feedback_selection", "native_command_from_centroid",
                "coordinates", "reference_centroid", "selection_mask")
        @assert llowfs.measurements[key].relative_difference == 0
    end
    first_step = C.read_json(path(wide, "derived/first-step.json"))
    @assert first_step["actual_first_step_relative_change"] < 0
    return (; frequencies_nested = true, radii_lambda_over_d = radii, appended_radii_lambda_over_d = radii[57:end],
        pixels_per_lambda_over_d = sky["lod"], mask_dimensions = size(mask), selected_pixels = count(mask),
        normal_flat = "all-zero physical mirror command", poke_amplitudes_m = [5e-9, 2.5e-9], measurements,
        transfer = (; minimum_signed_column_cosine_after_rejecting_tt = minimum(similarities),
            direct_projection_condition_number = physical_condition,
            native_projection_condition_number = cond(native_completion * basis), pupil_basis_condition_number = cond(pupil_basis)),
        effective_llowfs = llowfs)
end

narrow, wide = ARGS
report = check_bank(narrow, wide)
C.write_json(joinpath(wide, "bank-overlap.json"), report; atomic = true)
println(report)
