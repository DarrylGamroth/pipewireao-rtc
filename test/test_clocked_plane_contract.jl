using Test, PipeWireAORTC
const Owner = PipeWireAORTC.AOSOwner
@testset "compiled and PROPER mirror plane contracts" begin
    geometry = Dict("telescope_diameter_m" => 0.033)
    grid = Dict(
        "size" => [128, 128],
        "axes" => [1, 2],
        "sampling_m" => fill(0.033 / 128, 2),
        "center_pixel" => [65, 65],
    )
    schema = "test/physical-opd/1"
    compiled = Dict(
        "type" => "compiled_optical_paths_f32",
        "config" => Dict("dm_grid" => grid, "dm_opd_schema" => schema),
    )
    proper = Dict(
        "type" => "proper_optical_train_f32",
        "config" => Dict(
            "steps" => [
                merge(
                    grid,
                    Dict("op" => "add_opd", "input" => "dm_opd", "schema" => schema),
                ),
            ],
        ),
    )
    @test Owner.verify_clocked_mirror_plane(compiled, geometry, schema, 128) === nothing
    @test Owner.verify_clocked_mirror_plane(proper, geometry, schema, 128) === nothing
    for (key, value) in (
        ("axes", [2, 1]),
        ("size", [64, 64]),
        ("sampling_m", [0.001, 0.001]),
        ("center_pixel", [64, 64]),
    )
        invalid = deepcopy(compiled)
        invalid["config"]["dm_grid"][key] = value
        @test_throws ArgumentError Owner.verify_clocked_mirror_plane(
            invalid, geometry, schema, 128
        )
    end
    invalid = deepcopy(compiled)
    invalid["config"]["dm_opd_schema"] = "wrong"
    @test_throws ArgumentError Owner.verify_clocked_mirror_plane(
        invalid, geometry, schema, 128
    )
end

Base.include(@__MODULE__, joinpath(@__DIR__, "external_optical_documents.jl"))
@testset "clocked optics admit the ordinary optional PROPER loader" begin
    mktempdir() do directory
        physical, simulation = external_optical_documents()
        physical["optical_paths"] = Dict(
            name => Dict("sensor" => name, "lyot_stop_port" => port) for
            (name, port) in (("scc", "transmitted"), ("llowfs", "reflected"))
        )
        simulation["graphs"]["source"] = deepcopy(simulation["graphs"]["scc"])
        path = write_external_optical_documents(directory, physical, simulation)
        options = (;
            version = 6,
            plant = (; definition = path, settings = NamedTuple(), chopping = NamedTuple()),
            source_graph = "source",
        )
        @test Owner.requires_proper(options)
        @test !any(id -> id.name in ("Proper", "CUDA", "AMDGPU"), keys(Base.loaded_modules))
    end
end
