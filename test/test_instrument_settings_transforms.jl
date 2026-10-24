using Test, PipeWireAORTC

const IC = PipeWireAORTC.InstrumentConfiguration

@testset "reciprocal settings transform validates Float32 conversion" begin
    entry = Dict("transform" => "reciprocal")
    @test IC.transform(2, entry) === 0.5f0
    @test IC.transform(3.0, entry) === inv(3f0)
    @test IC.transform(floatmax(Float32), entry) === inv(floatmax(Float32))
    for value in (0, -1, true, false, Inf, -Inf, NaN, "2", nothing,
            1e-50, 1e50, nextfloat(0f0))
        @test_throws ArgumentError IC.transform(value, entry)
    end
end

@testset "reciprocal setting binds calibrated conversion into both graph modes" begin
    configured = Dict("profile" => "basic", "adc" => Dict("electrons_per_adu" => 2.5))
    binding = Dict("setting" => "adc.electrons_per_adu", "nodes" => ["frame_layout"],
        "config" => "scale", "transform" => "reciprocal")
    profiles = Dict("basic" => Dict("nodes" => [], "parameters" => []))
    document = Dict("profiles" => profiles, "settings_bindings" => [binding])
    graph = Dict("name" => "camera", "nodes" => [Dict("name" => "frame_layout",
        "config" => Dict("scale" => 0.0, "bias" => 100.0))])
    instrument = (;document=Dict("deformable_mirrors" => Dict(), "wavefront_sensors" => Dict()))
    declaration = (;document, instrument,
        graphs=Dict("production" => graph, "calibration" => deepcopy(graph)))

    @test IC._validate_settings_bindings([binding], profiles, configured, Dict(), Set(["frame_layout"])) === nothing
    for calibration in (false, true)
        resolved = IC.graph_document(declaration, configured; calibration)
        config = only(resolved["nodes"])["config"]
        @test config["scale"] == inv(2.5f0)
        @test config["bias"] == 100.0
        @test only(declaration.graphs[calibration ? "calibration" : "production"]["nodes"])["config"]["scale"] == 0.0
    end
    for transform in ("identity", "reciprocal")
        invalid = merge(binding, Dict("transform" => transform, "coupling" => 0.35))
        @test_throws ArgumentError IC._validate_settings_bindings([invalid], profiles, configured, Dict(), Set(["frame_layout"]))
    end
    gaussian = merge(binding, Dict("transform" => "gaussian_width", "coupling" => 0.35))
    @test IC._validate_settings_bindings([gaussian], profiles, configured, Dict(), Set(["frame_layout"])) === nothing
end
