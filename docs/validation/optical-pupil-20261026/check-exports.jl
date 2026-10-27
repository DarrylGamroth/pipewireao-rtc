using PipeWireAORTC, FilterGraphIsland, FilterGraphPipeWire, JuliaFilterGraph, JSON, Test
const E = PipeWireAORTC.InstrumentExport
const IC = PipeWireAORTC.InstrumentConfiguration
const C = PipeWireAORTC.Common
source,root = ARGS
mkpath(root)
@testset "real instrument optical pupil publication exports" begin
    for name in ("revolt-classic","gpi2")
        input = joinpath(source,name)
        files = ("instrument.yaml","rtc/configuration.yaml","rtc/mirror-controls.yaml")
        before = Dict(path=>C.sha256_file(joinpath(input,path)) for path in files)
        output = E.copy_source(input,joinpath(root,name))
        target = IC.prepare_publication(output)
        document = JSON.parsefile(target)
        @test document["schema_version"] == 2
        physical = IC.physical_definition(IC.load(joinpath(output,"instrument.yaml")))
        authoring = C.read_yaml(joinpath(output,"instrument.yaml"))
        for (name,dm) in document["deformable_mirrors"]
            author = authoring["deformable_mirrors"][name]
            @test dm["pupil"] == author["pupil"]
            @test IC.json_value(getproperty(physical.deformable_mirrors,Symbol(name)).pupil) == author["pupil"]
            @test length(dm["pupil_coordinates"]) == length(dm["layout"]["command_positions"])
            @test length(dm["shape_control"]["controlled_actuators"]) == length(dm["pupil_coordinates"])
            @test all(x->x isa Bool,dm["shape_control"]["controlled_actuators"])
        end
        @test all(C.sha256_file(joinpath(input,path)) == digest for (path,digest) in before)
        println("PUBLICATION ",target)
    end
end
@test !any(pkgid.name in ("CUDA","AMDGPU") for pkgid in keys(Base.loaded_modules))
println("JULIA ",VERSION," RTC ",pathof(PipeWireAORTC))
