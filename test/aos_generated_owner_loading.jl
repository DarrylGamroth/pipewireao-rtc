# Fresh-process CPU selector for a built version-3 generated HIL application.
# No science preload, native core, service or built-application mutation. The
# bootstrap boundary is injected; actual optional loaders and declaration
# verification remain the production path.
using Test, PipeWireAORTC

const Owner = PipeWireAORTC.AOSOwner
const IC = PipeWireAORTC.InstrumentConfiguration
loaded(name) = any(id -> id.name == name, keys(Base.loaded_modules))

@testset "generated HIL metadata precedes science, provenance precedes execution" begin
    length(ARGS) == 1 || throw(ArgumentError("usage: aos_generated_owner_loading.jl BUILT_VERSION_3_CONFIGURATION"))
    configuration = realpath(only(ARGS))
    @test all(!loaded, ("AdaptiveOpticsSim", "AdaptiveOpticsSimPipeWireHIL", "Proper", "CUDA", "AMDGPU"))
    options = Owner.configuration(configuration)
    @test options.version == 3
    @test options.backend === :cpu
    @test options.pupil_output
    @test Owner.requires_proper(options)
    @test all(!loaded, ("AdaptiveOpticsSim", "AdaptiveOpticsSimPipeWireHIL", "Proper"))
    # Full validation remains the loader default, and is unavailable cold.
    @test_throws ArgumentError IC.load_simulation(options.plant.definition)
    arguments = path -> ["--config", path, "--remote", "/tmp/aos-generated-preparation-only",
        "--control-node", "preparation-only-control", "--bootstrap-node", "preparation-only-bootstrap",
        "--bootstrap-instance", "7"]
    reached = Ref(false)
    with_owner = (f, admitted) -> begin
        @test all(!loaded, ("AdaptiveOpticsSim", "AdaptiveOpticsSimPipeWireHIL", "Proper"))
        f(merge(admitted, (; owner_check=() -> nothing)))
    end
    @test Owner._main(arguments(configuration); with_owner,
        load_cuda=() -> error("CPU selection must not load CUDA"),
        load_amdgpu=() -> error("CPU selection must not load AMDGPU"),
        run=admitted -> begin
            @test all(loaded, ("AdaptiveOpticsSim", "AdaptiveOpticsSimPipeWireHIL", "Proper"))
            # _main's actual invokelatest verification has admitted the real
            # generated declaration before handing it to execution.
            @test admitted.prescription_identity == options.prescription_identity
            aos = Base.require(Main, :AdaptiveOpticsSim)
            hil = Base.require(Main, :AdaptiveOpticsSimPipeWireHIL)
            system = Base.invokelatest(IC.prepare_system, admitted.plant.definition;
                settings=admitted.plant.settings, simulation_graph=admitted.plant.graph,
                target=aos.Backends.HostComputeDevice())
            @test system.target isa aos.Backends.HostComputeDevice
            @test size(hil.hil_frame_buffer(system.boundary)) == admitted.frame_shape
            @test IC.prescription_identity(system.declaration, system.configured) == admitted.prescription_identity
            reached[] = true
        end) == 0
    @test reached[]
    @test Base.invokelatest(IC.load_simulation, options.plant.definition).path == options.plant.definition

    # Deliberate corruption is confined to a temporary copy of the generated
    # application. Metadata can still load, but execution must never be reached.
    mktempdir() do directory
        application = joinpath(directory, "application")
        cp(dirname(configuration), application)
        copied = joinpath(application, basename(configuration))
        generated = joinpath(application, "generated", "optical-reference.yaml")
        open(io -> write(io, "\n# corrupted generated optical graph\n"), generated, "a")
        corrupt_options = Owner.configuration(copied)
        @test corrupt_options.version == 3
        @test Owner.requires_proper(corrupt_options)
        failure = try
            Owner._main(arguments(copied);
                with_owner=(f, admitted) -> f(merge(admitted, (; owner_check=() -> nothing))),
                run=_ -> error("corrupted provenance reached execution"))
            nothing
        catch error
            error
        end
        @test failure isa ArgumentError
        @test occursin("stale optical input: generated/optical-reference.yaml", sprint(showerror, failure))
        @test_throws ArgumentError Base.invokelatest(IC.load_simulation, corrupt_options.plant.definition)
    end
    @test all(!loaded, ("CUDA", "AMDGPU"))
end
