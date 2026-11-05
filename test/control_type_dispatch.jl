using Test, PipeWireAORTC

const Runner = PipeWireAORTC.RunnerCodec
const Envelope = PipeWireAORTC.ControlCodec
const Calibration = PipeWireAORTC.InstrumentCalibration
const ActionClient = PipeWireAORTC.CalibrationActionClient
const Parameters = PipeWireAORTC.ParameterSource
const Offsets = PipeWireAORTC.PhysicalOffsets

@testset "runner scalar storage and request validation" begin
    identity = Envelope.ControllerIdentity(UInt32(7), UInt64(11), Int64(13))
    header = Envelope.RequestHeader(identity, Int64(17), Int64(1), UInt32(13), Int64(1_000_000_000))
    for (kind,value) in ((:bool,true),(:int,Int32(-1)),(:long,Int64(-2)),
            (:float,UInt32(0x80000000)),(:double,UInt64(0x8000000000000000)),
            (:id,UInt32(3)),(:string,"setting"))
        scalar = Runner.RunnerScalar(kind,value)
        @test fieldtype(typeof(scalar),:value) === typeof(value)
        request = Runner.RunnerCommand(:properties_set,"graph",Dict("node.property"=>scalar))
        _,decoded = Runner.decode_request(Runner.encode_request(header,request))
        @test decoded.args[2]["node.property"].kind === kind
        @test decoded.args[2]["node.property"].value === value
    end
    for (kind,value) in ((:bool,Int32(1)),(:int,true),(:long,Int32(1)),
            (:float,1.0f0),(:double,UInt32(1)),(:id,Int32(1)),(:string,SubString("text",1,2)))
        @test_throws ArgumentError("invalid runner scalar kind/value") Runner.RunnerScalar(kind,value)
    end
    @test_throws ArgumentError("properties must be a typed String=>RunnerScalar dictionary") Runner.encode_request(
        header,Runner.RunnerCommand(:properties_set,"graph",Dict{String,Any}("node.property"=>Runner.RunnerScalar(:bool,true))))
end

@testset "capture JSON comparison preserves numeric representations" begin
    pairs = ((true,1,false),(false,0,false),(Int32(1),UInt64(1),true),(1,1.0,false),
        (UInt64(2)^53+1,Float64(2)^53,false),(-0.0,0.0,false),(NaN,NaN,true),
        (Dict("enabled"=>true),Dict("enabled"=>1),false),
        (Dict("count"=>Int32(1)),Dict("count"=>UInt64(1)),true),
        ([1,2],UInt64[1,2],true),([1,2],[1.0,2.0],false),
        (Dict("count"=>1),[1],false))
    for (left,right,expected) in pairs
        @test Calibration._capture_same_json(left,right) === expected
        @test Calibration._capture_same_json(right,left) === expected
    end
end

@testset "boundary dispatch rejects invalid representation before conversion" begin
    for value in (true,1.0,"1",nothing)
        @test_throws ArgumentError("invalid capture integer") Calibration._capture_uint(value)
        @test_throws ArgumentError("invalid signed capture integer") Calibration._capture_int(value)
        @test_throws ArgumentError("calibration integer out of range") ActionClient._integer(value,1,5)
        @test_throws ArgumentError("physical offsets require positive bounded time limits") Offsets._calibration_time(value,Int64)
    end
    @test Calibration._capture_uint(typemax(UInt64)) === typemax(UInt64)
    @test Calibration._capture_int(typemin(Int64)) === typemin(Int64)
    @test_throws ArgumentError("invalid capture integer") Calibration._capture_uint(-1)
    @test_throws ArgumentError("invalid capture integer") Calibration._capture_uint(big(typemax(UInt64))+1)
    @test_throws ArgumentError("invalid signed capture integer") Calibration._capture_int(typemax(UInt64))
    @test_throws ArgumentError("unsupported capture setting") Calibration._capture_settings(Dict("value"=>1+im))
    @test_throws ArgumentError("capture settings require string keys") Calibration._capture_settings(Dict(1=>"value"))
    for version in (true,Int32(1),1.0,"1",nothing)
        @test_throws ArgumentError("invalid parameter source configuration") Parameters._declaration_config(
            Dict("version"=>version,"sources"=>[]))
    end
    @test Parameters._declaration_config(Dict("version"=>Int64(1),"sources"=>[])) === nothing
    for shape in ([true],[1.0],[-1],(1,))
        @test_throws ArgumentError("invalid parameter shape") Parameters._declaration_shape(shape)
    end
    @test Offsets.exposure_end(Int64(0),UInt64(1)) === Int64(1)
    @test_throws ArgumentError("invalid model exposure interval") Offsets.exposure_end(Int32(0),UInt64(1))
    @test_throws ArgumentError("invalid model exposure interval") Offsets.exposure_end(Int64(0),Int64(1))
end
