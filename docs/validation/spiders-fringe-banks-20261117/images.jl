using Printf
using Statistics

include("banks.jl")

function plot_banks(narrow, wide, destination)
    a_modes, b_modes = bank_modes.((narrow, wide))
    @assert a_modes < b_modes
    samples = map((17, 73)) do seed
        small, large = [image_planes(joinpath(directory, "filtered-$seed")) for directory in (narrow, wide)]
        @assert small.mask == large.mask
        (; seed, small, large, delta = large.closed - small.closed)
    end
    @assert samples[1].small.mask == samples[2].small.mask
    span = maximum(s -> quantile(abs.(s.delta[s.small.mask]), 0.98), samples)
    limit = max(1, ceil(Int, span * 1e6))
    mktempdir() do directory
        # Each FITS cube averages phase-matched open and closed images within one bank.
        mask_means = Float64[]
        for (; seed, small, large, delta) in samples
            a, b, c = [mean(plane[small.mask]) for plane in (small.baseline, small.closed, large.closed)]
            append!(mask_means, (1e5*a, 1e5*b, 1e5*c, 100*(c/b-1)))
            open(joinpath(directory, "seed-$seed.dat"), "w") do io
                for y in axes(small.mask, 1)
                    for x in axes(small.mask, 2)
                        @printf(io, "%.5f %.5f %.9g %.9g %.9g %.9g %d\n",
                            (x-111)/7.86, (y-111)/7.86, small.baseline[y,x], small.closed[y,x],
                            large.closed[y,x], delta[y,x] * 1e6, small.mask[y,x])
                    end
                    println(io)
                end
            end
        end
        open(joinpath(directory, "means.gp"), "w") do io
            println(io, "array mask_means[8] = [", join(mask_means, ","), "]")
        end
        cd(directory) do
            run(`$(get(ENV, "GNUPLOT", "gnuplot")) -c $(joinpath(@__DIR__, "images.gp")) $limit $a_modes $b_modes`)
            cp("figure.png", destination; force = true)
        end
    end
end

plot_banks(ARGS[1], ARGS[2], abspath(ARGS[3]))
