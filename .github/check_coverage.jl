# Union executable lines by repository path across separate test processes and jobs.
function merge_reports(reports)
    files = Dict{String,Dict{Int,Int}}()
    for report in reports
        lines = nothing
        for record in eachline(report)
            if startswith(record, "SF:")
                file = relpath(normpath(record[4:end]))
                lines = get!(Dict{Int,Int}, files, file)
            elseif startswith(record, "DA:")
                isnothing(lines) && error("DA without SF in $report")
                fields = split(record[4:end], ',')
                line, hits = parse(Int, fields[1]), parse(Int, fields[2])
                line > 0 && hits >= 0 || error("invalid coverage in $report: $record")
                lines[line] = get(lines, line, 0) + hits
            elseif record == "end_of_record"
                lines = nothing
            end
        end
    end
    expected = Set(relpath(joinpath(root, name)) for dir in ("src", "ext")
                   for (root, _, names) in walkdir(dir) for name in names if endswith(name, ".jl"))
    push!(expected, "runtime/management.c")
    reported = Set(keys(files))
    expected == reported || error("LCOV source mismatch: missing $(setdiff(expected, reported)), unexpected $(setdiff(reported, expected))")
    return files
end

function write_report(output, files)
    hits = lines = 0
    open(output, "w") do io
        for file in sort!(collect(keys(files)))
            counts = files[file]
            println(io, "SF:", file)
            for line in sort!(collect(keys(counts)))
                println(io, "DA:", line, ",", counts[line])
            end
            covered = count(>(0), values(counts))
            println(io, "LF:", length(counts), "\nLH:", covered, "\nend_of_record")
            hits += covered
            lines += length(counts)
        end
    end
    lines > 0 || error("no executable lines in coverage reports")
    println("Project line coverage: $hits/$lines (", round(100 * hits / lines; digits=3), "%)")
    10 * hits > 9 * lines || error("project line coverage must exceed 90%")
end

length(ARGS) >= 2 || error("usage: julia check_coverage.jl OUTPUT.info INPUT.info ...")
write_report(first(ARGS), merge_reports(ARGS[2:end]))
