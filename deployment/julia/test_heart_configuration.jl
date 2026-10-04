using Test
module HeartConfigurationTests
include("common.jl")
include("heart_configuration.jl")
end
const HC=HeartConfigurationTests.HeartConfiguration

@testset "HEART configuration preparation without Python" begin
    @test "TELOFF" in HC.required_sections(Val(:classic))
    @test !("TELOFF" in HC.required_sections(Val(:copper)))
    @test HC.scalar(1e-5)=="0.000010"
    @test parse(Float64,HC.scalar(1e-30))==1e-30
    @test HC.scalar(-0.3)=="-0.3"
    @test_throws ArgumentError HC.scalar(NaN)
    @test_throws ArgumentError HC.scalar(true)
    @test_throws ArgumentError HC.scalar("bad\\escape")
    @test_throws ArgumentError HC.scalar("bad\"quote")
    @test_throws ArgumentError HC.scalar("x"^128)
    @test_throws Exception HC.load_document("- A: { x: 1, x: 2 }\n")
    @test_throws Exception HC.load_document("- A: { 1: 2 }\n")
    @test_throws ArgumentError HC.load_document("- A: { x: 1 }\n- A: { y: 2 }\n")
    @test HC.normalize_aliases("- ALIASES:\n    FOO: &foo 1\n    FOO: &foo 1\n- HO:\n    N: 1\n") ==
        "- ALIASES:\n    FOO: &foo 1\n- HO:\n    N: 1\n"
    @test_throws ArgumentError HC.normalize_aliases("- ALIASES:\n    FOO: &foo 1\n    FOO: &foo 2\n")
    mktempdir() do directory
        source=joinpath(directory,"config.yaml")
        write(source,"---\n- ALIASES:\n    PORT: &port 6000\n- HO:\n    VALUE: 0.00001\n    ROWS: [ { WFS_NUM: 0, ROWS: 64 } ]\n...\n")
        document,sections=HC.load_config(source)
        @test collect(keys(sections))==["ALIASES","HO"]
        emitted=HC.serialize_config(document,source)
        @test occursin("PORT: &port 6000",emitted)
        @test occursin("ROWS: [\n",emitted)
        @test first(HC.load_document(emitted))==document
        @test !occursin(r"[0-9][eE][+-]?[0-9]",emitted)
        payload=joinpath(directory,"background.f32le")
        write(payload,reinterpret(UInt8,Float32[1,2,3,4]))
        fits=joinpath(directory,"background.fits")
        HC.write_offset_fits(payload,fits,[2,2])
        @test filesize(fits)==5760
        @test reinterpret(Float32,ntoh.(reinterpret(UInt32,read(fits)[2881:2896])))==Float32[1,2,3,4]
        @test_throws ArgumentError HC.write_offset_fits(payload,fits,[3,3])
        @test_throws ArgumentError HC.inside_root(joinpath(dirname(directory),"other"),directory)
        @test HC.inside_root(payload,directory)==payload
        @test_throws ArgumentError HC.matrix_dimensions(fits)
        sections["ALIASES"]["PORT"]=-1
        @test_throws ArgumentError HC.serialize_config(document,source)
    end
    @test HC.runtime_requirements("classic")[1]["flags"]["enableClippingFeedback"]==1
    @test HC.runtime_requirements("copper")[2]["flags"]["enableInHoVect"]==1
end
