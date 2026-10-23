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
        default_registration = (; actuator_pitch_pupil_radius=0.125)
        @test_throws ArgumentError IC._pupil_registration((;actuator_pitch=0.125))
        mechanical = mirror_document()
        mechanical["actuator_pitch_m"] = 0.0015
        mechanical["actuator_pitch_provenance"] = "nominal synthetic specification"
        with_pitch = write_mirror(path,mechanical)
        @test with_pitch.actuator_pitch_m == 0.0015
        @test IC.actuator_coordinates(with_pitch; pupil_registration=default_registration) ==
            IC.actuator_coordinates(description; pupil_registration=default_registration)
        for pitch in (0, -1, Inf, NaN, true, "0.0015", nothing)
            invalid = deepcopy(mechanical)
            invalid["actuator_pitch_m"] = pitch
            @test_throws Exception write_mirror(path,invalid)
        end
        for key in ("actuator_pitch_m", "actuator_pitch_provenance")
            invalid = deepcopy(mechanical)
            delete!(invalid,key)
            @test_throws ArgumentError write_mirror(path,invalid)
        end
        for provenance in ("", " ", nothing, repeat("x",4097))
            invalid = deepcopy(mechanical)
            invalid["actuator_pitch_provenance"] = provenance
            @test_throws ArgumentError write_mirror(path,invalid)
        end
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
            pupil_registration=(; actuator_pitch_pupil_radius=0.2))
        @test registered[:, 1] ≈ [0.1, -0.3]
        @test_throws ArgumentError IC._pupil_registration((; actuator_pitch_pupil_radius=0))
        @test_throws ArgumentError IC._pupil_registration((; actuator_pitch_pupil_radius=NaN))
        @test_throws ArgumentError IC._pupil_registration((; actuator_pitch_pupil_radius=1e-100))
        @test_throws ArgumentError IC._pupil_registration((; actuator_pitch_pupil_radius=0.1, extra=1))
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

@testset "YAML mirror authoring preserves physical geometry" begin
    mktempdir() do directory
        document = mirror_document()
        document["actuator_pitch_m"] = 0.0015
        document["actuator_pitch_provenance"] = "Nominal synthetic specification; no metrology claim."
        json_path = joinpath(directory, "mirror.json")
        baseline = write_mirror(json_path, document)
        registration = (; actuator_pitch_pupil_radius=0.125)
        for suffix in (".yaml", ".yml")
            path = joinpath(directory, "mirror" * suffix)
            PipeWireAORTC.Common.write_yaml(path, document)
            description = IC.read_mirror_description(path)
            @test IC.json_value(description) == IC.json_value(baseline)
            @test description.layout.command_positions == baseline.layout.command_positions
            @test description.layout.provenance == baseline.layout.provenance
            @test description.actuator_pitch_provenance == baseline.actuator_pitch_provenance
            @test IC.actuator_coordinates(description; pupil_registration=registration) ==
                IC.actuator_coordinates(baseline; pupil_registration=registration)
            @test IC.source_grid_coordinates(description) == IC.source_grid_coordinates(baseline)
        end
    end
end

@testset "bounded YAML mirror authoring rejects invalid descriptions" begin
    mktempdir() do directory
        path = joinpath(directory, "mirror.yaml")
        for change in (
            d -> (d["unknown"] = 1),
            d -> (d["pupil_registration"] = Dict("actuator_pitch_pupil_radius" => 0.125)),
            d -> (d["layout"]["unknown"] = true),
            d -> (d["layout"]["command_positions"] = [[3, 4], [3, 4]]),
            d -> (d["layout"]["command_positions"] = [[5, 4]]),
            d -> (d["layout"]["command_positions"] = Any[Any[true, 4]]),
            d -> (d["layout"]["grid_shape"] = [4097, 4]),
            d -> (d["actuator_pitch_m"] = 0.0015),
        )
            invalid = mirror_document()
            change(invalid)
            PipeWireAORTC.Common.write_yaml(path, invalid)
            @test_throws ArgumentError IC.read_mirror_description(path)
        end
        PipeWireAORTC.Common.write_yaml(path, mirror_document())
        yaml = read(path, String)
        for suffix in ("model: duplicate\n", "unknown: .inf\n", "unknown: .nan\n",
                "---\nschema_version: 1\n", "1: integer key\n")
            write(path, yaml * suffix)
            @test_throws ArgumentError IC.read_mirror_description(path)
        end
        # A comment can reach the byte limit without changing scientific values.
        at_limit = yaml * "#" * repeat("x", 64 * 1024 - ncodeunits(yaml) - 1)
        write(path, at_limit)
        @test IC.command_count(IC.read_mirror_description(path)) == 3
        write(path, at_limit * "x")
        @test_throws ArgumentError IC.read_mirror_description(path)
        # YAML aliases must not bypass the native JSON description byte limit.
        expanded = """
        schema_version: 1
        id: &text $(repeat("x", 16000))
        model: *text
        manufacturer: *text
        layout:
          schema_version: 1
          name: *text
          command_order: *text
          provenance: *text
          grid_shape: [4, 4]
          axis_labels: [source column, source row]
          command_positions: [[3, 4], [2, 2], [4, 1]]
        """
        write(path, expanded)
        @test ncodeunits(expanded) < 64 * 1024
        @test_throws ArgumentError IC.read_mirror_description(path)
        write(path, UInt8[0xff, 0xfe])
        @test_throws Exception IC.read_mirror_description(path)
    end
end
