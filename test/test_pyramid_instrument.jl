using Test, PipeWireAORTC

const IC = PipeWireAORTC.InstrumentConfiguration
const C = PipeWireAORTC.Common
const F = PipeWireAORTC.Artifacts.FITSIO

function pyramid_sensor(; detector=[242, 240], pupil=[60, 60], separation=[60, 60], edge=[30, 30])
    return Dict{String,Any}("kind" => "pyramid", "detector_shape" => detector,
        "pupil_shape" => pupil, "pupil_separation_pixels" => separation,
        "pupil_edge_pixels" => edge, "expected_schema" => "example.pyramid-frame/1")
end

@testset "pyramid physical sensor geometry" begin
    mktempdir() do directory
        sensor = pyramid_sensor()
        authored = deepcopy(sensor)
        @test IC._validate_sensor_declaration(sensor, directory, "pyramid") === nothing
        @test sensor == authored
        @test IC.sensor_layout((;directory), sensor) ==
            (;kind="pyramid", detector_shape=(242, 240), pupil_shape=(60, 60),
                pupil_origins=((30, 30), (150, 30), (30, 150), (150, 150)))
        @test isempty(readdir(directory))
        rectangular = pyramid_sensor(;detector=[25, 38], pupil=[7, 11], separation=[5, 8], edge=[6, 8])
        @test IC._validate_sensor_declaration(rectangular, directory, "rectangular") === nothing
        @test IC.sensor_layout((;directory), rectangular).pupil_origins ==
            ((6, 8), (18, 8), (6, 27), (18, 27))
        # The far pupil may end exactly at the detector boundary.
        tight = pyramid_sensor(;detector=[2, 2], pupil=[1, 1], separation=[0, 0], edge=[0, 0])
        @test IC._validate_sensor_declaration(tight, directory, "tight") === nothing
        @test IC.sensor_layout((;directory), tight).pupil_origins == ((0, 0), (1, 0), (0, 1), (1, 1))
        large = pyramid_sensor(;detector=[typemax(Int), 2], pupil=[1, 1],
            separation=[typemax(Int) - 2, 0], edge=[0, 0])
        @test IC._validate_sensor_declaration(large, directory, "large") === nothing
        @test IC.sensor_layout((;directory), large).pupil_origins[4] == (typemax(Int) - 1, 1)
        sensor["acquisition"] = Dict("roi_origin" => [5, 9], "exposure_duration_s" => 0.001)
        @test IC._validate_sensor_declaration(sensor, directory, "pyramid") === nothing
        for key in ("detector_shape", "pupil_shape", "pupil_separation_pixels", "pupil_edge_pixels")
            for value in (Any[true, 1], [1.0, 1], [1], [1, 2, 3], 1, "1,2", [-1, 1],
                    [BigInt(typemax(Int)) + 1, 1])
                invalid = pyramid_sensor()
                invalid[key] = value
                @test_throws ArgumentError IC._validate_sensor_declaration(invalid, directory, "invalid")
            end
        end
        for key in ("detector_shape", "pupil_shape")
            invalid = pyramid_sensor()
            invalid[key] = [0, 60]
            @test_throws ArgumentError IC._validate_sensor_declaration(invalid, directory, "zero")
        end
        for sensor in (pyramid_sensor(;detector=[209, 240]), pyramid_sensor(;detector=[242, 209]),
                pyramid_sensor(;pupil=[typemax(Int), 60]),
                pyramid_sensor(;edge=[typemax(Int), 30]),
                pyramid_sensor(;separation=[typemax(Int), 60]),
                pyramid_sensor(;detector=[typemax(Int), typemax(Int)],
                    pupil=[typemax(Int) ÷ 2 + 1, 1], edge=[0, 0], separation=[0, 0]))
            @test_throws ArgumentError IC._validate_sensor_declaration(sensor, directory, "extent")
        end
        for (key, value) in (("kind", "unknown"), ("kind", true), ("expected_schema", ""),
                ("subaperture_origins", Dict()), ("optical_prescription", Dict()),
                ("pupil_origin", [30, 30]), ("acquisition", Dict("roi_origin" => Any[true, 1],
                    "exposure_duration_s" => 0.001)))
            invalid = pyramid_sensor()
            invalid[key] = value
            @test_throws ArgumentError IC._validate_sensor_declaration(invalid, directory, "invalid")
        end
        for key in keys(pyramid_sensor())
            invalid = pyramid_sensor()
            delete!(invalid, key)
            @test_throws ArgumentError IC._validate_sensor_declaration(invalid, directory, "missing")
        end
    end
end

@testset "legacy Shack-Hartmann metadata remains unchanged" begin
    mktempdir() do directory
        F.FITS(joinpath(directory, "origins.fits"), "w") do fits
            write(fits, Int32[0 0; 2 3])
        end
        sensor = Dict{String,Any}("detector_shape" => [4, 6], "subaperture_shape" => [2, 3],
            "subaperture_origins" => Dict("path" => "origins.fits", "hdu" => 1,
                "axes" => [1, 2], "type" => "Int32", "shape" => [2, 2]),
            "expected_schema" => "example.sh-frame/1")
        path = joinpath(directory, "sensor.yaml")
        C.write_yaml(path, sensor)
        bytes = read(path)
        authored = deepcopy(sensor)
        layout = (;detector_shape=(4, 6), subaperture_shape=(2, 3), subaperture_origins=((0, 0), (2, 3)))
        @test IC._validate_sensor_declaration(sensor, directory, "sh") === nothing
        @test IC.sensor_layout((;directory), sensor) === layout
        @test sensor == authored
        @test read(path) == bytes
        explicit = merge(sensor, Dict("kind" => "shack_hartmann"))
        @test IC._validate_sensor_declaration(explicit, directory, "sh") === nothing
        @test IC.sensor_layout((;directory), explicit) === layout
        invalid = merge(sensor, Dict("pupil_shape" => [1, 1]))
        @test_throws ArgumentError IC._validate_sensor_declaration(invalid, directory, "sh")

        # A mixed instrument hashes the SH artifact without inventing a pyramid artifact.
        instrument = (;document=Dict("deformable_mirrors" => Dict(),
            "wavefront_sensors" => Dict("sh" => sensor, "pyramid" => pyramid_sensor())))
        graph = Dict("name" => "empty", "nodes" => [])
        document = Dict("profiles" => Dict("test" => Dict("nodes" => [], "parameters" => [])),
            "settings_bindings" => [], "bindings" => Dict())
        declaration = (;directory, instrument, document,
            graphs=Dict("production" => graph, "calibration" => graph))
        @test IC.artifact_paths(declaration, Dict("profile" => "test")) == Set(["origins.fits"])
    end
    @test !any(id -> id.name in ("AdaptiveOpticsSim", "AdaptiveOpticsSimPipeWireHIL",
        "FilterGraphIsland", "JuliaFilterGraph", "CUDA", "AMDGPU"), keys(Base.loaded_modules))
end
