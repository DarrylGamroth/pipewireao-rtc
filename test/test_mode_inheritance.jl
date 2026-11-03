using Test, PipeWireAORTC
const E = PipeWireAORTC.InstrumentExport
@testset "bounded application mode inheritance" begin
    modes = Dict("controller" => Dict("application" => Dict("owners" => ["controller"], "environment" => Dict("A" => "1")),
        "session" => Dict("links" => [1, 2]), "core" => Dict("context.modules" => [3])),
        "fitted" => Dict("extends" => "controller", "application" => Dict("owners" => ["fitted"], "environment" => Dict("B" => "2"))))
    original = deepcopy(modes)
    result = E.resolve_mode(modes, "fitted")
    @test result["application"]["owners"] == ["fitted"]
    @test result["application"]["environment"] == Dict("A" => "1", "B" => "2")
    @test result["session"] == modes["controller"]["session"]
    @test !haskey(result, "extends") && modes == original
    for invalid in (Dict("a" => Dict("extends" => "missing")), Dict("a" => Dict("extends" => "a")),
            Dict("a" => Dict("extends" => "b"), "b" => Dict("extends" => "a")),
            Dict("a" => Dict("extends" => nothing)), Dict("a" => Dict("unknown" => true)),
            Dict("a" => Dict("session" => nothing)), Dict("a" => Dict("requires" => ["unknown"])))
        @test_throws ArgumentError E.resolve_mode(invalid, "a")
    end
    chain = Dict{String,Any}(string(i) => Dict("extends" => string(i + 1)) for i in 1:16)
    chain["17"] = Dict()
    @test_throws ArgumentError E.resolve_mode(chain, "1")
    @test E.merge_configuration(Dict("a" => [1]), Dict("a" => [2])) == Dict("a" => [1, 2])
    mktempdir() do directory
        mkpath(joinpath(directory, "rtc"))
        path = joinpath(directory, "rtc", "modes.yaml")
        for (default, declarations) in (("missing", Dict("a" => Dict())),
                ("a", Dict("a" => Dict(), "unused" => Dict("extends" => "unused"))),
                ("1", Dict(string(i) => Dict() for i in 1:65)))
            PipeWireAORTC.Common.write_yaml(path, Dict("default" => default, "modes" => declarations))
            @test_throws ArgumentError E.selected_mode(directory, Dict())
        end
    end
end

@testset "explicit telemetry templates preserve native queue policy" begin
    native = Dict("name" => "libpipewire-module-queue", "args" => Dict("node.name" => "existing"))
    entry = Dict{String,Any}("template" => "telemetry", "args" => Dict{String,Any}("node.name" => "residual-queue",
        "playback.props" => Dict{String,Any}("media.name" => "residual")))
    core = Dict("context.modules" => Any[deepcopy(native), deepcopy(entry)])
    E.queue_templates!(core)
    @test core["context.modules"][1] == native
    @test PipeWireAORTC.Common.metadata_json(core["context.modules"][1]) == PipeWireAORTC.Common.metadata_json(native)
    queue = core["context.modules"][2]
    @test queue["name"] == "libpipewire-module-queue"
    @test queue["args"]["capture.props"]["node.name"] == "residual-queue-input"
    @test queue["args"]["playback.props"]["node.name"] == "residual-queue-output"
    @test queue["args"]["queue.max-buffers"] === 1
    @test queue["args"]["playback.props"]["queue.max-buffers"] == "1"
    @test Set(r["type"] for r in queue["args"]["metadata"]) == Set(UInt32[768,769,773])
    @test all(r -> r["required"] === false,queue["args"]["metadata"])
    override = deepcopy(entry)
    override["args"]["queue.max-buffers"] = 4
    override["args"]["playback.props"]["node.loop.name"] = "other-loop"
    changed = Dict("context.modules" => Any[override]); E.queue_templates!(changed)
    @test only(changed["context.modules"])["args"]["playback.props"]["queue.max-buffers"] == "4"
    @test only(changed["context.modules"])["args"]["playback.props"]["node.loop.name"] == "other-loop"
    override["args"]["capture.props"] = Dict("node.name" => "explicit-input", "node.loop.name" => "input-loop")
    override["args"]["playback.props"]["node.name"] = "explicit-output"
    override["args"]["playback.props"]["queue.max-buffers"] = "9"
    changed = Dict("context.modules" => Any[override]); E.queue_templates!(changed)
    @test only(changed["context.modules"])["args"]["capture.props"]["node.name"] == "explicit-input"
    @test only(changed["context.modules"])["args"]["playback.props"]["node.name"] == "explicit-output"
    @test only(changed["context.modules"])["args"]["queue.max-buffers"] == 4
    @test only(changed["context.modules"])["args"]["playback.props"]["queue.max-buffers"] == "9"
    for mutate! in (x -> (x["template"] = "unknown"), x -> (x["unknown"] = true),
            x -> (x["args"]["unknown"] = true), x -> (x["args"]["queue.max-buffers"] = nothing),
            x -> (x["args"]["capture.props"] = nothing), x -> (x["args"]["playback.props"] = nothing),
            x -> (x["args"]["playback.props"]["unknown"] = true), x -> delete!(x["args"]["playback.props"], "media.name"))
        invalid = deepcopy(entry); mutate!(invalid)
        @test_throws ArgumentError E.queue_templates!(Dict("context.modules" => Any[invalid]))
    end
end

@testset "telemetry metadata profiles preserve explicit extensible layouts" begin
    record(type,size;required=false)=Dict("type"=>type,"size"=>size,"required"=>required)
    for entries in ([record(0x3fe,17;required=true)],[],
            [record(0x400+i,1) for i in 1:63],[record(0x3fe,4064)])
        args=Dict{String,Any}("metadata"=>entries)
        original=deepcopy(entries)
        @test E.queue_metadata!(args) === args
        @test args["metadata"] == original
    end
    for entries in ([record(0x3fe,4065)],[record(0x400+i,1) for i in 1:64],
            [record(0x3fe,8),record(0x3fe,8)],[record(0,8)],[record(13,8)],
            [record(7,8)],[record(0x3f00001,0)],
            [record(0x3fe,8;required=1)],[record(true,8)],
            [merge(record(0x3fe,8),Dict("unknown"=>1))],nothing)
        @test_throws ArgumentError E.queue_metadata!(Dict{String,Any}("metadata"=>entries))
    end
end
