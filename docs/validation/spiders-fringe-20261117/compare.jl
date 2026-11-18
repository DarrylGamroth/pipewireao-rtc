using Printf
using Statistics
using TOML

const photometry = TOML.parsefile(joinpath(@__DIR__, "..", "spiders-factorial-20261117", "photometry.toml"))
const peak = prod(photometry[key] for key in ("unocculted_star_peak", "photons_per_second_per_unit_intensity",
    "quantum_efficiency", "exposure_seconds"))

function read_pairs(directory)
    pairs = Dict{Int,NTuple{4,Float64}}()
    open(joinpath(directory, "paired.csv")) do io
        names = split(readline(io), ',')
        columns = map(["open_electrons", "closed_electrons", "open_modal_power", "closed_modal_power"]) do name
            only(findall(==(name), names))
        end
        @assert names[1:3] == ["sequence", "phase", "pts_ns"]
        for line in eachline(io)
            fields = split(line, ',')
            sequence = parse(Int, fields[1])
            @assert !haskey(pairs, sequence) && 2049 <= sequence <= 4096
            @assert parse(Int, fields[3]) == (sequence - 1) * 10_000_000
            @assert fields[2] == (iseven(sequence) ? "unfringed" : "fringed")
            values = parse.(Float64, fields[columns])
            @assert all(isfinite, values)
            pairs[sequence] = Tuple(values)
        end
    end
    return pairs
end

function compare(directory, seed)
    println("Seed ", seed)
    paths = [joinpath(directory, "$(name)-$(seed)") for name in ("raw64", "filtered")]
    raw_hashes, filtered_hashes = [readlines(joinpath(path, "inputs.sha256")) for path in paths]
    changed = filter(pair -> first(pair) != last(pair), collect(zip(raw_hashes, filtered_hashes)))
    @assert length(raw_hashes) == length(filtered_hashes) == 7
    @assert all(row -> endswith(row, "  calibration/acquisition-reconstructor.fits"), only(changed))

    raw, filtered = read_pairs.(paths)
    common = sort!(collect(intersect(keys(raw), keys(filtered))))
    @assert length(common) >= 0.90 * 2048
    windows = [("late", 2049:4096); [("block", i:i+511) for i in 2049:512:4096]]
    for (label, window) in windows
        indices = filter(in(window), common)
        camera = filter(iseven, indices)
        @printf("%s %d–%d, %d shared unfringed frames\n", label, first(window), last(window), length(camera))
        for (name, records) in (("raw64", raw), ("filtered", filtered))
            baseline, closed = [mean(records[i][j] for i in camera) / peak for j in 1:2]
            modal_ratio = sqrt(sum(records[i][4] for i in indices) / sum(records[i][3] for i in indices))
            @printf("  %-8s %.8e -> %.8e (%+.4f%%), modal RMS %+.3f%%\n",
                name, baseline, closed, 100 * (closed / baseline - 1), 100 * (modal_ratio - 1))
        end
        @printf("  filtered vs raw with SCC active %+.4f%%\n",
            100 * (sum(filtered[i][2] for i in camera) / sum(raw[i][2] for i in camera) - 1))
    end
end

foreach(seed -> compare(only(ARGS), seed), (17, 73))
