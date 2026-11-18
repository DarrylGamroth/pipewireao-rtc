using CUDA, Proper, AdaptiveOpticsSim, AdaptiveOpticsSimPipeWireHIL
using LinearAlgebra, Test
using PipeWireAO, PipeWireAORTC, FilterGraphAlgorithms, FilterGraphPipeWire, FilterGraphs

const HIL = AdaptiveOpticsSimPipeWireHIL
const EXT = HIL.ExternalPupil
const RTC = PipeWireAORTC
const FGP = FilterGraphPipeWire
const FGA = FilterGraphAlgorithms
const FG = FilterGraphs
const JSON = RTC.Common.JSON
const BRIDGE = Base.get_extension(HIL, :PipeWireAORTCExt)
const JSON_FILE = "transport.json"
const COMMAND = Symbol("dm-command")
const LIMITER = Symbol("constraint-feedback")
const FIRST_TIME_NS = UInt64(10_000_000)
const SCC_PERIOD = 3
const LAST_TICK = 2550
const PHASES = (baseline=1:450, closed=451:1050, dropout=1051:1200,
    resume=1201:1650, saturate=1651:1770, release=1771:LAST_TICK)
const MONITORED = (Symbol("modal-residual"), Symbol("llowfs-modal-residual"),
    Symbol("pair-status"), LIMITER, Symbol("controller-feedback"),
    Symbol("llowfs-correction"), Symbol("scc-correction"))

include(ENV["SPIDERS_TRANSPORT_SELECTOR"])
const TRANSPORT = SpidersDualTransport
include("measure.jl")

function phase_at(tick, variant=:experiment)
    if variant === :pulse
        tick == 1652 && return :saturate
        tick > 1652 && return :release
        tick >= 1201 && return :resume
    end
    return first(name for (name, window) in pairs(PHASES) if tick in window)
end

function identity_record(identity)
    return identity === nothing ? nothing : (;
        domain=bytes2hex(collect(identity.domain.bytes)), identity.generation, identity.sequence)
end

function prepare(app)
    options = BRIDGE.Configuration.configuration(joinpath(app, "simulation.conf"))
    options.backend === :cuda && options.period_ns == FIRST_TIME_NS && options.command_limit == 0.5 ||
        error("unexpected simulator calibration, source rate or limiter")
    options = merge(options, (; owner_check=()->nothing))
    CUDA.allowscalar(false)
    BLAS.set_num_threads(1)
    println("Preparing sealed captured CUDA plant"); flush(stdout)
    science = Base.invokelatest(BRIDGE.prepare_optics, options, Val(6))
    execution = EXT.prepare(science; clocked=true, options.command_count, options.command_limit)
    graph_properties = Dict(
        "llowfs"=>EXT.execution_properties(science.plant, :llowfs),
        "scc_fringed"=>EXT.execution_properties(science.plant, :scc),
        "scc_unfringed"=>EXT.execution_properties(science.plant, :scc; unfringed=true),
    )
    all(row -> parse(Int,row["optics.captured-node-count"]) > 0, values(graph_properties)) ||
        error("an optical path is not captured")
    EXT._with_optical_execution(execution) do
        EXT.warmup!(execution)
    end
    options.command_buffers > 0 || error("invalid command buffers")
    streams = EXT.stream_options(science, "unused", options.sensor_nodes;
        options.sensor_buffers, input_option=BRIDGE.clocked_command_option(options),
        reference_clock=RTC.Common.prepare_reference_clock(options))
    println("CUDA plant ready"); flush(stdout)
    return (; options, execution, streams, graph_properties)
end

function calibration_parameter(application, name)
    binding = only(filter(row -> row["port"] == name,
        JSON.parsefile(joinpath(application, "rtc", "dual-parameters.conf"))["parameters"]))
    path = normpath(joinpath(application, "rtc", binding["path"]))
    raw = RTC.InstrumentConfiguration.FITSIO.FITS(path, "r") do file
        read(file[binding["hdu"]])
    end
    return haskey(binding, "axes") ? permutedims(raw, Tuple(binding["axes"])) : raw
end

function prepare_stimulus(application, variant)
    baseline = Float32.(vec(calibration_parameter(application, "llowfs-modal-reference")))
    p = calibration_parameter(application, "vdm-to-pdm") *
        calibration_parameter(application, "active-to-full") *
        calibration_parameter(application, "llowfs-command-projection")
    direction = zeros(Float32, length(baseline))
    direction[1] = 1
    if size(p, 2) != length(direction)
        p = p * calibration_parameter(application, "llowfs-feedback-selection")
    end
    peak = maximum(abs, p * direction)
    isfinite(peak) && peak > 0 || error("sealing calibration produced a zero tip/tilt stimulus")
    # The pulse crosses the bound for one LLOWFS-only event.
    factor = variant === :pulse ? 1.15 : 2.0
    delta = direction * Float32(factor * 0.5 / (0.05 * peak))
    return (; baseline, biased=baseline+delta, delta, peak)
end

function with_control(f, state)
    observed = Pod[]
    remote = HIL.with_array_stream(state.wire, 1) do _
        global_node = only(find_globals(state.registry; interface="PipeWire:Interface:Node",
            properties=("node.name"=>"spiders-controller",)))
        bind(state.registry, global_node, Node; on_param=(_, _, id, _, _, pod)->begin
            id == SPA.PARAM_PROPS && pod !== nothing && push!(observed, pod)
            nothing
        end)
    end
    try
        return f(remote, observed)
    finally
        HIL.with_array_stream(state.wire, 1) do _
            close(remote)
        end
    end
end

function property_values(state, remote, observed)
    HIL.with_array_stream(state.wire, 1) do _
        empty!(observed)
        enum_params!(remote, SPA.PARAM_PROPS)
    end
    roundtrip(state.wire.core)
    return HIL.with_array_stream(state.wire, 1) do _
        Dict(String(name)=>pod_value(value) for pod in observed for (name,value) in SPA.Props(pod).values)
    end
end

function close_branch!(state, remote, observed, name)
    values = property_values(state, remote, observed)
    get(values, name, false) && return values
    HIL.with_array_stream(state.wire, 1) do _
        set_param!(remote, SPA.PARAM_PROPS, Pod(props_param(SPA.Props(name=>true))))
    end
    roundtrip(state.wire.core)
    confirmed = Ref{Any}(nothing)
    TRANSPORT.wait_until(; timeout=5, description="controller adoption of $name") do
        confirmed[] = property_values(state, remote, observed)
        get(confirmed[], name, false)
    end
    return confirmed[]
end

function record_optical(observer, tick, phase, camera, image, metadata, published, identity)
    observer === nothing && return
    MultirateMeasurement.record_optical!(observer; tick, phase, camera, image, metadata, published, identity)
end

function record_native(observer, tick, phase, name, payload, identity, pts)
    observer === nothing && return
    MultirateMeasurement.record_native!(observer; tick, phase, name, payload, identity, pts)
end

function camera_identity(execution, index, camera, metadata, tick)
    sequence = camera === :scc ? UInt64(cld(tick,SCC_PERIOD)) : UInt64(metadata.sequence)
    return AcquisitionIdentity(execution.domains[index], UInt64(1), sequence)
end

function publish_camera!(inbox, publisher, execution, camera, metadata, tick, phase)
    index = findfirst(==(camera), keys(execution.science.sensors))
    identity = camera_identity(execution, index, camera, metadata, tick)
    image = execution.buffers[index]
    stage_ok = EXT.publish_exposures!(publisher) do
        EXT.stage_exposure!(publisher, index+1, image, identity, metadata.pts,
            metadata.duration, EXT.trigger_state(execution.science, camera, metadata);
            optical_classification=EXT.sensor_optical_classification(execution.science, camera, metadata))
    end
    stage_ok || error("native camera stream rejected $camera at tick $tick")
    println(inbox, tick, ',', phase, ',', camera, ',', identity_record(identity).domain, ',',
        identity.generation, ',', identity.sequence, ',', metadata.pts, ',', metadata.duration, ',',
        get(metadata,:chopped_image_kind,:absent), ',', time_ns())
    return identity
end

function diagnostics!(state, samples)
    HIL.with_array_stream(state.wire, 1) do _
        for (name,capture) in pairs(state.captures)
            capture.failure === nothing || throw(capture.failure)
            for value in capture.samples
                push!(get!(() -> Any[], samples, name), value)
            end
            empty!(capture.samples)
        end
    end
    return nothing
end

function await_event!(state, execution, camera, identity, expect_command)
    started = time_ns()
    next_trigger = started
    receipt = nothing
    samples = Dict{Symbol,Vector{Any}}()
    command_output = camera === :scc ? Symbol("modal-residual") : Symbol("llowfs-modal-residual")
    camera_index = findfirst(==(camera), keys(execution.science.sensors)) + 1
    while true
        FGP.last_error(state.node) === nothing || throw(FGP.last_error(state.node))
        status = HIL.array_stream_status(state.wire, camera_index)
        status.failed && error("camera producer failed")
        pending = HIL.array_stream_status(state.wire, state.command_index)
        pending.failed && error("native HIL command consumer failed: $pending")
        new = pending.pending ?
            HIL.drain_pipewire_array!(execution.incoming_command, state.wire, state.command_index) : nothing
        if new !== nothing
            receipt === nothing || error("duplicate command for single camera event")
            expect_command || error("SCC produced a command before a new pair")
            receipt = new
        end
        diagnostics!(state, samples)
        now = time_ns()
        if expect_command
            matched = any(s -> s.identity == identity, get(samples,command_output,()))
            limiter = receipt !== nothing && any(s -> s.identity == receipt.identity, get(samples,LIMITER,()))
            receipt !== nothing && matched && limiter && !status.pending && return receipt, samples
        elseif !status.pending && now-started >= UInt64(3_000_000)
            return receipt, samples
        end
        now-started < UInt64(800_000_000) || error("missing camera event outcome camera=$camera identity=$identity receipt=$receipt samples=$(keys(samples)) status=$status")
        if now >= next_trigger
            trigger_process!(state.wire)
            next_trigger = now + UInt64(1_000_000)
        end
        sleep(0.0002)
    end
end

function record_samples(observer, tick, phase, state, samples)
    types = FG.output_formats(state.twin)
    for name in MONITORED
        for sample in get(samples, name, ())
            T = getproperty(types,name).element_type
            record_native(observer, tick, phase, name, reinterpret(T,sample.payload), sample.identity, sample.header.pts)
        end
    end
end

function run_events!(application, out, variant, preparation, state, observer, evidence)
    (; execution,options) = preparation
    science = execution.science
    publisher = EXT.ExposurePublisher(state.wire)
    quiet = EXT.emitter(execution)
    command = execution.command
    stimulus = prepare_stimulus(application, variant)
    bias_at = variant === :pulse ? 1652 : first(PHASES.saturate)
    restore_at = variant === :pulse ? 1653 : first(PHASES.release)
    biased_trial = variant in (:experiment, :pulse)
    evidence["stimulus"] = (; stimulus.peak, reference_delta=stimulus.delta, command_limit=options.command_limit, bias_at, restore_at, enabled=biased_trial)
    previous_command = nothing
    previous_scc = nothing
    consumed = 0
    close_receipts = Dict{String,Any}()
    evidence["closure"] = close_receipts
    applied = Dict{String,Any}()
    evidence["parameter_status"] = applied
    phase_counts = Dict{String,Any}()
    evidence["phases"] = phase_counts
    streams = Dict{String,Any}()
    evidence["stream_status"] = streams
    EXT.prepare_transport!(execution,state.wire)
    open(joinpath(out,"published-camera.csv"),"w") do inbox
        println(inbox,"tick,phase,camera,domain,generation,sequence,pts_ns,duration_ns,optical_kind,host_ns")
        open(joinpath(out,"applied-command.csv"),"w") do application_log
            println(application_log,"tick,phase,camera,camera_sequence,command_domain,command_generation,command_sequence,peak,host_ns")
            with_control(state) do remote, observed
                metadata = Dict{Symbol,Any}()
                emitter = (name,image,meta) -> begin
                    quiet(name,image,meta)
                    metadata[name] = meta
                    nothing
                end
                start = time_ns()
                ticks = variant === :smoke ? 18 : LAST_TICK
                for tick in 1:ticks
                    phase = phase_at(tick,variant)
                    if tick == 5
                        props = close_branch!(state, remote, observed, "llowfs-correction:closed")
                        close_receipts["llowfs"] = Dict("closed"=>props["llowfs-correction:closed"], "tick"=>tick)
                    elseif tick == first(PHASES.closed)
                        props = close_branch!(state, remote, observed, "correction:closed")
                        close_receipts["scc"] = Dict("closed"=>props["correction:closed"], "tick"=>tick)
                    elseif biased_trial && tick in (bias_at,restore_at)
                        value = phase === :saturate ? stimulus.biased : stimulus.baseline
                        FGP.replace_parameters!(state.node, Symbol("llowfs-modal-reference") => value)
                        applied[String(phase)*"_requested"] = FGP.parameter_status(state.node, Symbol("llowfs-reference"))
                    end
                    if !haskey(phase_counts,String(phase))
                        phase_counts[String(phase)] = Dict("llowfs"=>0, "scc"=>0, "command"=>0, "priming"=>0,
                            "clipping"=>0, "dm_nonzero"=>0, "first_host_ns"=>time_ns(), "last_host_ns"=>time_ns())
                        println("Phase $phase at tick $tick"); flush(stdout)
                    end
                    counts = phase_counts[String(phase)]
                    deadline = start+(tick-1)*FIRST_TIME_NS
                    while time_ns() < deadline
                        sleep(0.0002)
                    end
                    empty!(metadata)
                    EXT.step_clocked_source!(emitter, science, command; generation=UInt64(1)) == tick ||
                        error("plant model clock lost its fixed step")
                    science.source_command == command || error("native demand was not applied to plant input")
                    any(!iszero,science.source_dm_opd) && (counts["dm_nonzero"]+=1)
                    sent_scc = mod(tick-1,SCC_PERIOD)==0 && (!biased_trial || phase !== :dropout)
                    for (index,camera) in pairs(keys(science.sensors))
                        meta = metadata[camera]
                        meta.pts == (tick-1)*FIRST_TIME_NS && meta.duration == FIRST_TIME_NS ||
                            error("misaligned optical exposure")
                        published = camera === :llowfs || sent_scc
                        identity = published ? camera_identity(execution,index,camera,meta,tick) : nothing
                        record_optical(observer,tick,phase,camera,execution.buffers[index],meta,published,identity)
                    end
                    for camera in (:llowfs,:scc)
                        camera === :scc && !sent_scc && continue
                        identity = publish_camera!(inbox,publisher,execution,camera,metadata[camera],tick,phase)
                        counts[String(camera)]+=1
                        expected = camera === :llowfs ||
                            (previous_scc !== nothing && identity.sequence==previous_scc.sequence+1)
                        if camera === :scc
                            previous_scc = identity
                            expected || (counts["priming"]+=1)
                        end
                        receipt, samples = try
                            await_event!(state,execution,camera,identity,expected)
                        catch error
                            println(stderr,"transport failed at tick $tick ($phase): ", sprint(showerror,error))
                            flush(stderr)
                            rethrow()
                        end
                        record_samples(observer,tick,phase,state,samples)
                        receipt === nothing && continue
                        shared = receipt.identity
                        shared === nothing && error("shared demand omitted acquisition identity")
                        shared.domain != identity.domain || error("shared demand carried camera identity")
                        if previous_command !== nothing
                            previous_command.domain==shared.domain && previous_command.generation==shared.generation &&
                                previous_command.sequence+1==shared.sequence || error("shared command cohort or sequence changed")
                        end
                        previous_command = shared
                        max_command = maximum(abs,execution.incoming_command)
                        all(isfinite,execution.incoming_command) && max_command <= options.command_limit ||
                            error("native DM limit violated")
                        copyto!(command,execution.incoming_command)
                        record_native(observer,tick,phase,COMMAND,command,shared,receipt.pts)
                        consumed+=1
                        counts["command"]+=1
                        limiter = only(filter(s -> s.identity == shared, samples[LIMITER]))
                        feedback = reinterpret(Float32,limiter.payload)
                        any(!iszero,feedback) && (counts["clipping"]+=1)
                        println(application_log,tick,',',phase,',',camera,',',identity.sequence,',',
                            identity_record(shared).domain,',',shared.generation,',',shared.sequence,',',
                            max_command,',',time_ns())
                    end
                    if biased_trial && tick in (bias_at,restore_at)
                        applied[String(phase)*"_processed"] = FGP.parameter_status(state.node, Symbol("llowfs-reference"))
                    end
                    counts["last_host_ns"] = time_ns()
                    if tick % 150 == 0
                        println("tick=$tick commands=$consumed phase=$phase clipping=$(counts["clipping"])")
                        flush(stdout); flush(inbox); flush(application_log)
                    end
                end
            end
        end
    end
    for (index, option) in pairs(preparation.streams)
        streams[option.node_name] = HIL.array_stream_status(state.wire,index)
    end
    evidence["camera_domains"] = map(d->bytes2hex(collect(d.bytes)),execution.domains)
    evidence["last_command_identity"] = identity_record(previous_command)
    evidence["commands_consumed"] = consumed
    return nothing
end

function with_private_controller(f, application, feedback_options)
    prefix = ENV["PIPEWIREAO_PREFIX"]
    configuration = RTC.DeploymentConfiguration
    path = joinpath(application, "deployment.conf")
    deployment = configuration.decode(path, prefix)
    configuration.validate_application(deployment, path, prefix)
    session = configuration.decode(joinpath(application,"rtc","session.conf.in"),prefix)
    simulation = configuration.decode(joinpath(application,"simulation.conf"),prefix)
    configuration.validate_execution_groups(session)
    @testset "SPIDERS private multirate camera transport" begin
        TRANSPORT.with_sealed_core(application,prefix) do remote
            TRANSPORT.exercise(application,session,simulation["sensor_buffers"],remote;
                feedback_options,optical_check=f)
        end
    end
    configuration.validate_application(deployment, path, prefix)
    return nothing
end

function main(application,out,variant; prepared=nothing)
    application = abspath(application)
    variant in (:experiment,:control,:pulse,:smoke) || error("unknown experiment variant")
    observer = isdefined(Main,:MultirateMeasurement) && variant !== :smoke ?
        MultirateMeasurement.Observer(application) : nothing
    preparation = prepared === nothing ? prepare(application) : prepared
    evidence = Dict{String,Any}("application"=>application,"mode"=>variant,
        "model_step_ns"=>FIRST_TIME_NS,"scc_period_ticks"=>SCC_PERIOD,"cuda_optical_execution"=>preparation.graph_properties,
        "clean_stop"=>false)
    try
        with_private_controller(application,preparation.streams) do state
            evidence["running"] = true
            EXT._with_optical_execution(preparation.execution) do
                run_events!(application,out,variant,preparation,state,observer,evidence)
            end
        end
        evidence["clean_stop"]=true
    finally
        open(joinpath(out,JSON_FILE),"w") do output
            JSON.json(output,evidence)
            println(output)
        end
        observer === nothing || MultirateMeasurement.finish!(observer,out)
    end
    if variant in (:experiment,:pulse)
        phases = evidence["phases"]
        phases["dropout"]["scc"] == 0 && phases["dropout"]["llowfs"] == length(PHASES.dropout) ||
            error("dropout did not isolate SCC")
        phases["resume"]["priming"] == 1 && phases["resume"]["scc"] > 100 ||
            error("SCC did not reprime and return")
        phases["saturate"]["clipping"] > 0 && phases["release"]["dm_nonzero"] > 0 ||
            error("missing physical saturation or post-release optical feedback")
        all(p -> p["dm_nonzero"] > 0, values(phases)) || error("native DM never reached plant for a phase")
    end
    println("SPIDERS_MULTIRATE_PASS ",variant); flush(stdout)
    return preparation
end

if get(ENV,"SPIDERS_MULTIRATE_LOAD_ONLY","0") != "1"
    preparation = main(ARGS[1],ARGS[2],Symbol(ARGS[3]))
    control = length(ARGS) >= 4 ? ARGS[4] : ""
    if !isempty(control)
        EXT._with_optical_execution(preparation.execution) do
            EXT.warmup!(preparation.execution)
        end
        main(ARGS[1],control,Symbol(ARGS[5]); prepared=preparation)
    end
end
