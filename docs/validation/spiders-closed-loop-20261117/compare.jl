using Statistics

function exposure_means(path; first_sequence=5)
    windows = Dict{String,Dict{Tuple{String,Int,Int},Float64}}()
    for line in Iterators.drop(eachline(path), 1)
        window, phase, _, sequence, pts, intensity = split(line, ',')
        model_sequence = parse(Int, sequence)
        model_sequence >= first_sequence || continue
        key = (String(phase), model_sequence, parse(Int, pts))
        exposures = get!(Dict{Tuple{String,Int,Int},Float64}, windows, window)
        haskey(exposures, key) && error("Duplicate exposure in $window")
        exposures[key] = parse(Float64, intensity)
    end
    return windows
end

function compare(path)
    windows = exposure_means(path)
    reference, corrected = windows["open"], windows["closed"]
    for phase in ("fringed", "unfringed")
        paired = sort!(filter(key -> first(key) == phase,
            collect(intersect(keys(reference), keys(corrected)))))
        isempty(paired) && error("No paired $phase exposures")
        before, after = mean(reference[key] for key in paired), mean(corrected[key] for key in paired)
        ratios = [corrected[key] / reference[key] for key in paired]
        @show phase length(paired) first(paired)[2] last(paired)[2] before after after / before extrema(ratios)
    end
end

compare(only(ARGS))
