using Test, PipeWireAORTC

const S = PipeWireAORTC.Schemas
const C = PipeWireAORTC.Common

@testset "shared payload declarations" begin
    raw = S.declaration("raw_detector_pixels")
    command = S.declaration("demanded_pdm_command")
    @test raw["id"] == "pipewireao/raw-detector-pixels-u16/1"
    @test raw["element_type"] == "UInt16"
    @test raw["wire_type"] == "U16_LE"
    @test command["id"] == "pipewireao/dm-command-opd-um-f32/1"
    @test command["element_type"] == "Float32"
    @test command["wire_type"] == "F32_LE"
    reference(field) = Dict("\$ref" => "/schemas/demanded_pdm_command/" * field)
    source = Dict("schema" => reference("id"), "element-type" => reference("wire_type"))
    resolved = S.resolve(source)
    @test resolved == Dict("schema" => command["id"], "element-type" => "F32_LE")
    @test source["schema"] == reference("id")
    @test S.validate(resolved) === nothing
    @test_throws ArgumentError S.validate(merge(resolved, Dict("element-type" => "F64_LE")))
    @test S.validate(Dict("schema" => "external/custom-f64/1", "element-type" => "F64_LE")) === nothing
    @test S.resolve(Dict("\$ref" => "/instrument/custom/dimension")) ==
        Dict("\$ref" => "/instrument/custom/dimension")
    @test_throws Exception S.resolve(Dict("\$ref" => "/schemas/missing/id"))
    for contract in values(S.CATALOG)
        @test startswith(contract["id"], "pipewireao/")
        @test !occursin("calculon", contract["id"])
    end
end

@testset "concrete sessions validate known representations without references" begin
    mktempdir() do directory
        C.write_json(joinpath(directory, "session.conf"), Dict("ports" => [Dict(
            "schema" => S.identifier("demanded_pdm_command"), "element-type" => "F64_LE")]))
        C.write_json(joinpath(directory, "core.conf"), Dict())
        spec = Dict("session" => "session.conf", "core" => "core.conf")
        @test_throws ArgumentError PipeWireAORTC.InstrumentExport.prepare_session_configuration!(
            directory, spec, [], "unused.json", ENV["PIPEWIREAO_PREFIX"])
        C.write_json(joinpath(directory, "session.conf"), Dict("ports" => [Dict(
            "schema" => S.identifier("demanded_pdm_command"), "element-type" => "F32_LE")]))
        @test PipeWireAORTC.InstrumentExport.prepare_session_configuration!(
            directory, spec, [], "unused.json", ENV["PIPEWIREAO_PREFIX"]) === nothing
    end
end
