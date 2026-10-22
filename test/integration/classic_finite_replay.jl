# Opt-in finite scientific comparison. No managed session or service is touched.
# Run with the immutable Classic application environment and --threads=2,1:
#   julia --project=APPLICATION --threads=2,1 classic_finite_replay.jl APPLICATION NEW_OUTPUT [32]
# CLASSIC_NATIVE_PREFIX selects the reviewed core plus external queue plugins.
module ClassicFiniteReplay

using Test, SHA, TOML
using AdaptiveOpticsSim.AlgorithmGraphs, AdaptiveOpticsSim.Backends
using AdaptiveOpticsSimPipeWireHIL, REVOLTClassicSim
using PipeWireAO, PipeWireAO_jll, PipeWireAORTC
using FilterGraphIsland, FilterGraphPipeWire, FilterGraphAlgorithms, JuliaFilterGraph

# Reuse the shared software integration support, including its borrowed-buffer
# copying and private-core configuration. It only defines helpers on inclusion.
const SUPPORT = get(ENV, "CLASSIC_EXCHANGE_SUPPORT", normpath(joinpath(@__DIR__,
    "../../../../adaptive-optics-simulations/test/exchange_fixture.jl")))
include(SUPPORT)
include(joinpath(@__DIR__,"classic_observation.jl"))
include(joinpath(@__DIR__,"classic_replay.jl"))
using .ClassicReplay: prepare_controller, replay
const REPLAY_SHA256_AT_LOAD = bytes2hex(sha256(read(joinpath(@__DIR__,"classic_replay.jl"))))
const OBSERVATION_SHA256_AT_LOAD = bytes2hex(sha256(read(joinpath(@__DIR__,"classic_observation.jl"))))
const FEEDBACK_IN = Symbol("constraint-feedback")
const FEEDBACK_OUT = Symbol("controller-constraint-feedback")
const SCALE = Float32(1e-6)
digest(path) = bytes2hex(sha256(read(path)))
const TEST_SHA256_AT_LOAD = digest(@__FILE__)
const RTC_QUEUES = (("demanded","rtc-command"),("slopes","rtc-slopes"),
    ("flux","rtc-flux"),("validity","rtc-validity"),("current-offset","rtc-offset"),
    ("constraint-feedback","rtc-constraint-feedback"),("correction-role","rtc-correction-role"))

function write_private_configuration(path, application, core_name)
    installed = PipeWireAORTC.Common.read_json(joinpath(application,"core.conf.in"))
    selected = Set(["simulator-detector-queue-input";
        [prefix*"-queue-input" for (_,prefix) in RTC_QUEUES]])
    queues = filter(installed["context.modules"]) do declaration
        declaration["name"]=="libpipewire-module-queue" &&
            declaration["args"]["capture.props"]["node.name"] in selected
    end
    length(queues)==8 || error("application does not declare the eight selected copy queues")
    for declaration in queues
        args = declaration["args"]
        args["queue.max-buffers"]==1 && args["queue.storage"]=="copy" &&
            args["queue.overflow"]=="drop-oldest" || error("application observation queue contract changed")
    end
    modules = [Dict{String,Any}("name"=>name) for name in ("libpipewire-module-scheduler-v1",
        "libpipewire-module-protocol-native","libpipewire-module-spa-node-factory",
        "libpipewire-module-client-node","libpipewire-module-link-factory",
        "libpipewire-module-metadata","libpipewire-module-access")]
    append!(modules,queues)
    # Retain the exact queue declarations and dummy driver objects. Only this
    # functional test's daemon identity and unpinned, non-RT loop placement differ.
    configuration = Dict("context.properties"=>Dict("core.daemon"=>true,
        "core.name"=>core_name,"support.dbus"=>false,"library.use-fallback"=>false,
        "context.data-loops"=>[Dict("loop.name"=>name,"thread.name"=>name,
            "loop.rt-prio"=>-1,"loop.idle"=>"eventfd") for name in ("rtc-data-loop","observer-loop")]),
        "context.spa-libs"=>Dict("support.*"=>"support/libspa-support"),
        "context.modules"=>modules,"context.objects"=>installed["context.objects"])
    PipeWireAORTC.ScienceExport.write_spa_config(path,configuration)
    return nothing
end

function capture(::Type{T}, count) where {T}
    return FrameCapture(zeros(T, count), BufferHeader(0,0,0,0,0), UInt64(0),
        UInt64(0), UInt64(0), Threads.Atomic{UInt64}(0), StreamBuffer(), 0,
        nothing, ACQUISITION_TRIGGER_ABSENT)
end

function recording_parameters(format,schema)
    # The production copy queue needs capacity plus two pool buffers. Fixed
    # two-buffer recorders would constrain the shared source pool below that.
    return (ndarray_format(format;schema),
        Pod(buffers_param(size=payload_size(format),buffers=3)),
        Pod(header_metadata_param()),Pod(acquisition_metadata_param(;version=2)))
end

function named_port(registry, node, direction, name=nothing)
    properties = ["node.id" => string(node), "port.direction" => direction]
    name === nothing || push!(properties, "port.name" => name)
    return only(find_globals(registry; interface="PipeWire:Interface:Port", properties))
end

function connect_ports(prepared, registry, output_node, output_name, input_node, input_name;trackers=nothing)
    roundtrip(registry)
    output = named_port(registry, output_node, "out", output_name)
    input = named_port(registry, input_node, "in", input_name)
    return with_thread_loop_lock(prepared.loop) do _
        link = create_object(prepared.core, "link-factory", PipeWireAO.Link; properties=Dict(
            "link.output.node" => string(output_node), "link.output.port" => string(output.id),
            "link.input.node" => string(input_node), "link.input.port" => string(input.id),
            "object.linger" => "false"))
        trackers===nothing || push!(trackers,track_info!(link))
        link
    end
end

function prepare_observers(prepared,registry)
    # Selected scientific-invariance scope: actual detector and demanded-command
    # copy queues. The separate installed-session gate covers all eight panels.
    specs = (CLASSIC_OBSERVATION_STREAMS[1],CLASSIC_OBSERVATION_STREAMS[5])
    captures = map(ClassicObservationCapture,specs)
    streams = with_thread_loop_lock(prepared.loop) do _
        map(specs,captures) do spec,capture
            stream = Stream(prepared.core,"finite-observer-"*spec.name;
                properties=Dict("node.name"=>"finite-observer-"*spec.name,
                    "node.want-driver"=>"true","priority.driver"=>"100",
                    "node.loop.name"=>"observer-loop"),on_process=capture,
                on_param_changed=ClassicObservationFormat(capture))
            precompile(capture,(typeof(stream),))
            precompile(stream.callbacks.on_param_changed,(typeof(stream),UInt32,Pod))
            connect!(stream,:input;flags=STREAM_MAP_BUFFERS|STREAM_INACTIVE|
                STREAM_DONT_RECONNECT|STREAM_NO_CONVERT|STREAM_DRIVER,
                params=(ndarray_format(capture.format;schema=capture.schema),
                    _classic_buffer_parameters(capture)...))
            set_active!(stream,true)
            stream
        end
    end
    observer = (;specs,captures,streams,links=PipeWireAO.Link[])
    return observer
end

function attach_observers!(prepared,registry,observer)
    isempty(observer.links) || error("observer links are already attached")
    roundtrip(registry)
    for (spec,stream) in zip(observer.specs,observer.streams)
        wait_until("selected observation playback port is not published") do
            with_thread_loop_lock(prepared.loop) do _
                nodes=find_globals(registry;interface="PipeWire:Interface:Node",
                    properties=("node.name"=>spec.node,))
                isempty(nodes) && return false
                outputs=find_globals(registry;interface="PipeWire:Interface:Port",
                    properties=("node.id"=>string(only(nodes).id),"port.direction"=>"out"))
                inputs=find_globals(registry;interface="PipeWire:Interface:Port",
                    properties=("node.id"=>string(node_id(stream)),"port.direction"=>"in"))
                return length(outputs)==length(inputs)==1
            end
        end
        queue = only(find_globals(registry;interface="PipeWire:Interface:Node",
            properties=("node.name"=>spec.node,))).id
        push!(observer.links,connect_ports(prepared,registry,queue,nothing,node_id(stream),nothing))
    end
    roundtrip(prepared.core)
end

function detach_observers!(prepared,observer)
    with_thread_loop_lock(prepared.loop) do _
        foreach(close,observer.links)
        empty!(observer.links)
    end
    roundtrip(prepared.core)
end

function drive_observers!(prepared,observer,index,frames,demanded,identity)
    wait_until("selected observation queues did not deliver accepted sequence $index") do
        with_thread_loop_lock(prepared.loop) do _
            for capture in observer.captures
                capture.error===nothing || throw(capture.error)
            end
            if all(capture -> capture.header!==nothing && capture.header.sequence==index,observer.captures)
                @test observer.captures[1].values==@view(frames[:,index])
                @test observer.captures[2].values==@view(demanded[:,index])
                @test all(capture -> capture.identity==identity,observer.captures)
                return true
            end
            for stream in observer.streams
                if stream_state(stream)==PipeWireAO.LibPipeWire.PW_STREAM_STATE_STREAMING && is_driving(stream)
                    trigger_process!(stream)
                end
            end
            return false
        end
    end
end

function observer_record(prepared,observer,mode)
    observer===nothing && return Dict("mode"=>String(mode),"selected_queues"=>String[])
    return with_thread_loop_lock(prepared.loop) do _
        Dict("mode"=>String(mode),"selected_queues"=>[spec.node for spec in observer.specs],
            "streams"=>[Dict("name"=>spec.name,"samples"=>capture.count,
                "distinct_sequences"=>capture.distinct_sequences,
                "sequences"=>[identity.sequence for identity in capture.identities if identity!==nothing])
                for (spec,capture) in zip(observer.specs,observer.captures)])
    end
end

function record_prefix!(prepared, registry, frame_capture, command_capture, frames, demanded, adopted,observer,mode)
    count = size(adopted, 2)
    generation = frame_acquisition_generation(prepared)
    identities = Vector{AcquisitionIdentity}(undef, count)
    timings = Vector{PipeWireFrameCommandTiming}(undef, count)
    for index in 1:count
        if mode===:churn && index==cld(count,3)+1
            detach_observers!(prepared,observer)
        elseif mode===:churn && index==cld(2count,3)+1
            attach_observers!(prepared,registry,observer)
        end
        sequence = UInt64(index)
        completed = exchange_frame!(prepared)
        @test completed == sequence
        wait_until("finite replay captures missed sequence $sequence") do
            with_thread_loop_lock(prepared.loop) do _
                frame_capture.sequence == command_capture.sequence == sequence
            end
        end
        with_thread_loop_lock(prepared.loop) do _
            @test frame_capture.count[] == command_capture.count[] == sequence
            @test frame_capture.header.sequence == command_capture.header.sequence == sequence
            @test frame_capture.identity == command_capture.identity
            @test frame_capture.identity.sequence == sequence
            @test frame_capture.identity.generation == generation
            index == 1 || @test frame_capture.identity.domain == identities[1].domain
            @test frame_capture.version == command_capture.version == 2
            @test frame_capture.duration == command_capture.duration == prepared.configuration.exposure_duration_ns
            copyto!(@view(frames[:, index]), frame_capture.values)
            copyto!(@view(demanded[:, index]), command_capture.values)
            identities[index] = frame_capture.identity
        end
        @test frames[:, index] == expected_payload(hil_frame_buffer(prepared.boundary), UInt16)
        copyto!(@view(adopted[:, index]), hil_command_buffer(prepared.boundary))
        @test adopted[:, index] == demanded[:, index] .* SCALE
        @test hil_boundary_status(prepared.boundary).active_command_sequence == sequence
        timing = something(frame_command_timing(prepared))
        @test timing.sequence == sequence
        @test timing.source_published_nanoseconds <= timing.command_received_nanoseconds
        @test timing.command_received_nanoseconds - timing.source_published_nanoseconds == timing.end_to_end_latency_nanoseconds
        index == 1 || @test timings[index-1].command_received_nanoseconds <= timing.source_published_nanoseconds
        timings[index] = timing
        if mode===:normal || (mode===:slow && index in (1,count)) ||
                (mode===:churn && !isempty(observer.links))
            drive_observers!(prepared,observer,index,frames,demanded,identities[index])
        end
    end
    @test hil_boundary_status(prepared.boundary).frame_sequence == UInt64(count)
    if mode in (:slow,:churn)
        for capture in observer.captures
            sequences = [identity.sequence for identity in capture.identities if identity!==nothing]
            @test length(sequences)>=2
            @test any(>(1),diff(sequences))
        end
    end
    return (; identities, timings, generation)
end

function run_prefix(application, output, system, count;mode=:none)
    mkpath(output)
    println("Starting finite prefix: ",mode)
    flush(stdout)
    frames = zeros(UInt16, 352*352, count)
    demanded = zeros(Float32, 277, count)
    adopted = similar(demanded)
    core_name = "classic-finite-$(getpid())-$(time_ns())"
    # Keep AF_UNIX socket paths below the kernel limit regardless of the
    # evidence directory's depth. Only this test owns the temporary directory.
    runtime = mktempdir(prefix="classic-finite-")
    configuration_path = joinpath(output, "configuration")
    mkpath(runtime); mkpath(configuration_path)
    write_private_configuration(joinpath(configuration_path,"private-core.conf"),application,core_name)
    write(joinpath(configuration_path, "client.conf"), CLIENT_CONFIGURATION)
    # The registered JLL supplies the core; the composed application prefix
    # also supplies the external observation queue module and SPA plugins.
    artifact = abspath(get(ENV,"CLASSIC_NATIVE_PREFIX",String(PipeWireAO_jll.artifact_dir)))
    isfile(joinpath(artifact,"lib","pipewire-ao-0.3","libpipewire-module-queue.so")) ||
        error("set CLASSIC_NATIVE_PREFIX to the reviewed composed native prefix containing the queue module")
    environment = Dict("XDG_RUNTIME_DIR"=>runtime, "PIPEWIREAO_RUNTIME_DIR"=>runtime,
        "PIPEWIREAO_CONFIG_DIR"=>configuration_path,
        "PIPEWIREAO_MODULE_DIR"=>joinpath(artifact,"lib","pipewire-ao-0.3"),
        "PIPEWIREAO_SPA_PLUGIN_DIR"=>joinpath(artifact,"lib","spa-ao-0.2"),
        "PIPEWIREAO_DEBUG"=>"0")
    result = withenv(environment...) do
        log = open(joinpath(output, "private-core.log"), "w")
        daemon = prepared = registry = frame_sink = command_sink = owner_task = node = observer = nothing
        links = PipeWireAO.Link[]
        link_trackers = []
        cleanup_errors = Exception[]
        try
            daemon = run(pipeline(`$(joinpath(artifact,"bin","pipewire-ao")) -c private-core.conf`;
                stdout=log, stderr=log); wait=false)
            wait_until(() -> ispath(joinpath(runtime,core_name)), "private core socket missing")
            options = PipeWireAORTC.AOSOwner.configuration(joinpath(application,"simulation.conf"))
            configuration = REVOLTClassicSim.pipewire_configuration(system, core_name;
                frame_encoding=options.frame_encoding, frame_schema=options.frame_schema,
                command_schema=options.command_schema, command_scale=options.command_scale)
            @test configuration.frame_encoding == :uint16
            @test configuration.command_scale == SCALE
            prepared = prepare_pipewire_hil(system.boundary, configuration;
                frame_buffers=3,command_buffers=3)
            published = Channel{Any}(1)
            # With an interactive pool the script's main task runs there.
            # Keep the blocking native loop on a separate default thread and
            # prevent task migration after choosing that native owner thread.
            owner_task = Threads.@spawn :default begin
                current_task().sticky = true
                graph = prepare_controller(application)
                controller = nothing
                try
                    controller = FilterGraphPipeWire.PipeWireNode(graph;
                        name="classic-finite-jfg", remote=core_name, rate=500//1,
                        connect=false, fifo_inputs=true,
                        boundary_layout=FilterGraphAlgorithms.RowMajorLayout(),
                        feedback=FEEDBACK_IN=>FEEDBACK_OUT)
                    FilterGraphPipeWire.prepare!(controller; required_outputs=keys(graph.output_formats))
                    put!(published, controller)
                    FilterGraphPipeWire.connect!(controller)
                    FilterGraphPipeWire.run!(controller)
                catch err
                    isready(published) || put!(published, err)
                    rethrow()
                finally
                    controller === nothing || close(controller)
                    FilterGraphIsland.close_execution(graph)
                end
            end
            timedwait(() -> isready(published) || istaskdone(owner_task),300;pollint=0.01)==:ok ||
                error("controller preparation timed out")
            node = take!(published)
            node isa Exception && throw(node)
            wait_until(() -> FilterGraphPipeWire.node_id(node) !== nothing, "controller publication timed out")
            frame_capture = capture(UInt16, 352*352)
            command_capture = capture(Float32, 277)
            with_thread_loop_lock(prepared.loop) do _
                frame_sink = Stream(prepared.core, "finite-frames";
                    properties=Dict("node.name"=>"finite-frames", "node.reliable"=>"true"), on_process=frame_capture)
                command_sink = Stream(prepared.core, "finite-commands";
                    properties=Dict("node.name"=>"finite-commands", "node.reliable"=>"true"), on_process=command_capture)
                flags = STREAM_MAP_BUFFERS | STREAM_INACTIVE | STREAM_DONT_RECONNECT
                connect!(frame_sink, :input; flags,
                    params=recording_parameters(NdArrayFormat(NdArray.U16_LE,(352,352);
                        layout=NdArray.ROW_MAJOR,rate=configuration.rate), configuration.frame_schema))
                connect!(command_sink, :input; flags,
                    params=recording_parameters(NdArrayFormat(NdArray.F32_LE,(277,);
                        layout=NdArray.ROW_MAJOR,rate=configuration.rate), configuration.command_schema))
                registry = PipeWireAO.Registry(prepared.core)
                precompile(frame_capture,(typeof(frame_sink),))
                precompile(command_capture,(typeof(command_sink),))
            end
            rtc = FilterGraphPipeWire.node_id(node)
            push!(links, connect_ports(prepared,registry,node_id(prepared.frame_stream),nothing,rtc,"raw";trackers=link_trackers))
            push!(links, connect_ports(prepared,registry,rtc,"demanded",node_id(prepared.command_stream),nothing;trackers=link_trackers))
            push!(links, connect_ports(prepared,registry,node_id(prepared.frame_stream),nothing,node_id(frame_sink),nothing;trackers=link_trackers))
            push!(links, connect_ports(prepared,registry,rtc,"demanded",node_id(command_sink),nothing;trackers=link_trackers))
            detector_queue = only(find_globals(registry;interface="PipeWire:Interface:Node",
                properties=("node.name"=>"simulator-detector-queue-input",))).id
            push!(links,connect_ports(prepared,registry,node_id(prepared.frame_stream),nothing,detector_queue,nothing;trackers=link_trackers))
            for (name,prefix) in RTC_QUEUES
                queue = only(find_globals(registry;interface="PipeWire:Interface:Node",
                    properties=("node.name"=>prefix*"-queue-input",))).id
                push!(links,connect_ports(prepared,registry,rtc,name,queue,nothing;trackers=link_trackers))
            end
            roundtrip(prepared.core)
            with_thread_loop_lock(prepared.loop) do _
                set_active!(frame_sink,true); set_active!(command_sink,true)
            end
            start!(prepared)
            wait_until("every public controller output must have an active link") do
                with_thread_loop_lock(prepared.loop) do _
                    all(tracker -> has_current_info(tracker) && current_info(tracker).state==PipeWireAO.LINK_STATE_ACTIVE,link_trackers)
                end
            end
            if mode!==:none
                observer=prepare_observers(prepared,registry)
                attach_observers!(prepared,registry,observer)
            end
            prefix = record_prefix!(prepared,registry,frame_capture,command_capture,frames,demanded,adopted,observer,mode)
            @test FilterGraphPipeWire.last_error(node) === nothing
            observation = observer_record(prepared,observer,mode)
            println("Completed finite prefix: ",mode)
            flush(stdout)
            return (; frames, demanded, adopted, prefix..., core_name, native_prefix=artifact,observation)
        catch
            if node !== nothing && !(node isa Exception)
                println(stderr,"Private controller last_error: ",FilterGraphPipeWire.last_error(node))
                println(stderr,"Private controller state: ",FilterGraphPipeWire.node_state(node))
            end
            try
                open(joinpath(output,"failure-dump.json"),"w") do io
                    run(pipeline(`$(joinpath(artifact,"bin","pwao-dump")) -r $core_name`;stdout=io,stderr=stderr))
                end
            catch diagnostic_error
                println(stderr,"Private dump failed: ",diagnostic_error)
            end
            rethrow()
        finally
            prepared === nothing || attempt_cleanup!(() -> stop!(prepared),cleanup_errors)
            node === nothing || node isa Exception || attempt_cleanup!(() -> FilterGraphPipeWire.quit!(node),cleanup_errors)
            if owner_task !== nothing
                attempt_cleanup!(cleanup_errors) do
                    timedwait(() -> istaskdone(owner_task),10;pollint=0.01)==:ok || error("controller did not stop")
                    fetch(owner_task)
                end
            end
            if prepared !== nothing
                attempt_cleanup!(cleanup_errors) do
                    with_thread_loop_lock(prepared.loop) do _
                        observations = observer===nothing ? () : (reverse(observer.links)...,observer.streams...)
                        for resource in (reverse(link_trackers)...,observations...,reverse(links)...,command_sink,frame_sink,registry)
                            resource === nothing || attempt_cleanup!(() -> close(resource),cleanup_errors)
                        end
                    end
                end
                attempt_cleanup!(() -> close(prepared),cleanup_errors)
            end
            daemon === nothing || attempt_cleanup!(cleanup_errors) do
                Base.process_exited(daemon) || kill(daemon)
                wait(daemon)
                @test Base.process_exited(daemon)
            end
            close(log)
            isempty(cleanup_errors) || throw(CompositeException(cleanup_errors))
        end
    end
    @test !ispath(joinpath(runtime,core_name))
    rm(runtime;recursive=true)
    for (name,array) in (("frames-u16-row-major.bin",result.frames),
            ("demanded-f32-micrometre.bin",result.demanded),("adopted-f32-metre.bin",result.adopted))
        write(joinpath(output,name),array)
        result.observation[name*"-sha256"] = digest(joinpath(output,name))
    end
    return result
end

function run_replay(arguments)
    length(arguments) in (2,3) || error("expected APPLICATION NEW_OUTPUT [FRAME_COUNT]")
    application, output = abspath.(arguments[1:2])
    count = length(arguments)==3 ? parse(Int,arguments[3]) : 32
    6<=count<=256 || error("frame count must be 6:256")
    ispath(output) && error("evidence directory must be new")
    Threads.nthreads(:interactive)>=1 || error("use --threads=2,1 for the native controller owner")
    options = PipeWireAORTC.AOSOwner.configuration(joinpath(application,"simulation.conf"))
    target = if options.backend===:cpu
        Backends.HostComputeDevice()
    elseif options.backend===:cuda
        CUDA.functional() || error("CUDA is unavailable")
        CUDA.allowscalar(false)
        compute_device(CUDA.zeros(Float32,1))
    else
        error("finite Classic replay supports explicit CPU or CUDA selection")
    end
    mkpath(output)
    declared = PipeWireAORTC.Common.read_json(joinpath(application,"deployment.conf"))["artifacts"]
    before = Dict(name=>digest(joinpath(application,name)) for name in keys(declared))
    all(name -> before[name]==declared[name],keys(declared)) || error("application artifact hash mismatch")
    before["deployment.conf"] = digest(joinpath(application,"deployment.conf"))
    @testset "Classic finite $(options.backend) plant / CPU JFG replay" begin
        system = REVOLTClassicSim.prepare_hil_system(options.plant.settings;target)
        @test compute_device(system.boundary.frame_output)==target
        @test compute_device(system.boundary.command_input)==target
        result = run_prefix(application,joinpath(output,"none"),system,count)
        predicted = replay(application,result.frames,result.adopted)
        observation_records = [result.observation]
        for mode in (:normal,:slow,:churn)
            reset_hil_boundary!(system.boundary)
            @test hil_boundary_status(system.boundary).frame_sequence==0
            compared = run_prefix(application,joinpath(output,String(mode)),system,count;mode)
            @test compared.frames==result.frames
            @test compared.demanded==result.demanded
            @test compared.adopted==result.adopted
            @test replay(application,compared.frames,compared.adopted)==predicted
            push!(observation_records,compared.observation)
        end
        @test any(!iszero,result.adopted)
        @test count==1 || any(index -> result.frames[:,index]!=result.frames[:,1],2:count)
        @test count==1 || any(index -> result.adopted[:,index]!=result.adopted[:,1],2:count)
        payloads = Dict("frames-u16-row-major.bin"=>result.frames,
            "demanded-f32-micrometre.bin"=>result.demanded,
            "adopted-f32-metre.bin"=>result.adopted,"replayed-f32-metre.bin"=>predicted)
        for (name,array) in payloads
            write(joinpath(output,name),array)
        end
        for (name,hash) in before
            @test digest(joinpath(application,name))==hash
        end
        @test digest(@__FILE__)==TEST_SHA256_AT_LOAD
        @test digest(joinpath(@__DIR__,"classic_replay.jl"))==REPLAY_SHA256_AT_LOAD
        period_ns = round(Int,Float64(system.frame_period_s)*1e9)
        report = Dict("frames"=>count,"exact_replay"=>predicted==result.adopted,
            "application"=>application,"application_sha256"=>before,
            "support_sha256"=>digest(SUPPORT),"test_sha256"=>TEST_SHA256_AT_LOAD,
            "observation_helper_sha256"=>OBSERVATION_SHA256_AT_LOAD,
            "controller_replay_sha256"=>REPLAY_SHA256_AT_LOAD,
            "observation_modes"=>observation_records,
            "generation"=>result.generation,"core_name"=>result.core_name,
            "native_prefix"=>result.native_prefix,
            "native_sha256"=>Dict(name=>digest(joinpath(result.native_prefix,name)) for name in
                ("bin/pipewire-ao","lib/pipewire-ao-0.3/libpipewire-module-queue.so")),
            "domain"=>bytes2hex(collect(result.identities[1].domain.bytes)),
            "sequences"=>[identity.sequence for identity in result.identities],
            "source_published_ns"=>[timing.source_published_nanoseconds for timing in result.timings],
            "command_received_ns"=>[timing.command_received_nanoseconds for timing in result.timings],
            "model_period_ns"=>period_ns,"derived_model_timestamps_ns"=>collect(0:count-1).*period_ns,
            "command_scale"=>Float64(SCALE),"julia_version"=>string(VERSION),
            "backend"=>string(options.backend),
            "cuda_device"=>options.backend===:cuda ? string(CUDA.device()) : "not used",
            "frame_min_adc"=>minimum(result.frames),"frame_max_adc"=>maximum(result.frames),
            "frame_changed_components"=>sum(index -> sum(result.frames[:,index].!=result.frames[:,1]),2:count;init=0),
            "demanded_max_abs_um"=>maximum(abs,result.demanded),
            "adopted_max_abs_m"=>maximum(abs,result.adopted),
            "adopted_changed_components"=>sum(index -> sum(result.adopted[:,index].!=result.adopted[:,1]),2:count;init=0),
            "payload_sha256"=>Dict(name=>digest(joinpath(output,name)) for name in keys(payloads)),
            "scope"=>"finite software composition, exact numerical replay and selected detector/demanded copy-queue observation invariance; no cadence, latency, convergence, physical validation, lossless-observer or other-output invariance claim")
        open(joinpath(output,"result.toml"),"w") do io
            TOML.print(io,report)
        end
    end
end

function main(arguments)
    length(arguments) in (2,3) || error("expected APPLICATION NEW_OUTPUT [FRAME_COUNT]")
    options=PipeWireAORTC.AOSOwner.configuration(joinpath(abspath(arguments[1]),"simulation.conf"))
    options.backend===:cuda && (@eval import CUDA)
    # Optional backend methods/extensions must be visible throughout preparation.
    return Base.invokelatest(run_replay,arguments)
end

abspath(PROGRAM_FILE)==(@__FILE__) && main(ARGS)
end
