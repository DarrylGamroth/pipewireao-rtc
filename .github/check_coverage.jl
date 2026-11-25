# Union executable lines by repository path across separate test processes and jobs.
using CoverageTools: amend_coverage_from_src!

function read_reports(reports)
    files = Dict{String,Dict{Int,Int}}()
    for report in reports
        lines = nothing
        has_counts = false
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
                has_counts = true
            elseif record == "end_of_record"
                lines = nothing
            end
        end
        has_counts || error("empty coverage report: $report")
    end
    return files
end

function merge_reports(reports)
    files = read_reports(reports)
    expected = Set(relpath(joinpath(root, name)) for dir in ("src", "ext")
                   for (root, _, names) in walkdir(dir) for name in names if endswith(name, ".jl"))
    push!(expected, "runtime/management.c")
    reported = Set(keys(files))
    expected == reported || error("LCOV source mismatch: missing $(setdiff(expected, reported)), unexpected $(setdiff(reported, expected))")
    isempty(files["runtime/management.c"]) && error("empty coverage for runtime/management.c")
    for path in expected
        endswith(path, ".jl") || continue
        # Match a single Julia coverage run. The source fallback marks functions
        # which are unobserved across *all* jobs, including unloaded extensions.
        raw = files[path]
        nlines = countlines(path)
        all(line -> line <= nlines, keys(raw)) || error("coverage outside source: $path")
        counts = Union{Nothing,Int}[get(raw, line, nothing) for line in 1:nlines]
        amend_coverage_from_src!(counts, path)
        files[path] = Dict(i => hits for (i, hits) in pairs(counts) if !isnothing(hits))
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

if abspath(PROGRAM_FILE) == @__FILE__
    length(ARGS) >= 2 || error("usage: julia check_coverage.jl OUTPUT.info INPUT.info ...")
    write_report(first(ARGS), merge_reports(ARGS[2:end]))
end
