module CalibrationAcquisitionTests
using Test, PipeWireAODeployment
const A = PipeWireAODeployment.CalibrationAcquisition
const N = PipeWireAODeployment.NativeCalibrationActionClient
const C = PipeWireAODeployment.NativeCalibrationActionCodec
const G = PipeWireAODeployment.NativeControlClient
const E = PipeWireAODeployment.NativeControlCodec
const L = PipeWireAODeployment.NativeAcquisitionLifecycleCodec
const CLI = PipeWireAODeployment.CalibrationCLI
const Common = PipeWireAODeployment.Common
const ID = E.ControllerIdentity(UInt32(8), typemax(UInt64), Int64(11))
const BINDING = N.Binding("/tmp/test-core", "test.actions", 7, 42)
const TIMEOUTS = A.Timeouts(1_000_000_000, 1_000_000_000, 1_000_000_000, 1_000_000_000, 1_000_000_000)
plan(rule=C.Immediate(); run=typemax(UInt64), frames=2) = A.Plan(run, Float32[0,0],
    [Float32[1,0], Float32[0,1]], 2, frames, rule, TIMEOUTS)
mutable struct Endpoint{F}
    cursor::C.AcquisitionCursor
    commands::Vector{Any}
    transform::F
    closed::Bool
end
reply!(fake, ::C.Hold) = C.Held(fake.cursor)
reply!(fake, a::C.Adopt) = C.Adopted(fake.cursor, copy(a.figure), false)
advance(::C.Immediate, c) = c
advance(r::C.DiscardExposures, c) = C.AcquisitionCursor(c.domain,c.generation,c.sequence+r.frames,c.model_ns+UInt64(10)*r.frames)
advance(r::C.ModelTime, c) = C.AcquisitionCursor(c.domain,c.generation,c.sequence+1,c.model_ns+r.duration_ns)
function reply!(fake, a::C.Settle)
    fake.cursor = advance(a.rule, fake.cursor)
    return C.Settled(fake.cursor)
end
function reply!(fake, a::C.Collect)
    exposures = C.Exposure[]
    for _ in 1:a.frames
        c = fake.cursor
        push!(exposures, C.Exposure(c.domain,c.generation,c.sequence+1,c.model_ns,UInt64(10)))
        fake.cursor = C.AcquisitionCursor(c.domain,c.generation,c.sequence+1,c.model_ns+10)
    end
    return C.Responses(Float32[3,4],exposures,true)
end
reply!(fake, a::C.Restore) = C.Restored(copy(a.figure),false)
reply!(fake, ::C.Release) = C.Released()
function G.request!(fake::Endpoint, command;deadline,check)
    fake.closed && throw(G.UnknownOutcome("closed"))
    check()
    push!(fake.commands,command)
    answer = fake.transform(command.action, reply!(fake,command.action))
    header = E.ReplyHeader(ID,Int64(42),Int64(length(fake.commands)),C._operation(command.action),Int32(0))
    return C.Completion(header,L.Connected,command.run,command.serial,answer,"")
end
Base.close(fake::Endpoint) = (fake.closed=true; nothing)
function connection(transform=(a,r)->r; run=typemax(UInt64))
    endpoint = Endpoint(C.AcquisitionCursor(typemax(UInt64),UInt64(1)<<63,0,0),Any[],transform,false)
    return N.Connection(endpoint,BINDING,UInt64(run),UInt64(0),1_000_000_000,2,Any[],false)
end
ops(client) = C._operation.([c.action for c in client.client.commands])

@testset "interaction driver typed completions and all settling rules" begin
    for rule in (C.Immediate(),C.DiscardExposures(UInt32(2)),C.ModelTime(UInt64(30)))
        client = connection()
        result = A.acquire!(client,plan(rule))
        @test result.phase == "complete"
        @test result.restoration_confirmed && result.resume_permitted
        @test result.failure === nothing && result.recovery_failure === nothing
        @test ops(client) == [1,2,3,4,2,3,4,6,7]
        @test [c.serial for c in client.client.commands] == UInt64.(1:9)
        @test all(c->c.run==typemax(UInt64),client.client.commands)
        @test isempty(client.records) # No unbounded duplicate evidence retention.
        @test all(b->b.values==Float32[3,4] && b.valid,result.responses)
        document = A.document(result)
        @test document["run"] == typemax(UInt64)
        @test Common.parse_json(PipeWireAODeployment.CalibrationCLI.JSON3.write(document)) == document
        @test all(b->length(b["exposures"])==2,document["responses"])
        @test_throws ArgumentError A.acquire!(client,plan(rule))
    end
end

@testset "clipping and invalid causal evidence restore without retry" begin
    corruptions = (
        (a,r)->C._operation(a)==2 ? C.Adopted(r.cursor,r.figure,true) : r,
        (a,r)->C._operation(a)==2 ? C.Adopted(r.cursor,Float32[9,9],false) : r,
        (a,r)->C._operation(a)==2 ? C.Adopted(C.AcquisitionCursor(1,2,0,0),r.figure,false) : r,
        (a,r)->C._operation(a)==3 ? C.Settled(C.AcquisitionCursor(r.cursor.domain,r.cursor.generation,99,0)) : r,
        (a,r)->C._operation(a)==4 ? C.Responses(r.values,r.exposures,false) : r,
        (a,r)->C._operation(a)==4 ? C.Responses(Float32[NaN,4],r.exposures,true) : r,
        (a,r)->C._operation(a)==4 ? C.Responses(Float32[3],r.exposures,true) : r,
        (a,r)->C._operation(a)==4 ? C.Responses(r.values,r.exposures[1:1],true) : r,
        (a,r)->C._operation(a)==4 ? C.Responses(r.values,[C.Exposure(e.domain,e.generation,e.sequence+1,e.start_model_ns,e.duration_ns) for e in r.exposures],true) : r,
        (a,r)->C._operation(a)==4 ? C.Responses(r.values,[C.Exposure(1,e.generation,e.sequence,e.start_model_ns,e.duration_ns) for e in r.exposures],true) : r,
        (a,r)->C._operation(a)==4 ? C.Responses(r.values,[C.Exposure(e.domain,e.generation,e.sequence,0,e.duration_ns) for e in r.exposures],true) : r,
        (a,r)->C._operation(a)==4 ? C.Responses(r.values,[C.Exposure(e.domain,e.generation,e.sequence,e.start_model_ns,0) for e in r.exposures],true) : r,
        (a,r)->C._operation(a)==4 ? C.Responses(r.values,[C.Exposure(e.domain,e.generation,e.sequence,typemax(UInt64),1) for e in r.exposures],true) : r,
    )
    for (index,corrupt) in enumerate(corruptions)
        client = connection(corrupt)
        result = A.acquire!(client,plan(C.DiscardExposures(UInt32(1))))
        @test result.phase == "aborted"
        @test result.failure == (index==1 ? "ProbeClipped" : "InvalidEvidence")
        @test result.restoration_confirmed && result.resume_permitted
        @test result.recovery_failure === nothing
        @test ops(client)[end-1:end] == [6,7]
        @test isempty(result.responses) && A.document(result)["responses"] === nothing
    end
    for reason in (C.Cancelled,C.Endpoint,C.InvalidEvidence,C.ProbeClipped)
        client = connection((a,r)->C._operation(a)==2 ? C.Failed(reason) : r)
        result = A.acquire!(client,plan())
        @test result.phase == "aborted" && result.resume_permitted
        @test result.failure == ("Cancelled","Endpoint","InvalidEvidence","ProbeClipped")[Int(reason)]
        @test ops(client) == [1,2,6,7]
    end
end

@testset "faults retain unconfirmed ownership and stop submissions" begin
    for operation in (1,2,3,4,6,7)
        client = connection((a,r)->C._operation(a)==operation ? throw(G.UnknownOutcome("lost completion")) : r)
        result = A.acquire!(client,plan())
        @test result.phase == "fault" && !result.resume_permitted
        @test result.failure == "Endpoint" && result.recovery_failure == "Endpoint"
        @test client.client.closed
        @test ops(client)[end] == operation
        @test count(==(operation),ops(client)) == 1
        @test result.restoration_confirmed == (operation==7)
        @test isempty(result.responses)
    end
    for transform in (
        (a,r)->C._operation(a)==6 ? C.Restored(r.figure,true) : r,
        (a,r)->C._operation(a)==6 ? C.Restored(Float32[1,1],false) : r,
        (a,r)->C._operation(a)==6 ? C.Failed(C.InvalidEvidence) : r,
        (a,r)->C._operation(a)==7 ? C.Failed(C.Endpoint) : r)
        client = connection(transform)
        result = A.acquire!(client,plan())
        @test result.phase == "fault" && !result.resume_permitted
        @test count(==(6),ops(client))==1
        @test result.recovery_failure !== nothing
    end
end

@testset "boundary cancellation and elapsed completion recover finitely" begin
    client = connection()
    result = A.acquire!(client,plan();cancelled=()->length(client.client.commands)>=4)
    @test result.phase == "aborted" && result.failure == "Cancelled"
    @test result.resume_permitted && ops(client)==[1,2,3,4,6,7]
    client = connection()
    result = A.acquire!(client,plan();cancelled=()->length(client.client.commands)>=8)
    @test result.phase == "aborted" && result.failure == "Cancelled"
    @test result.resume_permitted && ops(client)==[1,2,3,4,2,3,4,6,7]
    client = connection()
    result = A.acquire!(client,plan();cancelled=()->true)
    @test result.phase == "aborted" && result.resume_permitted
    @test ops(client)==[6,7]
    clock = Ref(10.0)
    client = connection((a,r)->begin
        C._operation(a)==2 && (clock[]+=2)
        r
    end)
    result = A.acquire!(client,plan();clock=()->clock[])
    @test result.failure == "TimedOut(Adopting)" && result.phase == "aborted"
    @test result.resume_permitted && ops(client)==[1,2,6,7]
end

function plan_document()
    Dict("version"=>1,"run"=>typemax(UInt64),"reference"=>[0,0],"probes"=>[[1,0],[0,1]],
        "measurements"=>2,"frames_per_probe"=>2,"settling"=>Dict("kind"=>"immediate"),
        "timeouts_ns"=>Dict{String,Any}(k=>1_000_000_000 for k in ("ownership","adoption","settling","collection","restoration")))
end
@testset "plan bounds and snapshot before Hold" begin
    @test G.budget_ns(C.PROFILE,60.0)==60_000_000_000
    @test G.budget_ns(C.PROFILE,Float64(typemax(Int64))/1e9)==typemax(Int64)
    @test G.budget_ns(C.PROFILE,1e-10)==1
    @test_throws ArgumentError G.budget_ns(C.PROFILE,NaN)
    for mutate in (
        p->p["version"]=true,p->p["run"]=0,p->p["run"]=big(typemax(UInt64))+1,
        p->p["reference"]=Float32[],p->p["reference"]=[NaN,0],p->p["reference"]=[1e100,0],
        p->p["probes"]=[],p->p["probes"]=[[1]],p->p["probes"]=[[NaN,0]],
        p->p["measurements"]=true,p->p["measurements"]=0,p->p["frames_per_probe"]=4097,
        p->p["timeouts_ns"]["collection"]=0,p->p["timeouts_ns"]["collection"]=big(typemax(Int64))+1,
        p->p["unknown"]=1,p->p["settling"]=Dict("kind"=>"discard_exposures","frames"=>0))
        value = plan_document(); mutate(value)
        @test_throws ArgumentError A.Plan(value)
    end
    @test_throws ArgumentError A.Plan(1,zeros(4096),[zeros(4096)],2,1,C.Immediate(),TIMEOUTS)
    @test_throws ArgumentError A.Plan(1,zeros(2),fill(zeros(2),16384),30000,1,C.Immediate(),TIMEOUTS)
    value = plan_document(); p = A.Plan(value)
    value["reference"][1]=99
    @test p.reference==Float32[0,0]
    client=connection()
    p.reference[1]=NaN
    @test_throws ArgumentError A.acquire!(client,p)
    @test isempty(client.client.commands) && client.serial==0
    for client in (connection(;run=1),connection())
        client.command_count=3
        @test_throws ArgumentError A.acquire!(client,plan())
        @test isempty(client.client.commands)
    end
    mktempdir() do root
        path=joinpath(root,"large-plan")
        open(path,"w") do io
            seek(io,A.MAX_PLAN_BYTES);write(io,UInt8(' '))
        end
        @test_throws ArgumentError A.read_plan(path)
        payload=CLI.JSON3.write(plan_document())
        write(path,payload)
        @test A.read_plan(path).run==typemax(UInt64)
        for duplicate in (replace(payload,"\"run\":"=>"\"run\":1,\"run\":"),
                replace(payload,"\"ownership\":"=>"\"ownership\":1,\"ownership\":"),
                replace(payload,"\"kind\":\"immediate\""=>"\"kind\":\"immediate\",\"kind\":\"immediate\""))
            write(path,duplicate)
            @test_throws ArgumentError A.read_plan(path)
        end
    end
end

@testset "one-shot CLI and bounded exclusive evidence" begin
    mktempdir() do root
        path=joinpath(root,"plan.json"); Common.write_json(path,plan_document())
        args=["--remote",BINDING.remote,"--node",BINDING.node,"--owner-pid","7",
            "--owner-instance","42","--plan",path,"--evidence",joinpath(root,"evidence.jsonl")]
        output=joinpath(root,"stdout")
        open(output,"w") do io
            redirect_stdout(io) do
                @test CLI.run(args;acquire=(b,p;kwargs...)->A.acquire!(connection(),p;kwargs...))==0
            end
        end
        report=Common.read_json(output)
        @test report["phase"]=="complete" && report["resume_permitted"]
        evidence=Common.parse_json.(readlines(args[end]))
        @test first(evidence)["version"]==2 && length(evidence)==11
        @test last(evidence)["event"]=="acquisition"
        @test evidence[2]["serial"]==1 && evidence[2]["result"]["kind"]=="held"
        @test_throws Base.IOError CLI.run(args;acquire=(_...)->error("must not connect"))
        @test length(readlines(args[end]))==11
        @test_throws ArgumentError CLI.run(vcat(args,["--plan",path]))
        @test_throws ArgumentError CLI.run(["--endpoint","old"])
        journal=CLI.Journal(joinpath(root,"bounded"),1)
        called=Ref(false)
        CLI.record!(journal,CLI.MAX_EVIDENCE_BYTES) do
            called[]=true;Dict()
        end
        @test !called[] && isempty(journal.records) && journal.error!==nothing
        @test_throws ArgumentError CLI.finish!(journal,report)
        @test Common.parse_json(last(readlines(joinpath(root,"bounded"))))["event"]=="evidence_error"
    end
end
end # module
