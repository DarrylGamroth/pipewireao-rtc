# Union executable lines by repository path across separate test processes and jobs.
function read_reports(reports)
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
    return files
end

function merge_reports(reports, baseline)
    files = read_reports(reports)
    expected = Set(relpath(joinpath(root, name)) for dir in ("src", "ext")
                   for (root, _, names) in walkdir(dir) for name in names if endswith(name, ".jl"))
    push!(expected, "runtime/management.c")
    reported = Set(keys(files))
    expected == reported || error("LCOV source mismatch: missing $(setdiff(expected, reported)), unexpected $(setdiff(reported, expected))")
    julia_sources = read_reports((baseline,))
    Set(keys(julia_sources)) == setdiff(expected, ["runtime/management.c"]) ||
        error("baseline must cover exactly the package Julia sources")
    isempty(files["runtime/management.c"]) && error("empty coverage for runtime/management.c")
    for (path, executable) in julia_sources
        counts = files[path]
        !isempty(executable) && isempty(counts) && error("empty coverage for executable source $path")
    end
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
    required = fld(9 * lines, 10) + 1
    if hits < required
        missing = sort([(count(iszero, values(counts)), file) for (file, counts) in files]; rev=true)
        println("Largest gaps in executable line coverage:")
        for (uncovered, file) in Iterators.take(missing, 10)
            iszero(uncovered) && break
            println("  $file: $uncovered uncovered")
        end
        error("project line coverage must exceed 90% ($hits covered, $required required)")
    end
end

length(ARGS) >= 3 || error("usage: julia check_coverage.jl OUTPUT.info JULIA_BASELINE.info INPUT.info ...")
write_report(first(ARGS), merge_reports(ARGS[3:end], ARGS[2]))
