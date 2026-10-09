using Test,SHA
include("heart_calibration_telemetry.jl")
include("heart_correction_telemetry.jl")
include("heart_correction_profiles.jl")
const Profiles=HeartCorrectionProfiles
const Telemetry=HeartCalibrationTelemetry
digest(path)=bytes2hex(open(sha256,path))

@testset "native active profile representation and recurrence remain explicit" begin
    copper=Profiles.descriptor(:copper);classic=Profiles.descriptor(:classic)
    @test (copper.width,copper.measurements,copper.coordinates,copper.adc_bits,copper.ingress,copper.gain,copper.sign)==(64,3600,253,14,"deferred",.01,-1)
    @test (classic.width,classic.measurements,classic.coordinates,classic.adc_bits,classic.ingress,classic.gain,classic.sign)==(352,376,277,12,"streaming",-.3,1)
    @test copper.pole==classic.pole==.99
    @test copper.frame_output===:pwfs_frame
    @test classic.frame_output===:shwfs_frame
    @test Profiles.streams(:copper,256)[4]==("cbClUnclipped0",16,(253,1),256)
    @test Profiles.streams(:classic,256)[3]==("cbHoGrad0",13,(188,1),256)
    @test Profiles.streams(:classic,256)[5]==("cbDmCmd0",20,(277,1),258)
    @test_throws ArgumentError Profiles.descriptor(:other)
    @test_throws ArgumentError Profiles.streams(:classic,0)
    @test_throws ArgumentError Profiles.streams(:classic,257)
end

@testset "wire maps and Classic eligibility are byte-bound" begin
    mktempdir() do root
        path=joinpath(root,"map.f32le");matrix=Float32[1 2;3 4]
        write(path,vec(permutedims(matrix)))
        @test Profiles.read_matrix(path,(2,2),digest(path))==matrix
        @test_throws ArgumentError Profiles.read_matrix(path,(2,2),"wrong")
        @test_throws ArgumentError Profiles.read_matrix(path,(2,3),digest(path))
        mask=joinpath(root,"active.u8");bytes=ones(UInt8,188);bytes[[86,87,102,103]].=0
        write(mask,bytes)
        active=Profiles.read_active(mask,digest(mask))
        @test findall(!,active)==[86,87,102,103]
        @test_throws ArgumentError Profiles.read_active(mask,"wrong")
        bytes[1]=2;write(mask,bytes)
        @test_throws ArgumentError Profiles.read_active(mask,digest(mask))
    end
end

@testset "public sparse format requires exact bounds and unique coordinates" begin
    mktempdir() do root
        path=joinpath(root,"native.sparse")
        open(path,"w") do io
            println(io,"Sparse: rows=277 cols=277 nnz=12597")
            for index in 0:12596
                println(io,"$(div(index,277)) $(rem(index,277)) $(Float32(index)/10000f0)")
            end
        end
        matrix=Profiles.sparse_extrapolation(path)
        @test size(matrix)==(277,277)
        @test matrix[46,132]==12596f0/10000f0
        @test matrix[277,277]==0f0
        original=read(path,String)
        write(path,replace(original,"nnz=12597"=>"nnz=12597 name=dmExTT"))
        @test reinterpret(UInt32,vec(Profiles.sparse_extrapolation(path)))==reinterpret(UInt32,vec(matrix))
        write(path,replace(original,"nnz=12597"=>"nnz=12597 name=dmExTT name=duplicate"))
        @test_throws ArgumentError Profiles.sparse_extrapolation(path)
        write(path,replace(original,"nnz=12597"=>"nnz=12597 unknown=value"))
        @test_throws ArgumentError Profiles.sparse_extrapolation(path)
        write(path,replace(original,"rows=277"=>"rows=221"))
        @test_throws DimensionMismatch Profiles.sparse_extrapolation(path)
        write(path,original*"0 0 1\n")
        @test_throws ArgumentError Profiles.sparse_extrapolation(path)
        write(path,join(split(chomp(original),'\n')[1:end-1],'\n')*"\n")
        @test_throws ArgumentError Profiles.sparse_extrapolation(path)
    end
end

@testset "native disabled Classic measurements retain raw slopes" begin
    spec=Telemetry.TelemetrySpec("cbHoGrad0",Int32(13),188,1,16,3008)
    payload=zeros(UInt8,3008);active=fill(true,188);active[86]=false
    for index in 1:188
        first=16(index-1)+1
        payload[first:first+15]=reinterpret(UInt8,vcat(reinterpret(UInt32,[Int32(index==86 ? -1 : 1)]),
            reinterpret(UInt32,Float32[.125,.25,1001])))
    end
    frame=Telemetry.TelemetryFrame(spec,UInt64(0),UInt32(1),Int64(1),Int16(2),UInt16(188),UInt16(188),payload)
    @test Profiles.response_valid(frame,:classic,active)
    response=Telemetry.classic_response(frame;order=collect(1:188),scale=(1.0,1.0),active)
    @test response.slopes[171:172]==Float32[.125,.25]
    first=16(86-1)+1;payload[first:first+3]=reinterpret(UInt8,[Int32(0)])
    @test_throws ArgumentError Profiles.response_valid(frame,:classic,active)
    payload[first:first+3]=reinterpret(UInt8,[Int32(1)])
    @test_throws ArgumentError Profiles.response_valid(frame,:classic,active)
end

@testset "Classic full-window telemetry capacity uses complete aligned records" begin
    @test Profiles.required_file_budget(:classic,256)==UInt64(126895104)
    @test Profiles.required_file_budget(:classic,256)>UInt64(16*1024*1024)
    @test Profiles.required_file_budget(:classic,256)<=Profiles.descriptor(:classic).telemetry_max_bytes
    @test Profiles.required_file_budget(:copper,256)<=Profiles.descriptor(:copper).telemetry_max_bytes
    @test_throws ArgumentError Profiles.required_file_budget(:classic,257)
    mktempdir() do root
        path=joinpath(root,"classic-calibrated.tel");header=zeros(UInt8,1024)
        tag="cbHoPixelsCalib0";header[1:ncodeunits(tag)]=codeunits(tag)
        field!(offset,value)=(header[offset+1:offset+sizeof(value)]=reinterpret(UInt8,[value]))
        for (offset,value) in ((32,4.0),(40,Int32(8)),(48,UInt32(352)),(52,UInt32(352)),(56,UInt32(495616)),(144,UInt64(256)))
            field!(offset,value)
        end
        open(path,"w") do io
            write(io,header)
            truncate(io,Int(Profiles.required_file_budget(:classic,256)))
        end
        @test filesize(path)==126895104
        @test_throws ArgumentError Telemetry.TelemetryReader(path;tag,datatype=8,shape=(352,352),maximum_bytes=UInt64(16*1024*1024))
        reader=Telemetry.TelemetryReader(path;tag,datatype=8,shape=(352,352),maximum_bytes=Profiles.descriptor(:classic).telemetry_max_bytes)
        @test reader.spec.data_bytes==495616
        @test reader.observed_bytes==126895104
        close(reader)
        # This sparse fixture proves capacity only; no scientific frame body is decoded.
    end
end

@testset "normal correction retains rail values and verifies every diagnostic" begin
    for profile in (:copper,:classic)
        spec=Profiles.descriptor(profile);rail=UInt16(2^spec.adc_bits-1)
        rawspec=Telemetry.TelemetrySpec("cbHoPixelsRaw0",Int32(7),spec.width,spec.width,2,2spec.width^2)
        gradspec=Telemetry.TelemetrySpec("cbHoGrad0",Int32(spec.gradient_datatype),spec.gradient_rows,1,
            profile===:classic ? 16 : 4,profile===:classic ? 16spec.gradient_rows : 4spec.gradient_rows)
        payload=zeros(UInt8,rawspec.data_bytes)
        payload[1:2]=reinterpret(UInt8,[rail])
        raw=Telemetry.TelemetryFrame(rawspec,UInt64(0),UInt32(1),Int64(1),Int16(2),UInt16(0),UInt16(0),payload)
        gradbytes=zeros(UInt8,gradspec.data_bytes);active=profile===:classic ? fill(true,188) : nothing
        if profile===:classic
            for index in 1:188
                gradbytes[16(index-1)+1:16(index-1)+4]=reinterpret(UInt8,[Int32(1)])
                gradbytes[16(index-1)+13:16(index-1)+16]=reinterpret(UInt8,[1001f0])
            end
        else
            gradbytes[1:4]=reinterpret(UInt8,[1f0])
        end
        grad=Telemetry.TelemetryFrame(gradspec,UInt64(0),UInt32(1),Int64(1),Int16(2),UInt16(0),UInt16(0),gradbytes)
        thresholds=profile===:classic ? fill(1000f0,188) : nothing
        actual=Profiles.detector_statistics([raw],[grad],profile,active;thresholds)
        @test actual.maximum_adc==rail
        @test actual.upper_rail_frames==actual.upper_rail_pixels==1
        @test Profiles.validate_detector_diagnostics([raw],[grad],profile,active,actual;thresholds)==actual
        @test_throws ArgumentError Profiles.validate_detector_diagnostics([raw],[grad],profile,active,merge(actual,(;upper_rail_pixels=0));thresholds)
        @test_throws ArgumentError Profiles.validate_detector_diagnostics([raw],[grad],profile,active,merge(actual,(;upper_rail_frames=true));thresholds)
        @test_throws ArgumentError Profiles.validate_detector_diagnostics([raw],[grad],profile,active,merge(actual,(;maximum_adc=rail-1));thresholds)
        payload[1:2]=reinterpret(UInt8,[rail+UInt16(1)])
        @test_throws ArgumentError Profiles.detector_statistics([raw],[grad],profile,active;thresholds)
    end
end

@testset "normal Classic flux classification preserves raw dropouts on every frame" begin
    spec=Telemetry.TelemetrySpec("cbHoGrad0",Int32(13),188,1,16,3008)
    active=fill(true,188);active[[86,87,102,103]].=false
    thresholds=fill(1000f0,188);payload=zeros(UInt8,3008)
    function record!(index,state,flux;x=.125f0,y=-.25f0)
        offset=16(index-1)
        payload[offset+1:offset+16]=reinterpret(UInt8,vcat(reinterpret(UInt32,[Int32(state)]),reinterpret(UInt32,Float32[x,y,flux])))
    end
    for index in 1:188;record!(index,active[index] ? 1 : -1,1001f0);end
    record!(71,0,947.1875f0);record!(88,0,989f0)
    frame=Telemetry.TelemetryFrame(spec,UInt64(0),UInt32(1),Int64(1),Int16(2),UInt16(188),UInt16(188),payload)
    before=copy(payload)
    response=Profiles.normal_response(frame,:classic,active;thresholds)
    @test !response.valid && findall(response.dropout)==[71,88]
    @test frame.payload==before
    @test Telemetry.classic_response(frame;order=collect(1:188),scale=(1.0,1.0),active).slopes[141:142]==Float32[.125,-.25]
    counter=Profiles.ResponseDiagnostics(:classic)
    Profiles.observe_response!(counter,response);Profiles.observe_response!(counter,response)
    diagnostics=Profiles.response_diagnostics(counter)
    @test diagnostics.frames==2 && diagnostics.dropout_frames==2 && diagnostics.dropout_subaperture_samples==4
    @test diagnostics.per_subaperture_dropout_frames[[71,88]]==[2,2]
    @test Profiles.validate_response_diagnostics([frame,frame],:classic,active,diagnostics;thresholds)==diagnostics
    @test_throws ArgumentError Profiles.validate_response_diagnostics([frame,frame],:classic,active,merge(diagnostics,(;dropout_frames=1));thresholds)
    @test_throws ArgumentError Profiles.validate_response_diagnostics([frame,frame],:classic,active,merge(diagnostics,(;frames=true));thresholds)
    changed=copy(diagnostics.per_subaperture_dropout_frames);changed[71]=1
    @test_throws ArgumentError Profiles.validate_response_diagnostics([frame,frame],:classic,active,merge(diagnostics,(;per_subaperture_dropout_frames=changed));thresholds)
    for (state,flux) in ((1,1000f0),(1,1001f0),(0,999f0),(0,0f0),(0,-1f0))
        record!(71,state,flux)
        @test Profiles.normal_response(frame,:classic,active;thresholds).dropout[71]==(state==0)
    end
    for (state,flux) in ((0,1000f0),(1,999f0),(-1,1001f0),(2,1001f0),(1,NaN32),(0,Inf32))
        record!(71,state,flux)
        @test_throws ArgumentError Profiles.normal_response(frame,:classic,active;thresholds)
    end
    record!(71,1,1001f0)
    for state in (0,1)
        record!(86,state,1001f0)
        @test_throws ArgumentError Profiles.normal_response(frame,:classic,active;thresholds)
    end
    record!(86,-1,1001f0)
    for values in ((NaN32,1f0),(1f0,Inf32))
        record!(71,1,1001f0;x=values[1],y=values[2])
        @test_throws ArgumentError Profiles.normal_response(frame,:classic,active;thresholds)
    end
    record!(71,1,1001f0)
    @test_throws ArgumentError Profiles.normal_response(frame,:classic,active;thresholds=fill(999f0,188))
    @test_throws ArgumentError Profiles.normal_response(frame,:classic,fill(true,188);thresholds)
    @test_throws ArgumentError Profiles.normal_response(frame,:unsupported,active;thresholds)
end

@testset "normal Classic thresholds bind wire and native input identities" begin
    mktempdir() do root
        mkdir(joinpath(root,"heart"));mkdir(joinpath(root,"heart/calibration"))
        native=joinpath(root,"heart/calibration/threshold.fits");write(native,"synthetic sealed native resource")
        wire=joinpath(root,"heart/classic-flux-thresholds.f32le");write(wire,fill(1000f0,188))
        contract=(;normal_response_policy=Profiles.CLASSIC_RESPONSE_POLICY,flux_threshold_native_file="threshold.fits",
            flux_threshold_native_sha256=digest(native),flux_threshold_wire_sha256=digest(wire),runtime_inputs=Dict("threshold.fits"=>digest(native)))
        @test Profiles.read_response_thresholds(root,contract,:classic)==fill(1000f0,188)
        @test Profiles.read_response_thresholds(root,(;),:copper)===nothing
        for changed in (merge(contract,(;normal_response_policy="other")),merge(contract,(;flux_threshold_native_file="../threshold.fits")),
            merge(contract,(;flux_threshold_native_sha256="wrong")),merge(contract,(;flux_threshold_wire_sha256="wrong")),
            merge(contract,(;runtime_inputs=Dict("threshold.fits"=>"wrong"))))
            @test_throws ArgumentError Profiles.read_response_thresholds(root,changed,:classic)
        end
        write(wire,fill(999f0,188))
        @test_throws ArgumentError Profiles.read_response_thresholds(root,merge(contract,(;flux_threshold_wire_sha256=digest(wire))),:classic)
        write(wire,fill(1000f0,188));write(native,"tampered native input")
        @test_throws ArgumentError Profiles.read_response_thresholds(root,contract,:classic)
    end
end
