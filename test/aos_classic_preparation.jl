# Optional Classic qualification. ARGS: simulation.conf, package directory
# containing the historical REVOLTClassicSim reference package, backend.
# The reference package is used only as an oracle by this test.
using Test
using TOML
using PipeWireAORTC
using AdaptiveOpticsSim
using AdaptiveOpticsSim.AlgorithmGraphs
using AdaptiveOpticsSimPipeWireHIL

length(ARGS) == 3 || error("expected simulation.conf, reference package directory and cpu|cuda")
push!(LOAD_PATH, abspath(ARGS[2]))
using REVOLTClassicSim
const ClassicOwner = PipeWireAORTC.AOSOwner
const ClassicBackend = Symbol(ARGS[3])
ClassicBackend in (:cpu, :cuda) || error("backend must be cpu or cuda")
if ClassicBackend === :cuda
    @eval using CUDA
end

@testset "Classic FITS geometry and selected $ClassicBackend science preparation" begin
    options = merge(ClassicOwner.configuration(abspath(ARGS[1])), (; backend=ClassicBackend))
    @test TOML.parsefile(options.graph) == TOML.parsefile(REVOLTClassicSim.graph_path(:grid_gaussian))
    @test options.command_count == REVOLTClassicSim.command_count()
    science = ClassicOwner.prepare_science(options)
    grid_entry = findall(entry -> entry.binding === :pdm_actuator_grid_indices, options.artifacts)
    @test length(grid_entry) == 1
    geometry = science.artifacts[only(grid_entry)].data
    @test geometry isa Vector{Int32}
    @test geometry == REVOLTClassicSim.actuator_grid_indices()
    @test length(unique(geometry)) == options.command_count
    @test all(iszero, hil_command_buffer(science.boundary))
    @test size(hil_frame_buffer(science.boundary)) == options.frame_shape
    execution = ClassicBackend === :cpu ? StreamGraphExecution() : CapturedGraphExecution()
    reference = REVOLTClassicSim.prepare_hil_system(; profile=:grid_gaussian,
        target=science.target, execution)
    reference_driver = FixedStepModelTimeDriver(PeriodicSchedule(; period_ns=options.period_ns))
    warm = step_hil_frame_at!(reference.boundary, reference_driver)
    fill!(hil_command_buffer(reference.boundary), 0.0f0)
    adopt_hil_command!(reference.boundary, warm.sequence)
    reset_hil_boundary!(reference.boundary, reference_driver)
    probe = Float32[sin(index) * 1.0e-8 for index in 1:options.command_count]
    for index in 1:3
        actual = step_hil_frame_at!(science.boundary, science.driver)
        expected = step_hil_frame_at!(reference.boundary, reference_driver)
        @test actual.sequence == expected.sequence == index
        @test hil_frame_buffer(science.boundary) == hil_frame_buffer(reference.boundary)
        @test Array(graph_output(science.graph, :pdm_surface_opd)) == Array(graph_output(reference.graph, :pdm_surface_opd))
        @test Array(graph_output(science.graph, :pupil_opd)) == Array(graph_output(reference.graph, :pupil_opd))
        command = index == 1 ? probe : zeros(Float32, options.command_count)
        copyto!(hil_command_buffer(science.boundary), command)
        copyto!(hil_command_buffer(reference.boundary), command)
        adopt_hil_command!(science.boundary, actual.sequence)
        adopt_hil_command!(reference.boundary, expected.sequence)
    end
    println("CLASSIC_PREPARATION backend=$ClassicBackend commands=$(options.command_count) shape=$(options.frame_shape) exact_geometry=true exact_frames=3 exact_pupil_opd=true exact_pdm_surface=true")
end
