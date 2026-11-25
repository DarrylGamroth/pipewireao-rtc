# Opt-in native selector. Owns one private core and ordinary clients; never opens
# installed services or the desktop core. Run with --threads=3 and a compatible
# PIPEWIREAO_PREFIX when the packaged SDK is not the selected native target.
module AnalysisCapturePrivateCoreTests
using Test, PipeWireAORTC, PipeWireAO
using FilterGraphAlgorithms, FilterGraphs, FilterGraphPipeWire
include("control_private_core.jl")
const C = PipeWireAORTC.Common
const CS = PipeWireAORTC.ConfigurationStore
include("helpers/analysis_capture_fixture.jl")

function node_properties(loop, registry, original)
    snapshot = Ref{Union{Nothing,NodeInfo}}(nothing)
    node = with_thread_loop_lock(loop) do _
        bind(
            registry,
            original,
            Node;
            on_info = (_, info) -> begin
                (info.change_mask & NODE_CHANGE_PROPERTIES) == 0 || (snapshot[] = info)
                nothing
            end,
        )
    end
    try
        wait_proof(10, "copied node properties") do
            with_thread_loop_lock(_ -> snapshot[] !== nothing, loop)
        end
        return with_thread_loop_lock(loop) do _
            info = something(snapshot[])
            info.id == original.id &&
            info.properties["object.serial"] == original.properties["object.serial"] ||
                error("test node identity changed")
            copy(info.properties)
        end
    finally
        with_thread_loop_lock(_ -> close(node), loop)
    end
end

function acquire(
    core,
    registry,
    loop,
    source,
    remote,
    directory,
    name;
    explicit_mean = false,
    reject = false,
)
    stage = joinpath(directory, name)
    mkpath(stage)
    output_links = if explicit_mean
        (Dict("output" => name * ":mean", "input" => "analysis-explicit-mean:in"),)
    else
        ()
    end
    path = analysis_capture_configuration(stage, name; output_links)
    log_path = joinpath(stage, "analysis.log")
    receipt_path = joinpath(ENV["PIPEWIREAO_RUNTIME_DIR"], name * "-capture.json")
    state = joinpath(stage, "state")
    log = open(log_path, "w+")
    child = nothing
    explicit = nothing
    try
        if explicit_mean
            explicit = with_thread_loop_lock(loop) do _
                create_object(
                    core,
                    "spa-node-factory",
                    Node;
                    properties = Dict(
                        "factory.name" => "api.pipewireao.discard",
                        "node.name" => "analysis-explicit-mean",
                        "node.virtual" => "true",
                        "node.want-driver" => "true",
                        "object.linger" => "false",
                    ),
                )
            end
        end
        child = start_analysis_capture(path, remote, state, log)
        wait_proof(
            180,
            "finite analysis readiness";
            check = () -> begin
                Base.process_exited(child) && error("analysis exited before input")
            end,
        ) do
            occursin("PIPEWIREAO_ANALYSIS_READY", read(log_path, String))
        end
        roundtrip(registry)
        consumers = nodes(registry, name * ".discard."; prefix = true)
        @test length(consumers) == (explicit_mean ? 5 : 6)
        @test node_properties(
            loop, registry, only(nodes(registry, "analysis-test-source"))
        )["node.loop.name"] == "telemetry-loop"
        @test all(
            item ->
                get(node_properties(loop, registry, item), "node.loop.name", nothing) ==
                "telemetry-loop",
            consumers,
        )
        @test length(nodes(registry, name)) == 1
        # Constant input makes the accepted-frame mean known even if ordinary
        # native scheduling drops input exposures. Deliberately invalid Header
        # metadata exercises rejection and automatic exit without registration.
        sequence = UInt64(0)
        while !isfile(receipt_path) && !Base.process_exited(child) && sequence < 80
            sequence += 1
            flags = reject ? SPA.META_HEADER_FLAG_DISCONT : UInt32(0)
            header = BufferHeader(
                flags, UInt32(0), Int64(sequence * 1_000_000), Int64(0), sequence
            )
            token = submit_array!(source, fill(7.0f0, 4), header)
            try
                wait_array_source!(source, token; timeout_ns = 2_000_000_000)
            catch
                # The consumer closes as soon as its window ends. A publication
                # racing that close need not complete, but the acquisition must.
                wait_proof(
                    () -> Base.process_exited(child),
                    10,
                    "analysis exit after source withdrawal",
                )
                break
            end
            sleep(0.02)
        end
        wait_proof(() -> Base.process_exited(child), 30, "finite analysis completion")
        wait(child)
        @test success(child)
        @test isfile(receipt_path)
        receipt = C.read_json(receipt_path)
        @test receipt["state"] == (reject ? "rejected" : "registered")
        roundtrip(registry)
        @test isempty(nodes(registry, name * ".discard."; prefix = true))
        @test isempty(nodes(registry, name))
        if explicit_mean
            @test length(nodes(registry, "analysis-explicit-mean")) == 1
            @test get(
                node_properties(
                    loop, registry, only(nodes(registry, "analysis-explicit-mean"))
                ),
                "node.loop.name",
                nothing,
            ) != "telemetry-loop"
        end
        if reject
            @test receipt["reason"] == "invalid_metadata"
            @test !haskey(receipt, "artifacts")
        else
            mean = receipt["artifacts"]["mean"]
            @test mean["manifest"]["metadata"]["sample_count"] == 8
            @test mean["manifest"]["preparation"]["BUNIT"] == "adu"
            store = CS.Store(joinpath(state, "pipewireao/configuration"))
            PipeWireAORTC.Artifacts.FITS(CS.read_artifact(store, mean["id"])) do fits
                @test read(fits[1]) == fill(7.0f0, 2, 2)
            end
        end
    catch
        flush(log)
        for line in last(split(read(log_path, String), '\n'), 30)
            println(stderr, first(line, min(length(line), 400)))
        end
        rethrow()
    finally
        child === nothing || stop_proof_child!(child, "finite analysis child")
        explicit === nothing || with_thread_loop_lock(_ -> close(explicit), loop)
        close(log)
    end
end

@testset "finite native capture owns unused outputs, exits and registers after run" begin
    prefix = get(
        ENV, "PIPEWIREAO_PREFIX", String(PipeWireAO.LibPipeWire.PipeWireAO_jll.artifact_dir)
    )
    libdir =
        isdir(joinpath(prefix, "lib/x86_64-linux-gnu")) ?
        joinpath(prefix, "lib/x86_64-linux-gnu") : joinpath(prefix, "lib")
    isdir(joinpath(libdir, "spa-ao-0.2/discard")) || error(
        "native capture selector requires the discard plugin; set PIPEWIREAO_PREFIX to a compatible SDK",
    )
    with_control_private_core(;
        prefix,
        telemetry_loop = true,
        modules = "{ name = libpipewire-module-spa-node-factory }",
        spa_libraries = "api.pipewireao.discard = discard/libspa-pipewireao-discard",
    ) do remote, directory, _
        loop = ThreadLoop("analysis.capture.test")
        context, core, registry = with_thread_loop_lock(loop) do _
            context = Context(loop)
            core = CoreConnection(context; properties = Dict("remote.name" => remote))
            context, core, Registry(core)
        end
        start!(loop)
        source = nothing
        try
            format = NdArrayFormat(
                NdArray.F32_LE,
                (2, 2);
                layout = NdArray.ROW_MAJOR,
                rate = SPA.Fraction(1000, 1),
            )
            for (name, explicit_mean, reject) in (
                ("capture-unused", false, false),
                ("capture-explicit", true, false),
                ("capture-rejected", false, true),
            )
                source = NdArraySource(
                    core,
                    "analysis-test-source",
                    zeros(Float32, 4),
                    format;
                    schema = "test/analysis-samples-f32/1",
                    properties = Dict("node.loop.name" => "telemetry-loop"),
                )
                start!(source)
                try
                    acquire(
                        core,
                        registry,
                        loop,
                        source,
                        remote,
                        directory,
                        name;
                        explicit_mean,
                        reject,
                    )
                finally
                    close(source)
                    source = nothing
                end
                roundtrip(registry)
            end
        finally
            source === nothing || close(source)
            with_thread_loop_lock(loop) do _
                close(registry)
                close(core)
                close(context)
            end
            close(loop)
        end
    end
    check_missing_discard_factory()
    @test !any(
        id -> id.name in ("CUDA", "AMDGPU", "GPUCompiler"), keys(Base.loaded_modules)
    )
end
end
