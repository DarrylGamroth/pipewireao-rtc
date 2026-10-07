using Test
include("qualify_graph_updates.jl")
const GQ = GraphUpdateQualification

@testset "graph update qualification arguments" begin
    args = ["package","runtime","evidence","graph","control","reconstruct:reconstructor"]
    @test GQ.qualification_mode(args) === :updates
    @test GQ.qualification_mode([args;"baseline"]) === :baseline
    @test_throws ErrorException GQ.qualification_mode([args;"invalid"])
    @test GQ.qualification_mode([args[1:5];"reconstructor"]) === :updates
    @test GQ.parameter_node("reconstructor") == "reconstruct"
    @test GQ.parameter_node("reconstruct:reconstructor") == "reconstruct"
    @test GQ.parameter_node("reconstruct:reconstructor") isa String
    @test eltype(["parameter-generation","graph",GQ.parameter_node("reconstruct:reconstructor")]) === String
end

@testset "native generation adoption remains observed" begin
    reply(requested,active) = Dict("result"=>Dict("requested"=>requested,"active"=>active))
    @test !GQ.adopted(reply(4,3),(3,3))
    @test !GQ.adopted(reply(3,3),(3,3))
    @test GQ.adopted(reply(4,4),(3,3))
    @test_throws ErrorException GQ.generations(reply(4,nothing))
    @test_throws ErrorException GQ.generations(reply(4,5))
    @test_throws ErrorException GQ.generations(reply(true,true))
end

@testset "acknowledgements require fresh continuing Running status" begin
    status = Dict("ok"=>true,"state"=>"Running","admitted"=>true,
        "source"=>Dict("generation"=>2,"sequence"=>64,"completed"=>false))
    @test GQ.continuing(status,2) === status["source"]
    @test_throws ErrorException GQ.continuing(status,3)
    for (key,value) in (("state","Ready"),("admitted",false),("ok",false))
        changed = deepcopy(status); changed[key] = value
        @test_throws ErrorException GQ.continuing(changed,2)
    end
    changed = deepcopy(status); changed["source"]["completed"] = true
    @test_throws ErrorException GQ.continuing(changed,2)
end

@testset "typed rejection does not require a runner snapshot" begin
    codec = GQ.N.Codec
    controller = codec.Envelope.ControllerIdentity(UInt32(1),UInt64(1),Int64(1))
    header = codec.Envelope.ReplyHeader(controller,Int64(4),Int64(5),UInt32(9),Int32(-22))
    rejection = codec.Rejection(header,codec.Admitted,true,codec.Runner.RunnerError("gain","wrong type"))
    reply = Dict("error"=>Dict("field"=>"gain","message"=>"wrong type"),
        "state"=>nothing,"session_id"=>nothing)
    fields = GQ.completion_fields(rejection,reply)
    @test fields["result_code"] == -22
    @test !fields["snapshot_present"]
    @test !fields["runner_result_present"]
    @test fields["error"] == reply["error"]
    completion = codec.Completion(header,codec.Admitted,true,nothing,nothing,rejection.error)
    @test GQ.completion_fields(completion,reply) == fields
end

@testset "Float32 gain readback uses exact bits" begin
    reply = Dict("result"=>Dict("properties"=>Dict("control:gain"=>Dict(
        "type"=>"float","bits"=>reinterpret(UInt32,GQ.GAIN)))))
    @test GQ.gain_readback(reply,"control",GQ.GAIN)["type"] == "float"
    @test_throws ErrorException GQ.gain_readback(reply,"control",Float32(0.1))
end

@testset "reconstructor file validation and installed binding" begin
    mktempdir() do root
        package = joinpath(root,"package"); mkdir(package)
        evidence = joinpath(root,"evidence"); mkdir(evidence)
        original = joinpath(package,"original.f32le")
        GQ.C.write_json(joinpath(package,"deployment.conf"),Dict("environment"=>Dict(
            "PIPEWIREAO_RTC_PARAMETER_RECONSTRUCTOR"=>"@PACKAGE@/original.f32le")))
        values = fill(Float32(2),GQ.ROWS*GQ.COLUMNS)
        open(original,"w") do io
            write(io,htol.(reinterpret(UInt32,values)))
        end
        record = GQ.prepare_reconstructor(package,evidence)
        @test record["original_file"] == original
        @test record["shape"] == [253,3600]
        alternate = reinterpret(Float32,ltoh.(reinterpret(UInt32,read(record["alternate_file"]))))
        @test all(==(Float32(2)*Float32(0.99)),alternate)
        values[1] = Inf32
        open(original,"w") do io
            write(io,htol.(reinterpret(UInt32,values)))
        end
        @test_throws ErrorException GQ.prepare_reconstructor(package,evidence)
        write(original,zeros(UInt8,16))
        @test_throws ErrorException GQ.prepare_reconstructor(package,evidence)
    end
end
