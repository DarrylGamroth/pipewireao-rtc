using Test, PipeWireAORTC
const Owner = PipeWireAORTC.GraphOwner
const Common = PipeWireAORTC.Common

condition(; kwargs...) = merge(Dict("output" => "mirror-feedback",
    "schema" => Dict("\$ref" => "/schemas/pdm_constraint_feedback/id"),
    "absolute_tolerance" => 0, "trip_fraction" => 0.05, "clear_fraction" => 0.01,
    "persistence_ms" => 1000, "max_gap_ms" => 100), Dict(string(k)=>v for (k,v) in kwargs))

@testset "Bounded owner supervision authoring and canonical schemas" begin
    mktempdir() do root
        path = joinpath(root,"supervision.yaml")
        write_condition(entry) = Common.write_yaml(path,
            Dict("schema_version" => 1, "conditions" => [entry]))
        write_condition(condition())
        parsed = Owner.read_supervision(path)
        @test length(parsed) == 1
        @test only(parsed).output === Symbol("mirror-feedback")
        @test only(parsed).schema == PipeWireAORTC.Schemas.identifier("pdm_constraint_feedback")
        @test only(parsed).configuration.action === :monitor_only
        @test only(parsed).configuration.persistence_ns == 1_000_000_000
        @test only(parsed).tolerance == 0
        for (field,value) in ((:output,"bad/name"), (:schema,"pipewireao/controller-command-f32/1"),
                (:absolute_tolerance,-1), (:absolute_tolerance,true), (:enabled,"true"),
                (:persistence_ms,0), (:max_gap_ms,0.5), (:action,"close"), (:extra,1))
            write_condition(condition(; field=>value))
            @test_throws ArgumentError Owner.read_supervision(path)
        end
        @test_throws ArgumentError Owner.supervision_tolerance(NaN)
        Common.write_yaml(path,Dict("schema_version" => 1,
            "conditions" => [condition(),condition()]))
        @test_throws ArgumentError Owner.read_supervision(path)
        for conditions in ([], [condition() for _ in 1:9], Dict())
            Common.write_yaml(path,Dict("schema_version" => 1, "conditions"=>conditions))
            @test_throws ArgumentError Owner.read_supervision(path)
        end
        write(path,repeat(" ",65537))
        @test_throws ArgumentError Owner.read_supervision(path)
    end
    base=["--bootstrap-node","bootstrap","--bootstrap-instance","7","--remote","/tmp/private"]
    @test_throws ArgumentError Owner.arguments([base;"--supervision";"policy.yaml"])
    arguments=Owner.arguments([base;"--correction-property";"controller:closed";
        "--supervision";"policy.yaml"])
    @test arguments[7] == "policy.yaml"
    @test "--supervision" ∉ arguments[2]
    @test_throws ArgumentError Owner.arguments([base;"--correction-property";"controller:closed";
        "--supervision=a";"--supervision=b"])
end
