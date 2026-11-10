import Clocks

Base.include(@__MODULE__, joinpath(@__DIR__, "capture_file_inputs.jl"))

@testset "capture model intervals stay within signed nanosecond range" begin
    interval = Dict(
        "domain" => capture_coordinator_domain,
        "generation" => capture_generation,
        "sequence" => UInt64(1),
        "start_model_ns" => UInt64(typemax(Int64)) - 1,
        "duration_ns" => UInt64(1),
    )
    exposure = CaptureFiles._capture_exposure(interval, capture_cursor())
    @test CaptureFiles._capture_end(exposure).model_ns == typemax(Int64)
    for start in (UInt64(typemax(Int64)), UInt64(typemax(Int64)) + 1, typemax(UInt64) - 1)
        @test_throws ArgumentError CaptureFiles._capture_exposure(
            merge(interval, Dict("start_model_ns" => start)), capture_cursor()
        )
    end
end

function capture_store(
    parent; name = "capture", maximum = 10capture_contract.bytes, kwargs...
)
    CaptureFiles.CaptureStore(
        joinpath(parent, name),
        capture_contract;
        stage = "lamp-training",
        illumination = "lamp",
        settings = capture_settings,
        maximum_bytes = maximum,
        kwargs...,
    )
end
function capture_write(
    store; frames = 2, cursor = capture_cursor(), serial = 1, run = 7, kwargs...
)
    acquire, count = capture_source(; start = cursor, kwargs...)
    descriptor = CaptureFiles.capture!(
        store,
        acquire;
        run = UInt64(run),
        serial = UInt64(serial),
        probe = UInt32(1),
        cursor,
        frames = UInt32(frames),
        deadline = CaptureClock.monotonic() + 30,
    )
    return descriptor, count
end
capture_read(store, descriptor; kwargs...) = CaptureFiles.read_capture(
    store.directory,
    descriptor;
    expected_contract = capture_contract,
    expected_stage = "lamp-training",
    expected_illumination = "lamp",
    expected_settings = capture_settings,
    kwargs...,
)
function capture_rewrite(store, descriptor, change)
    path = joinpath(store.directory, descriptor.manifest)
    original = read(path)
    document = PipeWireAORTC.Common.parse_json(String(copy(original)))
    change(document)
    payload = codeunits(PipeWireAORTC.Common.JSON.json(document) * "\n")
    chmod(path, 0o600)
    write(path, payload)
    revised = CaptureActions.Captured(
        descriptor.cursor,
        descriptor.manifest,
        bytes2hex(sha256(payload)),
        descriptor.frames,
        descriptor.bytes,
        UInt64(length(payload)),
    )
    return revised, original
end
function capture_restore(store, descriptor, original)
    path = joinpath(store.directory, descriptor.manifest)
    chmod(path, 0o600)
    write(path, original)
    chmod(path, 0o444)
end

@testset "bounded Classic capture files (RTC-DEV-029)" begin
    @testset "owned ADC payloads, row-major encoding and exact full identity" begin
        mktempdir() do parent
            store = capture_store(parent)
            @test filemode(stat(store.directory)) & 0o777 == 0o700
            descriptor, count = capture_write(store)
            @test count[] == 2
            @test descriptor.bytes == 2capture_contract.bytes
            @test filesize(joinpath(store.directory, descriptor.manifest)) ==
                descriptor.metadata_bytes
            result = capture_read(store, descriptor)
            @test length(result.samples) == 2
            sample = first(result.samples)
            expected = first(first(capture_source())())
            @test sample.arrays.raw == expected.arrays.raw
            @test sample.arrays.slopes == expected.arrays.slopes
            @test eltype(sample.arrays.raw) === UInt16
            @test sample.arrays.raw[1, 2] == 0x8001
            @test sample.arrays.raw[end, end] == 0xffff
            @test sample.arrays.validity[3] === false
            @test !haskey(sample, :quality)
            @test sample.exposure.domain == capture_coordinator_domain
            @test sample.metadata["raw"]["identity"]["domain"] ==
                bytes2hex(collect(capture_domain.bytes))
            @test sample.metadata["raw"]["identity"]["generation"] == capture_generation
            @test sample.metadata["raw"]["header"]["pts"] == -17
            @test sample.metadata["raw"]["header"]["sequence"] == 101
            @test result.manifest["schema_version"] == 5
            @test result.manifest["cursor"]["model_ns"] == 4000000
            @test result.manifest["after"]["generation"] == capture_generation
            @test result.manifest["domain_mapping"]["coordinator"] ==
                capture_coordinator_domain
            @test result.manifest["domain_mapping"]["wire"] ==
                bytes2hex(collect(capture_domain.bytes))
            raw_path = joinpath(
                store.directory, dirname(descriptor.manifest), "frame-000001-raw.bin"
            )
            @test read(raw_path)[1:4] == UInt8[0x00, 0x00, 0x01, 0x80]
            @test filemode(stat(raw_path)) & 0o777 == 0o444
            result.samples[1].arrays.raw[1, 1] = 33
            @test capture_read(store, descriptor).samples[1].arrays.raw[1, 1] == 0
            @test result.samples[1].arrays.raw !== result.samples[2].arrays.raw
            @test_throws ArgumentError capture_read(
                store, descriptor; expected_stage = "dark"
            )
            @test_throws ArgumentError CaptureFiles.read_capture(
                store.directory,
                descriptor;
                expected_contract = CaptureFiles.Contract((;
                    raw = capture_contract.channels.raw
                )),
                expected_stage = "lamp-training",
                expected_illumination = "lamp",
                expected_settings = capture_settings,
            )
            link = joinpath(parent, "linked")
            symlink(store.directory, link)
            @test_throws ArgumentError CaptureFiles.read_capture(
                link,
                descriptor;
                expected_contract = capture_contract,
                expected_stage = "lamp-training",
                expected_illumination = "lamp",
                expected_settings = capture_settings,
            )
            # Explicit source TAI requires no PTP record and is distinct from model/recorder time.
            clock_store = capture_store(parent; name = "clock")
            timing = PipeWireAO.ExposureTiming(
                99; clock = PipeWireAO.METADATA_CLOCK_TAI, duration_nanoseconds = 2000000
            )
            reference_timestamp = PipeWireAO.ReferenceTimestamp(
                typemax(UInt64) - 1;
                clock = PipeWireAO.METADATA_CLOCK_TAI,
                duration_nanoseconds = 17,
            )
            clock_metadata =
                metadata -> map(
                    receipt -> capture_file_receipt(
                        receipt.identity,
                        receipt.model_start_ns,
                        receipt.duration_ns;
                        timing,
                        reference_timestamp,
                    ),
                    metadata,
                )
            clock_descriptor, _ = capture_write(
                clock_store; frames = 1, metadata_change = clock_metadata
            )
            clock_read = capture_read(clock_store, clock_descriptor)
            @test clock_read.samples[1].metadata["raw"]["exposure_timing"]["start_nanoseconds"] ==
                99
            @test clock_read.samples[1].metadata["raw"]["reference_timestamp"]["timestamp_nanoseconds"] ==
                typemax(UInt64) - 1
            @test clock_read.samples[1].metadata["raw"]["reference_timestamp"]["clock"] ==
                UInt32(PipeWireAO.METADATA_CLOCK_TAI)
            @test clock_read.manifest["recording"]["clock"] ==
                UInt32(PipeWireAO.METADATA_CLOCK_REALTIME)
            @test clock_read.manifest["exposures"][1]["recording"]["received"]["clock"] ==
                UInt32(PipeWireAO.METADATA_CLOCK_REALTIME)
            @test clock_read.samples[1].exposure.start_model_ns == 0
        end
    end
    @testset "model cadence may leave gaps between detector exposures" begin
        mktempdir() do parent
            store = capture_store(parent)
            descriptor, _ = capture_write(
                store; frames = 2, duration = 1896000, period = 2000000
            )
            result = capture_read(store, descriptor)
            @test result.samples[1].exposure.start_model_ns == 0
            @test result.samples[1].exposure.duration_ns == 1896000
            @test result.samples[2].exposure.start_model_ns == 2000000
            @test result.samples[2].exposure.duration_ns == 1896000
            @test descriptor.cursor.model_ns == 3896000
            @test result.samples[2].metadata["raw"]["model_start_ns"] == 2000000
            revised, original = capture_rewrite(
                store, descriptor, doc -> begin
                    record = doc["exposures"][2]
                    record["exposure"]["start_model_ns"] = 1895999
                    for receipt in values(record["metadata"])
                        receipt["model_start_ns"] = 1895999
                    end
                end
            )
            @test_throws ArgumentError capture_read(store, revised)
            capture_restore(store, descriptor, original)
            overlapping = capture_store(parent; name = "overlapping")
            @test_throws ArgumentError capture_write(
                overlapping; frames = 2, duration = 2000000, period = 1000000
            )
            @test !isfile(
                joinpath(overlapping.directory, "run-7-serial-1", "manifest.json")
            )
        end
    end
    @testset "preflight capacity, stale requests, and bounded settings" begin
        mktempdir() do parent
            store = capture_store(parent; maximum = capture_contract.bytes)
            acquire, count = capture_source()
            for frames in (UInt32(0), UInt32(2), UInt32(4097))
                @test_throws ArgumentError CaptureFiles.capture!(
                    store,
                    acquire;
                    run = UInt64(7),
                    serial = UInt64(1),
                    probe = UInt32(1),
                    cursor = capture_cursor(),
                    frames,
                    deadline = CaptureClock.monotonic() + 30,
                )
                @test count[] == 0
            end
            @test store.used_bytes == 0
            descriptor, _ = capture_write(store; frames = 1)
            @test_throws ArgumentError CaptureFiles.capture!(
                store,
                acquire;
                run = UInt64(7),
                serial = UInt64(1),
                probe = UInt32(1),
                cursor = descriptor.cursor,
                frames = UInt32(1),
                deadline = CaptureClock.monotonic() + 30,
            )
            @test count[] == 0
            ample = capture_store(parent; name = "ample")
            completed, _ = capture_write(ample; frames = 1)
            @test_throws ArgumentError CaptureFiles.capture!(
                ample,
                acquire;
                run = UInt64(7),
                serial = UInt64(2),
                probe = UInt32(1),
                cursor = capture_cursor(),
                frames = UInt32(1),
                deadline = CaptureClock.monotonic() + 30,
            )
            @test count[] == 0
            # A legitimate intervening owner exposure may advance beyond last capture.
            @test_throws ArgumentError CaptureFiles.capture!(
                ample,
                acquire;
                run = UInt64(7),
                serial = UInt64(2),
                probe = UInt32(1),
                cursor = capture_cursor(1, 4000000),
                frames = UInt32(1),
                deadline = CaptureClock.monotonic() + 30,
            )
            @test count[] == 0
            later = capture_cursor(2, 4000000)
            next, _ = capture_write(ample; frames = 1, cursor = later, serial = 2)
            @test next.cursor.sequence == 3
            @test_throws ArgumentError CaptureFiles.CaptureStore(
                joinpath(parent, "too-large"),
                capture_contract;
                stage = "x",
                illumination = "x",
                settings = Dict("oversized" => repeat("x", 16385)),
                maximum_bytes = 1000000,
            )
            @test !ispath(joinpath(parent, "too-large"))
            @test_throws ArgumentError capture_store(parent)
        end
    end
    @testset "preflight rejects without store or acquisition effects" begin
        mktempdir() do parent
            store = capture_store(parent; maximum = capture_contract.bytes)
            acquire, count = capture_source()
            state() = deepcopy((;
                store.directory,
                store.stage,
                store.illumination,
                store.settings,
                store.maximum_bytes,
                store.used_bytes,
                store.run,
                store.serial,
                store.cursor,
                store.domain,
            ))
            before = state()
            prepared = CaptureFiles.capture_preflight(
                store;
                run = UInt64(7),
                serial = UInt64(1),
                probe = UInt32(1),
                cursor = capture_cursor(),
                frames = UInt32(1),
                deadline = CaptureClock.monotonic() + 30,
            )
            @test prepared.after == capture_cursor()
            @test prepared.bytes == capture_contract.bytes
            @test !ispath(prepared.directory)
            @test state() == before
            @test isempty(readdir(store.directory))
            @test count[] == 0
            for frames in (UInt32(0), UInt32(2), UInt32(4097))
                @test_throws ArgumentError CaptureFiles.capture_preflight(
                    store;
                    run = UInt64(7),
                    serial = UInt64(1),
                    probe = UInt32(1),
                    cursor = capture_cursor(),
                    frames,
                    deadline = CaptureClock.monotonic() + 30,
                )
                @test state() == before
                @test isempty(readdir(store.directory))
                @test count[] == 0
            end
            descriptor, _ = capture_write(store; frames = 1)
            before = state()
            existing = readdir(store.directory)
            for (serial, cursor) in
                ((UInt64(1), descriptor.cursor), (UInt64(2), capture_cursor()))
                @test_throws ArgumentError CaptureFiles.capture_preflight(
                    store;
                    run = UInt64(7),
                    serial,
                    probe = UInt32(1),
                    cursor,
                    frames = UInt32(1),
                    deadline = CaptureClock.monotonic() + 30,
                )
                @test state() == before
                @test readdir(store.directory) == existing
                @test count[] == 0
            end
        end
    end
    @testset "interruption, deadlines and mismatched receipts never publish" begin
        mktempdir() do parent
            store = capture_store(parent)
            @test_throws ErrorException capture_write(store; frames = 2, fail = 2)
            @test !isfile(joinpath(store.directory, "run-7-serial-1", "manifest.json"))
            @test isfile(
                joinpath(store.directory, "run-7-serial-1", "frame-000001-raw.bin")
            )
            @test store.used_bytes == 2capture_contract.bytes
            acquire, count = capture_source()
            @test_throws InvalidStateException CaptureFiles.capture!(
                store,
                acquire;
                run = UInt64(7),
                serial = UInt64(2),
                probe = UInt32(1),
                cursor = store.cursor,
                frames = UInt32(1),
                deadline = CaptureClock.monotonic() - 1,
            )
            @test count[] == 0
            bad = capture_store(parent; name = "bad")
            change =
                metadata -> merge(
                    metadata,
                    (;
                        slopes = merge(
                            metadata.slopes,
                            (;
                                identity = PipeWireAO.AcquisitionIdentity(
                                    capture_domain, capture_generation, UInt64(99)
                                )
                            ),
                        )
                    ),
                )
            @test_throws ArgumentError capture_write(
                bad; frames = 1, metadata_change = change
            )
            @test !isfile(joinpath(bad.directory, "run-7-serial-1", "manifest.json"))
            for (index, flag) in enumerate((
                PipeWireAO.SPA.META_HEADER_FLAG_CORRUPTED,
                PipeWireAO.SPA.META_HEADER_FLAG_GAP,
            ))
                flagged = capture_store(parent; name = "flagged-$index")
                change_header =
                    metadata -> map(
                        receipt -> merge(
                            receipt,
                            (;
                                header = PipeWireAO.BufferHeader(
                                    flag,
                                    UInt32(0),
                                    Int64(0),
                                    Int64(0),
                                    receipt.identity.sequence,
                                )
                            ),
                        ),
                        metadata,
                    )
                @test_throws ArgumentError capture_write(
                    flagged; frames = 1, metadata_change = change_header
                )
                @test !isfile(
                    joinpath(flagged.directory, "run-7-serial-1", "manifest.json")
                )
            end
            stopped = capture_store(parent; name = "stopped")
            acquire, count = capture_source()
            @test_throws ErrorException CaptureFiles.capture!(
                stopped,
                acquire;
                run = UInt64(7),
                serial = UInt64(1),
                probe = UInt32(1),
                cursor = capture_cursor(),
                frames = UInt32(2),
                deadline = CaptureClock.monotonic() + 30,
                check = () -> (count[] == 0 || error("controller lost")),
            )
            @test count[] == 1
            @test !isfile(joinpath(stopped.directory, "run-7-serial-1", "manifest.json"))
            # External data and pre-existing directories are never cleaned or reused.
            marker = joinpath(parent, "retain.txt")
            write(marker, "keep")
            @test_throws ArgumentError CaptureFiles.CaptureStore(
                parent,
                capture_contract;
                stage = "x",
                illumination = "x",
                settings = Dict(),
                maximum_bytes = 10,
            )
            @test read(marker, String) == "keep"
        end
    end
    @testset "strict manifest and every payload contract" begin
        mktempdir() do parent
            store = capture_store(parent)
            descriptor, _ = capture_write(store; frames = 1)
            changes = Function[
                doc->(doc["unexpected"]=1),
                doc->(doc["schema_version"]=1),
                doc->(doc["schema_version"]=2),
                doc->(doc["schema_version"]=3),
                doc->(doc["exposures"][1]["metadata"]["raw"]["acquisition_version"]=3),
                doc->(doc["exposures"][1]["metadata"]["raw"]["trigger_classification"]=4),
                doc->(doc["exposures"][1]["metadata"]["raw"]["timebase"]=2),
                doc->(doc["exposures"][1]["metadata"]["raw"]["reference_timestamp"]=nothing),
                doc->(doc["exposures"][1]["metadata"]["raw"]["records"]["abi"]=2),
                doc->(doc["exposures"][1]["metadata"]["raw"]["records"]["byte_order"]="invalid"),
                doc->(doc["exposures"][1]["recording"]["received"]["timestamp_nanoseconds"]=typemax(
                    UInt64
                )),
                doc->(doc["recording"]["clock"]=0),
                doc->(doc["profile"]="copper"),
                doc->(doc["illumination"]="dark"),
                doc->(doc["settings"]["graph_sha256"]=repeat("c", 64)),
                doc->(doc["settings"]["photon_noise"]=1),
                doc->(doc["domain_mapping"]["coordinator"]=1),
                doc->(doc["exposures"][1]["exposure"]["sequence"]=2),
                doc->(doc["exposures"][1]["metadata"]["raw"]["identity"]["domain"]=repeat(
                    "0", 32
                )),
                doc->(doc["exposures"][1]["metadata"]["flux"]["model_start_ns"]=1),
                doc->(doc["channels"]["raw"]["schema"]="wrong-schema"),
                doc->(doc["channels"]["raw"]["rate"]=[501, 1]),
                doc->(doc["cursor"]["model_ns"]=7),
                doc->(doc["cursor"]["sequence"]=true),
                doc->(doc["cursor"]["sequence"]=1.0),
                doc->(doc["cursor"]["model_ns"]=2000000.0),
            ]
            for role in ("raw", "slopes", "flux", "validity")
                append!(
                    changes,
                    [
                        doc ->
                            (doc["exposures"][1]["payloads"][role]["encoding"] = "F64_LE"),
                        doc -> (
                            doc["exposures"][1]["payloads"][role]["layout"] = "COLUMN_MAJOR"
                        ),
                        doc -> (doc["exposures"][1]["payloads"][role]["shape"] = [1]),
                        doc -> (doc["exposures"][1]["payloads"][role]["bytes"] = 1),
                        doc -> (
                            doc["exposures"][1]["payloads"][role]["sha256"] = repeat(
                                "0", 64
                            )
                        ),
                        doc -> (
                            doc["exposures"][1]["payloads"][role]["path"] = "../outside.bin"
                        ),
                    ],
                )
            end
            for change in changes
                revised, original = capture_rewrite(store, descriptor, change)
                try
                    @test_throws ArgumentError capture_read(store, revised)
                finally
                    capture_restore(store, descriptor, original)
                end
            end
            # Duplicate JSON keys must not silently overwrite an earlier value.
            manifest_path = joinpath(store.directory, descriptor.manifest)
            original = read(manifest_path)
            duplicated = replace(
                String(copy(original)),
                "\"schema_version\":5" => "\"schema_version\":5,\"schema_version\":5",
            )
            @test ncodeunits(duplicated) > length(original)
            chmod(manifest_path, 0o600)
            write(manifest_path, duplicated)
            duplicate_descriptor = CaptureActions.Captured(
                descriptor.cursor,
                descriptor.manifest,
                bytes2hex(sha256(duplicated)),
                descriptor.frames,
                descriptor.bytes,
                UInt64(ncodeunits(duplicated)),
            )
            @test_throws ArgumentError capture_read(store, duplicate_descriptor)
            capture_restore(store, descriptor, original)
            # The untrusted descriptor cannot choose an arbitrary path, size or cursor.
            for (path, bytes, metadata, cursor) in (
                (
                    "../manifest.json",
                    descriptor.bytes,
                    descriptor.metadata_bytes,
                    descriptor.cursor,
                ),
                (
                    descriptor.manifest,
                    UInt64(1),
                    descriptor.metadata_bytes,
                    descriptor.cursor,
                ),
                (descriptor.manifest, descriptor.bytes, UInt64(0), descriptor.cursor),
                (
                    descriptor.manifest,
                    descriptor.bytes,
                    descriptor.metadata_bytes,
                    capture_cursor(1, 99),
                ),
            )
                bad = CaptureActions.Captured(
                    cursor, path, descriptor.sha256, descriptor.frames, bytes, metadata
                )
                @test_throws ArgumentError capture_read(store, bad)
            end
            raw_path = joinpath(
                store.directory, dirname(descriptor.manifest), "frame-000001-raw.bin"
            )
            original = read(raw_path)
            chmod(raw_path, 0o600)
            write(raw_path, original[1:(end-1)])
            @test_throws ArgumentError capture_read(store, descriptor)
            write(raw_path, original)
            rm(raw_path)
            outside = joinpath(parent, "outside.bin")
            write(outside, original)
            symlink(outside, raw_path)
            @test_throws ArgumentError capture_read(store, descriptor)
            rm(raw_path)
            write(raw_path, original)
            # Rehashed BOOL8 payload still rejects a byte that is neither 0 nor 1.
            bool_path = joinpath(
                store.directory, dirname(descriptor.manifest), "frame-000001-validity.bin"
            )
            chmod(bool_path, 0o600)
            bool_bytes = read(bool_path)
            bool_bytes[1] = 2
            write(bool_path, bool_bytes)
            revised, _ = capture_rewrite(
                store,
                descriptor,
                doc ->
                    doc["exposures"][1]["payloads"]["validity"]["sha256"] = bytes2hex(
                        sha256(bool_bytes)
                    ),
            )
            @test_throws ArgumentError capture_read(store, revised)
        end
    end
    @test !any(id.name in ("CUDA", "AMDGPU") for id in keys(Base.loaded_modules))
end

@testset "capture schema preserves missing and explicit classification facts" begin
    P = PipeWireAO
    optical = (
        nothing, P.OPTICAL_ABSENT, P.OPTICAL_UNFRINGED, P.OPTICAL_FRINGED, P.OPTICAL_MIXED
    )
    trigger = (
        nothing,
        P.ACQUISITION_TRIGGER_ABSENT,
        P.ACQUISITION_TRIGGER_LOW,
        P.ACQUISITION_TRIGGER_HIGH,
        P.ACQUISITION_TRIGGER_MIXED,
    )
    mktempdir() do parent
        for (index, (o, t)) in enumerate(Iterators.product(optical, trigger))
            store = capture_store(parent; name = "classification-$index")
            descriptor, _ = capture_write(
                store;
                frames = 1,
                metadata_change = metadata -> map(
                    receipt -> capture_file_receipt(
                        receipt.identity,
                        receipt.model_start_ns,
                        receipt.duration_ns;
                        optical = o,
                        trigger = t,
                    ),
                    metadata,
                ),
            )
            sample = only(capture_read(store, descriptor).samples)
            @test sample.metadata["raw"]["optical_classification"] ==
                (o === nothing ? nothing : UInt32(o))
            @test sample.metadata["raw"]["trigger_classification"] ==
                (t === nothing ? nothing : UInt32(t))
        end
    end
end

@testset "capture preserves opaque records and separates recorder times" begin
    P = PipeWireAO
    mktempdir() do parent
        store = capture_store(parent)
        opaque = fill(UInt8(0xa7), 3504)
        change =
            metadata -> map(metadata) do receipt
                snapshot = receipt.records
                entries = [
                    P.metadata_type(snapshot, i) =>
                        collect(P.metadata_bytes(snapshot, i)) for
                    i in 1:P.metadata_count(snapshot)
                ]
                push!(entries, UInt32(0x900) => opaque)
                merge(receipt, (; records = P.MetadataSnapshot(entries)))
            end
        descriptor, _ = capture_write(store; frames = 1, metadata_change = change)
        result = capture_read(store, descriptor)
        record = only(result.manifest["exposures"])
        @test only(
            filter(e -> e["type"] == 0x900, record["metadata"]["raw"]["records"]["entries"])
        )["data"] == bytes2hex(opaque)
        @test descriptor.metadata_bytes > 4096
        @test descriptor.metadata_bytes <=
            CaptureFiles.CAPTURE_HEADER_BYTES + CaptureFiles.CAPTURE_EXPOSURE_BYTES
        @test record["recording"]["received"]["clock"] == UInt32(P.METADATA_CLOCK_REALTIME)
        @test record["recording"]["payload_written"]["clock"] ==
            UInt32(P.METADATA_CLOCK_REALTIME)
        @test record["metadata"]["raw"]["reference_timestamp"]["timestamp_nanoseconds"] ==
            1_730_000_000_000_000_123
        @test !haskey(record["metadata"]["raw"], "absolute_times")
        revised, original = capture_rewrite(
            store,
            descriptor,
            d -> push!(
                d["exposures"][1]["metadata"]["raw"]["records"]["entries"],
                first(d["exposures"][1]["metadata"]["raw"]["records"]["entries"]),
            ),
        )
        @test_throws ArgumentError capture_read(store, revised)
        capture_restore(store, descriptor, original)
        revised, original = capture_rewrite(
            store,
            descriptor,
            d -> empty!(d["exposures"][1]["metadata"]["raw"]["records"]["entries"]),
        )
        @test_throws ArgumentError capture_read(store, revised)
        capture_restore(store, descriptor, original)
    end
end

@testset "capture preflight retains signed deadline and fresh I/O guards" begin
    mktempdir() do parent
        for (index, origin) in enumerate((Int64(-10), Int64(2)^53 + 1))
            store = capture_store(parent; name = "signed-$index")
            clock = Clocks.CachedNanoClock(origin)
            prepared = CaptureFiles.capture_preflight(
                store;
                run = UInt64(7),
                serial = UInt64(1),
                probe = UInt32(1),
                cursor = capture_cursor(),
                frames = UInt32(1),
                deadline = origin + 1,
                clock,
            )
            @test prepared.checked() === nothing
            @test isempty(readdir(store.directory)) && store.used_bytes == 0
            Clocks.update!(clock, origin + 1)
            @test_throws InvalidStateException prepared.checked()
            Clocks.update!(clock, origin - 1)
            @test_throws InvalidStateException prepared.checked()
            Clocks.update!(clock, origin)
            @test_throws InvalidStateException CaptureFiles.capture_preflight(
                store;
                run = UInt64(7),
                serial = UInt64(1),
                probe = UInt32(1),
                cursor = capture_cursor(),
                frames = UInt32(1),
                deadline = origin + 1,
                clock,
                check = () -> Clocks.update!(clock, origin + 1),
            )
            @test isempty(readdir(store.directory)) && store.used_bytes == 0
            Clocks.update!(clock, origin)
            checks = Ref(0)
            acquired = Ref(false)
            @test_throws InvalidStateException CaptureFiles.capture!(
                store,
                () -> (acquired[] = true; error("expired capture acquired"));
                run = UInt64(7),
                serial = UInt64(1),
                probe = UInt32(1),
                cursor = capture_cursor(),
                frames = UInt32(1),
                deadline = origin + 1,
                clock,
                check = () -> begin
                    checks[] += 1
                    checks[] == 2 && Clocks.update!(clock, origin + 1)
                end,
            )
            @test !acquired[] && checks[] == 2
            @test isempty(readdir(store.directory)) && store.used_bytes == 0
            @test store.run == 0 && store.serial == 0
        end
    end
end

@testset "capture contracts bind prepared channels without instrument roles" begin
    P = PipeWireAO
    channel(type, shape; schema = "generic-v1", rate = P.SPA.Fraction(37, 2)) =
        CaptureFiles.Channel(
            P.NdArrayFormat(type, shape; layout = P.NdArray.ROW_MAJOR, rate), schema
        )
    @test CaptureFiles._channel_names(["2.camera", "reference-slopes"]) ==
        (Symbol("2.camera"), Symbol("reference-slopes"))
    for names in
        (String[], ["same", "same"], ["../outside"], ["bad/name"], [""], fill("x", 17))
        @test_throws ArgumentError CaptureFiles._channel_names(names)
    end
    @test_throws ArgumentError CaptureFiles.Contract(NamedTuple())
    @test_throws ArgumentError CaptureFiles.Contract((; detector = nothing))
    @test_throws ArgumentError channel(P.NdArray.F64_LE, (2, 3))
    @test_throws ArgumentError channel(P.NdArray.F32_LE, (2, 3, 4))
    @test_throws ArgumentError channel(P.NdArray.U16_LE, (typemax(Int32),))
    @test_throws ArgumentError channel(P.NdArray.U16_LE, (2,); schema = "")
    @test_throws ArgumentError channel(P.NdArray.U16_LE, (2,); schema = repeat("s", 257))
    @test_throws ArgumentError CaptureFiles.Channel(
        P.NdArrayFormat(P.NdArray.U16_LE, (2, 3); layout = P.NdArray.COLUMN_MAJOR),
        "detector",
    )
    selected = NamedTuple{(Symbol("2.camera"), :wavefront, :accepted)}((
        channel(P.NdArray.U16_LE, (3,)),
        channel(P.NdArray.F32_LE, (2, 3)),
        channel(P.NdArray.BOOL8, (2, 3)),
    ))
    contract = CaptureFiles.Contract(selected)
    @test contract.bytes == 3 * 2 + 2 * 3 * 4 + 2 * 3
    arrays = NamedTuple{keys(selected)}((
        UInt16[0x8001, 2, 0xffff],
        Float32[1 3 5; 2 4 NaN],
        Bool[true false true; false true false],
    ))
    receipt = capture_file_receipt(
        P.AcquisitionIdentity(capture_domain, capture_generation, UInt64(1)),
        0,
        UInt64(2000000),
    )
    sample = (;
        arrays = merge(arrays, (; unused = "not a selected payload")),
        metadata = merge(map(_ -> receipt, selected), (; unused = nothing)),
    )
    exposure = CaptureActions.Exposure(
        capture_coordinator_domain,
        capture_generation,
        UInt64(1),
        UInt64(0),
        UInt64(2000000),
    )
    mktempdir() do parent
        store = CaptureFiles.CaptureStore(
            joinpath(parent, "evidence"),
            contract;
            stage = "arbitrary",
            illumination = "test",
            settings = Dict(),
            maximum_bytes = contract.bytes,
        )
        descriptor = CaptureFiles.capture!(
            store,
            () -> (sample, exposure);
            run = UInt64(1),
            serial = UInt64(1),
            probe = UInt32(0),
            cursor = capture_cursor(),
            frames = UInt32(1),
            deadline = CaptureClock.monotonic() + 30,
        )
        read_selected(expected_contract = contract) = CaptureFiles.read_capture(
            store.directory,
            descriptor;
            expected_contract,
            expected_stage = "arbitrary",
            expected_illumination = "test",
            expected_settings = Dict(),
        )
        result = read_selected()
        @test result.manifest["schema_version"] == 5
        @test !haskey(result.manifest, "profile")
        @test !haskey(only(result.manifest["exposures"]), "quality")
        @test keys(only(result.samples).arrays) == keys(selected)
        @test isequal(only(result.samples).arrays, arrays)
        @test length(readdir(dirname(joinpath(store.directory, descriptor.manifest)))) == 4
        wrong_schema = CaptureFiles.Contract(
            merge(
                selected,
                (; wavefront = channel(P.NdArray.F32_LE, (2, 3); schema = "other")),
            ),
        )
        wrong_rate = CaptureFiles.Contract(
            merge(
                selected,
                (;
                    wavefront = channel(
                        P.NdArray.F32_LE, (2, 3); rate = P.SPA.Fraction(37, 1)
                    )
                ),
            ),
        )
        @test_throws ArgumentError read_selected(wrong_schema)
        @test_throws ArgumentError read_selected(wrong_rate)
    end
end

@testset "reject historical schema-4 captures" begin
    directory = joinpath(@__DIR__, "data", "capture-schema4")
    generated = PipeWireAORTC.Common.parse_json(
        read(joinpath(directory, "generated.json"), String)
    )
    @test generated["generated"]["source_revision"] ==
        "94ecd39fe83e5f292c46d2d08f5867d78dd3d02d"
    value = generated["descriptor"]
    descriptor = CaptureActions.Captured(
        CaptureFiles._capture_read_cursor(value["cursor"]),
        value["manifest"],
        value["sha256"],
        UInt32(value["frames"]),
        UInt64(value["bytes"]),
        UInt64(value["metadata_bytes"]),
    )
    expected = (;
        expected_contract = capture_contract,
        expected_stage = "lamp-training",
        expected_illumination = "lamp",
        expected_settings = capture_settings,
    )
    @test_throws ArgumentError CaptureFiles.read_capture(directory, descriptor; expected...)
end
