using Printf
using Statistics
using TOML

const BANKS = (64, 112)
const METHODS = ("tsvd", "legacy")
const SEEDS = (17, 73)
const PHASES = ("unfringed", "fringed")
const BURN_IN = 2048
const BLOCK = 512
const END_SEQUENCE = 4096
const MODEL_STEP_NS = 10_000_000
const PHOTOMETRY = TOML.parsefile(joinpath(@__DIR__, "photometry.toml"))
const REFERENCE_PEAK_ELECTRONS = prod(PHOTOMETRY[key] for key in (
    "unocculted_star_peak", "photons_per_second_per_unit_intensity",
    "quantum_efficiency", "exposure_seconds",
))

struct Sample
    time_ns::Int64
    mean_electrons::Float64
end

function read_samples(path)
    open(`gzip -dc $path`) do io
        @assert readline(io) == "window,phase,generation,sequence,pts_ns,mean_electrons"
        epochs = Dict(label => Dict{Tuple{String,Int},Sample}() for label in ("open", "closed"))
        for line in eachline(io)
            label, phase, generation, sequence, time, intensity = split(line, ',')
            @assert parse(Int, generation) == (label == "open" ? 1 : 2)
            @assert phase in PHASES
            index = parse(Int, sequence)
            @assert phase == (isodd(index) ? "fringed" : "unfringed")
            if BURN_IN < index <= END_SEQUENCE
                key = (String(phase), index)
                @assert !haskey(epochs[label], key)
                sample = Sample(parse(Int64, time), parse(Float64, intensity))
                @assert isfinite(sample.mean_electrons) && sample.mean_electrons > 0
                epochs[label][key] = sample
            end
        end
        return epochs
    end
end

function paired_samples(directory, seed)
    arms = Dict(
        (bank, method) => read_samples(joinpath(directory, "$bank-$method-$seed.csv.gz"))
        for bank in BANKS for method in METHODS
    )
    all_epochs = [epoch for arm in values(arms) for epoch in values(arm)]
    paired = sort!(collect(intersect(keys.(all_epochs)...)); by=last)
    base = arms[(64, "tsvd")]["open"]
    max_open_relative = 0.0
    for key in paired
        sample = base[key]
        for epoch in all_epochs
            @assert epoch[key].time_ns == sample.time_ns
        end
        for arm in values(arms)
            relative = abs(arm["open"][key].mean_electrons / sample.mean_electrons - 1)
            max_open_relative = max(max_open_relative, relative)
        end
    end
    @assert all(diff([base[k].time_ns for k in paired]) .==
        MODEL_STEP_NS .* diff(last.(paired)))
    @assert max_open_relative <= 1e-6
    @printf("seed %d maximum per-frame open baseline difference %.6g%%\n",
        seed, 100max_open_relative)
    return arms, paired
end

intensity(epoch, keys) = mean(epoch[key].mean_electrons for key in keys)
relative(closed, open) = 100 * (closed / open - 1)

function summarize(seed, phase, arms, paired)
    keys = filter(key -> first(key) == phase, paired)
    @assert length(keys) >= 0.95 * (END_SEQUENCE - BURN_IN) / 2
    @printf("\nseed %d, %s, %d matched samples per epoch\n", seed, phase, length(keys))
    changes = Dict{Tuple{Int,String},Float64}()
    for bank in BANKS, method in METHODS
        arm = arms[(bank, method)]
        open = intensity(arm["open"], keys)
        closed = intensity(arm["closed"], keys)
        changes[(bank, method)] = relative(closed, open)
        @printf("%3d %-6s  open %.8f  closed %.8f  change %+.4f%%  blocks",
            bank, method, open, closed, changes[(bank, method)])
        for start in (BURN_IN + 1):BLOCK:END_SEQUENCE
            block = filter(key -> start <= last(key) < start + BLOCK, keys)
            @assert length(block) >= 0.9 * BLOCK / 2
            @printf(" %+.4f", relative(intensity(arm["closed"], block),
                intensity(arm["open"], block)))
        end
        @printf("  normalized open %.6e  closed %.6e\n",
            open / REFERENCE_PEAK_ELECTRONS, closed / REFERENCE_PEAK_ELECTRONS)
    end
    @printf("mode-count effect at TSVD %+.4f pp, at legacy %+.4f pp\n",
        changes[(112, "tsvd")] - changes[(64, "tsvd")],
        changes[(112, "legacy")] - changes[(64, "legacy")])
    @printf("damping effect at 64 %+.4f pp, at 112 %+.4f pp, interaction %+.4f pp\n",
        changes[(64, "legacy")] - changes[(64, "tsvd")],
        changes[(112, "legacy")] - changes[(112, "tsvd")],
        (changes[(112, "legacy")] - changes[(112, "tsvd")]) -
        (changes[(64, "legacy")] - changes[(64, "tsvd")]))
end

for seed in SEEDS
    arms, paired = paired_samples(@__DIR__, seed)
    for phase in PHASES
        summarize(seed, phase, arms, paired)
    end
end
