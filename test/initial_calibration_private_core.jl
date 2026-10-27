# Optional CPU optical pilot. Run with four Julia threads and an existing built
# Classic application; the fixture starts and closes its own native core.
module InitialCalibrationPrivateCoreTests

using Test, SHA, LinearAlgebra
using PipeWireAO, PipeWireAORTC, FilterGraphIsland, FilterGraphPipeWire, JuliaFilterGraph
using AdaptiveOpticsSim, AdaptiveOpticsSimPipeWireHIL, AdaptiveOpticsCalibration

include("native_control_private_core.jl")

const Calibration = PipeWireAORTC.InstrumentCalibration
const Server = PipeWireAORTC.NativeCalibrationEndpoint
const Actions = PipeWireAORTC.NativeCalibrationActionCodec
const ActionClient = PipeWireAORTC.NativeCalibrationActionClient
const Acquisition = PipeWireAORTC.CalibrationAcquisition
const Native = PipeWireAORTC.NativeControlClient
const Deployment = PipeWireAORTC.DeploymentConfiguration
const Wire = AdaptiveOpticsSimPipeWireHIL

function progress(message)
    println("initial calibration pilot: ", message)
    flush(stdout)
end

function application_hashes(directory)
    return Dict(relpath(joinpath(root, file), directory) =>
        bytes2hex(sha256(read(joinpath(root, file))))
        for (root, _, files) in walkdir(directory) for file in files)
end

@testset "Classic rejects under-threshold measurements and restores through native actions" begin
    Threads.nthreads(:default) >= 4 || error("run this optical pilot with --threads=4")
    application = ENV["PIPEWIREAORTC_CALIBRATION_APPLICATION"]
    before = application_hashes(application)
    recipe = Calibration.read_recipe(application)
    simulation = Deployment.decode(joinpath(application, "simulation.conf"),
        get(ENV, "PIPEWIREAO_PREFIX", "/opt/pipewireao"))
    @test simulation["backend"] == "cpu"
    @test simulation["command_scale"] == 1.0e-6
    @test simulation["frame_encoding"] == "uint16"
    declaration = PipeWireAORTC.InstrumentConfiguration.load_simulation(
        joinpath(application, simulation["plant"]["definition"]))
    detector = declaration.authoring["components"]["detector"]["config"]
    @test detector["photon_noise"]
    @test detector["readout_noise"]

    parameters = Calibration.read_parameters(application)
    # The deployed VDM path completes active coordinates before its full-VDM
    # physical projection; neither dimensions nor actuator positions infer it.
    completion = parameters[Symbol("vdm-to-pdm")] *
        parameters[Symbol("active-to-full")] * parameters[Symbol("controller-to-vdm")]
    @test size(completion, 1) == 277
    @test size(completion, 2) > 1 # This two-sign pilot covers only a prefix.
    mode = findfirst(column -> any(!iszero, column), eachcol(completion))
    @test mode !== nothing
    reference = zeros(Float32, 277)
    amplitude = Float32(recipe["poke_m"] / simulation["command_scale"])
    @test isfinite(amplitude) && amplitude > 0
    delta = amplitude .* completion[:, something(mode)]
    probes = [reference .+ delta, reference .- delta]
    @test probes[1] == -probes[2] && any(!iszero, probes[1])

    try
        with_control_private_core() do remote, directory, daemon
            chmod(dirname(remote), 0o700)
            for (index, scenario) in enumerate((:under_threshold, :cancel_before_hold, :controller_loss))
                @testset "$scenario" begin
                    frontend = Calibration.calibration_graph(application;
                        inputs=(raw="pixel-calibration:raw",), outputs=(:slopes, :flux, :validity))
                    command = server = client = serving = nothing
                    try
                        command = Calibration.calibration_graph(application;
                            inputs=(requested="pdm-command:requested",),
                            outputs=(:demanded, Symbol("constraint-feedback")))
                        name = "test.classic.initial.$(getpid()).$scenario"
                        instance = Int64(70+index)
                        if index == 1
                            @test_throws ArgumentError Calibration.prepare_initial_calibration(application, remote,
                                merge(frontend, (;source_graph_sha256=repeat("0",64))), command;
                                reference, name, instance, deadline=Native.monotonic()+120)
                        end
                        progress("preparing actual Classic endpoint for $scenario")
                        server = Calibration.prepare_initial_calibration(application, remote, frontend, command;
                            reference, name, instance, deadline=Native.monotonic()+300)
                        # Descriptor ownership transferred to the endpoint.
                        frontend = command = nothing
                        owner = server.effects
                        @test owner.active == parameters[:active]
                        progress("$scenario coordinator domain=1, wire acquisition domain=$(repr(owner.acquisition_domain))")
                        if index == 1
                            progress("selected frontend bindings=$([(entry.port, entry.source.path, Calibration.digest(entry.source.path)) for entry in owner.graphs.frontend.bindings])")
                        end
                        capture_module = parentmodule(typeof(owner.capture))
                        serve_deadline = Native.monotonic()+120
                        serving = @async try
                            Server.serve!(server; deadline=serve_deadline)
                        catch error
                            error
                        end
                        plan = Acquisition.Plan(UInt64(1), reference, probes,
                            recipe["estimator"]["measurement_count"], 1, Actions.Immediate(),
                            Acquisition.Timeouts(ntuple(_ -> 120_000_000_000, 5)...))
                        binding = ActionClient.Binding(remote, name, getpid(), instance)
                        client = ActionClient.connect(binding, plan.run, plan.timeouts.ownership;
                            command_count=length(reference))
                        if scenario === :controller_loss
                            held = ActionClient.complete!(client, Actions.Hold();
                                deadline=Native.monotonic()+120, record=false)
                            @test held isa Actions.Held
                            @test held.cursor.sequence == 0 && owner.token == 1
                            close(client); client = nothing
                            outcome = fetch(serving)
                            progress("idle controller loss server outcome=$outcome")
                            @test outcome isa Exception
                            @test Native.monotonic() < serve_deadline
                            @test server.phase === :Fault && server.serial == 1
                            # Hold adopted the reference once. A hidden Restore
                            # would advance its token; no exposure was admitted.
                            @test owner.closed && owner.token == 1 && owner.probe === nothing
                            @test owner.cursor.sequence == 0
                            @test all(slot -> slot.receipt === nothing, values(owner.capture.slots))
                            @test Wire.pipewire_calibration_status(owner.hil).pending_exposure === nothing
                        else
                            actions = DataType[]
                            serials = UInt64[]
                            observed = Actions.Exposure[]
                            consumed = Int[]
                            function observe(action, answer, serial)
                                progress("$scenario completed $(nameof(typeof(action))) serial=$serial result=$(nameof(typeof(answer)))")
                                push!(actions, typeof(action)); push!(serials, serial)
                                if action isa Actions.Adopt
                                    @test answer isa Actions.Adopted
                                    @test answer.figure == probes[Int(action.probe)+1] && !answer.clipped
                                    @test Wire.pipewire_probe_values(owner.hil) == answer.figure
                                elseif action isa Actions.Collect
                                    @test answer isa Actions.Responses
                                    captured = capture_module.snapshot(owner.capture)
                                    invalid = findall(i -> owner.active[i] && !captured.arrays.validity[i], eachindex(owner.active))
                                    thresholds = owner.graphs.frontend.parameters[:thresholds]
                                    finite = all(isfinite, answer.values)
                                    expected = all(i -> !owner.active[i] || captured.arrays.validity[i], eachindex(owner.active)) && finite
                                    progress("collection validity=$(answer.valid), active_count=$(count(owner.active)), invalid_active_indices=$invalid, nonfinite_responses=$(count(!isfinite, answer.values)), raw_extrema=$(extrema(captured.arrays.raw))")
                                    progress("invalid active flux/thresholds=$([(i, captured.arrays.flux[i], thresholds[i,:]) for i in invalid])")
                                    @test answer.valid == expected
                                    @test finite && !isempty(invalid)
                                    @test all(i -> isfinite(captured.arrays.flux[i]) &&
                                        captured.arrays.flux[i] < thresholds[i,2], invalid)
                                    @test eltype(captured.arrays.raw) === UInt16
                                    @test size(captured.arrays.raw) == (352,352)
                                    @test answer.values == vec(permutedims(captured.arrays.slopes))
                                    exposure = only(answer.exposures)
                                    @test exposure.domain == UInt64(1)
                                    for receipt in values(captured.metadata)
                                        @test receipt.identity.domain == owner.acquisition_domain
                                        @test (receipt.identity.generation, receipt.identity.sequence) ==
                                            (exposure.generation, exposure.sequence)
                                        @test receipt.model_start_ns == exposure.start_model_ns
                                        @test receipt.duration_ns == exposure.duration_ns == simulation["exposure_ns"]
                                        @test receipt.header == captured.metadata.raw.header
                                    end
                                    push!(observed, exposure)
                                elseif action isa Actions.Restore
                                    @test answer isa Actions.Restored && !answer.clipped
                                    @test answer.figure == reference && owner.restored
                                    @test Wire.pipewire_probe_values(owner.hil) == reference
                                elseif action isa Actions.Release
                                    @test answer isa Actions.Released && !owner.hil.started
                                end
                            end
                            consume(probe, batch) = push!(consumed, probe)
                            cancelled() = scenario === :cancel_before_hold
                            progress("starting $scenario acquisition")
                            result = Acquisition.acquire!(client, plan; observe, consume, cancelled)
                            expected_failure = scenario === :under_threshold ? "InvalidEvidence" : "Cancelled"
                            progress("$scenario acquisition $(result.phase), failure=$(result.failure)")
                            if result.phase == "fault"
                                close(client); client = nothing
                                outcome = fetch(serving)
                                close(server)
                                progress("unexpected fault server=$outcome, HIL=$(Wire.pipewire_calibration_status(owner.hil))")
                                progress("capture failure=$(owner.capture.failure), exception=$(owner.capture.exception)")
                                for (name, slot) in pairs(owner.capture.slots)
                                    progress("capture $name phase=$(slot.phase), receipt=$(slot.receipt)")
                                end
                                @test result.phase == "aborted"
                                error("initial calibration fault: $(result.failure); server outcome: $outcome")
                            end
                            @test result.phase == "aborted" && result.failure == expected_failure
                            @test result.restoration_confirmed && result.resume_permitted
                            @test result.recovery_failure === nothing
                            expected_actions = scenario === :under_threshold ?
                                [Actions.Hold, Actions.Adopt, Actions.Settle, Actions.Collect, Actions.Restore, Actions.Release] :
                                [Actions.Restore, Actions.Release]
                            @test length(actions) == length(expected_actions) &&
                                all(actual <: expected for (actual,expected) in zip(actions,expected_actions))
                            @test serials == UInt64.(1:length(expected_actions)) && client.serial == length(expected_actions)
                            @test isempty(client.records) && isempty(consumed)
                            if scenario === :under_threshold
                                @test length(observed) == 1
                                @test owner.cursor.sequence == only(observed).sequence == 1
                            else
                                @test isempty(observed) && owner.cursor.sequence == 0
                                @test all(slot -> slot.receipt === nothing, values(owner.capture.slots))
                            end
                            @test owner.capture.failure === :none
                            @test Wire.pipewire_calibration_status(owner.hil).pending_exposure === nothing
                            # Aborted candidate evidence does not promote responses;
                            # this test publishes no calibration bundle or activation.
                            @test Acquisition.document(result)["responses"] === nothing
                            close(client); client = nothing
                            @test fetch(serving) === nothing
                            @test server.phase === :Released
                        end
                        close(server)
                        @test owner.closed && owner.hil.closed && !owner.hil.started
                        @test all(worker -> istaskdone(worker.task) && worker.error[] === nothing, owner.workers)
                        @test all(slot -> slot.buffer.handle == C_NULL, values(owner.capture.slots))
                        @test !isopen(server.wakeup) && !isopen(server.core)
                        @test all(stream -> !isopen(stream), values(owner.capture.streams))
                    finally
                        client === nothing || close(client)
                        server === nothing || close(server)
                        frontend === nothing || FilterGraphIsland.close_execution(frontend.graph)
                        command === nothing || FilterGraphIsland.close_execution(command.graph)
                    end
                end
            end
        end
    finally
        @test application_hashes(application) == before
        @test !any(id -> id.name in ("CUDA", "AMDGPU"), keys(Base.loaded_modules))
    end
end

end # module
