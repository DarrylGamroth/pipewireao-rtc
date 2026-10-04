using Test
include("calibration_acquisition.jl")
const Acquisition = CalibrationAcquisition

@testset "completed ADC diagnostics retain settling and rail evidence" begin
    diagnostics = Acquisition.ExposureDiagnostics(14)
    raw = UInt16[0, 4, 16383, 16383]
    @test Acquisition.record_exposure!(diagnostics, raw, true) === nothing
    @test diagnostics.frames == 1 && diagnostics.invalid_frames == 0
    @test diagnostics.maximum_adc == 16383
    @test diagnostics.upper_rail_frames == 1 && diagnostics.upper_rail_pixels == 2
    @test raw == UInt16[0, 4, 16383, 16383]
    Acquisition.record_exposure!(diagnostics, UInt16[0, 8], false)
    @test diagnostics.frames == 2 && diagnostics.invalid_frames == 1
    @test diagnostics.upper_rail_frames == 1 && diagnostics.upper_rail_pixels == 2
    @test_throws ErrorException Acquisition.record_exposure!(diagnostics, UInt16[16384], true)
    @test diagnostics.frames == 2
    @test_throws ArgumentError Acquisition.record_exposure!(diagnostics, UInt16[], true)
    for bits in (0, 17, true)
        @test_throws ArgumentError Acquisition.ExposureDiagnostics(bits)
    end
    unknown = Acquisition.ExposureDiagnostics()
    Acquisition.record_exposure!(unknown, UInt16[65535], true)
    @test unknown.adc_upper_rail === nothing && unknown.upper_rail_pixels == 0
    sixteen = Acquisition.ExposureDiagnostics(16)
    Acquisition.record_exposure!(sixteen, UInt16[65535], true)
    @test sixteen.adc_upper_rail == 65535 && sixteen.upper_rail_pixels == 1
    session = (; raw=nothing, diagnostics=unknown)
    @test !Acquisition.exposure_diagnostics(session).raw_available
end

@testset "declared detector and transport exposure agree" begin
    declared = Dict("exposure_duration_s" => 0.001896)
    @test Acquisition.validate_exposure_duration(declared, UInt64(1_896_000)) === nothing
    for mismatch in (UInt64(0), UInt64(1_896_001), UInt64(2_000_000))
        @test_throws ArgumentError Acquisition.validate_exposure_duration(declared, mismatch)
    end
    for invalid in (0.0, -1.0, NaN, Inf, 1e100, 1e-12)
        @test_throws ArgumentError Acquisition.validate_exposure_duration(
            Dict("exposure_duration_s" => invalid), UInt64(1))
    end
end

@testset "prepared Classic eligibility preserves complete evidence" begin
    active = Acquisition.prepare_active(Val(:classic), nothing)
    @test active == fill(true, 188)
    supplied = copy(active)
    supplied[86] = false
    prepared = Acquisition.prepare_active(Val(:classic), supplied)
    supplied[87] = false
    @test prepared[87]
    @test !prepared[86]
    @test_throws DimensionMismatch Acquisition.prepare_active(Val(:classic), Bool[true])
    @test_throws ArgumentError Acquisition.prepare_active(Val(:classic), fill(false, 188))
    @test_throws ArgumentError Acquisition.prepare_active(Val(:classic), ones(UInt8, 188))
    @test Acquisition.prepare_active(Val(:copper), nothing) === nothing
    @test_throws ArgumentError Acquisition.prepare_active(Val(:copper), active)

    slopes = zeros(Float32, 376)
    flux = fill(2000.0f0, 188)
    validity = fill(true, 188)
    @test Acquisition.classic_response_valid(slopes, flux, validity, active)
    flux[86] = 0
    validity[86] = false
    @test !Acquisition.classic_response_valid(slopes, flux, validity, active)
    @test Acquisition.classic_response_valid(slopes, flux, validity, prepared)
    @test !validity[86] && iszero(flux[86])
    validity[87] = false
    @test !Acquisition.classic_response_valid(slopes, flux, validity, prepared)
    slopes[171] = NaN32
    @test_throws ErrorException Acquisition.classic_response_valid(slopes, flux, validity, prepared)
    slopes[171] = 0
    flux[86] = Inf32
    @test_throws ErrorException Acquisition.classic_response_valid(slopes, flux, validity, prepared)
    flux[86] = 0
    @test_throws ArgumentError Acquisition.classic_response_valid(slopes, flux, validity, fill(false, 188))
    @test_throws DimensionMismatch Acquisition.classic_response_valid(slopes, flux, validity, Bool[true])
end

@testset "command clipping feedback uses actual wire values" begin
    requested = Float32[0.9, -0.9, 0]
    demanded = Float32[0.8, -0.8, 0]
    feedback = requested - demanded
    @test Acquisition.validate_command_feedback(requested, demanded, feedback) === nothing
    @test_throws DimensionMismatch Acquisition.validate_command_feedback(requested, demanded[1:2], feedback)
    @test_throws ErrorException Acquisition.validate_command_feedback(requested, demanded, zeros(Float32, 3))
    @test_throws ErrorException Acquisition.validate_command_feedback(requested, Float32[NaN, -0.8, 0], feedback)
end
