using CoverageTools, Test
include("check_coverage.jl")

@testset "Splitting tests across jobs preserves Julia's executable lines" begin
    mktempdir() do directory
        cd(directory) do
            mkdir("src")
            mkdir("ext")
            mkdir("runtime")
            write("src/Example.jl", """
                function observed(x)
                    @static if false
                        return 99
                    end
                    return x + 1
                end
                other(x) = x - 1
                function untouched(x)
                    return 2x
                end
                """)
            write("ext/Optional.jl", "optional(x) = 2x\n")
            write("runtime/management.c", "int main(void) { return 0; }\n")
            write("native.info", "SF:runtime/management.c\nDA:1,1\nend_of_record\n")

            # Both an unloaded extension and an uncalled function contribute
            # misses. The compiler omits the unreachable return in observed().
            source = "src/Example.jl"
            reports() = vcat(process_folder("src"), process_folder("ext"))
            function collect_run(call, output; raw)
                # Each invocation starts with the same untouched source tree.
                for file in readdir("src"; join = true)
                    endswith(file, ".cov") && rm(file)
                end
                expr = "include(ARGS[1]); " * call
                run(`$(Base.julia_cmd()) --code-coverage=user -e $expr $source`)
                withenv("DISABLE_AMEND_COVERAGE_FROM_SRC" => (raw ? "yes" : nothing)) do
                    LCOV.writefile(output, reports())
                end
            end
            collect_run("observed(1)", "core.info"; raw = true)
            collect_run("other(1)", "science.info"; raw = true)
            collect_run("observed(1); other(1)", "single.info"; raw = false)
            combined = merge_reports(["core.info", "science.info", "native.info"])
            expected = read_reports(["single.info", "native.info"])
            @test combined == expected
            @test !haskey(combined[source], 3)
            missed = findfirst(contains("return 2x"), readlines(source))
            @test iszero(combined[source][missed])
            @test all(iszero, values(combined["ext/Optional.jl"])) && !isempty(combined["ext/Optional.jl"])
            @test_throws "exceed 90%" write_report("combined.info", combined)
            @test_throws "exceed 90%" write_report("exact.info", Dict("ten" => Dict(i => Int(i <= 9) for i in 1:10)))
            @test write_report("above.info", Dict("fixture" => Dict(i => Int(i <= 10) for i in 1:11))) === nothing
        end
    end
end
