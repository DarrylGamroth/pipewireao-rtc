# Optional CPU selector: --threads=4, PIPEWIREAORTC_INTERNAL_SOURCE_APPLICATION,
# and PIPEWIREAORTC_INTERNAL_SOURCE_INSTRUMENT name the built app and its source.
# No calibration is promoted; native validity is preserved even when false.
module InternalSourcePrivateCoreTests

using Test, SHA, LinearAlgebra
using PipeWireAO, PipeWireAORTC, FilterGraphIsland, FilterGraphPipeWire, JuliaFilterGraph
using AdaptiveOpticsSim, AdaptiveOpticsSimPipeWireHIL, AdaptiveOpticsCalibration
include("native_control_private_core.jl")

const Calibration = PipeWireAORTC.InstrumentCalibration
const IC = PipeWireAORTC.InstrumentConfiguration
const Endpoint = PipeWireAORTC.NativeCalibrationEndpoint
const Actions = PipeWireAORTC.NativeCalibrationActionCodec
const Client = PipeWireAORTC.NativeCalibrationActionClient
const Native = PipeWireAORTC.NativeControlClient
const Wire = AdaptiveOpticsSimPipeWireHIL
const Graphs = AdaptiveOpticsSim.AlgorithmGraphs

hashes(directory) = Dict(relpath(joinpath(root,file),directory) =>
    bytes2hex(sha256(read(joinpath(root,file))))
    for (root,_,files) in walkdir(directory) for file in files)
progress(message) = (println("internal source pilot: ",message); flush(stdout))

@testset "Classic declared internal source through native calibration actions" begin
    Threads.nthreads(:default) >= 4 || error("run this CPU selector with --threads=4")
    application = ENV["PIPEWIREAORTC_INTERNAL_SOURCE_APPLICATION"]
    source = ENV["PIPEWIREAORTC_INTERNAL_SOURCE_INSTRUMENT"]
    before, source_before = hashes(application), hashes(source)
    simulation = PipeWireAORTC.DeploymentConfiguration.decode(joinpath(application,"simulation.conf"),
        get(ENV,"PIPEWIREAO_PREFIX","/opt/pipewireao"))
    @test simulation["backend"] == "cpu"
    @test simulation["frame_encoding"] == "uint16"
    @test simulation["rate"] == 500 && simulation["pacing_rate_hz"] == 10
    @test simulation["exposure_ns"] == 1_896_000 && simulation["command_scale"] == 1e-6
    declaration = IC.load_simulation(joinpath(application,simulation["plant"]["definition"]))
    settings = IC.settings(declaration,simulation["plant"]["settings"])
    production = IC.graph_document(declaration,settings)
    internal = IC.graph_document(declaration,settings;simulation_graph="internal-source")
    detector(graph) = only(node for node in graph["nodes"] if node["name"] == "detector")
    @test detector(internal) == detector(production)
    @test detector(internal)["config"]["photon_noise"] && detector(internal)["config"]["readout_noise"]
    @test detector(internal)["config"]["bits"] == 12
    @test declaration.document["sources"]["guide"]["source_magnitude"] == 2
    @test any(node -> node["name"] == "atmosphere",production["nodes"])
    @test any(link -> link["destination"] == "pupil_opd_composition.uncompensated_opd" &&
        link["source"] == "atmosphere.atmosphere_opd",production["links"])
    @test all(node -> node["name"] != "atmosphere",internal["nodes"])
    @test !any(link -> link["destination"] == "pupil_opd_composition.uncompensated_opd",internal["links"])
    zero_input = only(input for input in internal["inputs"] if input["destination"] ==
        "pupil_opd_composition.uncompensated_opd")
    zero_binding = declaration.document["bindings"][zero_input["binding"]]
    @test zero_binding["kind"] == "zeros" && zero_binding["type"] == "Float32"
    recipe, parameters = Calibration.read_recipe(application), Calibration.read_parameters(application)
    completion = parameters[Symbol("vdm-to-pdm")] * parameters[Symbol("active-to-full")] *
        parameters[Symbol("controller-to-vdm")]
    mode = something(findfirst(column -> any(!iszero,column),eachcol(completion)))
    reference = zeros(Float32,simulation["command_count"])
    delta = Float32(recipe["poke_m"] / simulation["command_scale"]) .* completion[:,mode]
    @test any(!iszero,delta)
    figures = (reference,reference .+ delta,reference .- delta)
    records = Any[]
    actions = Any[]
    quiet_actions = get(ENV,"PIPEWIREAORTC_INTERNAL_SOURCE_QUIET_ACTIONS","0") == "1"
    try
        with_control_private_core(;temporary_prefix="classic-internal-source-") do remote,directory,daemon
            chmod(dirname(remote),0o700)
            frontend = Calibration.calibration_graph(application;
                inputs=(raw="pixel-calibration:raw",),outputs=(:slopes,:flux,:validity))
            command = server = client = nothing
            try
                command = Calibration.calibration_graph(application;inputs=(requested="pdm-command:requested",),
                    outputs=(:demanded,Symbol("constraint-feedback")))
                name, instance = "test.classic.internal.$(getpid())", Int64(108)
                progress("preparing declared internal-source graph; magnitude=2, poke_m=$(recipe["poke_m"]), mode=$mode")
                server = Calibration.prepare_initial_calibration(application,remote,frontend,command;
                    reference,name,instance,deadline=Native.monotonic()+300,simulation_graph="internal-source")
                frontend = command = nothing
                owner = server.effects
                @test Graphs.graph_name(owner.hil.boundary.graph) == Symbol(internal["name"])
                @test :atmosphere ∉ keys(owner.hil.boundary.graph.nodes)
                @test owner.active == parameters[:active]
                capture_module = parentmodule(typeof(owner.capture))
                serving = @async try Endpoint.serve!(server;deadline=Native.monotonic()+300) catch error; error end
                client = Client.connect(Client.Binding(remote,name,getpid(),instance),UInt64(1),
                    Int64(120_000_000_000);command_count=length(reference))
                identity(value) = value === nothing ? nothing : Dict("domain"=>repr(value.domain),
                    "generation"=>value.generation,"sequence"=>value.sequence)
                function capture_state()
                    isopen(owner.capture.core) || return Dict("core_closed"=>true)
                    state = capture_module._locked(owner.capture) do
                        Dict{String,Any}("sampled_at"=>Native.monotonic(),"phase"=>owner.capture.phase,
                            "failure"=>string(owner.capture.failure),"waiting"=>owner.capture.waiting,
                            "hil_status"=>Wire.pipewire_calibration_status(owner.hil),
                            "expected"=>identity(owner.capture.expected),
                            "slots"=>Dict(string(name)=>Dict("phase"=>slot.phase,
                                "receipt"=>slot.receipt === nothing ? nothing : identity(slot.receipt.identity))
                                for (name,slot) in pairs(owner.capture.slots)))
                    end
                    state["hil_status"] = repr(state["hil_status"])
                    # Copy synchronization metadata separately; do not nest the
                    # native loop lock with Julia's condition spinlock or print.
                    state["condition"] = lock(owner.wakeup.cond) do
                        Dict("set"=>owner.wakeup.set,"waiters"=>
                            [Dict("task"=>objectid(task),"server"=>task===serving) for task in owner.wakeup.cond.waitq])
                    end
                    state["server_phase"],state["sample_finished_at"] = string(server.phase),Native.monotonic()
                    return state
                end
                function complete(action)
                    submitted = Native.monotonic()
                    trace = Dict{String,Any}("action"=>string(nameof(typeof(action))),"submitted"=>submitted,
                        "deadline"=>submitted+120,"phase_before"=>string(server.phase))
                    push!(actions,trace)
                    quiet_actions || progress("submit $(trace["action"]) at $submitted, deadline=$(trace["deadline"]), phase=$(server.phase)")
                    # One passive sample only. The timer/task never signals the
                    # acquisition condition or requests native graph progress.
                    watch_timer = action isa Actions.Collect ? Timer(10) : nothing
                    watching = watch_timer === nothing ? nothing : @async try
                        wait(watch_timer)
                        if !haskey(trace,"completed") && !haskey(trace,"fault_at")
                            trace["outstanding_snapshot"] = capture_state()
                            progress("outstanding Collect snapshot=" * PipeWireAORTC.Common.JSON.json(trace["outstanding_snapshot"]))
                        end
                    catch error
                        if !(error isa EOFError)
                            trace["diagnostic_error"] = sprint(showerror,error)
                            progress("passive diagnostic error=$(trace["diagnostic_error"])")
                        end
                    end
                    try
                        answer = Client.complete!(client,action;deadline=submitted+120,record=false)
                        trace["completed"],trace["result"] = Native.monotonic(),string(nameof(typeof(answer)))
                        quiet_actions || progress("complete $(trace["action"]) at $(trace["completed"]), result=$(trace["result"]), phase=$(server.phase)")
                        return answer
                    catch error
                        trace["fault_at"],trace["error"] = Native.monotonic(),sprint(showerror,error)
                        progress("fault $(trace["action"]) at $(trace["fault_at"]), phase=$(server.phase), error=$(trace["error"])")
                        progress("HIL=$(Wire.pipewire_calibration_status(owner.hil))")
                        trace["fault_snapshot"] = capture_state()
                        progress("fault capture snapshot=" * PipeWireAORTC.Common.JSON.json(trace["fault_snapshot"]))
                        rethrow()
                    finally
                        watch_timer === nothing || close(watch_timer)
                        watching === nothing || fetch(watching)
                    end
                end
                @test complete(Actions.Hold()) isa Actions.Held
                for (index,figure) in enumerate(figures)
                    probe = UInt32(index-1)
                    adopted = complete(Actions.Adopt(probe,figure))
                    @test adopted isa Actions.Adopted && adopted.figure == figure && !adopted.clipped
                    @test Wire.pipewire_probe_values(owner.hil) == figure
                    settled = complete(Actions.Settle(probe,adopted.cursor,Actions.Immediate()))
                    @test settled isa Actions.Settled
                    answer = complete(Actions.Collect(probe,settled.cursor,
                        UInt32(recipe["estimator"]["measurement_count"]),UInt32(1)))
                    @test answer isa Actions.Responses
                    captured = capture_module.snapshot(owner.capture)
                    invalid = findall(i -> owner.active[i] && !captured.arrays.validity[i],eachindex(owner.active))
                    @test all(isfinite,answer.values)
                    @test answer.valid == isempty(invalid)
                    @test answer.values == vec(permutedims(captured.arrays.slopes))
                    @test eltype(captured.arrays.raw) === UInt16 && size(captured.arrays.raw) == (352,352)
                    @test maximum(captured.arrays.raw) <= 0x0fff
                    exposure = only(answer.exposures)
                    @test exposure.domain == 1 && exposure.sequence == index
                    for receipt in values(captured.metadata)
                        @test receipt.identity.domain == owner.acquisition_domain
                        @test (receipt.identity.generation,receipt.identity.sequence) == (exposure.generation,exposure.sequence)
                        @test receipt.model_start_ns == exposure.start_model_ns
                        @test receipt.duration_ns == exposure.duration_ns == simulation["exposure_ns"]
                        @test receipt.header == captured.metadata.raw.header
                    end
                    thresholds = owner.graphs.frontend.parameters[:thresholds]
                    record = Dict("figure"=>("flat","positive","negative")[index],"valid"=>answer.valid,
                        "sequence"=>exposure.sequence,"active_count"=>count(owner.active),"invalid_active"=>invalid,
                        "raw_adc_extrema"=>collect(extrema(captured.arrays.raw)),
                        "invalid_flux_thresholds"=>[Dict("index"=>i,"flux"=>captured.arrays.flux[i],
                            "thresholds"=>thresholds[i,:]) for i in invalid])
                    push!(records,record)
                    progress(PipeWireAORTC.Common.JSON.json(record))
                end
                restored = complete(Actions.Restore(reference,Actions.Immediate()))
                @test restored isa Actions.Restored && restored.figure == reference && !restored.clipped
                @test owner.restored && Wire.pipewire_probe_values(owner.hil) == reference
                @test complete(Actions.Release()) isa Actions.Released
                close(client); client = nothing
                @test fetch(serving) === nothing && server.phase === :Released
                close(server)
                @test owner.closed && owner.hil.closed && !owner.hil.started
                @test all(worker -> istaskdone(worker.task) && worker.error[] === nothing,owner.workers)
                @test all(slot -> slot.buffer.handle == C_NULL,values(owner.capture.slots))
                @test !isopen(server.wakeup) && !isopen(server.core)
                @test all(stream -> !isopen(stream),values(owner.capture.streams))
                @test Wire.pipewire_calibration_status(owner.hil).pending_exposure === nothing
            finally
                client === nothing || close(client)
                server === nothing || close(server)
                frontend === nothing || FilterGraphIsland.close_execution(frontend.graph)
                command === nothing || FilterGraphIsland.close_execution(command.graph)
            end
        end
    finally
        @test hashes(application) == before
        @test hashes(source) == source_before
        @test !any(id -> id.name in ("CUDA","AMDGPU"),keys(Base.loaded_modules))
        if haskey(ENV,"PIPEWIREAORTC_INTERNAL_SOURCE_EVIDENCE")
            open(ENV["PIPEWIREAORTC_INTERNAL_SOURCE_EVIDENCE"],"w") do io
                PipeWireAORTC.Common.JSON.json(io,Dict("scope"=>"three-frame declared stationary-source-equivalent CPU pilot; no numerical acceptance or lamp qualification",
                    "measurements"=>records,"actions"=>actions,"application_sha256"=>before,"source_sha256"=>source_before))
            end
        end
    end
end

end # module
