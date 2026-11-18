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
    base = staged ? "source-filtered-112/generated/dual-calibration" : "source/generated/dual-calibration"
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
    f64 = recipe(narrow)["spatial_frequencies"]
    f112 = recipe(wide)["spatial_frequencies"]
    @assert length(f64) == 32 && length(f112) == 56
    @assert f112[1:32] == f64
    @assert !haskey(recipe(wide), "system_flat")
    @assert recipe(wide)["poke_m"] == recipe(narrow)["poke_m"] == 5e-9
    @assert recipe(wide)["branch_modes"]["llowfs"] == [1, 2]
    @assert recipe(wide)["branch_modes"]["scc"] == collect(3:114)
    radii = [2hypot(f...) for f in f112]
    @assert radii[33:56] ≈ repeat([5, 7, 9]; inner = 8)
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
    projected = read_fits(path(wide, "source-filtered-112/generated/dual-calibration/dm-native-zero.fits"))
    @assert all(iszero, projected)
    return (; frequencies_nested = true, radii_lambda_over_d = radii, appended_radii_lambda_over_d = [5, 7, 9],
        pixels_per_lambda_over_d = sky["lod"], mask_dimensions = size(mask), selected_pixels = count(mask),
        normal_flat = "all-zero physical mirror command", poke_amplitudes_m = [5e-9, 2.5e-9], measurements,
        effective_llowfs = compare_llowfs(narrow, wide))
end

narrow, wide = ARGS
report = check_bank(narrow, wide)
C.write_json(joinpath(wide, "bank-overlap.json"), report; atomic = true)
println(report)
