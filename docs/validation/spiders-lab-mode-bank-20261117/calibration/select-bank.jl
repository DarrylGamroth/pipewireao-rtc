using LinearAlgebra, PipeWireAORTC, SHA
const RTC = PipeWireAORTC
const C = RTC.Common
const FITS = RTC.InstrumentConfiguration.FITSIO.FITS

read_fits(path, hdu = 1) = FITS(path) do file
    read(file[hdu])
end
sha(path) = bytes2hex(open(sha256, path))

function select_bank(wide, lab, labmap, input, output)
    asset(path) = joinpath(wide, "calibration-input", path)
    stored(name) = read_fits(joinpath(wide, "calibration/scc/artifacts", name * ".fits"))
    lab_grid = read_fits(labmap)
    model_map = asset("optics/physical15/dm/BAX307-actu-map.fits")
    @assert lab_grid == read_fits(model_map) && count(!iszero, lab_grid) == 468
    grid = hcat((collect(index) for index in Tuple.(findall(!iszero, lab_grid)))...)'
    coords_path = asset("optics/generated/dm-coordinates.fits")
    coords = read_fits(coords_path)'
    recipe = C.read_yaml(asset("calibration/optical-dark-hole.yaml"))
    coords = coords ./ recipe["mirror_response"]["coordinate_radius"]
    grid_from_coords = hcat(coords, ones(size(coords, 1))) \ grid
    coordinate_error = maximum(abs, hcat(coords, ones(size(coords, 1))) * grid_from_coords - grid)
    @assert coordinate_error < 1e-5
    commands, k₁, k₂, phases = (read_fits(lab, i) for i in 1:4)
    @assert size(commands) == (650, 468) && all(isfinite, commands)
    direct_path = asset("optics/generated/dm-direct.fits")
    completion_path = asset("optics/generated/dm-completion.fits")
    direct = findall(!iszero, read_fits(direct_path))
    completion = read_fits(completion_path)
    @assert completion[direct, :] == I && size(completion) == (468, 334)
    base = Float64.(stored("command-projection")')
    @assert size(base) == (334, 114) && cond(base) < 100
    basis = svd(base).U
    bands = ((9.0, 10.5), (10.5, 12.0))
    selected = []
    direct_modes = []
    for (lower, upper) in bands, sector in 0:7
        candidates = []
        for j in 1:2:length(k₁)
            x, y = k₁[j], k₂[j]
            @assert k₁[j+1] == x && k₂[j+1] == y && phases[j+1] - phases[j] ≈ π / 2
            y == 0 && x <= 0 && continue
            max(abs(x), y) == 12 && min(abs(x), y) == 0 && continue
            frequency = grid_from_coords[1:2, :] * [x, y] / 24
            separation = 2norm(frequency)
            lower <= separation < upper || continue
            azimuth = mod(atan(frequency[2], frequency[1]), π)
            floor(Int, 8azimuth / π) == sector || continue
            pair = Float64.(commands[j:(j+1), direct]')
            pair ./= maximum(abs, pair; dims = 1)
            factor = svd(pair)
            factor.S[end] > 0.2 * factor.S[1] || continue
            q = factor.U
            novelty = svdvals(q - basis * (basis' * q))[end]
            push!(candidates, (; j, x, y, frequency, separation, azimuth, novelty, pair))
        end
        @assert !isempty(candidates) (lower, upper, sector)
        winner = argmax(candidate -> candidate.novelty, candidates)
        (; j, x, y, frequency, separation, azimuth, novelty, pair) = winner
        @assert novelty > 0.15 (x, y, novelty)
        legacy = Float64.(commands[j:(j+1), :]')
        completed = completion * legacy[direct, :]
        reconstruction_error = [norm(completed[:, q] - legacy[:, q]) / norm(legacy[:, q]) for q in 1:2]
        # Verify the archived phases against source order, including the
        # generator's masked piston removal. Almost all visible samples share
        # the constant shift and sinusoidal amplitude. Three older exclusions
        # receive the shift but do not retain the underlying phase samples.
        fit_mask = vec(any(!iszero, legacy; dims = 2))
        fit_mask[[38, 57, 240]] .= false
        angles = (2π/24) * (grid * [x, y])
        phase_errors = map(1:2) do q
            samples = legacy[fit_mask, q]
            wave = sin.(angles[fit_mask] .+ phases[j + q - 1])
            model = hcat(ones(length(wave)), wave)
            norm(samples - model * (model \ samples)) / norm(samples)
        end
        @assert maximum(phase_errors) < 1e-5 (x, y, phase_errors)
        basis = svd(hcat(basis, pair)).U
        push!(direct_modes, pair)
        push!(selected, (; fits_rows = [j, j+1], source_grid_frequency = [x,y],
            source_phases_rad = phases[j:(j+1)], recipe_frequency = frequency, separation_lambda_over_d = separation,
            azimuth_deg = rad2deg(azimuth), minimum_novelty = novelty, candidate_pairs = length(candidates),
            command_relative_completion_error = reconstruction_error, command_relative_phase_fit_error = phase_errors))
        push!(recipe["spatial_frequencies"], frequency)
    end
    expanded = hcat(base ./ maximum(abs, base; dims = 1), direct_modes...)
    @assert size(expanded) == (334, 146) && cond(expanded) < 100
    recipe["branch_modes"]["scc"] = collect(3:146)
    C.write_yaml(joinpath(input, "calibration/optical-dark-hole.yaml"), recipe; atomic = true)
    projection_path = joinpath(output, "lab-direct-projection.fits")
    RTC.InstrumentCalibration.write_fits(projection_path, Float32.(hcat(direct_modes...)); units = "normalized laboratory native command")
    record = (; lab, lab_sha256 = sha(lab), labmap, labmap_sha256 = sha(labmap),
        model_map_sha256 = sha(model_map), coordinates_sha256 = sha(coords_path),
        direct_sha256 = sha(direct_path), completion_sha256 = sha(completion_path),
        direct_projection_sha256 = sha(projection_path), original_modes = 112, added_modes = 32, joint_modes = 146,
        grid_from_normalized_recipe_coordinates = [collect(row) for row in eachrow(grid_from_coords)],
        max_coordinate_fit_error_actuators = coordinate_error,
        direct_commands = length(direct), native_commands = 468, bands_lambda_over_d = bands, angle_sectors = 8,
        normalized_geometry_condition_number = cond(expanded), selection = selected)
    C.write_json(joinpath(output, "lab-bank-selection.json"), record; atomic = true)
end
select_bank(ARGS...)
