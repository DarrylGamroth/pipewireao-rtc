using Test
include("heart_calibration_owner.jl")
const NativeOwner = HeartCalibrationOwner

@testset "native owner options preserve the selected transport" begin
    mktempdir() do directory
        arguments = String[]
        for name in Protocol.NATIVE_REQUIRED_OPTIONS
            value = name == "profile" ? "copper" : name == "rate" ? "100" :
                name == "exposure-ns" ? "10000000" :
                name == "control-node" ? "fixture.calibration" :
                name == "control-instance" ? "19" : joinpath(directory, name)
            append!(arguments, ["--$name", value])
        end
        append!(arguments, ["--transport", "heart", "--controller-node", "fixture.heart",
            "--controller-pid", "123", "--controller-instance", "17",
            "--heart-client", "/usr/bin/true", "--heart-native-runtime", joinpath(directory, "native"),
            "--heart-probe-directory", joinpath(directory, "probes"), "--heart-telemetry-max-bytes", "4096"])
        options = NativeOwner.options(arguments)
        @test options.transport === :heart
        @test options.heart_telemetry_max_bytes == 4096
        @test options.heart_classic_order == collect(1:188)
        @test_throws ArgumentError NativeOwner.options(vcat(arguments, ["--heart-client", "/usr/bin/true"]))
        @test_throws ArgumentError NativeOwner.options(vcat(arguments, ["--heart-slope-scale-x", "0"]))
        @test_throws ArgumentError NativeOwner.options(vcat(arguments, ["--heart-slope-scale-y", "Inf"]))
        order_path = joinpath(directory, "wrong-order")
        write(order_path, zeros(UInt8, 16))
        @test_throws ArgumentError NativeOwner.options(vcat(arguments, ["--heart-classic-order", order_path]))
        mkdir(options.heart_probe_directory)
        @test_throws ArgumentError NativeOwner.options(arguments)
    end
end

struct HeldPlantFixture end
AdaptiveOpticsSimPipeWireHIL.pipewire_calibration_status(::HeldPlantFixture) =
    (; acquisition_domain=:fixture, acquisition_generation=UInt64(1), failed=false, pending_exposure=nothing)

function held_session(proof)
    state = CalibrationAcquisition.AcquisitionState()
    state.held = true
    NativeOwner.Session(HeldPlantFixture(), nothing, nothing, nothing, (; profile=:copper), :fixture,
        state, nothing, CalibrationAcquisition.ExposureDiagnostics(12), proof,
        Dict{String,HeartCalibrationTelemetry.TelemetryReader}(), nothing,
        HeartCalibrationTelemetry.FrameAssociation(), UInt64(0), nothing, () -> nothing,
        zeros(UInt16, 4096), zeros(Float32, 3600), zeros(Float32, 188), fill(false, 188),
        zeros(Float32, 1), Tuple{Int,Int}[], 0.0f0, UInt64(0), UInt64(0))
end

@testset "native held owner constructor requires evidence" begin
    create(session; held=true) = CalibrationServer.Owner(session; measurement_count=3600,
        maximum_timeout_ns=UInt64(1_000_000), native_controller_held=held)
    @test_throws ArgumentError create(held_session(nothing))
    @test_throws ArgumentError create(held_session(NativeOwner.NativeHold(123, 2, true, true, "startup CORRECT", repeat("a", 64), 0, "streaming", "0")))
    @test_throws ArgumentError create(held_session(NativeOwner.NativeHold(123, 1, false, true, "startup CORRECT", repeat("a", 64), 0, "streaming", "0")))
    @test_throws ArgumentError create(held_session(NativeOwner.NativeHold(123, 1, true, false, "startup CORRECT", repeat("a", 64), 0, "streaming", "0")))
    @test_throws ArgumentError create(held_session(NativeOwner.NativeHold(123, 1, true, true, "startup CORRECT", repeat("a", 64), 1, "streaming", "0")))
    session = held_session(NativeOwner.NativeHold(123, 1, true, true, "startup CORRECT", repeat("a", 64), 0, "streaming", "0"))
    @test_throws ArgumentError create(session; held=false)
    owner = create(session)
    @test owner.phase === :initial && owner.command_count == 277
    session.state.cursor_sequence = 1
    @test_throws ArgumentError create(session)
end

@testset "native Copper pupil contract" begin
    mktempdir() do directory
        mkpath(joinpath(directory, "config"))
        write(joinpath(directory, "config", "pwfsRoiOffsets_64.csv"),
            "4 2 1 uint\n33,34\n0,0\n34,1\n0,34\n")
        config_path = joinpath(directory, "config", "heart.yaml")
        config = """
        PWFS_QUAD_SIZE: [{ WFS_NUM: 0, ROWS: 30, COLS: 30 }]
        PWFS_QUAD_LOCATION_FILE: [{ WFS_NUM: 0, FILE: "./config/pwfsRoiOffsets_64.csv" }]
        PWFS_QUAD_PIXEL_MASK_FILE: [{ WFS_NUM: 0, FILE: "" }]
        PWFS_GRAD_TYPE: 1
        """
        write(config_path, config)
        @test NativeOwner.read_pupil_locations(directory) == [(33, 34), (0, 0), (34, 1), (0, 34)]
        write(config_path, replace(config, "PWFS_GRAD_TYPE: 1" => "#PWFS_GRAD_TYPE: 1"))
        @test_throws ErrorException NativeOwner.read_pupil_locations(directory)
        write(config_path, replace(config, "FILE: \"\"" => "FILE: \"mask.csv\""))
        @test_throws ErrorException NativeOwner.read_pupil_locations(directory)
    end
end

mutable struct EvidenceFixture{Options}
    options::Options
    evidence_count::UInt64
    evidence_bytes::UInt64
end

@testset "native evidence is retained under a finite budget" begin
    mktempdir() do directory
        session = EvidenceFixture((; heart_probe_directory=directory, heart_telemetry_max_bytes=UInt64(64)), UInt64(0), UInt64(0))
        NativeOwner.record_evidence!(session, (; kind="test", sequence=UInt64(1)))
        path = joinpath(directory, "native-evidence.jsonl")
        @test session.evidence_count == 1 && filesize(path) == session.evidence_bytes
        @test Protocol.JSON3.read(read(path, String)).sequence == 1
        @test_throws ErrorException NativeOwner.record_evidence!(session, (; kind="oversized", payload=repeat("a", 64)))
        @test session.evidence_count == 1
        open(path, "a") do io
            write(io, "tampered")
        end
        @test_throws ErrorException NativeOwner.record_evidence!(session, (; kind="x"))
    end
end


mutable struct CommandFixture{Options,Service}
    options::Options
    native_command_serial::UInt64
    service::Service
end

@testset "native failure preserves bounded output and exit outside runtime" begin
    mktempdir() do directory
        runtime = joinpath(directory, "runtime"); mkdir(runtime)
        evidence = joinpath(directory, "evidence"); mkdir(evidence)
        client = joinpath(directory, "client")
        write(client, "#!/bin/sh\nprintf 'ack<0><ACCEPTED>\\nstatus<1><FAILED>\\n'\nprintf 'native rejection detail\\n' >&2\nexit 7\n")
        chmod(client, 0o700)
        options = (; heart_client=client, heart_native_runtime=runtime, heart_probe_directory=evidence)
        session = CommandFixture(options, UInt64(0), () -> nothing)
        exception = try
            NativeOwner.native_command!(session, "ENABLE_WFS_WC", String[], CalibrationAcquisition.deadline(UInt64(2_000_000_000)))
            nothing
        catch error
            error
        end
        @test exception isa ErrorException
        message = sprint(showerror, exception)
        @test occursin("exit=7", message)
        @test occursin("status<1><FAILED>", message)
        @test occursin("native rejection detail", message)
        result = Protocol.JSON3.read(read(joinpath(evidence, "command-1.log.json"), String))
        @test result.exitcode == 7 && result.termsignal == 0 && !result.truncated
        @test_throws ErrorException NativeOwner.require_command_success("ENABLE_WFS_WC", (; exitcode=0, termsignal=result.termsignal, failure=result.failure, truncated=result.truncated, stdout=result.stdout, stderr=result.stderr, path=result.path))
        NativeOwner.retain_startup_failure(options, exception)
        rm(runtime; recursive=true)
        @test isfile(joinpath(evidence, "command-1.log"))
        @test isfile(joinpath(evidence, "command-1.log.stderr"))
        @test occursin("native rejection detail", Protocol.JSON3.read(read(joinpath(evidence, "owner-failure.json"), String)).failure)
        oversized = joinpath(evidence, "oversized")
        write(oversized, repeat("x", 100))
        bounded = NativeOwner.bounded_text(oversized, 8)
        @test bounded.truncated && ncodeunits(bounded.text) == 8
    end
end

@testset "inherited endpoint proof requires fresh successful startup CORRECT" begin
    mktempdir() do directory
        runtime = joinpath(directory, "runtime"); mkdir(runtime)
        evidence = joinpath(directory, "evidence"); mkdir(evidence)
        options = (; heart_native_runtime=runtime, heart_probe_directory=evidence)
        status = Dict("generation"=>1, "sequence"=>0, "state"=>"paused", "error"=>nothing,
            "child_pid"=>123, "child_returncode"=>nothing)
        write(joinpath(runtime, "command-1-CORRECT.log"), "ack<0><ACCEPTED>\nstatus<0><SUCCESS>\n")
        write(joinpath(runtime, "command-1-CORRECT.log.stderr"), "")
        # Match native JSON field access, including exact Int64 generation.
        parsed = Protocol.JSON3.read(Protocol.JSON3.write(status))
        digest = NativeOwner.startup_enable_proof(options, parsed)
        @test length(digest) == 64
        @test isfile(joinpath(evidence, "startup-owner-status.json"))
        @test read(joinpath(evidence, "startup-CORRECT.log"), String) == read(joinpath(runtime, "command-1-CORRECT.log"), String)
        status["generation"] = 2
        @test_throws ErrorException NativeOwner.startup_enable_proof(options, Protocol.JSON3.read(Protocol.JSON3.write(status)))
        status["generation"] = 1
        write(joinpath(runtime, "command-1-CORRECT.log"), "ack<0><ACCEPTED>\nstatus<1><FAILED>\n")
        @test_throws ErrorException NativeOwner.startup_enable_proof(options, parsed)
    end
end


@testset "adoption stages retain the precise failing gate" begin
    mktempdir() do directory
        session = EvidenceFixture((; heart_probe_directory=directory, heart_telemetry_max_bytes=UInt64(4096)), UInt64(0), UInt64(0))
        @test NativeOwner.adoption_stage(() -> 123, session, UInt64(1), "native_std_dm_receipt") == 123
        @test_throws ErrorException NativeOwner.adoption_stage(() -> error("missing next bucket"), session, UInt64(1), "native_dm_bucket")
        rows = Protocol.JSON3.read.(filter(!isempty, split(read(joinpath(directory, "native-evidence.jsonl"), String), '\n')))
        @test [row.stage for row in rows] == ["native_std_dm_receipt", "native_std_dm_receipt", "native_dm_bucket", "native_dm_bucket"]
        @test [row.disposition for row in rows] == ["entered", "completed", "entered", "failed"]
        @test rows[end].detail == "missing next bucket"
        @test rows[end].sequence == 1
    end
end

@testset "native telemetry survives runtime cleanup under per-file bounds" begin
    mktempdir() do directory
        runtime = joinpath(directory, "runtime"); mkdir(runtime)
        evidence = joinpath(directory, "evidence"); mkdir(evidence)
        immutable = joinpath(directory, "immutable"); mkdir(immutable)
        symlink(immutable, joinpath(runtime, "config"))
        write(joinpath(runtime, "2026-10-04_01-32-03_cbDmCmd0_RUNNING_20261004T013203.000.tel"), "complete command fixture")
        write(joinpath(runtime, "2026-10-04_01-32-03_cbHoGrad0_RUNNING_20261004T013203.000.tel"), "partial frame fixture")
        options = (; heart_native_runtime=runtime, heart_probe_directory=evidence, heart_telemetry_max_bytes=UInt64(64))
        records = NativeOwner.retain_native_telemetry(options)
        @test length(records) == 2
        rm(runtime; recursive=true)
        retained = joinpath(evidence, "native-telemetry")
        @test read(joinpath(retained, "2026-10-04_01-32-03_cbDmCmd0_RUNNING_20261004T013203.000.tel"), String) == "complete command fixture"
        @test read(joinpath(retained, "2026-10-04_01-32-03_cbHoGrad0_RUNNING_20261004T013203.000.tel"), String) == "partial frame fixture"
        @test isfile(joinpath(retained, "snapshot.json"))
        @test_throws ErrorException NativeOwner.retain_native_telemetry(options)
    end
end


@testset "native recorder uses complete tag names and canonical files" begin
    @test NativeOwner.recording_arguments() == ["-configTelemEnable", "1", "-configTelemCbNames",
        "cbHoPixelsRaw0,cbHoPixelsCalib0,cbHoGrad0,cbDmCmd0"]
    mktempdir() do directory
        genuine = "2026-10-04_01-32-03_cbDmCmd0_RUNNING_20261004T013203.123456.tel"
        impostors = ["cbDmCmd0_RUNNING_fixture.tel", "2026-10-04_01-32-03_cbDmCmd1_RUNNING_20261004T013203.tel",
            "2026-10-04_01-32-03_cbDmCmd0extra_RUNNING_20261004T013203.tel", genuine * ".tmp"]
        for name in [genuine; impostors]
            write(joinpath(directory, name), "fixture")
        end
        @test NativeOwner.telemetry_paths(directory, "cbDmCmd0") == [joinpath(directory, genuine)]
        @test isempty(NativeOwner.telemetry_paths(directory, "cbHoGrad0"))
        @test_throws ErrorException NativeOwner.telemetry_paths(directory, "cbDmCmd")
        write(joinpath(directory, "2026-10-04_01-32-04_cbDmCmd0_RUNNING_20261004T013204.tel"), "second")
        @test length(NativeOwner.telemetry_paths(directory, "cbDmCmd0")) == 2
    end
end

@testset "exposure stages preserve partial processing without completion" begin
    mktempdir() do directory
        runtime = joinpath(directory, "runtime"); mkdir(runtime)
        session = EvidenceFixture((; heart_probe_directory=directory, heart_native_runtime=runtime,
            heart_telemetry_max_bytes=UInt64(16384)), UInt64(0), UInt64(0))
        header = zeros(UInt8, HeartCalibrationTelemetry.FILE_HEADER_BYTES)
        header[145] = 1
        raw = joinpath(runtime, "2026-10-04_01-32-03_cbHoPixelsRaw0_RUNNING_fixture.tel")
        write(raw, [header; zeros(UInt8, 64)])
        grad = joinpath(runtime, "2026-10-04_01-32-03_cbHoGrad0_RUNNING_fixture.tel")
        write(grad, zeros(UInt8, HeartCalibrationTelemetry.FILE_HEADER_BYTES))
        @test NativeOwner.exposure_stage(() -> :published, session, UInt64(1), "plant_frame_publication") === :published
        @test_throws ErrorException NativeOwner.exposure_stage(() -> error("no gradient bucket"), session,
            UInt64(1), "native_measurement_bucket")
        rows = Protocol.JSON3.read.(filter(!isempty, split(read(joinpath(directory, "native-evidence.jsonl"), String), '\n')))
        @test all(row -> row.kind == "exposure_stage", rows)
        @test [row.disposition for row in rows] == ["entered", "completed", "entered", "failed"]
        @test rows[end].detail.failure == "no gradient bucket"
        @test rows[end].detail.telemetry[1].files[1].committed == 1
        @test rows[end].detail.telemetry[3].files[1].committed == 0
        @test !any(row -> row.stage == "plant_exposure_completion", rows)
        @test session.evidence_count == 4
    end
end

@testset "native diagnostic log prefix survives cleanup under a fixed bound" begin
    mktempdir() do directory
        runtime = joinpath(directory, "runtime"); mkdir(runtime)
        evidence = joinpath(directory, "evidence"); mkdir(evidence)
        options = (; heart_probe_directory=evidence, heart_native_runtime=runtime)
        write(joinpath(runtime, "heart-1.log"), repeat("x", NativeOwner.MAX_COMMAND_REPLY_BYTES + 1))
        records = NativeOwner.retain_native_logs(options)
        rm(runtime; recursive=true)
        @test only(records).truncated
        @test only(records).bytes == NativeOwner.MAX_COMMAND_REPLY_BYTES
        @test filesize(joinpath(evidence, "native-logs/heart-1.log")) == NativeOwner.MAX_COMMAND_REPLY_BYTES
        @test_throws ErrorException NativeOwner.retain_native_logs(options)
    end
end

@testset "native probe filenames cannot be silently truncated by public client" begin
    suffix = "/probe-1.csv"
    directory = "/" * repeat("a", 127 - ncodeunits(suffix) - 1)
    @test ncodeunits(NativeOwner.native_probe_path(directory, UInt64(1))) == 127
    @test_throws ArgumentError NativeOwner.native_probe_path(directory * "a", UInt64(1))
    @test_throws ArgumentError NativeOwner.native_probe_path(directory, UInt64(10))
    @test_throws ArgumentError NativeOwner.native_probe_path(directory, typemax(UInt64))
    @test endswith(NativeOwner.native_probe_path("/short", typemax(UInt64)), ".csv")
    @test_throws ArgumentError NativeOwner.native_probe_path("/" * repeat("é", 60), UInt64(1))
end

@testset "calibrated auxiliary mean uses completed sync-fenced pixels with zero timestamp" begin
    spec = HeartCalibrationTelemetry.TelemetrySpec("cbHoPixelsCalib0", Int32(8), 64, 64, 4, 16384)
    payload = collect(reinterpret(UInt8, fill(2.0f0, 4096)))
    frame = HeartCalibrationTelemetry.TelemetryFrame(spec, UInt64(0), UInt32(1), Int64(0), Int16(2), UInt16(64), UInt16(64), payload)
    locations = [(0, 0), (0, 32), (32, 0), (32, 32)]
    @test_throws ArgumentError HeartCalibrationTelemetry.require_complete(frame) # old diagnostic path failed here
    @test NativeOwner.pupil_intensity(frame, locations) == 2.0f0
    invalid = HeartCalibrationTelemetry.TelemetryFrame(spec, UInt64(0), UInt32(1), Int64(0), Int16(2), UInt16(63), UInt16(64), payload)
    @test_throws ErrorException NativeOwner.pupil_intensity(invalid, locations)
    spec_grad = HeartCalibrationTelemetry.TelemetrySpec("cbHoGrad0", Int32(8), 3600, 1, 4, 14400)
    grad = HeartCalibrationTelemetry.TelemetryFrame(spec_grad, UInt64(0), UInt32(1), Int64(1), Int16(2), UInt16(3600), UInt16(3600), zeros(UInt8, 14400))
    @test !HeartCalibrationTelemetry.copper_response(grad).valid
    grad_zero_timestamp = HeartCalibrationTelemetry.TelemetryFrame(spec_grad, UInt64(0), UInt32(1), Int64(0), Int16(2), UInt16(3600), UInt16(3600), zeros(UInt8, 14400))
    @test_throws ArgumentError HeartCalibrationTelemetry.copper_response(grad_zero_timestamp)
end

@testset "primary exposure fault survives later reader EOF" begin
    mktempdir() do directory
        options = (; heart_probe_directory=directory)
        session = (; options)
        NativeOwner.retain_primary_failure!(session, UInt64(1), "native_response_decode", ErrorException("initial decode failed"))
        NativeOwner.retain_primary_failure!(session, UInt64(1), "plant_exposure_completion", EOFError())
        @test NativeOwner.primary_failure(options, "reader EOF") == "initial decode failed"
        record = Protocol.JSON3.read(read(joinpath(directory, "primary-failure.json"), String))
        @test record.stage == "native_response_decode" && record.sequence == 1
        @test NativeOwner.primary_failure((; heart_probe_directory=joinpath(directory, "absent")), "reader EOF") == "reader EOF"
    end
end

@testset "native ingress evidence distinguishes selected mode and actual environment" begin
    status = (; native_ingress=(; mode="deferred",environment_key="HRT_DEFER_WFS_INGRESS",observed_environment="1"))
    @test NativeOwner.validate_ingress_status(status,"deferred") == "1"
    @test_throws ErrorException NativeOwner.validate_ingress_status(status,"streaming")
    @test_throws ErrorException NativeOwner.validate_ingress_status((; native_ingress=(; mode="deferred",environment_key="HRT_DEFER_WFS_INGRESS",observed_environment="0")),"deferred")
    @test_throws ErrorException NativeOwner.validate_ingress_status((;),"deferred")
    @test_throws ArgumentError NativeOwner.validate_ingress_status(status,"unknown")
end
