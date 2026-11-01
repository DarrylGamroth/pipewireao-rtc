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
        delete!(document, "command_acquisition_version")
        delete!(document, "command_buffers")
        PipeWireAORTC.Common.write_json(path, document)
        cpu = PipeWireAORTC.AOSOwner.configuration(path)
        @test cpu.command_buffers == 3
        @test !cpu.sensor_buffer_properties
        document["sensor_buffer_properties"] = true
        PipeWireAORTC.Common.write_json(path,document)
        @test PipeWireAORTC.AOSOwner.configuration(path) == merge(cpu,(;sensor_buffer_properties=true))
        for invalid in (1,"true",nothing)
            document["sensor_buffer_properties"] = invalid
            PipeWireAORTC.Common.write_json(path,document)
            @test_throws ArgumentError PipeWireAORTC.AOSOwner.configuration(path)
        end
        delete!(document,"sensor_buffer_properties")
        original_sensor_versions = get(document,"sensor_acquisition_versions",nothing)
        sensor_name = first(keys(cpu.sensor_acquisition_versions))
        document["sensor_acquisition_versions"] = Dict(string(sensor_name)=>3)
        PipeWireAORTC.Common.write_json(path,document)
        selected = PipeWireAORTC.AOSOwner.configuration(path)
        @test getproperty(selected.sensor_acquisition_versions,sensor_name) == 3
        @test selected.sensor_acquisition_versions == merge(cpu.sensor_acquisition_versions,NamedTuple{(sensor_name,)}((3,)))
        invalid_versions = [Dict("unknown"=>3),Dict(string(sensor_name)=>true)]
        isempty(cpu.plant.chopping) || push!(invalid_versions,Dict(string(first(keys(cpu.plant.chopping)))=>2))
        for versions in invalid_versions
            document["sensor_acquisition_versions"] = versions
            PipeWireAORTC.Common.write_json(path,document)
            @test_throws ArgumentError PipeWireAORTC.AOSOwner.configuration(path)
        end
        if original_sensor_versions === nothing
            delete!(document,"sensor_acquisition_versions")
        else
            document["sensor_acquisition_versions"] = original_sensor_versions
        end
        document["command_buffers"] = 3
        PipeWireAORTC.Common.write_json(path, document)
        @test PipeWireAORTC.AOSOwner.configuration(path) == cpu
        for buffers in (2, 64)
            document["command_buffers"] = buffers
            PipeWireAORTC.Common.write_json(path, document)
            @test PipeWireAORTC.AOSOwner.configuration(path) == merge(cpu, (; command_buffers=buffers))
        end
        for buffers in (1, 65, nothing, true, "3", 3.0)
            document["command_buffers"] = buffers
            PipeWireAORTC.Common.write_json(path, document)
            @test_throws ArgumentError PipeWireAORTC.AOSOwner.configuration(path)
        end
        delete!(document, "command_buffers")
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
        for device in (0, 1)
            document["backend"] = "cuda"
            document["device"] = device
            PipeWireAORTC.Common.write_json(path, document)
            @test PipeWireAORTC.AOSOwner.configuration(path) == merge(cpu, (; backend=:cuda, device))
        end
        for (backend, device) in (("unknown", 0),
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

# Transport construction remains cold: no graph preparation, GPU import or core.
using AdaptiveOpticsSim, AdaptiveOpticsSimPipeWireHIL
@testset "clocked command transport uses the resolved buffer contract" begin
    options = PipeWireAORTC.AOSOwner.configuration(abspath(only(ARGS)))
    owner = Base.get_extension(PipeWireAORTC, :PipeWireAORTCAOSExt).ExternalPupilOwner
    @test options.command_buffers == 3
    @test owner.clocked_command_option(options).buffers == 3
    for buffers in (2, 64)
        selected = merge(options, (; command_buffers=buffers))
        transport = owner.clocked_command_option(selected)
        @test transport.buffers == buffers
        @test transport.acquisition_version == selected.command_acquisition_version
    end
    @test !any(id -> id.name in ("Proper", "CUDA", "AMDGPU"), keys(Base.loaded_modules))
end
