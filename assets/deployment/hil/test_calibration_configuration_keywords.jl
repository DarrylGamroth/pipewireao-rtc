using Test, PipeWireAO, AdaptiveOpticsSimPipeWireHIL

function configuration_expression(path)
    parsed = Meta.parseall(read(path, String))
    matches = Expr[]

    function visit(expression)
        expression isa Expr || return
        if expression.head == :(=) && expression.args[1] === :configuration
            call = expression.args[2]
            if call isa Expr && call.head == :call && call.args[1] === :PipeWireHILConfiguration
                push!(matches, expression)
            end
        end
        foreach(visit, expression.args)
    end

    visit(parsed)
    @test length(matches) == 1
    return only(matches)
end

function evaluate_configuration(path; frame_schema, command_schema, command_scale)
    fixture = Module(gensym(:CalibrationConfigurationFixture))
    Core.eval(fixture, :(using PipeWireAO, AdaptiveOpticsSimPipeWireHIL))
    Core.eval(fixture, :(const SPA = PipeWireAO.SPA))
    Core.eval(fixture, :(const RAW_SCHEMA = $frame_schema))
    Core.eval(fixture, :(const COMMAND_SCHEMA = $command_schema))
    Core.eval(fixture, :(const COMMAND_TO_METRES = $command_scale))
    Core.eval(fixture, :(options = (;
        remote="/tmp/calibration-keyword-fixture",
        rate=500,
        exposure_ns=UInt64(1_896_000),
    )))
    Core.eval(fixture, :(timeout_ns = UInt64(1_234_567_890)))
    return Core.eval(fixture, configuration_expression(path))
end

@testset "calibration owner HIL configuration passes timeout as a keyword" begin
    cases = (
        ("calibration_owner.jl", "org.calculon.ao.raw-detector-pixels/1",
            "org.calculon.ao.demanded-pdm-command/1", 1.0f-6),
        ("heart_calibration_owner.jl", "org.heart.std-wfs.raw-pixels/1",
            "org.heart.std-dm.actuator-command/1", 1.0f0),
    )

    for (filename, frame_schema, command_schema, command_scale) in cases
        configuration = evaluate_configuration(joinpath(@__DIR__, filename);
            frame_schema, command_schema, command_scale)
        @test configuration isa AdaptiveOpticsSimPipeWireHIL.PipeWireHILConfiguration
        @test configuration.timeout_ns === UInt64(1_234_567_890)
        @test configuration.frame_schema == frame_schema
        @test configuration.command_schema == command_schema
        @test configuration.rate == PipeWireAO.SPA.Fraction(UInt32(500), UInt32(1))
        @test configuration.exposure_duration_ns === UInt64(1_896_000)
        @test configuration.frame_encoding === :uint16
        @test configuration.command_scale === command_scale
    end
end
