using Test
include("heart_calibration_telemetry.jl")
include("heart_correction_telemetry.jl")
const CorrectionTelemetry=HeartCorrectionTelemetry
const Telemetry=HeartCalibrationTelemetry

function field!(bytes,offset,value)
    bytes[offset+1:offset+sizeof(value)]=reinterpret(UInt8,[value])
end

@testset "Classic padded VDM is distinct from Copper active coordinates" begin
    mktempdir() do directory
        tag="cbClUnclipped0";path=joinpath(directory,"classic.tel")
        header=zeros(UInt8,1024);header[1:ncodeunits(tag)]=codeunits(tag)
        for (offset,value) in ((32,4.0),(40,Int32(16)),(48,UInt32(277)),(52,UInt32(1)),(56,UInt32(1152)),(144,UInt64(1)))
            field!(header,offset,value)
        end
        bucket=zeros(UInt8,64+1152)
        field!(bucket,0,Int64(1));field!(bucket,32,Int16(2));field!(bucket,34,UInt16(2))
        bucket[65:64+4*277]=reinterpret(UInt8,fill(0.125f0,277))
        write(path,vcat(header,bucket))
        @test_throws ArgumentError CorrectionTelemetry.vdm_reader(path;tag,maximum_bytes=UInt64(4096))
        reader=CorrectionTelemetry.vdm_reader(path;tag,maximum_bytes=UInt64(4096),coordinates=277)
        try
            frame=Telemetry.next_frame!(reader)
            @test_throws ArgumentError CorrectionTelemetry.vdm_values(frame,UInt64(1))
            @test CorrectionTelemetry.vdm_values(frame,UInt64(1);coordinates=277)==fill(0.125f0,277)
            @test Telemetry.next_frame!(reader)===nothing
        finally
            close(reader)
        end
        @test_throws ArgumentError CorrectionTelemetry.vdm_reader(path;tag,maximum_bytes=UInt64(4096),coordinates=221)
    end
end

@testset "Classic demand retains separate native extrapolation and physical stages" begin
    E=zeros(Float32,277,277);P=zeros(Float32,277,277)
    for index in 1:277;E[index,index]=2;P[index,index]=0.5;end
    projection=CorrectionTelemetry.ZonalProjection(E,P)
    vdm=fill(0.1f0,277)
    witness=CorrectionTelemetry.projection_witness(projection,vdm,copy(vdm))
    @test witness.clipping_excluded
    @test witness.demanded_um==Float64.(vdm)
    @test witness.maximum_error_bound_um>0
    @test_throws ArgumentError CorrectionTelemetry.projection_witness(projection,vdm,2vdm)
    @test_throws ArgumentError CorrectionTelemetry.projection_witness(projection,fill(1f0,277),fill(.8f0,277))
    @test_throws DimensionMismatch CorrectionTelemetry.ZonalProjection(zeros(Float32,277,221),P)
    @test_throws DimensionMismatch CorrectionTelemetry.projection_witness(projection,fill(.1f0,221),vdm)
    E[1,1]=NaN
    @test_throws ArgumentError CorrectionTelemetry.ZonalProjection(E,P)
end

@testset "bounded public VDM file representation" begin
    mktempdir() do directory
        path=joinpath(directory,"vdm.tel")
        header=zeros(UInt8,1024)
        tag="cbClUnclipped0"
        header[1:ncodeunits(tag)]=codeunits(tag)
        field!(header,32,4.0)
        field!(header,40,Int32(16))
        field!(header,48,UInt32(253))
        field!(header,52,UInt32(1))
        field!(header,56,UInt32(1024))
        field!(header,144,UInt64(1))
        bucket=zeros(UInt8,1088)
        field!(bucket,0,Int64(1))
        field!(bucket,32,Int16(2))
        field!(bucket,34,UInt16(2))
        write(path,vcat(header,bucket))
        reader=CorrectionTelemetry.vdm_reader(path;tag,maximum_bytes=UInt64(4096))
        try
            frame=Telemetry.next_frame!(reader)
            @test CorrectionTelemetry.vdm_values(frame,UInt64(1))==zeros(Float32,253)
            @test Telemetry.next_frame!(reader)===nothing
        finally
            close(reader)
        end
        @test_throws ArgumentError CorrectionTelemetry.vdm_reader(path;tag="wrong",maximum_bytes=UInt64(4096))
        @test_throws ArgumentError CorrectionTelemetry.vdm_reader(path;tag,maximum_bytes=UInt64(1024))
        field!(header,40,Int32(8));write(path,vcat(header,bucket))
        @test_throws ArgumentError CorrectionTelemetry.vdm_reader(path;tag,maximum_bytes=UInt64(4096))
        field!(header,40,Int32(16));field!(header,48,UInt32(277));write(path,vcat(header,bucket))
        @test_throws ArgumentError CorrectionTelemetry.vdm_reader(path;tag,maximum_bytes=UInt64(4096))
        link=joinpath(directory,"linked.tel");symlink(path,link)
        @test_throws ArgumentError CorrectionTelemetry.vdm_reader(link;tag,maximum_bytes=UInt64(4096))
    end
end

@testset "native correction VDM association is serialized, not a sync claim" begin
    spec=Telemetry.TelemetrySpec("cbClUnclipped0",Int32(16),253,1,4,1024)
    data=zeros(UInt8,1024)
    data[1:1012]=reinterpret(UInt8,fill(0.25f0,253))
    frame=Telemetry.TelemetryFrame(spec,UInt64(0),UInt32(0),Int64(1),Int16(2),UInt16(0),UInt16(0),data)
    @test CorrectionTelemetry.vdm_values(frame,UInt64(1))==fill(0.25f0,253)
    @test_throws ArgumentError CorrectionTelemetry.vdm_values(frame,UInt64(0))
    @test_throws ArgumentError CorrectionTelemetry.vdm_values(frame,UInt64(2))
    wrong=Telemetry.TelemetryFrame(spec,UInt64(0),UInt32(1),Int64(1),Int16(2),UInt16(0),UInt16(0),data)
    @test_throws ArgumentError CorrectionTelemetry.vdm_values(wrong,UInt64(1))
end

@testset "native demand must independently exclude hidden clipping" begin
    projection=zeros(Float32,277,253)
    for i in 1:253;projection[i,i]=1;end
    vdm=fill(0.1f0,253);received=vcat(vdm,zeros(Float32,24))
    witness=CorrectionTelemetry.projection_witness(projection,vdm,received)
    @test witness.clipping_excluded
    @test witness.demanded_max_abs_um==Float64(0.1f0)
    @test witness.maximum_error_bound_um>0
    metres=Float32.(Float64.(received).*1e-6)
    @test_throws ArgumentError CorrectionTelemetry.projection_witness(projection,vdm,metres)
    bad=copy(received);bad[1]+=0.01f0
    @test_throws ArgumentError CorrectionTelemetry.projection_witness(projection,vdm,bad)
    clipped=fill(1.0f0,253)
    @test_throws ArgumentError CorrectionTelemetry.projection_witness(projection,clipped,vcat(fill(0.8f0,253),zeros(Float32,24)))
    @test_throws DimensionMismatch CorrectionTelemetry.projection_witness(zeros(Float32,277,252),vdm,received)
    vdm[1]=NaN
    @test_throws ArgumentError CorrectionTelemetry.projection_witness(projection,vdm,received)
    vdm[1]=nextfloat(0.0f0)
    @test_throws ArgumentError CorrectionTelemetry.projection_witness(projection,vdm,received)
end
