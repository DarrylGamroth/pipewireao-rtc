# Each input is an aggregated LCOV report for disjoint production files.
# Count DA records because LCOV generators need not emit LF/LH summaries.
files = Set{String}()
counts = Dict{String,Tuple{Int,Int}}()
for report in ARGS
    file = ""
    for line in eachline(report)
        if startswith(line, "SF:")
            file = normpath(line[4:end])
            file in files && error("duplicate LCOV source: $file")
            push!(files, file)
            counts[file] = (0, 0)
        elseif startswith(line, "DA:")
            fields = split(line[4:end], ',')
            hits, lines = counts[file]
            counts[file] = (hits + (parse(Int, fields[2]) > 0), lines + 1)
        end
    end
end
expected = Set(relpath(joinpath(root, name)) for dir in ("src", "ext")
               for (root, _, names) in walkdir(dir) for name in names if endswith(name, ".jl"))
push!(expected, "runtime/management.c")
expected == files || error("LCOV source mismatch: missing $(setdiff(expected, files)), unexpected $(setdiff(files, expected))")
for (file, (_, lines)) in counts
    lines == 0 && @info "No executable lines reported" file
end
covered = sum(first, values(counts))
total = sum(last, values(counts))
total > 0 || error("LCOV reports contain no executable lines")
println("Project line coverage: $covered/$total (", round(100 * covered / total; digits=3), "%)")
10 * covered > 9 * total || error("project line coverage must exceed 90%")
