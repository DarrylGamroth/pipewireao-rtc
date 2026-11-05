include("calibration_optical.jl")

@testset "Native optical calibration stays inside the runtime command domain" begin
    implementation = Base.get_extension(PipeWireAORTC, :PipeWireAORTCCalibrationExt)
    implementation === nothing && (implementation = OpticalCalibrationTestImplementation)
    surface =
        command ->
            reshape(Float32[command[1], -command[1], command[2], -command[2]], 2, 2) .*
            1.0f-12
    observe = opd -> (; scc = 1.0f0 .+ opd .* 1.0f6)
    projection = Float32[1 1; 1 -1]
    options = (;
        pupil_support = trues(2, 2),
        branch_modes = (scc = 1:2,),
        pixel_masks = (scc = trues(2, 2),),
        poke_m = 1.0f-8,
        normalization_probe = 0.01f0,
        tsvd_rtol = 1.0f-5,
        derivative_tolerance = 0.001,
        reconstruction_tolerance = 0.001,
    )
    # The old numerical gates accept this weak mirror only by demanding commands
    # far outside the declared native domain. The guard must reject those probes.
    unchecked = OpticalCalibration.calibrate_optical(
        surface, observe, projection; options...
    )
    @test unchecked.report["status"] == "accepted"
    @test maximum(abs, unchecked.projection .* options.poke_m) > 0.5
    bounded = implementation.bounded_optical_surface(surface, [-0.5, -0.5], [0.5, 0.5])
    @test_throws ArgumentError OpticalCalibration.calibrate_optical(
        bounded.surface, observe, projection; options...
    )
    @test bounded.record["tested_maximum_absolute_command"] <= 0.5
    @test_throws ArgumentError bounded.surface(Float32[NaN, 0])
    @test_throws DimensionMismatch bounded.surface(zeros(Float32, 3))
    bounded.surface(Float32[0.5, -0.5])
    @test bounded.record["tested_maximum_absolute_command"] == 0.5
    @test_throws ArgumentError bounded.surface(Float64[0.50000001, 0])
end
