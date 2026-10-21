using Test, TOML, SHA, Libdl, LinearAlgebra
using PipeWireAORTC, AdaptiveOpticsSim, AdaptiveOpticsSim.AlgorithmGraphs
using AdaptiveOpticsSimPipeWireHIL, REVOLTClassicSim

length(ARGS) == 2 || error("usage: cpu-science.jl APPLICATION RECEIPT")
application, receipt = abspath.(ARGS)
BLAS.set_num_threads(1)
loaded_gpu() = any(id -> id.name in ("CUDA", "AMDGPU", "GPUCompiler"), keys(Base.loaded_modules))
gpu_libraries() = filter(path -> occursin(r"(?i)(libcuda|libcudart|libamdhip64|libhsa-runtime64|libcublas|libcufft)", path), Libdl.dllist())
O = PipeWireAORTC.AOSOwner
options = merge(O.configuration(joinpath(application, "simulation.conf")),
    (; backend=:cpu, remote="/tmp/classic-offline-unused", control_node="simulator-wfs",
       plant_module=REVOLTClassicSim))
frames = String[]
@testset "Registered Classic CPU preparation and direct-plant replay" begin
    @test pkgversion(PipeWireAORTC) == v"0.2.0"
    @test !loaded_gpu() && isempty(gpu_libraries())
    @test options.plant.settings.pupil_resolution == 480
    @test options.period_ns == 2_000_000
    @test options.exposure_ns == 1_896_000
    @test options.frame_encoding === :uint16
    @test options.command_scale == 1f-6
    science = O.prepare_science(options)
    @test size(hil_frame_buffer(science.boundary)) == (352, 352)
    @test size(hil_command_buffer(science.boundary)) == (277,)
    @test size(graph_output(science.graph, :pupil_opd)) == (480, 480)
    @test all(iszero, hil_command_buffer(science.boundary))

    reference = REVOLTClassicSim.prepare_hil_system(options.plant.settings;
        target=science.target, execution=StreamGraphExecution())
    driver = FixedStepModelTimeDriver(PeriodicSchedule(; period_ns=options.period_ns))
    warm = step_hil_frame_at!(reference.boundary, driver)
    fill!(hil_command_buffer(reference.boundary), 0f0)
    adopt_hil_command!(reference.boundary, warm.sequence)
    reset_hil_boundary!(reference.boundary, driver)
    for index in 1:3
        actual = step_hil_frame_at!(science.boundary, science.driver)
        expected = step_hil_frame_at!(reference.boundary, driver)
        frame = hil_frame_buffer(science.boundary)
        @test actual.sequence == expected.sequence == index
        @test frame == hil_frame_buffer(reference.boundary)
        @test all(isfinite, frame) && all(value -> 0 <= value <= typemax(UInt16), frame)
        @test sum(frame) > 0
        @test graph_output(science.graph, :pdm_surface_opd) == graph_output(reference.graph, :pdm_surface_opd)
        @test graph_output(science.graph, :pupil_opd) == graph_output(reference.graph, :pupil_opd)
        push!(frames, bytes2hex(sha256(reinterpret(UInt8, vec(frame)))))
        command = index == 1 ? Float32[sin(i) * 1e-8 for i in 1:277] : zeros(Float32, 277)
        copyto!(hil_command_buffer(science.boundary), command)
        copyto!(hil_command_buffer(reference.boundary), command)
        adopt_hil_command!(science.boundary, actual.sequence)
        adopt_hil_command!(reference.boundary, expected.sequence)
    end
    @test !loaded_gpu() && isempty(gpu_libraries())
end
PipeWireAORTC.Common.write_json(receipt, Dict("result"=>"passed", "scope"=>"Finite CPU numerical replay only; no transport, service, admission or timing qualification",
    "julia"=>string(VERSION), "rtc"=>string(pkgversion(PipeWireAORTC)), "aos"=>string(pkgversion(AdaptiveOpticsSim)),
    "classic"=>string(pkgversion(REVOLTClassicSim)), "backend"=>"cpu", "pupil_resolution"=>480,
    "frame_shape"=>[352,352], "commands"=>277, "frames"=>3, "frame_sha256"=>frames,
    "gpu_modules_loaded"=>loaded_gpu(), "gpu_libraries_loaded"=>gpu_libraries(), "services_started"=>false))
