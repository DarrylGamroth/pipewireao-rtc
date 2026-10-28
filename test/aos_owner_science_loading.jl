# Opt-in fresh-process CPU preparation selector. Consume a real built version-4
# owner configuration; do not preload its optional science packages. The owner
# bootstrap is injected so this opens no PipeWire core or service. CPU selection
# is explicit for this preparation check and never rewrites the built config.
using Test, PipeWireAORTC

const Owner = PipeWireAORTC.AOSOwner

@testset "fresh AOS owner loads optional science before declaration verification" begin
    @test all(id -> id.name ∉ ("AdaptiveOpticsSim", "AdaptiveOpticsSimPipeWireHIL", "Proper", "CUDA", "AMDGPU"),
        keys(Base.loaded_modules))
    length(ARGS) == 1 || throw(ArgumentError("usage: aos_owner_science_loading.jl BUILT_EXTERNAL_PUPIL_CONFIGURATION"))
    configuration = realpath(only(ARGS))
    original = read(configuration)
    options = Owner.configuration(configuration)
    @test options.version == 4
    arguments = ["--config",configuration,"--remote","/tmp/aos-owner-preparation-only",
        "--control-node","preparation-only-control","--bootstrap-node","preparation-only-bootstrap",
        "--bootstrap-instance","7"]
    prepared = Ref(false)
    with_owner = (f, admitted) -> f(merge(admitted,
        (;backend=:cpu, device=0, owner_check=()->nothing)))
    @test Owner._main(arguments; with_owner,
        load_cuda=()->error("CPU preparation must not load CUDA"),
        load_amdgpu=()->error("CPU preparation must not load AMDGPU"),
        run=admitted -> begin
            @test admitted.backend === :cpu && admitted.device == 0
            science = Owner.prepare_external_pupil_science(admitted)
            @test science.identity == admitted.prescription_identity
            @test Set(keys(science.sensors)) == Set(keys(admitted.sensor_nodes))
            @test all(sensor -> all(isfinite,sensor.image),values(science.sensors))
            @test science.plant.state.domain === nothing
            prepared[] = true
        end) == 0
    @test prepared[]
    @test read(configuration) == original
    @test all(id -> id.name ∉ ("CUDA","AMDGPU"),keys(Base.loaded_modules))
end
