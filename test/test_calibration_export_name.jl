using Test, PipeWireAODeployment

@testset "calibration labels preserve a bounded base prefix" begin
    calibration = PipeWireAODeployment.CalibrationExport
    heart = PipeWireAODeployment.HeartCalibrationExport
    for count in (1, 28, 29, 40)
        base = first(repeat("copper-fgn-", 4), count)
        expected = first(base, 28) * "-calibration"
        actual = calibration.calibration_name(base)
        @test actual == expected
        @test ncodeunits(actual) <= 40
        @test occursin(r"^[a-z0-9][a-z0-9-]{0,39}$", actual)
        @test startswith(actual, first(base, min(count, 28)))
        @test calibration.calibration_name(base) == actual
        @test heart.calibration_name(base, "copper") == actual
    end
    @test calibration.calibration_name("fixture") == "fixture-calibration"
    @test heart.calibration_name("revolt-classic-heart-hil-cuda", "classic") ==
        "revolt-classic-heart-cal-cuda"
    correction = PipeWireAODeployment.HeartCorrectionExport
    @test correction.deployment_name("classic", "cuda") == "classic-heart-cuda-correction"
    @test correction.deployment_name("copper", "cuda") == "copper-heart-cuda-correction"
end
