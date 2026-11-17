using LinearAlgebra
using PipeWireAORTC
using Printf
using Statistics
using TOML

const FITS = PipeWireAORTC.InstrumentConfiguration.FITSIO.FITS
const C = PipeWireAORTC.Common
const REFERENCE = TOML.parsefile(joinpath(@__DIR__, "..",
    "spiders-factorial-20261117", "photometry.toml"))
const PEAK_ELECTRONS = prod(REFERENCE[key] for key in (
    "unocculted_star_peak", "photons_per_second_per_unit_intensity",
    "quantum_efficiency", "exposure_seconds",
))
const WIDTH = 512

fits_cube(path) = FITS(file -> permutedims(read(file[1]), (3, 2, 1)), path)
percentage(biased, closed) = 100 * (closed / biased - 1)

function read_paired(path)
    open(path) do io
        headings = String.(split(readline(io), ','))
        return headings, reduce(hcat, (
            let fields = split(line, ',')
                @assert length(fields) == length(headings)
                index = parse(Int, fields[1])
                phase = iseven(index) ? "unfringed" : "fringed"
                @assert fields[2] == phase
                @assert parse(Int, fields[3]) == (index - 1) * 10_000_000
                [Float64(index); parse.(Float64, fields[4:end])]
            end for line in eachline(io)
        ))
    end
end

function check_baseline(seed, current)
    path = joinpath(@__DIR__, "..", "spiders-factorial-20261117", "64-tsvd-$seed.csv.gz")
    previous = open(`gzip -dc $path`) do io
        readline(io)
        baseline = Dict{Int,Float64}()
        for line in eachline(io)
            label, _, _, index, _, value = split(line, ',')
            label == "open" || continue
            baseline[parse(Int, index)] = parse(Float64, value)
        end
        return baseline
    end
    indices = [i for i in axes(current, 2) if haskey(previous, Int(current[1, i]))]
    @assert length(indices) >= 0.9 * size(current, 2)
    largest = maximum(abs(current[2, i] - previous[Int(current[1, i])]) for i in indices)
    @printf("Replayed camera baseline over %d shared exposures, max difference %.8g e⁻/pixel\n",
        length(indices), largest)
    @assert iszero(largest)
    return nothing
end

function compare(label, pairs)
    a, b = pairs
    @printf("%-37s  %12.6e  %12.6e  %+8.4f%%\n", label, a, b, percentage(a, b))
end

function report_window(label, matched, coordinates, window, region_pixels)
    println(label, "  ", size(matched, 2), " matched exposures")
    open, closed = mean(view(matched, 2:3, findall(iseven, view(matched, 1, :))); dims=2)
    compare("Unfringed contrast", (open / PEAK_ELECTRONS, closed / PEAK_ELECTRONS))
    compare("Chopped pixel RMS, e⁻/pixel",
        sqrt.(mean(view(matched, 4:5, :); dims=2) ./ region_pixels))
    controllable = vec(mean(view(matched, 6:7, :); dims=2)) ./ region_pixels
    modal = vec(mean(view(matched, 8:9, :); dims=2)) ./ size(coordinates, 1)
    controllable_mean = [sum(abs2, view(coordinates, :, window, i)) / region_pixels for i in 1:2]
    modal_mean = [sum(abs2, view(coordinates, :, window, i)) / size(coordinates, 1) for i in 3:4]
    compare("Controllable chopped RMS, e⁻/pixel", sqrt.(controllable))
    compare("Controllable temporal mean norm", sqrt.(controllable_mean))
    compare("Controllable temporal std. dev.", sqrt.(max.(0.0, controllable .- controllable_mean)))
    compare("Active modal RMS", sqrt.(modal))
    compare("Active modal temporal mean norm", sqrt.(modal_mean))
    compare("Active modal temporal std. dev.", sqrt.(max.(0.0, modal .- modal_mean)))
    return nothing
end

function summarize(root, seed; replay_biased_baseline=true, require_command_receipt=true)
    println("\nSeed ", seed)
    path = joinpath(root, string(seed))
    _, matched = read_paired(joinpath(path, "paired.csv"))
    coordinates = fits_cube(joinpath(path, "coordinate-means.fits"))
    images = fits_cube(joinpath(path, "unfringed-means.fits"))
    region = view(images, :, :, 3) .!= 0
    region_pixels = count(region)
    @assert allunique(view(matched, 1, :))
    if require_command_receipt
        receipt = C.read_json(joinpath(path, "measurement.json"))
        @assert size(matched, 2) == receipt["matched_exposures"]
        @assert size(coordinates) == (receipt["controllable_rank"], 5, 4)
        @assert region_pixels == receipt["region_pixels"]
        image_label = "Image means over $(length(receipt["image_sequences"])) matched unfringed exposures"
    else
        @assert size(matched, 2) >= 0.95 * 4 * WIDTH
        @assert size(coordinates) == (64, 5, 4) && region_pixels == 12703
        image_label = "Mean images from the matched unfringed exposures"
    end
    replay_biased_baseline && check_baseline(seed, matched)
    report_window("Full late window", matched, coordinates, 1, region_pixels)
    start = 2049
    for window in 2:5
        indices = findall(index -> start <= index < start + WIDTH, view(matched, 1, :))
        @assert length(indices) >= 0.9 * WIDTH
        report_window("Sequences $(start)–$(start + WIDTH - 1)", view(matched, :, indices),
            coordinates, window, region_pixels)
        start += WIDTH
    end
    println(image_label)
    image_mean(index) = mean(view(images, :, :, index)[region]) / PEAK_ELECTRONS
    compare("Image mean contrast", (image_mean(1), image_mean(2)))
    return nothing
end

if abspath(PROGRAM_FILE) == @__FILE__
    for seed in (17, 73)
        summarize(only(ARGS), seed)
    end
end
