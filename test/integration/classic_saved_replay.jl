# Read-only science revalidation of a retained managed capture. No session is started.
module ClassicSavedReplay
using Test
include("classic_managed_replay.jl")
const M=ClassicManagedReplay
const C=M.C

function load_record(stage,name,::Type{T},rows,count,metadata,expected_hash) where T
    path=joinpath(stage,name)
    @test C.sha256_file(path)==expected_hash
    @test filesize(path)==sizeof(T)*rows*count
    values=open(path) do io
        read!(io,Matrix{T}(undef,rows,count))
    end
    entry=metadata[name]
    @test length(entry["seen"])==length(entry["identities"])==length(entry["pts_ns"])==count
    identities=map(entry["identities"]) do identity
        identity===nothing && return nothing
        M.AcquisitionIdentity(M.AcquisitionDomain(Tuple(hex2bytes(identity["domain"]))),
            UInt64(identity["generation"]),UInt64(identity["sequence"]))
    end
    # Capture stored each column at its actual Header.sequence. Only PTS was retained;
    # do not invent the other Header fields when loading the saved columns.
    headers=[pts===nothing ? nothing : (;pts) for pts in entry["pts_ns"]]
    return (;values,seen=BitVector(entry["seen"]),identities,headers)
end

function main(application,stage,provenance_path,frozen_harness)
    result_path=joinpath(stage,"offline-verification.json")
    ispath(result_path) && error("verification receipt already exists; preserve it")
    options,count=M.replay_options(application)
    provenance=C.read_json(provenance_path)
    observation=C.read_json(joinpath(stage,"observation.json"))
    ledger=C.read_json(joinpath(stage,"final-launch.json"))
    metadata=C.read_json(joinpath(stage,"prefix-identities.json"))
    retained=("observation.json","prefix-identities.json","phase-timing.json",
        "ready.json","start.json","stop.json","session.json","shutdown-attempt.json",
        "final-launch.json","gpu-audit.json")
    input_hashes=Dict(name=>C.sha256_file(joinpath(stage,name)) for name in retained)
    frozen_hashes=Dict(name=>C.sha256_file(joinpath(frozen_harness,name)) for name in keys(M.SOURCE_HASHES))
    source=merge(Dict("deployment.conf"=>provenance["deployment_sha256"]),provenance["artifacts"])
    report=nothing
    @testset "Saved managed Classic CPU science revalidation" begin
        @test all(C.sha256_file(joinpath(application,path))==hash for (path,hash) in source)
        @test C.sha256_file(joinpath(application,"Manifest.toml"))==provenance["manifest_sha256"]
        @test C.read_json(joinpath(stage,"ready.json"))["state"]=="Ready"
        @test C.read_json(joinpath(stage,"start.json"))["state"]=="Running"
        @test C.read_json(joinpath(stage,"stop.json"))["state"]=="Ready"
        @test C.read_json(joinpath(stage,"shutdown-attempt.json"))["accepted"]===true
        @test ledger["phase"]=="stopped" && ledger["cleanup_complete"]===true
        @test get(ledger,"error",nothing)===nothing && isempty(get(ledger,"cleanup_errors",[]))
        records=map((("frames-u16-row-major.bin",UInt16,352*352),
            ("demanded-f32-micrometre.bin",Float32,277),
            ("applied-f32-micrometre.bin",Float32,277))) do (name,type,rows)
            load_record(stage,name,type,rows,count,metadata,observation["payload_sha256"][name])
        end
        report=M.verify_science(application,records,observation,ledger,source)
        @test all(C.sha256_file(joinpath(stage,name))==hash for (name,hash) in input_hashes)
        @test all(C.sha256_file(joinpath(frozen_harness,name))==hash for (name,hash) in frozen_hashes)
    end
    # Retain the original failed test result. This receipt reports a separate offline check.
    report["verification"]="Offline revalidation of saved managed capture; no live lifecycle repeated"
    report["retained_metadata_sha256"]=input_hashes
    report["collected_harness_sha256"]=frozen_hashes
    report["provenance_sha256"]=C.sha256_file(provenance_path)
    report["saved_replay_sha256"]=C.sha256_file(@__FILE__)
    report["applied_metadata_contract"]="Header sequence/PTS and payload; no Acquisition metadata"
    C.write_json(result_path,report)
end
abspath(PROGRAM_FILE)==(@__FILE__) && main(ARGS...)
end
