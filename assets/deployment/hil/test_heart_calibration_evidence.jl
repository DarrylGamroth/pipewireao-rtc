using Test, JSON3, SHA
include("heart_calibration_evidence.jl")
const Evidence = HeartCalibrationEvidence

function write_value!(bytes, offset, value::T) where T<:Integer
    copyto!(bytes, offset+1, reinterpret(UInt8, [htol(value)]), 1, sizeof(T))
end
write_value!(bytes, offset, value::Float64) = write_value!(bytes, offset, reinterpret(UInt64, value))
function write_json(path, value)
    open(path, "w") do io
        JSON3.write(io, value); write(io, '\n')
    end
end
function native_stream(path, tag, datatype, shape, payloads; calibrated=false, dm=false)
    element_bytes = datatype == 7 ? 2 : 4
    data_bytes = cld(prod(shape)*element_bytes, 64)*64
    header = zeros(UInt8, 1024)
    copyto!(header, 1, codeunits(tag), 1, ncodeunits(tag))
    write_value!(header, 32, Float64(element_bytes)); write_value!(header, 40, Int32(datatype))
    write_value!(header, 48, UInt32(shape[1])); write_value!(header, 52, UInt32(shape[2]))
    write_value!(header, 56, UInt32(data_bytes)); write_value!(header, 144, UInt64(length(payloads)))
    open(path, "w") do io
        write(io, header)
        for (index, payload) in enumerate(payloads)
            bytes = zeros(UInt8, 64+data_bytes)
            write_value!(bytes, 0, calibrated ? Int64(0) : Int64(1_000_000+index))
            write_value!(bytes, 16, UInt64(index-1)); write_value!(bytes, 32, Int16(2)); write_value!(bytes, 34, UInt16(2))
            progress = datatype == 7 || dm ? UInt16(0) : calibrated ? UInt16(64) : UInt16(3600)
            write_value!(bytes, 36, progress); write_value!(bytes, 38, progress)
            write_value!(bytes, 44, dm ? UInt32(0) : UInt32(index))
            copyto!(bytes, 65, payload, 1, length(payload)); write(io, bytes)
        end
    end
end
function evidence_fixture(directory)
    package, evidence = joinpath(directory, "package"), joinpath(directory, "evidence")
    mkpath(joinpath(package, "heart/calibration")); mkpath(joinpath(evidence, "heart/native"))
    write(joinpath(package, "deployment.conf"), "{}\n")
    write(joinpath(package, "heart/calibration/pwfsRoiOffsets_64.csv"), "4 2 1 uint\n0,0\n0,32\n32,0\n32,32\n")
    positive = zeros(Float32, 277); positive[139] = 0.04f0
    negative = zeros(Float32, 277); negative[139] = -0.04f0
    reference = zeros(Float32, 277)
    plan = (; version=1, run=1, reference, probes=[positive, negative], measurements=3600, frames_per_probe=2,
        settling=(; kind="discard_exposures", frames=1), timeouts_ns=(; ownership=1, adoption=1, settling=1, collection=1, restoration=1))
    write_json(joinpath(package, "heart-calibration-plan.json"), plan)
    mkpath(joinpath(package,"heart/bin")); write(joinpath(package,"heart/bin/scaoTemplate"), "native fixture")
    ingress = (; mode="streaming", environment_key="HRT_DEFER_WFS_INGRESS", environment_value="0", shape=[64,64],
        packet_rows=32,datagrams_per_frame=2,executable_sha256=Evidence.digest(joinpath(package,"heart/bin/scaoTemplate")))
    calibration = (; native_ingress=ingress, telemetry_max_bytes_per_file=1_000_000, plant=(; detector_seed=531, graph_sha256="plant"),
        native_config_sha256="native-config", frozen_plan=(; sha256=Evidence.digest(joinpath(package, "heart-calibration-plan.json"))), frozen_method=nothing)
    write_json(joinpath(package, "provenance.json"), (; heart_calibration=calibration))
    config = (; rng_seed=531, bits=14, exposure_duration_s=0.002)
    mapping = (; opaque_domain=1, complete_domain=collect(1:16))
    correct = "ack<0><ACCEPTED>\nstatus<0><SUCCESS>\n"
    hold = (; child_pid=123, generation=1, admitted_frames=0, run_acknowledged=true, endpoints_acknowledged=true,
        ingress_mode="streaming", ingress_environment="0", endpoint_enable_command="startup CORRECT", endpoint_reply_sha256=bytes2hex(sha256(correct)))
    startup = (; engine="heart", profile="copper", acquisition_generation=1, acquisition_domain_mapping=mapping,
        sequence=0, native_controller_held=hold, detector_config=config, graph_sha256="plant")
    identity = (; deployment_sha256=Evidence.digest(joinpath(package, "deployment.conf")), acquisition_generation=1,
        acquisition_domain_mapping=mapping, native_child_pid=123, runtime=joinpath(directory,"runtime"), instance="run-owned",
        processes=(; heart=(; pid=124)))
    write_json(joinpath(evidence, "native-runtime-identity.json"), identity)
    write_json(joinpath(evidence, "heart/native/heart-owner-status.json"), (; child_pid=123,generation=1,owner_pid=124,
        native_ingress=(; mode="streaming",environment_key="HRT_DEFER_WFS_INGRESS",observed_environment="0"), error=nothing,source_config_sha256="native-config", rendered_config=joinpath(identity.runtime,identity.instance,"heart/native/config/heart.yaml")))
    mkpath(joinpath(evidence,"native-control"))
    write(joinpath(evidence,"native-control/startup-CORRECT.log"),correct)
    write(joinpath(evidence,"native-control/startup-CORRECT.log.stderr"),"")
    for serial in 1:5
        name=serial==1 ? "RUN" : serial==2 ? "SET_TELM_RECORD" : "DM_SHAPE"
        write_json(joinpath(evidence,"native-control/command-$serial.log.json"), (; name,exitcode=0,termsignal=0,
            failure=nothing,truncated=false,stdout=correct,stderr=""))
    end
    raw = [collect(reinterpret(UInt8, fill(UInt16(index), 4096))) for index in 1:7]
    cal = [collect(reinterpret(UInt8, fill(2.0f0, 4096))) for _ in 1:7]
    grad = [collect(reinterpret(UInt8, fill(index == 1 ? 0.0f0 : Float32(index), 3600))) for index in 1:7]
    dm = [collect(reinterpret(UInt8, figure)) for figure in (positive, negative, reference)]
    paths = Dict{String,String}()
    for (tag, dtype, shape, payloads, calibrated, command) in (("cbHoPixelsRaw0",7,(64,64),raw,false,false),
        ("cbHoPixelsCalib0",8,(64,64),cal,true,false), ("cbHoGrad0",8,(3600,1),grad,false,false), ("cbDmCmd0",20,(277,1),dm,false,true))
        path = joinpath(evidence, "heart/native/DATE_$(tag)_RUN_TIME.tel"); paths[tag] = path
        native_stream(path, tag, dtype, shape, payloads; calibrated, dm=command)
    end
    association = joinpath(evidence, "native-association.jsonl")
    open(association, "w") do io
        for index in 1:7
            if index in (1,4,7)
                probe = cld(index,3)
                hash = bytes2hex(sha256(dm[probe]))
                JSON3.write(io, (; kind="adopted", sequence=probe, native_bucket=probe-1, native_sync=0,
                    clipped=false, requested_sha256=hash, adopted_sha256=hash)); write(io, '\n')
            end
            e = (; domain=1, generation=1, sequence=index, start_model_ns=(index-1)*2_000_000, duration_ns=2_000_000)
            JSON3.write(io, (; kind="exposure", probe_sequence=cld(index,3), exposure=e, native_sync=index, raw_bucket=index-1, measurement_bucket=index-1,
                valid=index>1, raw_sha256=bytes2hex(sha256(raw[index])), measurement_sha256=bytes2hex(sha256(grad[index])),
                calibrated_sha256=bytes2hex(sha256(cal[index])))); write(io, '\n')
        end
    end
    final = merge(startup, (; sequence=7, completed=true, restoration_confirmed=true, ownership_held=false, failure=nothing,
        native_evidence=(; sha256=Evidence.digest(association)), detector_diagnostics=(; frames=7, maximum_adc=7,
            invalid_frames=1, upper_rail_pixels=0, upper_rail_frames=0, adc_upper_rail=16383)))
    write_json(joinpath(evidence, "simulator-result.json"), final)
    responses = [(; valid=true, values=fill(mean, 3600), exposures=[(; domain=1,generation=1,sequence=index,
        start_model_ns=(index-1)*2_000_000,duration_ns=2_000_000) for index in indices]) for (mean,indices) in ((2.5f0,2:3),(5.5f0,5:6))]
    result = (; version=1, run=1, phase="complete", restoration_confirmed=true, resume_permitted=true,
        failure=nothing, recovery_failure=nothing, responses)
    write_json(joinpath(evidence, "calibration-result.json"), result)
    completion = (; startup_owner_report=startup, final_owner_report=final, runtime_identity=identity,
        limits=(; completed_exposures=7,native_dm_records=3), cli_result_sha256=Evidence.digest(joinpath(evidence,"calibration-result.json")))
    write_json(joinpath(evidence, "native-plan-result.json"), completion)
    return package,evidence,paths,completion,result
end

@testset "actual native payloads authorize public means and reject metadata-only candidates" begin
    mktempdir() do directory
        package,evidence,paths,completion,result = evidence_fixture(directory)
        verified = Evidence.verify(package,evidence)
        @test verified.public_means_match_native
        @test verified.accepted_frames == 4
        @test verified.maximum_adc == 7 && verified.invalid_frames == 1
        original = read(paths["cbHoGrad0"])
        changed = copy(original); changed[1024+14464+65] ⊻= UInt8(1); write(paths["cbHoGrad0"],changed)
        @test_throws ArgumentError Evidence.verify(package,evidence)
        write(paths["cbHoGrad0"],original)
        changed_result = JSON3.read(JSON3.write(result), Dict{String,Any})
        changed_result["responses"][1]["values"][1] += 1
        write_json(joinpath(evidence,"calibration-result.json"),changed_result)
        write_json(joinpath(evidence,"native-plan-result.json"),merge(completion,(; cli_result_sha256=Evidence.digest(joinpath(evidence,"calibration-result.json")))))
        @test_throws ArgumentError Evidence.verify(package,evidence) # self-consistent hashes still fail actual means
        write_json(joinpath(evidence,"calibration-result.json"),result)
        write_json(joinpath(evidence,"native-plan-result.json"),completion)
        for (name, change) in (("heart/native/heart-owner-status.json", d -> d["child_pid"] = 999),
            ("heart/native/heart-owner-status.json", d -> d["native_ingress"]["observed_environment"] = "1"),
            ("simulator-result.json", d -> d["detector_diagnostics"]["maximum_adc"] = 8))
            path = joinpath(evidence,name); saved = read(path)
            changed = JSON3.read(String(copy(saved)),Dict{String,Any}); change(changed); write_json(path,changed)
            @test_throws ArgumentError Evidence.verify(package,evidence)
            write(path,saved)
        end
        original_dm = read(paths["cbDmCmd0"])
        changed_dm = copy(original_dm); changed_dm[1024+65] ⊻= UInt8(1); write(paths["cbDmCmd0"],changed_dm)
        @test_throws ArgumentError Evidence.verify(package,evidence)
        write(paths["cbDmCmd0"],original_dm)
        association_path = joinpath(evidence,"native-association.jsonl")
        saved_association = read(association_path,String)
        rows = split(chomp(saved_association),'\n'); rows[1],rows[2] = rows[2],rows[1]
        write(association_path,join(rows,'\n') * "\n")
        final = JSON3.read(read(joinpath(evidence,"simulator-result.json"),String),Dict{String,Any})
        final["native_evidence"]["sha256"] = Evidence.digest(association_path)
        write_json(joinpath(evidence,"simulator-result.json"),final)
        write_json(joinpath(evidence,"native-plan-result.json"),merge(completion,(; final_owner_report=final)))
        @test_throws ArgumentError Evidence.verify(package,evidence)
        write(association_path,saved_association)
        write_json(joinpath(evidence,"simulator-result.json"),completion.final_owner_report)
        write_json(joinpath(evidence,"native-plan-result.json"),completion)
        rm(paths["cbHoPixelsRaw0"])
        @test_throws ArgumentError Evidence.verify(package,evidence)
    end
end
