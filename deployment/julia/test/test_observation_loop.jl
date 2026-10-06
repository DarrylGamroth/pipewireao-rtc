using Test, PipeWireAODeployment, PipeWireAO, JSON3
const Native = PipeWireAO.LibPipeWire

# Exercise public context/data-loop APIs through the owner's generated
# bindings. The dictionary below is the public pw_properties ABI, not a
# daemon-private object. This test starts no source, graph or remote daemon.
function acquire_loop(context, properties)
    native_properties = Properties(properties)
    try
        dictionary = Ref(unsafe_load(native_properties.handle).dict)
        return GC.@preserve native_properties dictionary Native.pw_context_acquire_loop(context.handle,
            Base.unsafe_convert(Ptr{Native.spa_dict},dictionary))
    finally
        close(native_properties)
    end
end

@testset "public optional-loop selection and native thread names" begin
    base = Dict("context.properties"=>Dict("context.data-loops"=>[
        Dict("loop.name"=>name) for name in ("rtc-data-loop","source-loop","sink-loop")]),
        "context.modules"=>Any[])
    exported = PipeWireAODeployment.HILExport.hil_core(base;detector_observation=true)
    loops = exported["context.properties"]["context.data-loops"]
    # Keep this a portable API test rather than a placement/RT-rights test.
    for loop in loops
        loop["loop.rt-prio"] = "0"
        pop!(loop,"thread.affinity",nothing)
    end
    context = Context(properties=Dict("context.data-loops"=>String(JSON3.write(loops))))
    try
        main_loop = Native.pw_context_get_main_loop(context.handle)
        rtc_loop = acquire_loop(context,Dict("node.loop.name"=>"rtc-data-loop"))
        observer_loop = acquire_loop(context,Dict("node.loop.name"=>"observer-loop"))
        @test rtc_loop != C_NULL && observer_loop != C_NULL
        @test rtc_loop != observer_loop && rtc_loop != main_loop && observer_loop != main_loop
        @test acquire_loop(context,Dict("node.loop.class"=>"main")) == main_loop
        for iteration in 1:16
            # Make the observer most recently used, then request every supported
            # ordinary selection. Neither generic route may acquire it.
            @test acquire_loop(context,Dict("node.loop.name"=>"observer-loop")) == observer_loop
            @test acquire_loop(context,Dict("node.loop.class"=>"data.rt")) == rtc_loop
            @test acquire_loop(context,Dict{String,String}()) == rtc_loop
            @test Native.pw_context_acquire_loop(context.handle,C_NULL) == rtc_loop
            selected = Native.pw_context_get_data_loop(context.handle)
            @test Native.pw_data_loop_get_loop(selected) == rtc_loop
            @test unsafe_string(Native.pw_data_loop_get_name(selected)) == "rtc-data-loop"
            @test unsafe_string(Native.pw_data_loop_get_class(selected)) == "data.rt"
        end
        if Sys.islinux()
            names = [strip(read(joinpath("/proc",string(getpid()),"task",tid,"comm"),String))
                for tid in readdir(joinpath("/proc",string(getpid()),"task"))]
            @test count(==("observer-loop"),names) == 1
            @test count(==("rtc-data-loop"),names) == 1
        end
        Native.pw_context_release_loop(context.handle,observer_loop)
        Native.pw_context_release_loop(context.handle,rtc_loop)
    finally
        close(context)
    end
end
