# Offline arithmetic audit of checked-in HEART data; no device or RTC is opened.
using JSON, SHA, Test, YAML

function read_csv(path)
    lines = filter(!isempty, strip.(readlines(path)))
    header = split(first(lines))
    rows, columns, planes = parse.(Int, header[1:3])
    @test planes == 1
    @test length(lines) == rows + 1
    values = [parse.(Float64, split(line, ',')) for line in lines[2:end]]
    @test all(length(row) == columns for row in values)
    matrix = reduce(vcat, permutedims.(values))
    @test all(isfinite, matrix)
    return matrix
end

function main(heart, core, instrument, output)
    heart, core, instrument = abspath.((heart, core, instrument))
    hashes = Dict{String,String}()
    function load(name; directory="source/template/config/handlers")
        relative = joinpath(directory, name * ".csv")
        path = joinpath(heart, relative)
        hashes[relative] = bytes2hex(sha256(read(path)))
        return read_csv(path)
    end
    coefficients = Dict(name => load(name * suffix) for (name, suffix) in
        (("wfr", "PhaseToVoltsCoeff"), ("twt", "PhaseToVoltsCoeff"), ("tt", "AngleToVoltsCoeff")))
    volts = Dict(name => load(name * "MinMaxVolts") for name in ("wfr", "twt", "tt"))
    for name in ("wfr", "twt", "tt")
        @test load(name * (name == "tt" ? "AngleToVoltsCoeff" : "PhaseToVoltsCoeff");
            directory="source/devices/config") == coefficients[name]
        @test load(name * "MinMaxVolts"; directory="source/devices/config") == volts[name]
        @test all(volts[name][1, :] .<= volts[name][2, :])
    end
    @test size(coefficients["wfr"]) == (3, 97)
    @test size(coefficients["twt"]) == (3, 2304)
    @test size(coefficients["tt"]) == (2, 2)
    wfr, twt, tt = coefficients["wfr"], coefficients["twt"], coefficients["tt"]
    # The woofer loader inverts its linear calibration; c₂ is not used.
    @test all(wfr[3, :] .== 0)
    wfr_endpoints = [wfr[1, i] + wfr[2, i] * volts["wfr"][j, i] for j in 1:2, i in 1:97]
    @test all(isapprox.(wfr_endpoints[1, :], 3.4))
    @test all(isapprox.(wfr_endpoints[2, :], -3.4))
    @test all(isapprox.((1 .- wfr[1, :]) ./ wfr[2, :], -100))
    # This follows the equal-voltage branch before evaluating the polynomial.
    disabled = findall(volts["twt"][1, :] .== volts["twt"][2, :])
    @test length(disabled) == 5
    twt_endpoints = [i in disabled ? 0.0 :
        evalpoly(volts["twt"][j, i], twt[:, i]) for j in 1:2, i in 1:2304]
    @test all(twt_endpoints[1, :] .<= twt_endpoints[2, :])
    @test all(twt_endpoints[:, disabled] .== 0)
    typical = findall(i -> isapprox(twt_endpoints[1, i], -1.07; atol=1e-6) &&
        isapprox(twt_endpoints[2, i], 1.07; atol=1e-6), 1:2304)
    @test length(typical) == 2297
    special = setdiff(collect(1:2304), union(typical, disabled))
    @test special .- 1 == [879, 1656]
    tt_endpoints = [tt[1, i] + tt[2, i] * volts["tt"][j, i] for j in 1:2, i in 1:2]
    @test tt_endpoints == [-1820.0 -1820.0; 1820.0 1820.0]
    slew, initial = load("wfrSlewRateClipping"), load("wfrInitialDisplacement")
    @test size(slew) == size(initial) == (97, 1)
    @test all(slew .== 0.2378)
    @test all(initial .== 3.4)
    @test isapprox(1948 / 81.919 * 0.01, 0.2378; atol=1e-5)
    # Independently verify the configured crop and its 1-based hardware centre.
    driver = read(joinpath(heart, "source/devices/src/dpioTweeterHandler.c"), String)
    xoffset = parse(Int, match(r"static const int xOffset = (\d+);", driver)[1])
    yoffset = parse(Int, match(r"static const int yOffset = (\d+);", driver)[1])
    centre = [xoffset, yoffset] .+ (48 - 1) / 2 .+ 1
    @test centre == [35.5, 32.5]
    @test xoffset + 48 <= 64 && yoffset + 48 <= 64
    for relative in ("source/devices/src/dpioTweeterHandler.c", "source/devices/src/dpioWooferTTHandler.c",
            "source/template/config/gpi2config.yaml", "source/template/config/handlers/DPIO_config.yaml")
        hashes[relative] = bytes2hex(sha256(read(joinpath(heart, relative))))
    end
    # No package initialization, graph preparation, native core or GPU is needed.
    configuration = YAML.load_file(joinpath(instrument, "instrument.yaml"))
    diameter = configuration["telescope"]["telescope_diameter_m"]
    stage_bounds = YAML.load_file(joinpath(instrument, "calibration-recipe.yaml"))["tiptilt"]["command_limits_m"]
    @test stage_bounds[1] == -stage_bounds[2]
    current_stage_opd_m = stage_bounds[2]
    mas_per_rad = 180 / pi * 3600 * 1000
    equivalent_sky_mas = current_stage_opd_m / (diameter / 2) * mas_per_rad
    @test isapprox(equivalent_sky_mas, 53.0932; atol=0.001)
    for (count, shape) in ((97, (11, 11)), (2304, (48, 48)))
        map = load("dmActuatorMap_$count"; directory="source/template/config")
        @test size(map) == shape
        @test length(filter(>(0), vec(map))) == count
        @test Set(filter(>(0), vec(map))) == Set(1:count)
    end
    report = Dict(
        "scope" => "Float64 arithmetic on checked-in files, not deployed calibration, C-driver execution or hardware validation",
        "heart_commit" => strip(read(`git -C $heart rev-parse HEAD`, String)),
        "heart_core_commit" => strip(read(`git -C $core rev-parse HEAD`, String)),
        "heart_units_sha256" => bytes2hex(sha256(read(joinpath(core, "doc/hrtUnits.dox")))),
        "heart_documented_dm_units" => "microns of wavefront; logical RTC conversion to metres OPD is 1e-6",
        "source_sha256" => hashes,
        "instrument_sha256" => Dict(path=>bytes2hex(sha256(read(joinpath(instrument, path))))
            for path in ("instrument.yaml", "calibration-recipe.yaml", "rtc/mirror-controls.yaml")),
        "pupil_registration" => Dict(name=>Dict("actuator_pitch_pupil_radius"=>
            entry["pupil_registration"]["actuator_pitch_pupil_radius"],
            "pitches_across_pupil_diameter"=>2 / entry["pupil_registration"]["actuator_pitch_pupil_radius"])
            for (name, entry) in configuration["deformable_mirrors"]),
        "woofer" => Dict("channels"=>97, "phase_endpoint_at_min_voltage_um"=>wfr_endpoints[1, 1],
            "phase_endpoint_at_max_voltage_um"=>wfr_endpoints[2, 1], "volts_for_positive_one_phase_um"=>-100,
            "configured_upstream_slew_per_update"=>only(unique(slew)),
            "driver_slew_phase_um_per_call"=>1948 / 81.919 * 0.01),
        "tweeter" => Dict("channels"=>2304, "typical_channels"=>length(typical),
            "typical_phase_limits_um"=>twt_endpoints[:, first(typical)],
            "equal_voltage_channels_zero_based"=>disabled .- 1,
            "special_channels"=>[Dict("zero_based_channel"=>i-1, "volts"=>volts["twt"][:, i],
                "phase_limits_um"=>twt_endpoints[:, i]) for i in special],
            "physical_grid_shape"=>[64, 64], "command_grid_shape"=>[48, 48],
            "hardware_crop_origin_zero_based"=>[xoffset, yoffset], "hardware_crop_centre_one_based"=>centre),
        "tiptilt" => Dict("driver_angle_limits_mas"=>tt_endpoints[:, 1],
            "current_simulation_coefficient_limit_opd_m"=>current_stage_opd_m,
            "current_simulation_equivalent_sky_mas"=>equivalent_sky_mas,
            "conditional_coefficient_for_1820_sky_mas_opd_m"=>1820 / mas_per_rad * diameter / 2),
        "unresolved" => ["physical provenance of legacy calibration coefficients and compliance with documented wavefront convention", "TT mas mechanical versus sky angle",
            "actual deployed calibration file identity", "external upstream woofer clipping and flat files",
            "current GPI2 pupil registration and calibrated controlled/slaved actuator mask"])
    open(output, "w") do io
        write(io, JSON.json(report; pretty=2), '\n')
    end
end

length(ARGS) == 4 || error("usage: check-calibration.jl GPI2_HEART_CHECKOUT HEART_CORE_CHECKOUT INSTRUMENT OUTPUT_JSON")
@testset "GPI checked-in calibration arithmetic and crop registration" begin
    main(ARGS...)
end
