# Optional cold admission check using a real built clocked optical application.
# julia --project=/path/to/science-environment test/clocked_backend_configuration.jl /path/to/application/simulation.conf
using Test, PipeWireAORTC

@testset "clocked optical backend configuration" begin
    length(ARGS) == 1 || error("supply a built clocked optical simulation.conf")
    source = abspath(only(ARGS))
    mktempdir() do directory
        application = joinpath(directory, "application")
        cp(dirname(source), application)
        path = joinpath(application, basename(source))
        document = PipeWireAORTC.DeploymentConfiguration.decode(path, get(ENV, "PIPEWIREAO_PREFIX", "/opt/pipewireao"))
        @test document["version"] == 6
        document["backend"] = "cpu"
        document["device"] = 0
        PipeWireAORTC.Common.write_json(path, document)
        cpu = PipeWireAORTC.AOSOwner.configuration(path)
        @test cpu.command_acquisition_version == 2
        document["command_acquisition_version"] = 2
        PipeWireAORTC.Common.write_json(path, document)
        @test PipeWireAORTC.AOSOwner.configuration(path) == cpu
        document["command_acquisition_version"] = 3
        PipeWireAORTC.Common.write_json(path, document)
        @test PipeWireAORTC.AOSOwner.configuration(path) == merge(cpu, (; command_acquisition_version=3))
        for version in (1, 4, nothing, true, "3", 3.0)
            document["command_acquisition_version"] = version
            PipeWireAORTC.Common.write_json(path, document)
            @test_throws ArgumentError PipeWireAORTC.AOSOwner.configuration(path)
        end
        delete!(document, "command_acquisition_version")
        document["backend"] = "amdgpu"
        document["device"] = 1
        PipeWireAORTC.Common.write_json(path, document)
        amd = PipeWireAORTC.AOSOwner.configuration(path)
        @test amd == merge(cpu, (; backend=:amdgpu, device=1))
        for (backend, device) in (("cuda", 0), ("cuda", 1), ("unknown", 0),
                ("amdgpu", 0), ("amdgpu", -1), ("cpu", 1),
                ("amdgpu", true), ("amdgpu", "1"), ("amdgpu", nothing))
            document["backend"] = backend
            document["device"] = device
            PipeWireAORTC.Common.write_json(path, document)
            @test_throws ArgumentError PipeWireAORTC.AOSOwner.configuration(path)
        end
        @test !any(id -> id.name in ("Proper", "CUDA", "AMDGPU"), keys(Base.loaded_modules))
    end
end
