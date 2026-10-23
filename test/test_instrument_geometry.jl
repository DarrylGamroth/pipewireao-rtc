using Test, JSON, PipeWireAORTC

const IC = PipeWireAORTC.InstrumentConfiguration

function mirror_document(; id="generic-test-mirror", positions=[[3, 4], [2, 2], [4, 1]], shape=[4, 4])
    return Dict{String,Any}(
        "schema_version" => 1,
        "id" => id,
        "manufacturer" => "Example Instruments",
        "model" => "Test mirror",
        "layout" => Dict{String,Any}(
            "schema_version" => 1,
            "name" => "Generic test layout",
            "grid_shape" => shape,
            "axis_labels" => ["source column", "source row"],
            "command_positions" => positions,
            "command_order" => "listed physical command order",
            "provenance" => "synthetic test data",
        ),
    )
end

function write_mirror(path, document)
    write(path, JSON.json(document))
    return IC.read_mirror_description(path)
end

@testset "generic mirror descriptions and cold geometry" begin
    mktempdir() do directory
        path = joinpath(directory, "mirror.json")
        description = write_mirror(path, mirror_document())
        @test description isa NamedTuple
        @test description.layout.command_positions == ((3, 4), (2, 2), (4, 1))
        @test IC.command_count(description) == 3
        @test IC._mirror_axis_count(description) == 4
        @test IC.actuator_index_map(description) == UInt16[
            0 0 0 3
            0 2 0 0
            0 0 0 0
            0 0 1 0
        ]
        default_registration = (; actuator_pitch=0.125)
        @test IC.actuator_coordinates(description; pupil_registration=default_registration) == Float32[
            0.0625 -0.0625 0.1875
            -0.1875 0.0625 0.1875
        ]
        @test IC.actuator_grid_indices(description) == Int32[3, 10, 16]
        @test IC.source_grid_coordinates(description) == (
            zernike_positions=((0.25, 0.75), (-0.25, -0.25), (0.75, -0.75)),
            fourier_positions=((Float64(Float32(1 / 6)), Float64(Float32(1 / 2))),
                (Float64(Float32(-1 / 6)), Float64(Float32(-1 / 6))),
                (Float64(Float32(1 / 2)), Float64(Float32(-1 / 2)))),
        )
        singleton = merge(description,(;layout=merge(description.layout,
            (;grid_shape=(3,1),command_positions=((1,1),(2,1),(3,1))))))
        @test IC.source_grid_coordinates(singleton).fourier_positions == ((-0.5,0.0),(0.0,0.0),(0.5,0.0))
        basis = Dict("id"=>"fourier","name"=>"Fourier","units"=>"m","coefficient_limit"=>1.0,
            "normalization"=>"sampled_rms","provenance"=>"test source geometry",
            "definition"=>Dict("kind"=>"fourier","max_frequency"=>64))
        # A 3-point source axis has only the Nyquist frequency: do not publish
        # its identically-zero sine quadrature. Singleton axes carry no modes.
        @test_throws ArgumentError IC.resolve_basis(nothing,basis,singleton,IC.source_grid_coordinates(singleton))
        odd_grid = merge(description,(;layout=merge(description.layout,
            (;grid_shape=(5,1),command_positions=Tuple((i,1) for i in 1:5)))))
        resolved = IC.resolve_basis(nothing,basis,odd_grid,IC.source_grid_coordinates(odd_grid))
        @test resolved.definition.frequencies == ((1,0),)
        @test all(p -> p[2] == 0.0,resolved.definition.positions)
        large_grid = merge(description,(;layout=merge(description.layout,(;grid_shape=(65,65)))))
        @test_throws ArgumentError IC.resolve_basis(nothing,basis,large_grid,IC.source_grid_coordinates(large_grid))
        registered = IC.actuator_coordinates(description, Float64;
            pupil_registration=(; actuator_pitch=0.2))
        @test registered[:, 1] ≈ [0.1, -0.3]
        @test_throws ArgumentError IC._pupil_registration((; actuator_pitch=0))
        @test_throws ArgumentError IC._pupil_registration((; actuator_pitch=NaN))
        @test_throws ArgumentError IC._pupil_registration((; actuator_pitch=1e-100))
        @test_throws ArgumentError IC._pupil_registration((; actuator_pitch=0.1, extra=1))
        @test_throws ArgumentError IC._mirror_axis_count(merge(description,
            (; layout=merge(description.layout, (; grid_shape=(4, 3))))))

        # A 19 × 19 physical map with 277 positions checks command-order preservation.
        row_widths = (7, 9, 11, 13, 15, 17, 19, 19, 19, 19, 19, 19, 19,
            17, 15, 13, 11, 9, 7)
        positions = Tuple((column, row) for row in 19:-1:1 for width in (row_widths[row],)
            for column in ((20 - width) ÷ 2 + 1):((20 + width) ÷ 2))
        canonical = merge(description, (; layout=merge(description.layout,
            (; grid_shape=(19, 19), command_positions=positions))))
        @test IC.command_count(canonical) == 277
        @test IC.actuator_index_map(canonical)[19, 7:13] == UInt16.(1:7)
        @test IC.actuator_index_map(canonical)[1, 7:13] == UInt16.(271:277)
        @test IC.actuator_coordinates(canonical; pupil_registration=default_registration)[:, [1, 139, 277]] ==
            Float32[-0.375 0 0.375; -1.125 0 1.125]
    end
end

@testset "mirror description validation" begin
    mktempdir() do directory
        path = joinpath(directory, "mirror.json")
        for invalid in (
            mirror_document(; positions=[[3, 4], [3, 4]]),
            mirror_document(; positions=[[5, 4]]),
            mirror_document(; positions=[Any[true, 4]]),
            mirror_document(; positions=Any[]),
            mirror_document(; id=""),
        )
            write(path, JSON.json(invalid))
            @test_throws ArgumentError IC.read_mirror_description(path)
        end
        write(path, "{\"schema_version\":1,\"schema_version\":1}")
        @test_throws ArgumentError IC.read_mirror_description(path)
        write(path, JSON.json(mirror_document()))
        @test_throws ArgumentError IC.read_mirror_description(1)
        @test_throws ArgumentError IC.read_mirror_description(joinpath(directory, "missing.json"))
        write(path, repeat(" ", 64 * 1024 + 1))
        @test_throws ArgumentError IC.read_mirror_description(path)
    end
end
