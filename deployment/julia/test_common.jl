using Test
include("common.jl")
using .Common

@testset "Julia operational preparation utilities" begin
    @test parse_json("{\"x\":4611686018427387903}")["x"] === 4611686018427387903
    @test parse_json("{\"x\":18446744073709551615}")["x"] === typemax(UInt64)
    @test parse_json("{\"x\":1.0}")["x"] === 1.0
    @test parse_json("{\"x\":1e0}")["x"] === 1.0
    @test_throws ArgumentError parse_json("18446744073709551616")
    @test_throws ArgumentError parse_json(repeat("[",66)*"0"*repeat("]",66))
    for malformed in ("+1", "01", "true garbage", "{\"x\":1} garbage", "[1] garbage", "\u00a01", "{\"x\":01}")
        @test_throws ArgumentError parse_json(malformed)
    end
    @test parse_json(" \t{\"message\":\"true +1\",\"x\":1e-3}\r\n")["x"] === 0.001
    mktempdir() do directory
        path = joinpath(directory, "value.json")
        write_json(path, Dict("version" => 1, "values" => [1.0, 2.0]); atomic=true)
        @test read_json(path)["version"] === 1
        @test read_json(path)["values"] == [1, 2]
        @test length(sha256_file(path)) == 64
        @test_throws ArgumentError read_json(path; maximum=2)
        @test_throws ArgumentError write_json(path, Dict("bad" => [NaN]); atomic=true)
        @test read_json(path)["version"] === 1
        @test readdir(directory) == ["value.json"]
        write(path, "{\"value\":1e400}")
        @test_throws Exception read_json(path)
    end
    @test cli_arguments(["--base-package", "fixture", "--enable"];
        required=["base-package"], flags=["enable"]) == (base_package="fixture", enable=true)
    @test_throws ArgumentError cli_arguments(["--base-package"] ; required=["base-package"])
    @test_throws ArgumentError cli_arguments(["--unknown", "x"]; required=["base-package"])
    @test_throws ArgumentError cli_arguments(["--timeout", "1", "--timeout", "2"];
        defaults=(timeout="30",))
    @test cli_arguments(["--item", "a", "--item=b"]; repeats=["item"]).item == ["a", "b"]
    @test run_checked(["/bin/echo", "hello"]).stdout == "hello\n"
    @test run_checked(["/bin/sh", "-c", "exit 7"]).returncode == 7
    @test run_checked(["/bin/sh", "-c", "printf '%s' \"\$RTC_MIGRATION_TEST\""];
        env=Dict("RTC_MIGRATION_TEST" => "value")).stdout == "value"
    @test_throws ErrorException run_checked(["/bin/sleep", "5"]; timeout=0.05)
    @test_throws Exception run_checked(["/bin/sh", "-c", "head -c 1000 /dev/zero"];
        maximum_output_bytes=100)
end
