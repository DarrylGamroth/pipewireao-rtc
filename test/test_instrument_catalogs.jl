using Test, PipeWireAORTC

const IC = PipeWireAORTC.InstrumentConfiguration

@testset "shared scientific basis definitions" begin
    first = Dict{String,Any}("id" => "engineering", "template" => "zernike",
        "name" => "Engineering shapes", "units" => "µm OPD", "coefficient_limit" => 0.05)
    second = Dict{String,Any}("id" => "alignment", "template" => "zernike",
        "name" => "Alignment", "units" => "m", "coefficient_limit" => 2e-8)
    resolved = IC.resolve_basis_definition(first)
    other = IC.resolve_basis_definition(second)
    @test resolved["definition"] == other["definition"]
    @test resolved["id"] == "engineering" && other["id"] == "alignment"
    @test resolved["units"] == "µm OPD" && other["units"] == "m"
    @test resolved["coefficient_limit"] == 0.05 && other["coefficient_limit"] == 2e-8
    @test resolved["normalization"] == "sampled_peak"
    @test [(mode["n"], mode["m"]) for mode in resolved["definition"]["modes"]] ==
        [(0,0), (1,1), (1,-1), (2,0), (2,-2), (2,2), (3,1), (3,-1), (4,0)]
    @test [mode["name"] for mode in resolved["definition"]["modes"]] ==
        ["Piston", "Tip", "Tilt", "Defocus", "Astigmatism x/y", "Astigmatism axes", "Coma x", "Coma y", "Spherical"]
    @test !haskey(first, "definition") && !haskey(resolved, "template")
    resolved["definition"]["modes"][1]["name"] = "Changed"
    @test other["definition"]["modes"][1]["name"] == "Piston"
    @test IC.resolve_basis_definition(first)["definition"]["modes"][1]["name"] == "Piston"

    selected = deepcopy(first)
    selected["definition"] = Dict("modes" => [Dict("n" => 2, "m" => 0, "name" => "Defocus")])
    @test IC.resolve_basis_definition(selected)["definition"]["modes"] == selected["definition"]["modes"]
    fourier = merge(first, Dict("template" => "fourier"))
    @test IC.resolve_basis_definition(fourier)["definition"] == Dict("kind" => "fourier", "max_frequency" => 7)
    @test IC.resolve_basis_definition(fourier)["normalization"] == "sampled_rms"
    fourier["definition"] = Dict("max_frequency" => 3)
    @test IC.resolve_basis_definition(fourier)["definition"]["max_frequency"] == 3
    @test !haskey(IC.catalog_document("bases", "zernike"), "units")
    @test !haskey(IC.catalog_document("bases", "fourier"), "coefficient_limit")

    for invalid in (merge(first, Dict("template" => "unknown")),
            merge(first, Dict("template" => "../zernike")),
            merge(first, Dict("source" => "zernike")),
            merge(first, Dict("normalization" => "sampled_rms")),
            merge(first, Dict("definition" => Dict("kind" => "fourier"))),
            merge(first, Dict("definition" => Dict("max_frequency" => 2))),
            merge(fourier, Dict("definition" => Dict("max_frequency" => true))))
        @test_throws ArgumentError IC.resolve_basis_definition(invalid)
    end

    sampled = Dict{String,Any}("id" => "measured", "name" => "Measured modes", "units" => "m",
        "coefficient_limit" => 1e-7, "normalization" => "supplied", "provenance" => "Measured modal commands",
        "definition" => Dict("kind" => "sampled", "command_order" => "mirror", "names" => ["Mode 1"],
            "artifact" => Dict("path" => "calibration/modes.fits", "hdu" => 1,
                "axes" => [1,2], "type" => "Float32", "shape" => [2,1])))
    @test IC.resolve_basis_definition(sampled) == sampled
    copy = IC.resolve_basis_definition(sampled)
    copy["definition"]["artifact"]["shape"][1] = 4
    @test sampled["definition"]["artifact"]["shape"] == [2,1]
    invalid = deepcopy(sampled)
    invalid["definition"]["artifact"]["source"] = "elsewhere"
    @test_throws ArgumentError IC.resolve_basis_definition(invalid)
end

@testset "shared simulator settings schema" begin
    selection = Dict{String,Any}("template" => "atmosphere", "title" => "First instrument",
        "description" => "Prepared simulator settings")
    schema = IC.resolve_settings_schema(selection)
    second = IC.resolve_settings_schema(merge(selection, Dict("title" => "Second instrument")))
    @test schema["title"] == "First instrument" && second["title"] == "Second instrument"
    @test schema["properties"] == second["properties"]
    @test !haskey(schema["properties"]["profile"], "enum")
    @test schema["properties"]["profile"]["readOnly"]
    @test schema["properties"]["pupil_resolution"]["readOnly"]
    atmosphere = schema["properties"]["atmosphere"]["properties"]
    @test atmosphere["reference_wavelength_m"]["x-display-scale"] == 1e9
    @test atmosphere["reference_wavelength_m"]["x-display-title"] == "Reference wavelength (nm)"
    @test atmosphere["layer_ids"]["uniqueItems"]
    @test atmosphere["rng_seed"]["minimum"] == 0
    @test Set(keys(atmosphere)) == Set(("r0", "reference_wavelength_m", "L0", "fractional_cn2",
        "wind_speed", "wind_direction_deg", "altitude", "layer_ids", "rng_seed"))
    atmosphere["r0"]["title"] = "Changed"
    @test second["properties"]["atmosphere"]["properties"]["r0"]["title"] == "Fried parameter r0 (m)"
    @test IC.resolve_settings_schema("atmosphere")["properties"] == second["properties"]

    augmented = merge(selection, Dict("properties" => Dict("gain" => Dict("type" => "number"))))
    @test IC.resolve_settings_schema(augmented)["properties"]["gain"] == Dict("type" => "number")
    @test !haskey(IC.resolve_settings_schema(selection)["properties"], "gain")
    inline = Dict("type" => "object", "properties" => Dict("gain" => Dict("type" => "number")))
    @test IC.resolve_settings_schema(inline) == inline
    measured = IC.resolve_settings_schema("measured_influences")["properties"]["influence_functions"]
    @test measured["readOnly"]
    @test Set(measured["required"]) == Set(("path", "hdu", "axes", "command_indices",
        "sample_origin", "sample_pitch", "opd_scale_m", "reference_command_m"))
    @test measured["properties"]["axes"]["uniqueItems"]
    @test measured["properties"]["command_indices"]["maxItems"] == 4096
    @test measured["properties"]["sample_pitch"]["items"]["exclusiveMinimum"] == 0
    measured["properties"]["axes"]["title"] = "Changed"
    @test IC.resolve_settings_schema("measured_influences")["properties"]["influence_functions"]["properties"]["axes"]["title"] ==
        "FITS axes (column, row, command)"
    for invalid in ("unknown", "../atmosphere", Dict("template" => "atmosphere", "source" => "elsewhere"),
            Dict("template" => "measured_influences", "source" => "elsewhere"),
            Dict("template" => "atmosphere", "properties" => Dict("gain" => Dict("type" => "unknown"))),
            Dict("type" => "object", "properties" => Dict("gain" => Dict("type" => "number", "source" => "elsewhere"))))
        @test_throws ArgumentError IC.resolve_settings_schema(invalid)
    end
end

@testset "inline profile properties do not collide with catalog selection" begin
    property = Dict("template"=>Dict("type"=>"string"))
    @test IC.resolve_profile_settings_schema(property) == property
    @test IC.resolve_profile_settings_schema(property) !== property
    @test haskey(IC.resolve_profile_settings_schema("measured_influences"),"influence_functions")
    @test_throws ArgumentError IC.resolve_profile_settings_schema(Dict("template"=>"unknown"))
end
