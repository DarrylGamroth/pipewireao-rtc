# Optional cold CPU selector; requires RTC, AOS, and AOS HIL.
module AOSPupilBindingsTests

using Test, PipeWireAORTC, AdaptiveOpticsSim, AdaptiveOpticsSimPipeWireHIL

const IC = PipeWireAORTC.InstrumentConfiguration

@testset "Configured pupil bindings resolve literal, setting, and JSON Pointer extents" begin
    telescope = Dict("telescope_diameter_m" => 8.0,
        "central_obstruction_ratio" => 0.25, "pupil_reflectivity" => 0.7,
        "aperture_revision" => 1)
    physical = Dict("deformable_mirrors" => Dict(), "wavefront_sensors" => Dict(),
        "telescope" => telescope)
    declaration = (;directory=@__DIR__, instrument=(;document=physical),
        document=Dict("frame_period_s" => 0.001))
    configured = Dict("pupil_resolution" => 8)
    schema = Dict("properties" => Dict("pupil_resolution" => Dict("type" => "integer")))
    reference = Dict("\$ref" => "/settings/pupil_resolution")
    coordinates = Float32[-7, -5, -3, -1, 1, 3, 5, 7] ./ 8f0
    expected_support = [0.25f0^2 <= x^2 + y^2 <= 1f0
        for x in coordinates, y in coordinates]

    for kind in ("pupil_coordinates", "pupil_support")
        for resolution in (8, "pupil_resolution", reference)
            binding = Dict("kind" => kind, "resolution" => resolution)
            @test IC._validate_bindings(Dict("pupil" => binding), Dict(), configured,
                schema, Dict(), @__DIR__) === nothing
            prepared = IC.binding_values(declaration, configured, binding)
            if kind == "pupil_coordinates"
                @test size(prepared) == (8, 8, 2)
                @test eltype(prepared) === Float32
                # First array axis is normalized x; second is normalized y.
                @test prepared[:, :, 1] == [x for x in coordinates, y in coordinates]
                @test prepared[:, :, 2] == [y for x in coordinates, y in coordinates]
            else
                @test size(prepared) == (8, 8)
                @test eltype(prepared) === Bool
                @test prepared == expected_support
            end
        end
        for invalid in (true, 0, -1, 100_000, BigInt(typemax(Int)) + 1)
            for resolution in (invalid, "pupil_resolution", reference)
                binding = Dict("kind" => kind, "resolution" => resolution)
                @test_throws ArgumentError IC.binding_values(declaration,
                    Dict("pupil_resolution" => invalid), binding)
            end
        end
        for resolution in (true, 0, -1)
            binding = Dict("kind" => kind, "resolution" => resolution)
            @test_throws ArgumentError IC._validate_bindings(Dict("pupil" => binding),
                Dict(), configured, schema, Dict(), @__DIR__)
        end
        for binding in (Dict("kind" => kind),
                Dict("kind" => kind, "resolution" => 8, "type" => "Float32"))
            @test_throws ArgumentError IC._validate_bindings(Dict("pupil" => binding),
                Dict(), configured, schema, Dict(), @__DIR__)
        end
    end
    @test !any(id -> id.name in ("CUDA", "AMDGPU"), keys(Base.loaded_modules))
end

end
