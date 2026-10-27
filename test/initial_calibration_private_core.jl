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

@testset "Classic initial calibration uses actual owned streams and native actions" begin
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

    with_control_private_core() do remote, directory, daemon
        chmod(dirname(remote), 0o700)
        frontend = Calibration.calibration_graph(application;
            inputs=(raw="pixel-calibration:raw",), outputs=(:slopes, :flux, :validity))
        command = nothing
        server = client = serving = nothing
        try
            command = Calibration.calibration_graph(application;
                inputs=(requested="pdm-command:requested",),
                outputs=(:demanded, Symbol("constraint-feedback")))
            name, instance = "test.classic.initial.$(getpid())", Int64(71)
            @test_throws ArgumentError Calibration.prepare_initial_calibration(application, remote,
                merge(frontend, (;source_graph_sha256=repeat("0",64))), command;
                reference, name, instance, deadline=Native.monotonic()+120)
            progress("preparing actual Classic endpoint")
            server = Calibration.prepare_initial_calibration(application, remote, frontend, command;
                reference, name, instance, deadline=Native.monotonic()+300)
            progress("endpoint prepared")
            # Descriptor ownership transferred to the endpoint.
            frontend = command = nothing
            owner = server.effects
            progress("coordinator domain=1, wire acquisition domain=$(repr(owner.acquisition_domain))")
            capture_module = parentmodule(typeof(owner.capture))
            serving = @async try
                Server.serve!(server; deadline=Native.monotonic()+120)
            catch error
                error
            end
            plan = Acquisition.Plan(UInt64(1), reference, probes,
                recipe["estimator"]["measurement_count"], 1, Actions.Immediate(),
                Acquisition.Timeouts(ntuple(_ -> 120_000_000_000, 5)...))
            binding = ActionClient.Binding(remote, name, getpid(), instance)
            client = ActionClient.connect(binding, plan.run, plan.timeouts.ownership;
                command_count=length(reference))
            control_task = current_task()
            actions = DataType[]
            serials = UInt64[]
            observed = Actions.Exposure[]
            consumed = Int[]
            function observe(action, answer, serial)
                progress("completed $(nameof(typeof(action))) serial=$serial result=$(nameof(typeof(answer)))")
                push!(actions, typeof(action)); push!(serials, serial)
                if action isa Actions.Adopt
                    @test answer isa Actions.Adopted
                    @test answer.figure == probes[Int(action.probe)+1] && !answer.clipped
                    @test Wire.pipewire_probe_values(owner.hil) == answer.figure
                    @test length(consumed) == Int(action.probe)
                elseif action isa Actions.Collect
                    @test answer isa Actions.Responses && answer.valid
                    captured = capture_module.snapshot(owner.capture)
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
            function consume(probe, batch)
                @test current_task() === control_task
                @test probe == length(consumed)+1
                @test length(observed) == probe
                @test batch.valid && all(isfinite, batch.values)
                @test only(batch.exposures) == observed[probe]
                push!(consumed, probe)
            end
            progress("starting acquisition")
            result = Acquisition.acquire!(client, plan; observe, consume)
            progress("acquisition $(result.phase)")
            if result.phase != "complete"
                close(client); client = nothing
                outcome = fetch(serving)
                close(server)
                progress("failure=$(result.failure), recovery=$(result.recovery_failure), server=$outcome")
                # All native work is fenced before reading retained diagnostics.
                probe = owner.transport
                progress("probe sequence=$(probe.sequence), published=$(probe.published), received=$(probe.received), closed=$(probe.closed), error=$(probe.error)")
                progress("HIL $(Wire.pipewire_calibration_status(owner.hil))")
                progress("capture phase=$(owner.capture.phase), failure=$(owner.capture.failure), exception=$(owner.capture.exception)")
                for (name, slot) in pairs(owner.capture.slots)
                    progress("capture $name phase=$(slot.phase), receipt=$(slot.receipt)")
                end
                for worker in owner.workers
                    progress("graph done=$(istaskdone(worker.task)), error=$(worker.error[])")
                end
                @test result.phase == "complete"
                error("initial calibration failed: $(result.failure); server outcome: $outcome")
            end
            @test result.phase == "complete"
            @test result.restoration_confirmed && result.resume_permitted
            @test result.failure === result.recovery_failure === nothing
            @test actions == [Actions.Hold, Actions.Adopt, Actions.Settle, Actions.Collect,
                Actions.Adopt, Actions.Settle, Actions.Collect, Actions.Restore, Actions.Release]
            @test serials == UInt64.(1:9) && client.serial == 9
            @test isempty(client.records) && consumed == [1,2]
            @test length(result.responses) == length(observed) == 2
            if length(observed) == 2
                @test observed[1].sequence+1 == observed[2].sequence
                @test observed[1].start_model_ns+observed[1].duration_ns == observed[2].start_model_ns
                @test owner.cursor.sequence == observed[end].sequence
            end
            @test owner.capture.failure === :none
            @test all(slot -> slot.buffer.handle == C_NULL, values(owner.capture.slots))
            @test Wire.pipewire_calibration_status(owner.hil).pending_exposure === nothing
            # This is candidate acquisition evidence for one completion mode.
            # The pilot publishes no calibration bundle or activation request.
            @test Acquisition.document(result)["responses"] !== nothing
            close(client); client = nothing
            @test fetch(serving) === nothing
            @test server.phase === :Released
            close(server)
            @test owner.closed && owner.hil.closed
            @test all(worker -> istaskdone(worker.task), owner.workers)
            @test !isopen(server.wakeup) && !isopen(server.core)
            @test all(stream -> !isopen(stream), values(owner.capture.streams))
        finally
            client === nothing || close(client)
            server === nothing || close(server)
            frontend === nothing || FilterGraphIsland.close_execution(frontend.graph)
            command === nothing || FilterGraphIsland.close_execution(command.graph)
        end
    end
    @test application_hashes(application) == before
    @test !any(id -> id.name in ("CUDA", "AMDGPU"), keys(Base.loaded_modules))
end

end # module
