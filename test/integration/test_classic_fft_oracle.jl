using Test, AdaptiveOpticsSim
include("classic_fft_oracle.jl")
const O = ClassicFFTOracle
O.B.set_fft_provider_threads!(1)

@testset "Exact CPU oracle FFT preconditions" begin
    mktempdir() do directory
        @test_throws ArgumentError O.record((; graph=(; values=zeros(Float32, 4))), directory)
        native = (; graph=(; transform=O.F.plan_fft!(zeros(ComplexF32, 12, 16); flags=O.F.MEASURE)))
        O.record(native, directory)
        provenance = O.C.read_json(joinpath(directory, "plans.json"))
        @test !isempty(provenance["plans"])
        @test O.verify(native, provenance)
        @test_throws ArgumentError O.verify((; graph=(; other=native.graph.transform)), provenance)
        wisdom = read(joinpath(directory, "wisdom"))
        write(joinpath(directory, "wisdom"), "invalid wisdom")
        @test_throws ArgumentError O.restore!(directory)
        write(joinpath(directory, "wisdom"), wisdom)
        contract = O.restore!(directory)
        oracle = (; graph=(; transform=Base.invokelatest(
            O.B.plan_repeated_fft_backend!, zeros(ComplexF32, 12, 16))))
        @test O.verify(oracle, contract)
        O.F.forget_wisdom()
        @test_throws ErrorException Base.invokelatest(
            O.B.plan_repeated_fft_backend!, zeros(ComplexF32, 13, 17))
    end
end
