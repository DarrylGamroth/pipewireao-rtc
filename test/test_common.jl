using Test
using PipeWireAORTC.Common
using PipeWireAORTC.Common: finite_json
using YAML

@testset "generated numeric YAML sequences" begin
    mktempdir() do directory
        path = joinpath(directory, "coordinates.yaml")
        values = Dict(
            "pupil_origins" => [[30, 30], [150, 30]],
            "shape" => [60, 60], "axes" => [2, 1],
            "command_limits" => [-1.0e-6, 1.0e-6],
            "position" => [1.0, -0.0, 3.5],
            "coefficients" => Float32[0.1, 0.1, 0, -0.8, 0],
            "integers" => [typemax(Int64)],
            "wide" => fill(typemax(Int64), 8),
            "long" => collect(1:20), "empty" => Int[],
            "flags" => [true, false], "mixed" => Any[true, 2],
            "strings" => ["[1, 2]", "- 1\n- 2\n", "1: 2"],
        )
        write_yaml(path, values; atomic=true)
        emitted = read(path, String)
        @test occursin("pupil_origins:\n  - [30, 30]\n  - [150, 30]\n", emitted)
        @test occursin("shape: [60, 60]\n", emitted)
        @test occursin("axes: [2, 1]\n", emitted)
        @test occursin("command_limits: [-1.0e-6, 1.0e-6]\n", emitted)
        @test occursin("position: [1.0, -0.0, 3.5]\n", emitted)
        @test occursin("coefficients: [", emitted)
        @test occursin("integers: [9223372036854775807]\n", emitted)
        @test occursin("wide:\n  - 9223372036854775807\n", emitted)
        @test occursin("long:\n  - 1\n", emitted)
        @test occursin("flags:\n  - true\n", emitted)
        @test occursin("mixed:\n  - true\n", emitted)
        # Compare with the existing serializer, including Float32 promotion and strings.
        @test isequal(read_yaml(path), YAML.load(YAML.write(values)))
        write_yaml(path, read_yaml(path))
        @test read(path, String) == emitted
        write_yaml(path, values; header="Generated coordinates.\n---\n...")
        @test startswith(read(path, String), "# Generated coordinates.\n# ---\n# ...\n")
        @test isequal(read_yaml(path), YAML.load(YAML.write(values)))
    end
end

@testset "finite JSON tuple validation" begin
    samples = Tuple((;name="Mode $i", values=(0.0f0, 1.0f0, -1.0f0)) for i in 1:8)
    bases = Tuple((;id="basis-$i", modes=samples) for i in 1:2)
    instrument = (;mirrors=Tuple((;id="mirror-$i", bases) for i in 1:2))
    @test finite_json(instrument) === instrument
    for invalid in (Inf, -Inf, NaN, Inf32, NaN32)
        tail = (;modes=(samples..., (;name="Invalid", values=(0.0, invalid))))
        @test_throws ArgumentError finite_json((instrument, tail))
    end
end

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
    # Session cleanup may pass the final milliseconds of its overall deadline.
    @test_throws ErrorException run_checked(["/bin/sleep", "1"]; timeout=0.001)
    @test_throws Exception run_checked(["/bin/sh", "-c", "head -c 1000 /dev/zero"];
        maximum_output_bytes=100)
end

@testset "single-document YAML configuration" begin
    mktempdir() do directory
        path = joinpath(directory,"settings.yaml")
        write(path,"schema_version: 1\nvalues: [1.0, 2.0]\n")
        @test read_yaml(path)["values"] == [1.0,2.0]
        write_yaml(path, Dict("schema_version"=>1, "values"=>[1.0,2.0]);
            atomic=true, header="Generated by the test writer.")
        @test startswith(read(path,String), "# Generated")
        @test read_yaml(path)["values"] == [1.0,2.0]
        @test_throws ArgumentError write_yaml(path, Dict("value"=>Inf); atomic=true)
        @test read_yaml(path)["schema_version"] == 1
        @test readdir(directory) == ["settings.yaml"]
        @test_throws ArgumentError read_yaml(path;maximum=2)
        for malformed in ("x: 1\nx: 2\n", "---\nx: 1\n---\nx: 2\n", "")
            write(path,malformed)
            @test_throws Exception read_yaml(path)
        end
        write(path,"x:\n  <<: {a: 1}\n  <<: {b: 2}\n")
        @test_throws ArgumentError read_yaml(path)
        write(path,"defaults: &defaults\n  gain: 1.0\nselected:\n  <<: *defaults\n  gain: 2.0\n")
        @test read_yaml(path)["selected"]["gain"] == 2.0
        write(path,"defaults: &defaults\n  gain: 1.0\nselected:\n  <<: *defaults\n  gain: 2.0\n  gain: 3.0\n")
        @test_throws Exception read_yaml(path)
    end
end
