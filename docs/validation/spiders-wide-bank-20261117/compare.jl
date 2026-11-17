using Statistics

function samples(path)
    rows = Dict{Tuple{String,String,Int,Int},Float64}()
    for line in Iterators.drop(eachline(path), 1)
        window, phase, _, sequence, pts, mean_electrons = split(line, ',')
        index = parse(Int, sequence)
        5 <= index <= 16 || continue
        key = (String(window), String(phase), index, parse(Int, pts))
        haskey(rows, key) && error("duplicate sample in $path")
        value = parse(Float64, mean_electrons)
        isfinite(value) && value > 0 || error("invalid intensity in $path")
        rows[key] = value
    end
    return rows
end

function compare(reference_path, wide_path)
    reference, wide = samples(reference_path), samples(wide_path)
    for phase in ("unfringed", "fringed")
        frames = sort([(i, pts) for (window, name, i, pts) in keys(reference)
            if window == "open" && name == phase &&
               all(haskey(run, (role, phase, i, pts)) for run in (reference, wide)
                   for role in ("open", "closed"))])
        length(frames) == 6 || error("incomplete paired window for $phase")
        intensity(run, window) = mean(run[(window, phase, i, pts)] for (i, pts) in frames)
        base_open, base_closed = intensity(reference, "open"), intensity(reference, "closed")
        wide_open, wide_closed = intensity(wide, "open"), intensity(wide, "closed")
        println((; phase, count=length(frames), base_open, base_closed, wide_open, wide_closed,
            base_change=base_closed/base_open-1, wide_change=wide_closed/wide_open-1,
            closed_ratio=wide_closed/base_closed))
    end
end

compare(ARGS...)
