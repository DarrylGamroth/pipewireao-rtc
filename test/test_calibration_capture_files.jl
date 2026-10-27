using Test, SHA, PipeWireAORTC
import PipeWireAO
const CaptureFiles = PipeWireAORTC.InstrumentCalibration
const CaptureActions = PipeWireAORTC.NativeCalibrationActionCodec
const CaptureClock = PipeWireAORTC.NativeControlClient
@assert isdefined(CaptureFiles,:CaptureStore)

const capture_settings = Dict{String,Any}("profile"=>"classic","simulation_graph"=>"internal-source",
    "graph_sha256"=>repeat("a",64),"mask_sha256"=>repeat("b",64),"source_magnitude"=>2.0,
    "exposure_ns"=>2000000,"photon_noise"=>true,"readout_noise"=>true,"adc_bits"=>12)
const capture_domain = PipeWireAO.AcquisitionDomain(ntuple(index -> UInt8(index),16))
const capture_generation = UInt64(2)^53+7
const capture_coordinator_domain = UInt64(2)^53+11
capture_cursor(sequence=0,model=0) = CaptureActions.AcquisitionCursor(capture_coordinator_domain,capture_generation,UInt64(sequence),UInt64(model))

function capture_source(;start=capture_cursor(),fail=0,metadata_change=identity,
        duration=2000000,period=duration)
    count = Ref(0)
    function acquire()
        count[] += 1
        count[] == fail && error("interrupted acquisition")
        sequence = start.sequence+UInt64(count[])
        model = start.model_ns+UInt64(count[]-1)*UInt64(period)
        exposure = CaptureActions.Exposure(start.domain,start.generation,sequence,model,UInt64(duration))
        # Asymmetry catches accidental transpose/column-major encoding. Keep
        # full ADC values including the top UInt16 bit, without electron conversion.
        raw = reshape(UInt16.(mod.(0:352*352-1,65536)),352,352)
        raw[1,2],raw[2,1],raw[end,end] = 0x8001,0x0012,0xffff
        arrays = (;raw,slopes=reshape(Float32.(1:376),188,2),flux=fill(Float32(count[]),188),
            validity=[index != 3 for index in 1:188])
        receipt = (;identity=PipeWireAO.AcquisitionIdentity(capture_domain,start.generation,sequence),
            model_start_ns=Int64(model),duration_ns=UInt64(duration),
            header=PipeWireAO.BufferHeader(UInt32(0),UInt32(0),Int64(-17),Int64(-2),sequence),
            acquisition_version=UInt32(2),acquisition_flags=UInt32(5),
            wire_start=nothing,timebase=nothing,ptp_reference=nothing)
        metadata = metadata_change((;raw=receipt,slopes=receipt,flux=receipt,validity=receipt))
        return (;arrays,metadata),exposure
    end
    return acquire,count
end
function capture_store(parent;name="capture",maximum=10CaptureFiles.CLASSIC_CAPTURE_BYTES,kwargs...)
    CaptureFiles.CaptureStore(joinpath(parent,name);stage="lamp-training",illumination="lamp",
        settings=capture_settings,maximum_bytes=maximum,kwargs...)
end
function capture_write(store;frames=2,cursor=capture_cursor(),serial=1,run=7,kwargs...)
    acquire,count = capture_source(;start=cursor,kwargs...)
    descriptor = CaptureFiles.capture!(store,acquire;run=UInt64(run),serial=UInt64(serial),probe=UInt32(1),
        cursor,frames=UInt32(frames),deadline=CaptureClock.monotonic()+30)
    return descriptor,count
end
capture_read(store,descriptor;kwargs...) = CaptureFiles.read_capture(store.directory,descriptor;
    expected_profile="classic",expected_stage="lamp-training",expected_illumination="lamp",expected_settings=capture_settings,kwargs...)
function capture_rewrite(store,descriptor,change)
    path = joinpath(store.directory,descriptor.manifest)
    original = read(path)
    document = PipeWireAORTC.Common.parse_json(String(copy(original)))
    change(document)
    payload = codeunits(PipeWireAORTC.Common.JSON.json(document)*"\n")
    chmod(path,0o600)
    write(path,payload)
    revised = CaptureActions.Captured(descriptor.cursor,descriptor.manifest,bytes2hex(sha256(payload)),
        descriptor.frames,descriptor.bytes,UInt64(length(payload)))
    return revised,original
end
function capture_restore(store,descriptor,original)
    path = joinpath(store.directory,descriptor.manifest)
    chmod(path,0o600)
    write(path,original)
    chmod(path,0o444)
end

@testset "bounded Classic capture files (RTC-DEV-029)" begin
    @testset "owned ADC payloads, row-major encoding and exact full identity" begin
        mktempdir() do parent
            store = capture_store(parent)
            @test filemode(stat(store.directory)) & 0o777 == 0o700
            descriptor,count = capture_write(store)
            @test count[] == 2
            @test descriptor.bytes == 2CaptureFiles.CLASSIC_CAPTURE_BYTES
            @test filesize(joinpath(store.directory,descriptor.manifest)) == descriptor.metadata_bytes
            result = capture_read(store,descriptor)
            @test length(result.samples) == 2
            sample = first(result.samples)
            expected = first(first(capture_source())())
            @test sample.arrays.raw == expected.arrays.raw
            @test sample.arrays.slopes == expected.arrays.slopes
            @test eltype(sample.arrays.raw) === UInt16
            @test sample.arrays.raw[1,2] == 0x8001
            @test sample.arrays.raw[end,end] == 0xffff
            @test sample.arrays.validity[3] === false
            @test sample.quality["valid_rois"] == 187
            @test sample.exposure.domain == capture_coordinator_domain
            @test sample.metadata["raw"]["identity"]["domain"] == bytes2hex(collect(capture_domain.bytes))
            @test sample.metadata["raw"]["identity"]["generation"] == capture_generation
            @test sample.metadata["raw"]["header"]["pts"] == -17
            @test result.manifest["cursor"]["model_ns"] == 4000000
            @test result.manifest["after"]["generation"] == capture_generation
            @test result.manifest["domain_mapping"]["coordinator"] == capture_coordinator_domain
            @test result.manifest["domain_mapping"]["wire"] == bytes2hex(collect(capture_domain.bytes))
            raw_path = joinpath(store.directory,dirname(descriptor.manifest),"frame-000001-raw.bin")
            @test read(raw_path)[1:4] == UInt8[0x00,0x00,0x01,0x80]
            @test filemode(stat(raw_path)) & 0o777 == 0o444
            result.samples[1].arrays.raw[1,1] = 33
            @test capture_read(store,descriptor).samples[1].arrays.raw[1,1] == 0
            @test result.samples[1].arrays.raw !== result.samples[2].arrays.raw
            @test_throws ArgumentError capture_read(store,descriptor;expected_stage="dark")
            @test_throws ArgumentError CaptureFiles.read_capture(store.directory,descriptor;
                expected_profile="copper",expected_stage="lamp-training",expected_illumination="lamp",expected_settings=capture_settings)
            link = joinpath(parent,"linked")
            symlink(store.directory,link)
            @test_throws ArgumentError CaptureFiles.read_capture(link,descriptor;
                expected_profile="classic",expected_stage="lamp-training",expected_illumination="lamp",expected_settings=capture_settings)
            # Clock provenance is copied independently of model time, including PTP.
            clock_store = capture_store(parent;name="clock")
            clock_metadata = metadata -> map(receipt -> merge(receipt,(;
                wire_start=PipeWireAO.AcquisitionExposureStart(Int64(99),UInt64(2)),
                timebase=PipeWireAO.ACQUISITION_TIMEBASE_TAI,
                ptp_reference=PipeWireAO.AcquisitionPtpReference(PipeWireAO.PtpClockIdentity(ntuple(i -> UInt8(i),8)),UInt8(7)),
                acquisition_flags=UInt32(15))),metadata)
            clock_descriptor,_ = capture_write(clock_store;frames=1,metadata_change=clock_metadata)
            clock_read = capture_read(clock_store,clock_descriptor)
            @test clock_read.samples[1].metadata["raw"]["wire_start"]["nanoseconds"] == 99
            @test clock_read.samples[1].metadata["raw"]["ptp_reference"]["domain_number"] == 7
            @test clock_read.samples[1].exposure.start_model_ns == 0
        end
    end
    @testset "model cadence may leave gaps between detector exposures" begin
        mktempdir() do parent
            store = capture_store(parent)
            descriptor,_ = capture_write(store;frames=2,duration=1896000,period=2000000)
            result = capture_read(store,descriptor)
            @test result.samples[1].exposure.start_model_ns == 0
            @test result.samples[1].exposure.duration_ns == 1896000
            @test result.samples[2].exposure.start_model_ns == 2000000
            @test result.samples[2].exposure.duration_ns == 1896000
            @test descriptor.cursor.model_ns == 3896000
            @test result.samples[2].metadata["raw"]["model_start_ns"] == 2000000
            revised,original = capture_rewrite(store,descriptor,doc -> begin
                record = doc["exposures"][2]
                record["exposure"]["start_model_ns"] = 1895999
                for receipt in values(record["metadata"])
                    receipt["model_start_ns"] = 1895999
                end
            end)
            @test_throws ArgumentError capture_read(store,revised)
            capture_restore(store,descriptor,original)
            overlapping = capture_store(parent;name="overlapping")
            @test_throws ArgumentError capture_write(overlapping;frames=2,duration=2000000,period=1000000)
            @test !isfile(joinpath(overlapping.directory,"run-7-serial-1","manifest.json"))
        end
    end
    @testset "preflight capacity, stale requests, and bounded settings" begin
        mktempdir() do parent
            @test_throws ArgumentError capture_store(parent;name="copper",profile="copper")
            @test !ispath(joinpath(parent,"copper"))
            store = capture_store(parent;maximum=CaptureFiles.CLASSIC_CAPTURE_BYTES)
            acquire,count = capture_source()
            for frames in (UInt32(0),UInt32(2),UInt32(4097))
                @test_throws ArgumentError CaptureFiles.capture!(store,acquire;run=UInt64(7),serial=UInt64(1),probe=UInt32(1),
                    cursor=capture_cursor(),frames,deadline=CaptureClock.monotonic()+30)
                @test count[] == 0
            end
            @test store.used_bytes == 0
            descriptor,_ = capture_write(store;frames=1)
            @test_throws ArgumentError CaptureFiles.capture!(store,acquire;run=UInt64(7),serial=UInt64(1),probe=UInt32(1),
                cursor=descriptor.cursor,frames=UInt32(1),deadline=CaptureClock.monotonic()+30)
            @test count[] == 0
            ample = capture_store(parent;name="ample")
            completed,_ = capture_write(ample;frames=1)
            @test_throws ArgumentError CaptureFiles.capture!(ample,acquire;run=UInt64(7),serial=UInt64(2),probe=UInt32(1),
                cursor=capture_cursor(),frames=UInt32(1),deadline=CaptureClock.monotonic()+30)
            @test count[] == 0
            # A legitimate intervening owner exposure may advance beyond last capture.
            @test_throws ArgumentError CaptureFiles.capture!(ample,acquire;run=UInt64(7),serial=UInt64(2),probe=UInt32(1),
                cursor=capture_cursor(1,4000000),frames=UInt32(1),deadline=CaptureClock.monotonic()+30)
            @test count[] == 0
            later = capture_cursor(2,4000000)
            next,_ = capture_write(ample;frames=1,cursor=later,serial=2)
            @test next.cursor.sequence == 3
            @test_throws ArgumentError CaptureFiles.CaptureStore(joinpath(parent,"too-large");stage="x",illumination="x",
                settings=Dict("oversized"=>repeat("x",16385)),maximum_bytes=1000000)
            @test !ispath(joinpath(parent,"too-large"))
            @test_throws ArgumentError capture_store(parent)
        end
    end
    @testset "preflight rejects without store or acquisition effects" begin
        mktempdir() do parent
            store = capture_store(parent;maximum=CaptureFiles.CLASSIC_CAPTURE_BYTES)
            acquire,count = capture_source()
            state() = deepcopy((;store.directory,store.stage,store.illumination,store.settings,
                store.maximum_bytes,store.used_bytes,store.run,store.serial,store.cursor,store.domain))
            before = state()
            prepared = CaptureFiles.capture_preflight(store;run=UInt64(7),serial=UInt64(1),probe=UInt32(1),
                cursor=capture_cursor(),frames=UInt32(1),deadline=CaptureClock.monotonic()+30)
            @test prepared.after == capture_cursor()
            @test prepared.bytes == CaptureFiles.CLASSIC_CAPTURE_BYTES
            @test !ispath(prepared.directory)
            @test state() == before
            @test isempty(readdir(store.directory))
            @test count[] == 0
            for frames in (UInt32(0),UInt32(2),UInt32(4097))
                @test_throws ArgumentError CaptureFiles.capture_preflight(store;run=UInt64(7),serial=UInt64(1),probe=UInt32(1),
                    cursor=capture_cursor(),frames,deadline=CaptureClock.monotonic()+30)
                @test state() == before
                @test isempty(readdir(store.directory))
                @test count[] == 0
            end
            descriptor,_ = capture_write(store;frames=1)
            before = state()
            existing = readdir(store.directory)
            for (serial,cursor) in ((UInt64(1),descriptor.cursor),(UInt64(2),capture_cursor()))
                @test_throws ArgumentError CaptureFiles.capture_preflight(store;run=UInt64(7),serial,probe=UInt32(1),
                    cursor,frames=UInt32(1),deadline=CaptureClock.monotonic()+30)
                @test state() == before
                @test readdir(store.directory) == existing
                @test count[] == 0
            end
        end
    end
    @testset "interruption, deadlines and mismatched receipts never publish" begin
        mktempdir() do parent
            store = capture_store(parent)
            @test_throws ErrorException capture_write(store;frames=2,fail=2)
            @test !isfile(joinpath(store.directory,"run-7-serial-1","manifest.json"))
            @test isfile(joinpath(store.directory,"run-7-serial-1","frame-000001-raw.bin"))
            @test store.used_bytes == 2CaptureFiles.CLASSIC_CAPTURE_BYTES
            acquire,count = capture_source()
            @test_throws InvalidStateException CaptureFiles.capture!(store,acquire;run=UInt64(7),serial=UInt64(2),probe=UInt32(1),
                cursor=store.cursor,frames=UInt32(1),deadline=CaptureClock.monotonic()-1)
            @test count[] == 0
            bad = capture_store(parent;name="bad")
            change = metadata -> merge(metadata,(;slopes=merge(metadata.slopes,(;identity=PipeWireAO.AcquisitionIdentity(capture_domain,capture_generation,UInt64(99))))))
            @test_throws ArgumentError capture_write(bad;frames=1,metadata_change=change)
            @test !isfile(joinpath(bad.directory,"run-7-serial-1","manifest.json"))
            for (index,flag) in enumerate((PipeWireAO.SPA.META_HEADER_FLAG_CORRUPTED,PipeWireAO.SPA.META_HEADER_FLAG_GAP))
                flagged = capture_store(parent;name="flagged-$index")
                change_header = metadata -> map(receipt -> merge(receipt,(;header=PipeWireAO.BufferHeader(
                    flag,UInt32(0),Int64(0),Int64(0),receipt.identity.sequence))),metadata)
                @test_throws ArgumentError capture_write(flagged;frames=1,metadata_change=change_header)
                @test !isfile(joinpath(flagged.directory,"run-7-serial-1","manifest.json"))
            end
            stopped = capture_store(parent;name="stopped")
            acquire,count = capture_source()
            @test_throws ErrorException CaptureFiles.capture!(stopped,acquire;run=UInt64(7),serial=UInt64(1),probe=UInt32(1),
                cursor=capture_cursor(),frames=UInt32(2),deadline=CaptureClock.monotonic()+30,
                check=() -> (count[] == 0 || error("controller lost")))
            @test count[] == 1
            @test !isfile(joinpath(stopped.directory,"run-7-serial-1","manifest.json"))
            # External data and pre-existing directories are never cleaned or reused.
            marker = joinpath(parent,"retain.txt")
            write(marker,"keep")
            @test_throws ArgumentError CaptureFiles.CaptureStore(parent;stage="x",illumination="x",settings=Dict(),maximum_bytes=10)
            @test read(marker,String) == "keep"
        end
    end
    @testset "strict manifest and every payload contract" begin
        mktempdir() do parent
            store = capture_store(parent)
            descriptor,_ = capture_write(store;frames=1)
            changes = Function[
                doc -> (doc["unexpected"] = 1),
                doc -> (doc["profile"] = "copper"),
                doc -> (doc["illumination"] = "dark"),
                doc -> (doc["settings"]["graph_sha256"] = repeat("c",64)),
                doc -> (doc["settings"]["photon_noise"] = 1),
                doc -> (doc["domain_mapping"]["coordinator"] = 1),
                doc -> (doc["exposures"][1]["exposure"]["sequence"] = 2),
                doc -> (doc["exposures"][1]["metadata"]["raw"]["identity"]["domain"] = repeat("0",32)),
                doc -> (doc["exposures"][1]["metadata"]["flux"]["model_start_ns"] = 1),
                doc -> (doc["exposures"][1]["quality"]["valid_rois"] = 188),
                doc -> (doc["exposures"][1]["quality"]["finite_slopes"] = 1),
                doc -> (doc["cursor"]["model_ns"] = 7),
                doc -> (doc["cursor"]["sequence"] = true),
                doc -> (doc["cursor"]["sequence"] = 1.0),
                doc -> (doc["cursor"]["model_ns"] = 2000000.0)]
            for role in ("raw","slopes","flux","validity")
                append!(changes,[
                    doc -> (doc["exposures"][1]["payloads"][role]["encoding"] = "F64_LE"),
                    doc -> (doc["exposures"][1]["payloads"][role]["layout"] = "COLUMN_MAJOR"),
                    doc -> (doc["exposures"][1]["payloads"][role]["shape"] = [1]),
                    doc -> (doc["exposures"][1]["payloads"][role]["bytes"] = 1),
                    doc -> (doc["exposures"][1]["payloads"][role]["sha256"] = repeat("0",64)),
                    doc -> (doc["exposures"][1]["payloads"][role]["path"] = "../outside.bin")])
            end
            for change in changes
                revised,original = capture_rewrite(store,descriptor,change)
                try
                    @test_throws ArgumentError capture_read(store,revised)
                finally
                    capture_restore(store,descriptor,original)
                end
            end
            # Duplicate JSON keys must not silently overwrite an earlier value.
            manifest_path = joinpath(store.directory,descriptor.manifest)
            original = read(manifest_path)
            duplicated = replace(String(copy(original)),"\"schema_version\":1"=>"\"schema_version\":1,\"schema_version\":1")
            @test ncodeunits(duplicated) > length(original)
            chmod(manifest_path,0o600); write(manifest_path,duplicated)
            duplicate_descriptor = CaptureActions.Captured(descriptor.cursor,descriptor.manifest,bytes2hex(sha256(duplicated)),
                descriptor.frames,descriptor.bytes,UInt64(ncodeunits(duplicated)))
            @test_throws ArgumentError capture_read(store,duplicate_descriptor)
            capture_restore(store,descriptor,original)
            # The untrusted descriptor cannot choose an arbitrary path, size or cursor.
            for (path,bytes,metadata,cursor) in (
                    ("../manifest.json",descriptor.bytes,descriptor.metadata_bytes,descriptor.cursor),
                    (descriptor.manifest,UInt64(1),descriptor.metadata_bytes,descriptor.cursor),
                    (descriptor.manifest,descriptor.bytes,UInt64(0),descriptor.cursor),
                    (descriptor.manifest,descriptor.bytes,descriptor.metadata_bytes,capture_cursor(1,99)))
                bad = CaptureActions.Captured(cursor,path,descriptor.sha256,descriptor.frames,bytes,metadata)
                @test_throws ArgumentError capture_read(store,bad)
            end
            raw_path = joinpath(store.directory,dirname(descriptor.manifest),"frame-000001-raw.bin")
            original = read(raw_path)
            chmod(raw_path,0o600)
            write(raw_path,original[1:end-1])
            @test_throws ArgumentError capture_read(store,descriptor)
            write(raw_path,original)
            rm(raw_path)
            outside = joinpath(parent,"outside.bin")
            write(outside,original)
            symlink(outside,raw_path)
            @test_throws ArgumentError capture_read(store,descriptor)
            rm(raw_path)
            write(raw_path,original)
            # Rehashed BOOL8 payload still rejects a byte that is neither 0 nor 1.
            bool_path = joinpath(store.directory,dirname(descriptor.manifest),"frame-000001-validity.bin")
            chmod(bool_path,0o600)
            bool_bytes = read(bool_path); bool_bytes[1] = 2; write(bool_path,bool_bytes)
            revised,_ = capture_rewrite(store,descriptor,doc ->
                doc["exposures"][1]["payloads"]["validity"]["sha256"] = bytes2hex(sha256(bool_bytes)))
            @test_throws ArgumentError capture_read(store,revised)
        end
    end
    @test !any(id.name in ("CUDA","AMDGPU") for id in keys(Base.loaded_modules))
end
