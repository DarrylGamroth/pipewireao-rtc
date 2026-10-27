# Optional actual CPU/native Capture selector. Run once with --threads=4 and
# PIPEWIREAORTC_INTERNAL_SOURCE_APPLICATION / _INSTRUMENT plus a fresh
# PIPEWIREAORTC_CAPTURE_DIRECTORY. Files remain owned by the explicit campaign.
# PIPEWIREAORTC_CAPTURE_GRAPH selects internal-source (default) or dark.
module InitialCalibrationCapturePrivateCoreTests

using Test, SHA
using PipeWireAO, PipeWireAORTC, FilterGraphIsland, FilterGraphPipeWire, JuliaFilterGraph
using AdaptiveOpticsSim, AdaptiveOpticsSimPipeWireHIL, AdaptiveOpticsCalibration
include("native_control_private_core.jl")

const Calibration = PipeWireAORTC.InstrumentCalibration
const Endpoint = PipeWireAORTC.NativeCalibrationEndpoint
const Actions = PipeWireAORTC.NativeCalibrationActionCodec
const Client = PipeWireAORTC.NativeCalibrationActionClient
const Native = PipeWireAORTC.NativeControlClient
const Wire = AdaptiveOpticsSimPipeWireHIL

progress(message) = (println("native Capture pilot: ",message); flush(stdout))
hashes(directory) = Dict(relpath(joinpath(root,file),directory)=>bytes2hex(sha256(read(joinpath(root,file))))
    for (root,_,files) in walkdir(directory) for file in files)

function snapshot(owner)
    progress("HIL=$(Wire.pipewire_calibration_status(owner.hil))")
    capture = owner.capture
    function slots()
        progress("capture phase=$(capture.phase), failure=$(capture.failure), exception=$(capture.exception), owner_cursor=$(owner.cursor)")
        for (name,slot) in pairs(capture.slots)
            progress("capture $name phase=$(slot.phase), receipt=$(slot.receipt)")
        end
    end
    if isopen(capture.core)
        try
            parentmodule(typeof(capture))._locked(slots,capture)
        catch error
            progress("slot snapshot lock unavailable: $(sprint(showerror,error))")
            slots()
        end
    else
        slots()
    end
    return nothing
end

@testset "Classic native Capture publishes verified immutable transported evidence" begin
    Threads.nthreads(:default) >= 4 || error("run this selector with --threads=4")
    application = ENV["PIPEWIREAORTC_INTERNAL_SOURCE_APPLICATION"]
    source = ENV["PIPEWIREAORTC_INTERNAL_SOURCE_INSTRUMENT"]
    capture_directory = abspath(ENV["PIPEWIREAORTC_CAPTURE_DIRECTORY"])
    @test !ispath(capture_directory) && !islink(capture_directory)
    app_before,source_before = hashes(application),hashes(source)
    simulation = PipeWireAORTC.DeploymentConfiguration.decode(joinpath(application,"simulation.conf"),
        get(ENV,"PIPEWIREAO_PREFIX","/opt/pipewireao"))
    @test simulation["backend"] == "cpu" && simulation["frame_encoding"] == "uint16"
    @test simulation["rate"] == 500 && simulation["exposure_ns"] == 1_896_000
    reference = zeros(Float32,simulation["command_count"])
    illumination = get(ENV,"PIPEWIREAORTC_CAPTURE_GRAPH","internal-source")
    illumination in ("internal-source","dark") || error("unsupported capture test graph")
    stage = illumination == "dark" ? "dark" : "lamp-training"
    actions = Any[]
    descriptor = settings = active = full_domain = closed_owner = nothing
    selected_hashes = Dict{String,String}()
    try
        with_control_private_core(;temporary_prefix="classic-native-capture-") do remote,directory,daemon
            chmod(dirname(remote),0o700)
            frontend = Calibration.calibration_graph(application;
                inputs=(raw="pixel-calibration:raw",),outputs=(:slopes,:flux,:validity))
            command = server = client = serving = nothing
            try
                command = Calibration.calibration_graph(application;inputs=(requested="pdm-command:requested",),
                    outputs=(:demanded,Symbol("constraint-feedback")))
                name,instance = "test.classic.capture.$(getpid())",Int64(118)
                progress("preparing one declared $illumination CPU session with capture storage")
                server = Calibration.prepare_initial_calibration(application,remote,frontend,command;
                    reference,name,instance,deadline=Native.monotonic()+300,simulation_graph=illumination,
                    capture_directory,capture_stage=stage,capture_maximum_bytes=3Calibration.CLASSIC_CAPTURE_BYTES)
                frontend = command = nothing
                owner = server.effects
                @test owner.capture_store !== nothing && owner.capture_store.directory == capture_directory
                @test owner.capture_store.stage == stage && owner.capture_store.illumination == illumination
                @test filemode(stat(capture_directory)) & 0o777 == 0o700
                settings,active = deepcopy(owner.capture_store.settings),copy(owner.active)
                full_domain = bytes2hex(collect(owner.acquisition_domain.bytes))
                @test settings["simulation_graph"] == illumination
                @test settings["exposure_ns"] == 1_896_000 && settings["rate"] == 500
                @test settings["rtc_graph_sha256"] == app_before[joinpath("rtc","graph.conf")]
                @test settings["detectors"]["detector"]["config"]["photon_noise"]
                @test settings["detectors"]["detector"]["config"]["readout_noise"]
                @test settings["detectors"]["detector"]["config"]["bits"] == 12
                for (group,projection) in (("frontend_parameters",owner.graphs.frontend),
                        ("command_parameters",owner.graphs.command))
                    for binding in projection.bindings
                        port = String(binding.port)
                        source_hash = Calibration.digest(binding.source.path)
                        group == "frontend_parameters" && (selected_hashes[port] = source_hash)
                        identity = projection.provenance[binding.port]
                        stored = settings[group][port]
                        @test stored["original_sha256"] == source_hash == identity["original_sha256"]
                        @test stored["sha256"] == identity["sha256"]
                        @test stored["hdu"] == identity["hdu"]
                        @test stored["axes"] == identity["axes"]
                        @test stored["target_type"] == identity["target_type"]
                        @test stored["target_shape"] == identity["target_shape"]
                    end
                end
                serving = @async try Endpoint.serve!(server;deadline=Native.monotonic()+360) catch error; error end
                client = Client.connect(Client.Binding(remote,name,getpid(),instance),UInt64(1),
                    Int64(120_000_000_000);command_count=length(reference))
                function complete(action)
                    submitted = Native.monotonic()
                    trace = Dict{String,Any}("action"=>string(nameof(typeof(action))),"submitted"=>submitted,
                        "phase_before"=>string(server.phase),"deadline"=>submitted+120)
                    push!(actions,trace)
                    progress("submit $(trace["action"]), phase=$(server.phase), serial=$(client.serial+1)")
                    try
                        answer = Client.complete!(client,action;deadline=submitted+120,record=false)
                        trace["completed"],trace["result"] = Native.monotonic(),string(nameof(typeof(answer)))
                        progress("complete $(trace["action"]), result=$(trace["result"]), phase=$(server.phase)")
                        return answer
                    catch error
                        trace["error"] = sprint(showerror,error)
                        trace["fault_at"] = Native.monotonic()
                        progress("action failed: $(trace["error"]); no retry")
                        snapshot(owner)
                        rethrow()
                    end
                end
                held = complete(Actions.Hold())
                @test held isa Actions.Held && held.cursor.sequence == 0
                @test Wire.pipewire_probe_values(owner.hil) == reference
                probe = UInt32(0)
                adopted = complete(Actions.Adopt(probe,reference))
                @test adopted isa Actions.Adopted && adopted.figure == reference && !adopted.clipped
                @test owner.probe == probe && Wire.pipewire_probe_values(owner.hil) == reference
                settled = complete(Actions.Settle(probe,adopted.cursor,Actions.Immediate()))
                @test settled isa Actions.Settled && server.phase === :Settled
                # Capture is admitted in Settled. A known preflight rejection
                # leaves that phase, cursor, payload budget and slots unchanged.
                rejected = complete(Actions.Capture(probe,settled.cursor,UInt32(4)))
                @test rejected isa Actions.Failed && rejected.reason === Actions.InvalidEvidence
                @test server.phase === :Settled && owner.cursor == settled.cursor
                @test owner.capture_store.used_bytes == 0 && owner.capture_store.serial == 0
                @test isempty(readdir(capture_directory))
                @test all(slot -> slot.receipt === nothing,values(owner.capture.slots))
                @test Wire.pipewire_calibration_status(owner.hil).pending_exposure === nothing
                descriptor = complete(Actions.Capture(probe,settled.cursor,UInt32(3)))
                @test descriptor isa Actions.Captured && server.phase === :Captured
                @test descriptor.frames == 3 && descriptor.bytes == 3Calibration.CLASSIC_CAPTURE_BYTES
                @test descriptor.cursor == owner.cursor && descriptor.cursor.sequence == 3
                @test owner.capture_store.used_bytes == descriptor.bytes
                @test descriptor.manifest == "run-1-serial-5/manifest.json"
                @test isempty(client.records)
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
                @test all(stream -> !isopen(stream),values(owner.capture.streams))
                @test !isopen(server.wakeup) && !isopen(server.core)
                @test Wire.pipewire_calibration_status(owner.hil).pending_exposure === nothing
                closed_owner = owner
            catch error
                progress("session failed: $(sprint(showerror,error)); no retry")
                server === nothing || snapshot(server.effects)
                rethrow()
            finally
                client === nothing || close(client)
                server === nothing || close(server)
                frontend === nothing || FilterGraphIsland.close_execution(frontend.graph)
                command === nothing || FilterGraphIsland.close_execution(command.graph)
            end
        end
        # File use begins only after public Restore/Release and endpoint/core closure.
        @test closed_owner !== nothing && closed_owner.closed
        evidence_before = hashes(capture_directory)
        result = Calibration.read_capture(capture_directory,descriptor;expected_profile="classic",
            expected_stage=stage,expected_illumination=illumination,expected_settings=settings)
        @test result.manifest["settings"] == settings
        @test result.manifest["stage"] == stage && result.manifest["illumination"] == illumination
        @test result.manifest["domain_mapping"] == Dict("coordinator"=>UInt64(1),"wire"=>full_domain)
        @test length(result.samples) == 3
        @test result.manifest["cursor"]["model_ns"] == descriptor.cursor.model_ns
        @test result.manifest["settings"]["frontend_parameters"]["active"]["original_sha256"] == selected_hashes["active"]
        for (index,sample) in enumerate(result.samples)
            @test eltype(sample.arrays.raw) === UInt16 && size(sample.arrays.raw) == (352,352)
            @test maximum(sample.arrays.raw) <= 0x0fff
            @test sample.exposure.sequence == index && sample.exposure.duration_ns == 1_896_000
            @test sample.exposure.domain == 1
            @test sample.quality["valid_rois"] == count(sample.arrays.validity)
            for receipt in values(sample.metadata)
                @test receipt["identity"]["domain"] == full_domain
                @test receipt["identity"]["generation"] == sample.exposure.generation
                @test receipt["identity"]["sequence"] == sample.exposure.sequence
                @test receipt["model_start_ns"] == sample.exposure.start_model_ns
                @test receipt["duration_ns"] == sample.exposure.duration_ns
            end
            if index > 1
                previous = result.samples[index-1].exposure
                @test sample.exposure.start_model_ns-previous.start_model_ns == 2_000_000
                @test sample.exposure.start_model_ns-(previous.start_model_ns+previous.duration_ns) == 104_000
                @test sample.arrays.raw !== result.samples[index-1].arrays.raw
            end
        end
        invalid_active = [findall(active .& .!sample.arrays.validity) for sample in result.samples]
        @test any(!isempty,invalid_active)
        raw_summary = [Dict("minimum"=>minimum(sample.arrays.raw),"maximum"=>maximum(sample.arrays.raw),
            "mean_adc"=>sum(Float64,sample.arrays.raw)/length(sample.arrays.raw)) for sample in result.samples]
        progress("three $illumination exposures; raw ADC summaries=$raw_summary; validity retained, no interaction acceptance")
        # Owned read arrays may change without modifying immutable on-disk evidence.
        original = result.samples[1].arrays.raw[1,1]
        result.samples[1].arrays.raw[1,1] = xor(original,UInt16(1))
        @test hashes(capture_directory) == evidence_before
        reread = Calibration.read_capture(capture_directory,descriptor;expected_profile="classic",
            expected_stage=stage,expected_illumination=illumination,expected_settings=settings)
        @test reread.samples[1].arrays.raw[1,1] == original
        @test all(filemode(stat(joinpath(capture_directory,path))) & 0o777 == 0o444 for path in keys(evidence_before))
        if haskey(ENV,"PIPEWIREAORTC_CAPTURE_EVIDENCE")
            PipeWireAORTC.Common.write_json(ENV["PIPEWIREAORTC_CAPTURE_EVIDENCE"],Dict(
                "scope"=>"actual native Classic Capture transport/storage; intrinsic invalidity retained; no calibration acceptance",
                "descriptor"=>Client.document(descriptor),"actions"=>actions,"invalid_active"=>invalid_active,
                "illumination"=>illumination,"raw_adc_summary"=>raw_summary,
                "exposures"=>[Dict("sequence"=>sample.exposure.sequence,"start_model_ns"=>sample.exposure.start_model_ns,
                    "duration_ns"=>sample.exposure.duration_ns) for sample in reread.samples],
                "capture_files"=>evidence_before,"application_files"=>app_before,"source_files"=>source_before))
        end
    finally
        @test hashes(application) == app_before
        @test hashes(source) == source_before
        @test !any(id -> id.name in ("CUDA","AMDGPU"),keys(Base.loaded_modules))
    end
end

end # module
