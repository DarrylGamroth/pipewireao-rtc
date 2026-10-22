# CPU-only numerical-extension test; no server or services needed.
using Test, PipeWireAORTC, PipeWireAO
using FilterGraphIsland, FilterGraphPipeWire, JuliaFilterGraph
const E=Base.get_extension(PipeWireAORTC,:PipeWireAORTCGraphExt)

@testset "independent optional link callbacks" begin
    states=[Threads.Atomic{Int}(Int(PipeWireAO.LINK_STATE_INIT)) for _ in 1:4]
    callbacks=map(1:4) do i
        E.analysis_link_observer(states[i],((id=UInt32(i),),(id=UInt32(10+i),)),
            ((id=UInt32(20+i),),(id=UInt32(30+i),)))
    end
    info(i,state)=(output_node_id=UInt32(i),output_port_id=UInt32(10+i),
        input_node_id=UInt32(20+i),input_port_id=UInt32(30+i),state=state)
    for i in (3,1,4,2)
        callbacks[i](nothing,info(i,PipeWireAO.LINK_STATE_PAUSED))
        @test states[i][]==Int(PipeWireAO.LINK_STATE_PAUSED)
        @test count(state->state[]==Int(PipeWireAO.LINK_STATE_PAUSED),states)==findfirst(==(i),(3,1,4,2))
    end
    callbacks[2](nothing,info(1,PipeWireAO.LINK_STATE_ACTIVE))
    @test states[2][]==Int(PipeWireAO.LINK_STATE_ERROR)
    @test all(i->states[i][]==Int(PipeWireAO.LINK_STATE_PAUSED),(1,3,4))
    @test !any(id->id.name in ("CUDA","AMDGPU","GPUCompiler"),keys(Base.loaded_modules))
end

@testset "readiness does not need the owner's Julia event loop" begin
    if Threads.nthreads(:default)<2
        @test_skip Threads.nthreads(:default)>=2
    else
        config=(name="readiness-regression",)
        E.analysis_ready_notice(config,4) # Compile before the native wait.
        pipe=Pipe()
        completed=Threads.Atomic{Bool}(false)
        before_return=false
        try
            redirect_stdout(pipe) do
                monitor=FilterGraphIsland.spawn_monitor() do
                    @ccall gc_safe=true usleep(100000::Cuint)::Cint
                    E.analysis_ready_notice(config,4)
                    completed[]=true
                end
                @ccall gc_safe=true usleep(700000::Cuint)::Cint
                before_return=completed[]
                fetch(monitor)
            end
            close(pipe.in)
            message=read(pipe,String)
            @test before_return
            @test occursin("PIPEWIREAO_ANALYSIS_READY name=readiness-regression links=4",message)
        finally
            close(pipe)
        end
    end
end
