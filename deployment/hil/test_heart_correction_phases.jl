using Test
include("heart_calibration_telemetry.jl")
include("heart_correction_telemetry.jl")
include("heart_correction_profiles.jl")
include("heart_correction_phases.jl")
include("test_heart_correction_phase_fixture.jl")
const Phases=HeartCorrectionPhases
const Telemetry=HeartCalibrationTelemetry
function phase_test_session(root,service=()->nothing)
    return (;options=(;heart_native_runtime=root,heart_telemetry_max_bytes=UInt64(1024*1024)),
        readers=Dict{String,Telemetry.TelemetryReader}(),service)
end
remaining_phase(until)=(time_ns()<until || error("fixture deadline expired");until-time_ns())
function consume_phase!(session,store,phase,frames)
    for (tag,datatype,shape) in Phases.STREAMS
        for index in 1:Phases.expected_count(phase,tag,frames)
            frame=Phases.read_frame!(session,store,tag,datatype,shape,time_ns()+UInt64(1_000_000_000);remaining=remaining_phase)
            Phases.validate_frame(frame,phase,tag,index,frames)
        end
    end
    Phases.drained!(session,store,frames)
end
@testset "native rotation is gated by all empty phase headers" begin
    mktempdir() do root
        frames=2;store=Phases.PhaseStore();session=phase_test_session(root)
        for phase in Phases.PHASES
            phase_fixture_set(root,Phases.STREAMS,phase,frames;empty=true)
            admitted=Phases.enter!(session,store,phase,time_ns()+UInt64(1_000_000_000);remaining=remaining_phase,frames)
            @test length(admitted)==5
            @test store.current===phase
            @test all(entry->entry.per_file_records==0 && entry.inode>0,values(admitted))
            # Public synthetic writer appends to the same inode after admission.
            for (tag,datatype,shape) in Phases.STREAMS
                phase_fixture_file(root,phase,tag,datatype,shape,frames)
            end
            consume_phase!(session,store,phase,frames)
        end
        @test length(store.paths)==3
        @test length(Phases.read_archive(root;frames,budget=UInt64(1024*1024)).files)==15
        @test_throws ErrorException Phases.enter!(session,store,:restore_run,time_ns()+UInt64(1_000_000_000);remaining=remaining_phase,frames)
        foreach(close,values(session.readers))
    end
end
@testset "new phase admission excludes partial sets and premature records" begin
    mktempdir() do root
        store=Phases.PhaseStore();session=phase_test_session(root)
        for stream in Phases.STREAMS[1:4];phase_fixture_file(root,:startup_run,stream...,2;empty=true);end
        @test_throws ErrorException Phases.enter!(session,store,:startup_run,time_ns()+UInt64(10_000_000);remaining=remaining_phase,frames=2)
        @test store.current===nothing && isempty(session.readers)
        phase_fixture_file(root,:startup_run,Phases.STREAMS[5]...,2)
        @test_throws ErrorException Phases.enter!(session,store,:startup_run,time_ns()+UInt64(1_000_000_000);remaining=remaining_phase,frames=2)
    end
    mktempdir() do root
        store=Phases.PhaseStore();session=phase_test_session(root)
        phase_fixture_set(root,Phases.STREAMS,:startup_run,2;empty=true)
        path=phase_fixture_path(root,:startup_run,"cbDmCmd0")
        open(path,"r+") do io;seek(io,128);write(io,UInt64(1));end
        @test_throws ErrorException Phases.enter!(session,store,:startup_run,time_ns()+UInt64(1_000_000_000);remaining=remaining_phase,frames=2)
    end
end
@testset "retained phase counters and file ownership remain strict" begin
    mktempdir() do root
        frames=2
        for phase in Phases.PHASES;phase_fixture_set(root,Phases.STREAMS,phase,frames);end
        archive=Phases.read_archive(root;frames,budget=UInt64(1024*1024))
        @test archive.phases[:startup_run]["cbDmCmd0"][1].bucket==0
        @test archive.phases[:correcting]["cbDmCmd0"][1].bucket==1
        @test archive.phases[:restore_run]["cbDmCmd0"][1].bucket==3
        @test archive.phases[:restore_run]["cbDmCmd0"][1].sync==2
        path=phase_fixture_path(root,:correcting,"cbDmCmd0")
        open(path,"r+") do io;seek(io,144);write(io,UInt64(3));end
        @test_throws ErrorException Phases.read_archive(root;frames,budget=UInt64(1024*1024))
        phase_fixture_file(root,:correcting,"cbDmCmd0",20,(277,1),frames)
        extra=joinpath(root,replace(basename(path),".000000"=>".000001"));cp(path,extra)
        @test_throws ErrorException Phases.read_archive(root;frames,budget=UInt64(1024*1024))
        rm(extra);write(joinpath(root,"unknown.tel"),zeros(UInt8,1024))
        @test_throws ErrorException Phases.read_archive(root;frames,budget=UInt64(1024*1024))
    end
    mktempdir() do root
        store=Phases.PhaseStore();session=phase_test_session(root)
        phase_fixture_set(root,Phases.STREAMS,:startup_run,2;empty=true)
        Phases.enter!(session,store,:startup_run,time_ns()+UInt64(1_000_000_000);remaining=remaining_phase,frames=2)
        path=phase_fixture_path(root,:startup_run,"cbDmCmd0")
        mv(path,path*".old");phase_fixture_file(root,:startup_run,"cbDmCmd0",20,(277,1),2;empty=true)
        @test_throws ErrorException Phases.drained!(session,store,2)
        foreach(close,values(session.readers))
    end
end
@testset "all phase headers are observed before the admission callback returns" begin
    mktempdir() do root
        frames=2;store=Phases.PhaseStore();polls=Ref(0)
        for stream in Phases.STREAMS[1:4];phase_fixture_file(root,:startup_run,stream...,frames;empty=true);end
        service=()->begin
            polls[]+=1
            polls[]==2 && phase_fixture_file(root,:startup_run,Phases.STREAMS[5]...,frames;empty=true)
        end
        session=phase_test_session(root,service)
        admitted=Phases.enter!(session,store,:startup_run,time_ns()+UInt64(2_000_000_000);remaining=remaining_phase,frames)
        @test polls[]>=2
        @test length(admitted)==length(session.readers)==5
        @test all(reader->reader.frames==0,values(session.readers))
        foreach(close,values(session.readers))
    end
end
@testset "Classic phases retain native padded VDM and permanent eligibility" begin
    mktempdir() do root
        frames=2;active=fill(true,188);active[[86,87,102,103]].=false
        streams=Phases.stream_contract(:classic)
        @test streams[1]==("cbHoPixelsRaw0",7,(352,352))
        @test streams[3]==("cbHoGrad0",13,(188,1))
        @test streams[4]==("cbClUnclipped0",16,(277,1))
        for phase in Phases.PHASES;phase_fixture_set(root,streams,phase,frames;active);end
        archive=Phases.read_archive(root;frames,budget=UInt64(4*1024*1024),profile=:classic,active)
        @test length(archive.files)==15
        @test archive.phases[:restore_run]["cbDmCmd0"][1].sync==2
        @test_throws ArgumentError Phases.read_archive(root;frames,budget=UInt64(4*1024*1024))
        path=phase_fixture_path(root,:correcting,"cbHoGrad0")
        open(path,"r+") do io;seek(io,1024+64+16(86-1));write(io,Int32(0));end
        @test_throws ArgumentError Phases.read_archive(root;frames,budget=UInt64(4*1024*1024),profile=:classic,active)
    end
end
