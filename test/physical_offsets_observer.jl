# Cold CPU selector; no native connection or accelerator imports.
using Test, SHA, LinearAlgebra
using PipeWireAORTC, AdaptiveOpticsSimPipeWireHIL, FilterGraphAlgorithms, FilterGraphPipeWire, JuliaFilterGraph
const Offsets=PipeWireAORTC.PhysicalOffsets
const Ext=Base.get_extension(PipeWireAORTC,:PipeWireAORTCOffsetsExt)
const Calibration=PipeWireAORTC.InstrumentCalibration
const JFG=JuliaFilterGraph
const Cal=Calibration
const Common=PipeWireAORTC.Common

@testset "physical offset model clock copies source facts without arrays" begin
    observer=Ext.ClockObserver{:command,Nothing}(Ext.ModelClock(),nothing)
    domain=ntuple(i->UInt8(i),16)
    identity=SampleAcquisitionIdentity(domain,2,7)
    sample=SampleMetadata(7;timestamp_nanoseconds=120,exposure_duration_nanoseconds=10,
        acquisition_identity=identity)
    record=FilterGraphAlgorithms.AdmittedSampleMetadata(true,sample)
    observer(Val(:frame),(command=Float32[123],),(command=record,))
    snapshot=Ext.clock_sample(observer.clock)
    @test snapshot.valid
    @test snapshot.identity.domain.bytes==domain
    @test snapshot.identity.generation==2 && snapshot.identity.sequence==7
    @test snapshot.pts==120 && snapshot.duration==10
    @test snapshot.reset_generation==0
    observer(Val(:reset))
    snapshot=Ext.clock_sample(observer.clock)
    @test !snapshot.valid && snapshot.reset_generation==1
    observer(Val(:frame),(command=Float32[456],),(command=record,))
    @test Ext.clock_sample(observer.clock).valid
    observer(Val(:invalidated))
    @test !Ext.clock_sample(observer.clock).valid
    @test Ext.clock_sample(observer.clock).reset_generation==1
    observer(Val(:frame),(command=Float32[1],),(command=FilterGraphAlgorithms.AdmittedSampleMetadata(false,sample),))
    @test !Ext.clock_sample(observer.clock).valid
    corrupt=SampleMetadata(8;timestamp_nanoseconds=130,exposure_duration_nanoseconds=10,
        acquisition_identity=SampleAcquisitionIdentity(domain,2,8),corrupted=true)
    observer(Val(:frame),(command=Float32[1],),(command=FilterGraphAlgorithms.AdmittedSampleMetadata(true,corrupt),))
    @test !Ext.clock_sample(observer.clock).valid
end

@testset "physical offset artifact identity and explicit logical axes" begin
    mktempdir() do directory
        data=Float32[1 2;3 4;5 6]
        path=joinpath(directory,"p.fits")
        Calibration.write_fits(path,data)
        selection=Dict("path"=>"p.fits","sha256"=>bytes2hex(sha256(read(path))),
            "axes"=>[2,1],"shape"=>[3,2])
        @test Ext.matrix(joinpath(directory,"offsets.yaml"),selection)==data
        @test_throws ArgumentError Ext.matrix(joinpath(directory,"offsets.yaml"),merge(selection,Dict("sha256"=>repeat("0",64))))
        @test_throws DimensionMismatch Ext.matrix(joinpath(directory,"offsets.yaml"),merge(selection,Dict("shape"=>[2,3])))
        @test_throws ArgumentError Ext.matrix(joinpath(directory,"offsets.yaml"),merge(selection,Dict("unused"=>1)))
    end
    @test !any(id.name in ("CUDA","AMDGPU") for id in keys(Base.loaded_modules))
end


include("physical_offsets_documents.jl")
@testset "receiver binds actual graph factors, sign and offset route before publication" begin
    mktempdir() do directory
        P=Float32[1 0;0 1;1 1;1 -1]
        Q=Float32.(pinv(Float64.(P)))
        C=Float32[1 .2;.3 1]
        graph,path=physical_offset_fixture(directory;P,Q,C)
        @test Offsets.prepare(path,graph).receiver isa Offsets.Receiver
        document=Common.read_yaml(path)
        for update in (Dict("parameter"=>"q"),Dict("algorithm"=>"absent"),Dict("reference_sign"=>1))
            Common.write_yaml(path,merge(document,update))
            @test_throws ArgumentError Offsets.prepare(path,graph)
        end
        Common.write_yaml(path,merge(document,Dict("clock_output"=>"absent")))
        @test_throws ArgumentError Offsets.frame_observer(path,nothing,JFG.output_formats(graph))
        Common.write_yaml(path,document)
        JFG.replace_parameters!(graph,:q=>2Q)
        @test_throws ArgumentError Offsets.prepare(path,graph)
        JFG.replace_parameters!(graph,:q=>Q,:offset=>P*Float32[1e-9,0])
        @test_throws ArgumentError Offsets.prepare(path,graph)
    end
end
