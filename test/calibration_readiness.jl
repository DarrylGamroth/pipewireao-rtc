# Optional CPU/private-core regression for asynchronous graph registration.
module CalibrationReadinessTests

using Test, PipeWireAO, PipeWireAORTC, FilterGraphIsland, FilterGraphPipeWire, JuliaFilterGraph
using AdaptiveOpticsSim, AdaptiveOpticsSimPipeWireHIL, AdaptiveOpticsCalibration

include("native_control_private_core.jl")
const Transport = Base.get_extension(PipeWireAORTC, :PipeWireAORTCCalibrationExt)
const Native = PipeWireAORTC.NativeCalibrationEndpoint
const Control = PipeWireAORTC.NativeControlClient

function registration_trial(remote, registry, path, trial, wakeup, guard)
    graphs = []
    workers = Transport.CalibrationGraphWorker[]
    names = ("test.calibration-readiness.$trial.wfs", "test.calibration-readiness.$trial.pdm")
    notify() = Native.wake!(wakeup,guard)
    try
        for name in names
            graph = FilterGraphIsland.prepare_service_graph(FilterGraphIsland.parse_arguments([
                "--graph",path,"--check","--execution","complete-frame"]))
            push!(graphs,graph)
            push!(workers,Transport.start_calibration_graph((;graph),remote,name,500//1;notify))
        end
        # Only native registry and worker notifications can make progress.
        # There is no periodic poll or diagnostic wake before this deadline.
        Native.await(wakeup,guard,Control.monotonic()+(trial == 1 ? 120 : 10)) do
            for worker in workers
                if istaskdone(worker.task)
                    fetch(worker.task)
                    worker.error[] === nothing || throw(worker.error[])
                    error("graph stopped before registration")
                end
            end
            all(worker -> worker.ready[],workers) || return false
            all(names) do name
                all((("in",:requested),("out",:demanded),("out",Symbol("constraint-feedback")))) do (direction,port)
                    Transport.calibration_endpoint(registry,name,direction,port) !== nothing
                end
            end
        end
        @test all(worker -> worker.ready[] && !istaskdone(worker.task),workers)
    finally
        foreach(Transport.quit_calibration_graph!,workers)
        for worker in workers
            Native.await(() -> istaskdone(worker.task),wakeup,guard,Control.monotonic()+20)
            fetch(worker.task)
            @test worker.error[] === nothing
        end
        all(worker -> istaskdone(worker.task),workers) && foreach(FilterGraphIsland.close_execution,graphs)
    end
end

@testset "calibration registry readiness has matching notifications" begin
    Threads.nthreads(:default) >= 4 || error("run readiness selector with --threads=4")
    with_control_private_core() do remote,directory,daemon
        wakeup,guard = Base.AsyncCondition(),ReentrantLock()
        notify() = Native.wake!(wakeup,guard)
        loop = ThreadLoop("test.calibration-readiness")
        context = core = registry = listener = nothing
        try
            with_thread_loop_lock(loop) do _
                context = Context(loop)
                core = CoreConnection(context;properties=Dict("remote.name"=>remote))
                registry = Registry(core)
                listener = add_listener!(registry;
                    on_global_added=(_...)->(notify();nothing),
                    on_global_removed=(_...)->(notify();nothing))
            end
            start!(loop)
            path = joinpath(directory,"pdm.conf")
            write(path,"""
            { filter.graph = {
                nodes = [{ name = pdm label = pdm-command-f32 type = ndarray
                    config = { actuator_count = 2 command_limits = [-0.5 0.5]
                        slew_limit = null initial_current = null quantization_origin = null
                        quantization_step = null dither_seed = null } }]
                inputs = ["pdm:requested"]
                outputs = ["pdm:demanded" "pdm:constraint-feedback"]
            } }
            """)
            for trial in 1:20
                registration_trial(remote,registry,path,trial,wakeup,guard)
            end
        finally
            with_thread_loop_lock(loop) do _
                for resource in (listener,registry,core,context)
                    resource === nothing || close(resource)
                end
            end
            close(loop)
            lock(guard) do
                close(wakeup)
            end
        end
    end
    @test !any(id.name in ("CUDA","AMDGPU") for id in keys(Base.loaded_modules))
end

end
