using Test
include("heart_correction_flags.jl")
const Flags=HeartCorrectionFlags
@testset "native profile flag sets are exact and independently protected" begin
    copper=Flags.required_flags(:copper);classic=Flags.required_flags(:classic)
    @test length(copper)==13 && length(classic)==24 && issubset(copper,classic)
    for profile in (:copper,:classic)
        rows=[(;section,field,value) for (section,field,value) in Flags.required_flags(profile)]
        @test Flags.validate_flags(rows,profile)===nothing
        @test_throws ErrorException Flags.validate_flags(rows,profile===:copper ? :classic : :copper)
        @test_throws ErrorException Flags.validate_flags(rows[1:end-1],profile)
        @test_throws ErrorException Flags.validate_flags(vcat(rows,rows[1:1]),profile)
        @test_throws ErrorException Flags.validate_flags(vcat(rows,[(;section="TFC",field="unknown",value=0)]),profile)
        changed=copy(rows);changed[1]=merge(changed[1],(;value=1-changed[1].value))
        @test_throws ErrorException Flags.validate_flags(changed,profile)
        changed=Any[rows...];changed[1]=merge(changed[1],(;value=false))
        @test_throws ErrorException Flags.validate_flags(changed,profile)
        copyset=Flags.required_flags(profile);empty!(copyset)
        @test !isempty(Flags.required_flags(profile))
    end
    @test_throws ArgumentError Flags.required_flags(:unknown)
end
