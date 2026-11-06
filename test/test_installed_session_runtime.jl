using Test, PipeWireAORTC

const E = PipeWireAORTC.ScienceExport

@testset "generated RTC launcher is the sole RTC runtime asset" begin
    @test occursin("# Generated", E.rtc_launcher())
    @test occursin("PipeWireAORTC.MediaSession.main(ARGS)", E.rtc_launcher())
    @test occursin("--threads=1,0", E.rtc_launcher())
    @test !occursin("wireplumber", lowercase(E.rtc_launcher()))
    @test !occursin("lua", lowercase(E.rtc_launcher()))
    @test occursin("--startup-file=no", E.rtc_launcher())
    @test occursin("--project=", E.rtc_launcher())
    @test occursin("-- \"\$@\"", E.rtc_launcher())

    mktempdir() do root
        package = mkpath(joinpath(root, "package"))
        authored = joinpath(package, "rtc", "configuration.yaml")
        mkpath(dirname(authored))
        write(authored, "schema_version: 1\n")
        bytes = read(authored)
        rtc = E.stage_rtc!(package)
        launcher = joinpath(rtc, "bin/pipewireao-rtc")
        @test read(launcher, String) == E.rtc_launcher()
        @test (stat(launcher).mode & 0o111) != 0
        @test E.validate_rtc(rtc) === nothing
        @test read(authored) == bytes
        before = read(launcher, String)
        @test !isdir(joinpath(rtc, "modules"))
        @test !isdir(joinpath(rtc, "scripts"))
        @test !isdir(joinpath(rtc, "wireplumber"))
        @test sort([
            relpath(joinpath(parent, name), rtc) for (parent, _, names) in walkdir(rtc) for
            name in names
        ]) == ["bin/pipewireao-rtc", "configuration.yaml"]

        unexpected = joinpath(rtc, "bin", "unexpected-runtime.asset")
        write(unexpected, "retired dependency")
        @test_throws ArgumentError E.validate_rtc(rtc)
        @test_throws ArgumentError E.stage_rtc!(package)
        @test read(authored) == bytes
        rm(unexpected)
        @test read(launcher, String) == before

        rm(launcher)
        @test_throws ArgumentError E.validate_rtc(rtc)
        @test E.stage_rtc!(package) == rtc
        @test read(authored) == bytes
        @test E.validate_rtc(rtc) === nothing
        @test E.stage_rtc!(package) == rtc
    end
end
