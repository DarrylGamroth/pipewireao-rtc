using Test,SHA
include("heart_correction_owner.jl")
const CorrectionOwner=HeartCorrectionOwner

function correction_arguments(directory)
    arguments=String[]
    for name in Protocol.NATIVE_REQUIRED_OPTIONS
        value=name=="profile" ? "copper" : name=="rate" ? "500" :
            name=="exposure-ns" ? "2000000" :
            name=="control-node" ? "fixture.correction" :
            name=="control-instance" ? "23" : joinpath(directory,name)
        append!(arguments,["--$name",value])
    end
    append!(arguments,["--transport","heart","--correction-diagnostics","true",
        "--controller-node","fixture.heart","--controller-pid","123","--controller-instance","17",
        "--heart-client","/usr/bin/true","--heart-native-runtime",joinpath(directory,"native"),
        "--heart-probe-directory",joinpath(directory,"probes"),"--heart-telemetry-max-bytes","16777216",
        "--heart-active-contract",joinpath(directory,"contract.json"),"--heart-projection",joinpath(directory,"projection.f32le"),
        "--heart-native-ingress-mode","deferred"])
    return arguments
end

mutable struct EvidenceWindowFixture{Options}
    options::Options
    native_command_serial::UInt64
    evidence_count::UInt64
    evidence_bytes::UInt64
end

mutable struct AdmissionFixture
    active::Union{Nothing,Bool}
    completed_correct::Union{Nothing,Bool}
    retained::Bool
    window::Int
end

@testset "correction source hold and restored archive remain independent" begin
    state=(;closed=false,held=true)
    owner=(;session=(;state,native_controller_held=nothing),active=nothing,retained=true)
    @test CorrectionOwner.lifecycle_held(owner)
    closed=merge(owner,(;session=merge(owner.session,(;state=(;closed=true,held=true)))))
    @test !CorrectionOwner.lifecycle_held(closed)
    unheld=merge(owner,(;session=merge(owner.session,(;state=(;closed=false,held=false)))))
    @test !CorrectionOwner.lifecycle_held(unheld)
end

@testset "initial and reset actuation require public resume after links" begin
    for generation in (1,2)
        state=Protocol.OwnerState()
        owner=AdmissionFixture(nothing,nothing,false,generation)
        events=Symbol[:held_native_run,:connect_reply]
        links_active=Ref(false)
        observed_deadline=Ref{Union{Nothing,Float64}}(nothing)
        begin_native=function (candidate,expected;deadline=nothing)
            observed_deadline[]=deadline
            links_active[] && state.running || error("native receipt cannot complete before public admission")
            @test expected==generation
            push!(events,:zero_adopted)
            candidate.active=true
            push!(events,:native_correct)
        end
        # Reproduce the old startup/reset ordering with the same bounded stage:
        # a connect reply alone cannot complete the initial command receipt.
        @test_throws ErrorException begin_native(owner,generation)
        @test !CorrectionOwner.admit_active_window!(owner,state;begin_window=begin_native)
        @test events==[:held_native_run,:connect_reply]
        links_active[]=true;push!(events,:rtc_session_start)
        @test !CorrectionOwner.admit_active_window!(owner,state;begin_window=begin_native)
        reply=Protocol.control!(state,"{\"version\":1,\"id\":1,\"operation\":\"resume\"}",UInt64(10),UInt64(2),()->nothing)
        @test reply.ok && state.running
        push!(events,:public_source_resume)
        deadline=Main.HILHeartControl.Client.monotonic()+10.0
        @test CorrectionOwner.admit_active_window!(owner,state;begin_window=begin_native,deadline)
        @test observed_deadline[]===deadline
        push!(events,:first_exposure)
        @test events==[:held_native_run,:connect_reply,:rtc_session_start,:public_source_resume,:zero_adopted,:native_correct,:first_exposure]
        @test CorrectionOwner.admit_active_window!(owner,state;begin_window=begin_native)
        @test count(==(:zero_adopted),events)==1
        state.running=false
        @test !CorrectionOwner.admit_active_window!(owner,state;begin_window=begin_native)
    end
end
@testset "new native generation starts a fresh evidence journal" begin
    mktempdir() do root
        first=joinpath(root,"first");mkdir(first)
        session=EvidenceWindowFixture((;heart_probe_directory=first,heart_telemetry_max_bytes=UInt64(4096)),UInt64(7),UInt64(0),UInt64(0))
        CorrectionOwner.Native.record_evidence!(session,(;kind="first_generation"))
        second=joinpath(root,"second");mkdir(second)
        stale=EvidenceWindowFixture(merge(session.options,(;heart_probe_directory=second)),session.native_command_serial,session.evidence_count,session.evidence_bytes)
        @test_throws ErrorException CorrectionOwner.Native.record_evidence!(stale,(;kind="second_generation"))
        first_bytes=read(joinpath(first,"native-evidence.jsonl"))
        CorrectionOwner.begin_evidence_window!(session,second)
        @test session.native_command_serial==session.evidence_count==session.evidence_bytes==0
        CorrectionOwner.Native.record_evidence!(session,(;kind="second_generation"))
        @test session.evidence_count==1
        @test read(joinpath(first,"native-evidence.jsonl"))==first_bytes
        @test occursin("second_generation",read(joinpath(second,"native-evidence.jsonl"),String))
        @test_throws ErrorException CorrectionOwner.begin_evidence_window!(session,second)
    end
end

@testset "active native owner preserves distinct state and explicit scope" begin
    mktempdir() do directory
        arguments=correction_arguments(directory)
        options=CorrectionOwner.options(arguments)
        @test options.transport===:heart
        @test options.profile===:copper
        @test options.correction_diagnostics
        @test options.heart_native_ingress_mode=="deferred"
        @test_throws ErrorException CorrectionOwner.options(replace(arguments,"deferred"=>"streaming"))
        @test_throws ErrorException CorrectionOwner.options(replace(arguments,"copper"=>"classic"))
        @test_throws ErrorException CorrectionOwner.options(vcat(arguments,["--heart-client","/usr/bin/true"]))
        @test_throws ErrorException CorrectionOwner.options(replace(arguments,"true"=>"false"))
        mkdir(options.heart_probe_directory)
        @test_throws ErrorException CorrectionOwner.options(arguments)
    end
    @test length(CorrectionOwner.required_flags(:copper))==13
    @test !(CorrectionOwner.NativeActive <: CorrectionOwner.Native.NativeHold)
end

@testset "active projection contract preserves exact row-major bytes" begin
    mktempdir() do directory
        options=CorrectionOwner.options(correction_arguments(directory))
        write(options.graph,"fixture normal plant")
        projection=zeros(Float32,277,253)
        for index in 1:253;projection[index,index]=index/1000f0;end
        write(options.heart_projection,vec(permutedims(projection)))
        contract=Dict("version"=>1,"profile"=>"copper","controller_coordinates"=>253,"frames"=>options.frames,
            "detector_acceptance_policy"=>CorrectionOwner.Profiles.DETECTOR_ACCEPTANCE_POLICY,
            "native_ingress_mode"=>"deferred","gain"=>0.01,"pole"=>0.99,"integration_scalar"=>1.0,"controller_sign"=>-1,
            "plant_sha256"=>CorrectionOwner.digest(options.graph),
            "projection_wire_sha256"=>CorrectionOwner.digest(options.heart_projection),
            "frozen_helpers"=>Dict(name=>CorrectionOwner.digest(joinpath(@__DIR__,name)) for name in CorrectionOwner.FROZEN_HELPERS),
            "runtime_flags"=>[Dict("section"=>section,"field"=>field,"value"=>value) for (section,field,value) in CorrectionOwner.required_flags(:copper)])
        admission=Dict("passed"=>true,"actual_native_captures_revalidated"=>10,"actual_native_references_revalidated"=>2,
            "actual_training_grid_reproduced"=>true,"actual_validation_selection_reproduced"=>true,"actual_locked_utility_reproduced"=>true,
            "locked_test_sha256"=>"fixture locked seal","selected_controller_sha256"=>"fixture controller seal")
        admission_path=joinpath(directory,"heart-cold-admission.json")
        Protocol.write_json_atomic(admission_path,admission)
        contract["cold_admission_sha256"]=CorrectionOwner.digest(admission_path)
        contract["locked_test_sha256"]=admission["locked_test_sha256"]
        contract["selected_controller_sha256"]=admission["selected_controller_sha256"]
        Protocol.write_json_atomic(options.heart_active_contract,contract)
        actual,read_projection=CorrectionOwner.load_contract(options)
        @test reinterpret(UInt32,vec(projection))==reinterpret(UInt32,vec(read_projection))
        @test actual.controller_sign==-1
        contract["runtime_flags"]=contract["runtime_flags"][1:end-1]
        Protocol.write_json_atomic(options.heart_active_contract,contract)
        @test_throws ErrorException CorrectionOwner.load_contract(options)
        contract["runtime_flags"]=[Dict("section"=>section,"field"=>field,"value"=>value) for (section,field,value) in CorrectionOwner.required_flags(:copper)]
        contract["gain"]=0
        Protocol.write_json_atomic(options.heart_active_contract,contract)
        @test_throws ErrorException CorrectionOwner.load_contract(options)
    end
end

include("test_heart_correction_phase_fixture.jl")
@testset "closed generation proves all three native phase file sets" begin
    mktempdir() do root
        frames=2;budget=UInt64(1024*1024)
        for phase in CorrectionOwner.Phases.PHASES
            phase_fixture_set(root,CorrectionOwner.Phases.STREAMS,phase,frames)
        end
        records=CorrectionOwner.verify_closed_window(root,frames,budget)
        @test length(records)==5
        @test records["cbDmCmd0"].records==4
        @test records["cbDmCmd0"].last_sync==2
        @test records["cbClUnclipped0"].last_sync==0
        @test records["cbDmCmd0"].phase_records==Dict("startup_run"=>1,"correcting"=>2,"restore_run"=>1)
        @test length(records["cbDmCmd0"].files)==3
        @test_throws ErrorException CorrectionOwner.verify_closed_window(root,frames+1,budget)
        path=phase_fixture_path(root,:restore_run,"cbDmCmd0")
        open(path,"r+") do io;seek(io,1024+44);write(io,UInt32(0));end
        @test_throws ErrorException CorrectionOwner.verify_closed_window(root,frames,budget)
        phase_fixture_file(root,:restore_run,"cbDmCmd0",20,(277,1),frames)
        open(io->write(io,UInt8(0)),path,"a")
        @test_throws ErrorException CorrectionOwner.verify_closed_window(root,frames,budget)
    end
end
@testset "active receipts match exact native wire exposure sync" begin
    calls=Any[]
    arm=(sink,sequence;kwargs...)->push!(calls,(;sink,sequence,kwargs=(;kwargs...)))
    for sequence in UInt64[0,1,256]
        CorrectionOwner.arm_native_receipt!(:fixture,sequence;arm)
        @test calls[end].sequence==sequence
        @test calls[end].kwargs==(sequence==0 ? (;allow_zero_sequence=true) : (;))
        @test CorrectionOwner.require_receipt_sequence((;header=(;sequence)),sequence)===nothing
    end
    for (actual,expected) in ((0,1),(1,0),(0,256),(256,0),(255,256),(257,256))
        @test_throws ErrorException CorrectionOwner.require_receipt_sequence((;header=(;sequence=UInt64(actual))),UInt64(expected))
    end
end

@testset "old unique-file policy rejects the same valid rotated file fixture" begin
    mktempdir() do root
        for phase in CorrectionOwner.Phases.PHASES
            phase_fixture_set(root,CorrectionOwner.Phases.STREAMS,phase,2)
        end
        session=(;options=(;heart_native_runtime=root,heart_telemetry_max_bytes=UInt64(1024*1024)),
            readers=Dict{String,CorrectionOwner.Telemetry.TelemetryReader}(),service=()->nothing)
        @test_throws ErrorException CorrectionOwner.Native.read_native!(session,"cbHoPixelsRaw0",7,(64,64),time_ns()+UInt64(1_000_000_000))
        @test CorrectionOwner.verify_closed_window(root,2,UInt64(1024*1024))["cbHoPixelsRaw0"].records==2
    end
end

@testset "Classic active owner requires bound transfer and full-window profile capacity" begin
    mktempdir() do root
        arguments=correction_arguments(root)
        arguments=replace(arguments,"copper"=>"classic","deferred"=>"streaming","16777216"=>"134217728")
        active_path=joinpath(root,"active.u8")
        append!(arguments,["--heart-classic-active",active_path])
        options=CorrectionOwner.options(arguments)
        @test options.profile===:classic && options.heart_telemetry_max_bytes==UInt64(128*1024*1024)
        @test_throws ErrorException CorrectionOwner.options(replace(arguments,"134217728"=>"16777216"))
        write(options.graph,"synthetic normal Classic plant")
        write(active_path,UInt8[index in (86,87,102,103) ? 0 : 1 for index in 1:188])
        matrix=zeros(Float32,277,277);for index in 1:277;matrix[index,index]=1;end
        write(options.heart_projection,vec(permutedims(matrix)))
        E_path=joinpath(root,"native-extrapolation.f32le");write(E_path,vec(permutedims(matrix)))
        admission=Dict("passed"=>true,"actual_native_transfer_reproduced"=>true,"actual_native_captures_revalidated"=>1,
            "actual_native_frames_revalidated"=>1561,"actual_native_accepted_frames_revalidated"=>1536,
            "transfer_score_sha256"=>"synthetic transfer seal","selected_controller_sha256"=>"synthetic padded CM seal")
        admission_path=joinpath(root,"heart-cold-admission.json");Protocol.write_json_atomic(admission_path,admission)
        mkdir(joinpath(root,"heart"));mkdir(joinpath(root,"heart/calibration"))
        native_threshold=joinpath(root,"heart/calibration/threshold.fits");write(native_threshold,"sealed synthetic native FITS")
        wire_threshold=joinpath(root,"heart/classic-flux-thresholds.f32le");write(wire_threshold,fill(1000f0,188))
        contract=Dict("version"=>1,"profile"=>"classic","controller_coordinates"=>277,"frames"=>options.frames,
            "normal_response_policy"=>CorrectionOwner.Profiles.CLASSIC_RESPONSE_POLICY,
            "flux_threshold_native_file"=>"threshold.fits","flux_threshold_native_sha256"=>CorrectionOwner.digest(native_threshold),
            "flux_threshold_wire_sha256"=>CorrectionOwner.digest(wire_threshold),"runtime_inputs"=>Dict("threshold.fits"=>CorrectionOwner.digest(native_threshold)),
            "native_ingress_mode"=>"streaming","gain"=>-.3,"pole"=>.99,"integration_scalar"=>1,"controller_sign"=>1,
            "detector_acceptance_policy"=>CorrectionOwner.Profiles.DETECTOR_ACCEPTANCE_POLICY,
            "native_telemetry_max_bytes"=>128*1024*1024,"physical_projection_mode"=>"native-default-copy","projection_native_file"=>nothing,
            "projection_wire_sha256"=>CorrectionOwner.digest(options.heart_projection),"extrapolation_wire_sha256"=>CorrectionOwner.digest(E_path),
            "wfs_active_sha256"=>CorrectionOwner.digest(active_path),"plant_sha256"=>CorrectionOwner.digest(options.graph),
            "frozen_helpers"=>Dict(name=>CorrectionOwner.digest(joinpath(@__DIR__,name)) for name in CorrectionOwner.FROZEN_HELPERS),
            "runtime_flags"=>[Dict("section"=>section,"field"=>field,"value"=>value) for (section,field,value) in CorrectionOwner.required_flags(:classic)],
            "cold_admission_sha256"=>CorrectionOwner.digest(admission_path),"transfer_score_sha256"=>admission["transfer_score_sha256"],
            "selected_controller_sha256"=>admission["selected_controller_sha256"])
        Protocol.write_json_atomic(options.heart_active_contract,contract)
        actual,projection=CorrectionOwner.load_contract(options)
        @test actual.controller_sign==1 && projection isa CorrectionOwner.CorrectionTelemetry.ZonalProjection
        for key in ("actual_native_frames_revalidated","actual_native_accepted_frames_revalidated","actual_native_captures_revalidated")
            changed=copy(admission);changed[key]=0;Protocol.write_json_atomic(admission_path,changed)
            contract["cold_admission_sha256"]=CorrectionOwner.digest(admission_path);Protocol.write_json_atomic(options.heart_active_contract,contract)
            @test_throws ErrorException CorrectionOwner.load_contract(options)
        end
        Protocol.write_json_atomic(admission_path,admission);contract["cold_admission_sha256"]=CorrectionOwner.digest(admission_path)
        contract["detector_acceptance_policy"]="calibration-zero-rails";Protocol.write_json_atomic(options.heart_active_contract,contract)
        @test_throws ErrorException CorrectionOwner.load_contract(options)
    end
end

@testset "native runtime sparse links resolve only the sealed Classic input" begin
    mktempdir() do root
        calibration=joinpath(root,"calibration");mkdir(calibration)
        runtime=joinpath(root,"runtime");mkdir(runtime);mkdir(joinpath(runtime,"config"))
        name="map.sparse";source=joinpath(calibration,name)
        open(source,"w") do io
            println(io,"Sparse: rows=277 cols=277 nnz=12597")
            for index in 0:12596
                println(io,"$(div(index,277)) $(rem(index,277)) 0.125")
            end
        end
        link=joinpath(runtime,"config",name);symlink(realpath(source),link)
        options=(;heart_native_runtime=runtime)
        contract=(;extrapolation_native_file=name,runtime_inputs=Dict(name=>CorrectionOwner.digest(source)))
        @test islink(link)
        @test_throws ArgumentError CorrectionOwner.Profiles.sparse_extrapolation(link)
        actual=CorrectionOwner.read_native_extrapolation(options,contract)
        expected=CorrectionOwner.Profiles.sparse_extrapolation(source)
        @test reinterpret(UInt32,vec(actual))==reinterpret(UInt32,vec(expected))
        other=joinpath(calibration,"changed.sparse")
        write(other,replace(read(source,String),"0.125"=>"0.25";count=1))
        rm(link);symlink(realpath(other),link)
        @test_throws ErrorException CorrectionOwner.read_native_extrapolation(options,contract)
        rm(link);symlink(realpath(source),link)
        write(source,replace(read(source,String),"0.125"=>"0.25";count=1))
        @test_throws ErrorException CorrectionOwner.read_native_extrapolation(options,contract)
    end
end
