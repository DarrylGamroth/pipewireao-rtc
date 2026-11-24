using Test
using FITSIO
using PipeWireAORTC

const GraphOwner = PipeWireAORTC.GraphOwner

@testset "chopped warmup authoring is bounded and explicit" begin
    mktemp() do path, io
        close(io)
        document = Dict{String,Any}(
            "version" => 1,
            "input" => "image",
            "exposure_duration_ns" => 10_000_000,
            "trigger_high_is_fringed" => true,
        )
        PipeWireAORTC.Common.write_yaml(path, document)
        @test GraphOwner.read_chopped_warmup(path) == (;
            input = :image,
            exposure_duration_ns = 10_000_000,
            trigger_high_is_fringed = true,
        )
        for change in (
            d -> (d["version"] = true),
            d -> (d["input"] = "bad input"),
            d -> (d["exposure_duration_ns"] = 0),
            d -> (d["trigger_high_is_fringed"] = 1),
            d -> (d["period"] = 2),
        )
            invalid = deepcopy(document)
            change(invalid)
            PipeWireAORTC.Common.write_yaml(path, invalid)
            @test_throws ArgumentError GraphOwner.read_chopped_warmup(path)
        end
        argv = [
            "--bootstrap-node",
            "rtc.bootstrap.graph",
            "--bootstrap-instance",
            "7",
            "--remote",
            "/tmp/rtc-private",
            "--chopped-warmup",
            path,
        ]
        @test GraphOwner.arguments(argv)[9] == (; path, at_install = false)
        @test GraphOwner.arguments(argv)[2] == ["--remote", "/tmp/rtc-private"]
        @test_throws ArgumentError GraphOwner.arguments([argv; "--chopped-warmup"; path])
    end
end

module GraphOwnerPipeWire
parse_arguments(args) = (;
    args, capture_backend = "--captured-test" in args ? "cuda" : nothing,
    execution = "--row-block-test" in args ? "row-block" : "complete-frame",
    row_workers = 0,
)
end

@testset "native graph bootstrap arguments and cold load order" begin
    argv = [
        "--bootstrap-node",
        "rtc.bootstrap.graph",
        "--bootstrap-instance=7",
        "--remote",
        "/tmp/rtc-private",
        "--graph",
        "graph.conf",
        "--session-run-control",
        "--fits-bindings",
        "bindings.conf",
    ]
    binding, graph, fits, correction_properties, timeout_ms, recovery_nodes = GraphOwner.arguments(
        argv
    )
    @test isempty(correction_properties)
    @test isempty(recovery_nodes)
    @test timeout_ms == 5000
    @test binding == (;
        remote = "/tmp/rtc-private",
        bootstrap_node = "rtc.bootstrap.graph",
        bootstrap_instance = 7,
    )
    @test graph ==
        ["--remote", "/tmp/rtc-private", "--graph", "graph.conf", "--session-run-control"]
    @test fits == "bindings.conf"
    disabled = GraphOwner.arguments([argv; "--unpublished-output"; "mean-pupil-intensity"])
    @test disabled[2] == graph
    @test last(disabled) === (; port = Symbol("mean-pupil-intensity"), node = nothing, media = nothing, sink = nothing)
    live_args = ["--latest-output", "mean-pupil-intensity", "rtc-display", "mean-pupil-intensity"]
    enabled = GraphOwner.arguments([argv; live_args])
    @test enabled[2] == graph
    @test last(enabled) == (; port = Symbol("mean-pupil-intensity"), node = "rtc-display",
        media = "mean-pupil-intensity", sink = nothing)
    sink_args = ["--latest-output-sink", "rtc-display-sink", "playback_1"]
    linked = GraphOwner.arguments([argv; live_args; sink_args])
    @test last(linked).sink == (; node = "rtc-display-sink", port = "playback_1")
    @test linked[2] == graph
    @test_throws ArgumentError GraphOwner.arguments([argv; sink_args])
    @test_throws ArgumentError GraphOwner.arguments([argv; live_args; sink_args; sink_args])
    @test_throws ArgumentError GraphOwner.arguments([argv; live_args[1:3]])
    @test_throws ArgumentError GraphOwner.arguments([argv; live_args; "--unpublished-output"; "other"])
    @test_throws ArgumentError GraphOwner.arguments([argv; "--latest-output"; "value"; "bad/name"; "media"])
    with_loop = GraphOwner.arguments([argv; "--correction-property"; "controller:closed"])
    @test with_loop[4] == ["controller:closed"]
    @test with_loop[5] == 5000
    @test with_loop[2] == graph
    priming = ["--prime-on-output", "modal-residual"]
    @test_throws ArgumentError GraphOwner.arguments([argv; priming])
    open_loop = [argv; "--correction-property"; "controller:closed"]
    selected = GraphOwner.arguments([open_loop; priming])
    @test first(selected).prime_on_output === Symbol("modal-residual")
    @test selected[2] == graph && last(selected) === nothing
    @test_throws ArgumentError GraphOwner.arguments([open_loop; priming; priming])
    @test_throws ArgumentError GraphOwner.arguments([open_loop; "--prime-on-output=slash/port"])
    coupled = [open_loop; "--correction-property=other:closed"; "--recovery-node=temporal"]
    selected = GraphOwner.arguments([
        coupled; "--prime-on-output"; "controller:closed=modal-residual";
        "--prime-on-output=other:closed=low-order-residual,low-order-validity"
    ])
    @test first(selected).prime_on_output == (
        "controller:closed" => Symbol("modal-residual"),
        "other:closed" => (Symbol("low-order-residual"), Symbol("low-order-validity")),
    )
    @test_throws ArgumentError GraphOwner.arguments([coupled; priming; priming])
    @test_throws ArgumentError GraphOwner.arguments([
        coupled; "--prime-on-output=controller:closed=modal-residual";
        "--prime-on-output=controller:closed=other-residual"
    ])
    @test_throws ArgumentError GraphOwner.arguments([
        open_loop; "--prime-on-output=controller:closed=modal-residual,"
    ])
    recovery = GraphOwner.arguments(
        [
            argv;
            "--correction-property=controller:closed";
            "--recovery-node=temporal";
            "--recovery-node";
            "command"
        ],
    )
    @test recovery[6] == ["temporal", "command"]
    @test recovery[2] == graph
    coupled = GraphOwner.arguments(
        [
            argv;
            "--correction-property=a:closed";
            "--correction-property=b:closed";
            "--recovery-node=command"
        ],
    )
    @test coupled[4] == ["a:closed", "b:closed"]
    @test coupled[6] == ["command"]
    for extra in (
        ["--recovery-node=command"],
        ["--correction-property=controller:closed", "--recovery-node=controller"],
        ["--correction-property=controller:closed", "--recovery-node=bad/name"],
        [
            "--correction-property=controller:closed",
            "--recovery-node=x",
            "--recovery-node=x",
        ],
        ["--correction-property=a:enabled", "--recovery-node=x"],
        [
            "--correction-property=a:closed",
            "--correction-property=b:closed",
            "--recovery-node=b",
        ],
        [["--correction-property=a$i:closed" for i in 1:17]; "--recovery-node=x"],
    )
        @test_throws ArgumentError GraphOwner.arguments([argv; extra])
    end
    timed = GraphOwner.arguments(
        [
            argv;
            "--correction-property=controller:closed";
            "--correction-timeout-ms";
            "2000"
        ]
    )
    @test timed[5] == 2000
    @test timed[2] == graph
    for timeout in ("0", "-1", "60001", "1.5", "true", "999999999999999999999")
        @test_throws ArgumentError GraphOwner.arguments(
            [
                argv;
                "--correction-property=controller:closed";
                "--correction-timeout-ms";
                timeout
            ],
        )
    end
    @test_throws ArgumentError GraphOwner.arguments([argv; "--correction-timeout-ms=2000"])
    @test_throws ArgumentError GraphOwner.arguments(
        [
            argv;
            "--correction-property=controller:closed";
            "--correction-timeout-ms=2000";
            "--correction-timeout-ms=1000"
        ],
    )
    for invalid in ("closed", ":closed", "controller:", "a:b:c", "controller:\0closed")
        @test_throws ArgumentError GraphOwner.arguments(
            [argv; "--correction-property"; invalid]
        )
    end
    @test_throws ArgumentError GraphOwner.arguments(
        [
            argv;
            "--correction-property";
            "controller:closed";
            "--correction-property=controller:closed"
        ],
    )
    for extra in (
        ["--check"],
        ["--remote", "/tmp/other"],
        ["--bootstrap-instance", "8"],
        ["--fits-bindings", "other"],
    )
        @test_throws ArgumentError GraphOwner.arguments([argv; extra])
    end
    for flags in (
        ["--bootstrap-node", "bad/name"],
        ["--bootstrap-instance", "0"],
        ["--remote", "relative"],
    )
        @test_throws ArgumentError GraphOwner.arguments(flags)
    end
    events = Symbol[]
    fake_owner = function (f, options)
        push!(events, :preparing)
        try
            f(
                merge(
                    options,
                    (;
                        owner_check = () -> push!(events, :check),
                        bootstrap_runtime = :runtime,
                    ),
                ),
            )
        finally
            push!(events, :cleanup)
        end
    end
    without_fits = argv[1:(end-2)]
    qualified = [without_fits; "--qualify-at-install"; "--chopped-warmup"; "/missing-test-data"]
    @test GraphOwner.arguments(qualified)[9] == (; path = "/missing-test-data", at_install = true)
    @test_throws ArgumentError GraphOwner.arguments([qualified; "--qualify-at-install"])
    @test_throws ArgumentError GraphOwner.arguments([without_fits; "--qualify-at-install=true"])
    @test_throws ArgumentError GraphOwner._main(
        [qualified; "--row-block-test"];
        with_owner = fake_owner, load_science = () -> GraphOwnerPipeWire,
    )
    for unsupported in ("--row-block-test", "--captured-test")
        @test_throws ArgumentError GraphOwner._main(
            [without_fits; "--correction-property=controller:closed"; priming; unsupported];
            with_owner = fake_owner, load_science = () -> GraphOwnerPipeWire,
            run = (_, _, _) -> error("unsupported graph preparation began"),
        )
    end
    @test GraphOwner._main(
        qualified;
        with_owner = fake_owner,
        load_science = () -> GraphOwnerPipeWire,
        run = (options, _, _) -> begin
            @test options.qualify_at_install
            @test options.chopped_warmup === nothing
            @test "--qualify-at-install" ∉ options.args
        end,
    ) == 0
    empty!(events)
    @test GraphOwner._main(
        [without_fits; "--chopped-warmup"; "/missing-test-data"];
        with_owner = fake_owner,
        load_science = () -> (push!(events, :load_science); GraphOwnerPipeWire),
        run = (options, runtime, entries) -> begin
            @test runtime === :runtime
            @test isempty(entries)
            @test isempty(options.correction_properties)
            @test options.correction_timeout_ms == 5000
            @test options.chopped_warmup === nothing
            push!(events, :run)
        end,
    ) == 0
    @test events == [:preparing, :check, :load_science, :check, :check, :run, :cleanup]
    empty!(events)
    cancelled = function (f, options)
        push!(events, :preparing)
        try
            f(
                merge(
                    options,
                    (;
                        owner_check = () -> throw(InterruptException()),
                        bootstrap_runtime = :runtime,
                    ),
                ),
            )
        finally
            push!(events, :cleanup)
        end
    end
    @test_throws InterruptException GraphOwner._main(
        without_fits;
        with_owner = cancelled,
        load_science = () -> push!(events, :load_science),
    )
    @test events == [:preparing, :cleanup]
    @test !any(
        id -> id.name in ("FilterGraphPipeWire", "FilterGraphs", "CUDA"),
        keys(Base.loaded_modules),
    )
end

@testset "FITS graph contracts, logical ordering and cancellation" begin
    mktempdir() do directory
        path = joinpath(directory, "reference.fits")
        values = Float32[1 2 3; 4 5 6]
        FITS(path, "w") do fits
            write(fits, values)
        end
        manifest = joinpath(directory, "bindings.json")
        write(
            manifest,
            """{"parameters":[{"port":"reference","path":"reference.fits","hdu":1,"axes":[2,1]}]}""",
        )
        entries = GraphOwner.bindings(manifest)
        @test fieldnames(GraphOwner.FITSBinding) == (:port, :source)
        relaxed = joinpath(directory, "bindings.conf")
        write(
            relaxed,
            """
 # Standard relaxed SPA JSON; paths remain manifest-relative.
 parameters = [
     { port = reference path = reference.fits hdu = 1 axes = [ 2 1 ] }
 ]
 """,
        )
        @test only(GraphOwner.bindings(relaxed)).source.axes == (2, 1)
        formats = (; reference = (; element_type = Float32, shape = (3, 2)))
        updates = GraphOwner.prepare_bindings(entries, formats)
        @test only(updates).first === :reference
        @test only(updates).second == permutedims(values)
        @test only(updates).second isa Matrix{Float32}
        @test sort(readdir(directory)) ==
            ["bindings.conf", "bindings.json", "reference.fits"]
        @test_throws DimensionMismatch GraphOwner.prepare_bindings(
            entries, (; reference = (; element_type = Float32, shape = (2, 3)))
        )
        transposed = [
            GraphOwner.FITSBinding(
                :reference, PipeWireAORTC.Artifacts.FITSArtifact(path; axes = (1, 2))
            ),
        ]
        @test_throws DimensionMismatch GraphOwner.prepare_bindings(transposed, formats)
        @test only(
            GraphOwner.prepare_bindings(
                entries, (; reference = (; element_type = Float64, shape = (3, 2)))
            ),
        ).second isa Matrix{Float64}
        rm(path)
        # All graph format checks precede opening even the first FITS source.
        @test_throws r"Graph has no external Parameter Port" GraphOwner.prepare_bindings(
            entries, (;)
        )
        @test_throws r"unsupported FITS parameter type" GraphOwner.prepare_bindings(
            entries, (; reference = (; element_type = UInt64, shape = (3, 2)))
        )
        @test_throws r"artifact dimensions must be positive integers" GraphOwner.prepare_bindings(
            entries, (; reference = (; element_type = Float32, shape = (0, 2)))
        )
        @test_throws r"artifact dimensions must be positive integers" GraphOwner.prepare_bindings(
            entries, (; reference = (; element_type = Float32, shape = (true, 2)))
        )
        @test_throws r"decoded artifact exceeds 256 MiB" GraphOwner.prepare_bindings(
            entries, (; reference = (; element_type = Float32, shape = (67108865, 1)))
        )
        @test_throws DimensionMismatch GraphOwner.prepare_bindings(
            entries, (; reference = (; element_type = Float32, shape = (6,)))
        )
        no_axes = [
            GraphOwner.FITSBinding(:reference, PipeWireAORTC.Artifacts.FITSArtifact(path))
        ]
        @test_throws r"multidimensional FITS binding requires axes" GraphOwner.prepare_bindings(
            no_axes, formats
        )
        second = GraphOwner.FITSBinding(:second, only(entries).source)
        @test_throws r"artifact dimensions must be positive integers" GraphOwner.prepare_bindings(
            [entries; second],
            (;
                reference = (; element_type = Float32, shape = (3, 2)),
                second = (; element_type = Float32, shape = (-1, 2)),
            ),
        )
        third = GraphOwner.FITSBinding(:third, only(entries).source)
        @test_throws r"retained FITS parameters exceed 512 MiB" GraphOwner.prepare_bindings(
            [entries; second; third],
            (;
                reference = (; element_type = Float32, shape = (67108864, 1)),
                second = (; element_type = Float32, shape = (67108864, 1)),
                third = (; element_type = Float32, shape = (1, 1)),
            ),
        )
        @test_throws r"duplicate FITS parameter" GraphOwner.prepare_bindings(
            [entries; entries], formats
        )
        @test_throws InterruptException GraphOwner.prepare_bindings(
            entries, formats; check = () -> throw(InterruptException())
        )
        for invalid in (
            """{"parameters":[{"port":"r","path":"x","shape":[2,2]}]}""",
            """{"parameters":[{"port":"r","path":"x","type":"Float32"}]}""",
            """{"parameters":[{"port":"r","path":"x","axes":[1,1]}]}""",
            """{"parameters":[{"port":"r","path":"x","hdu":0}]}""",
            """{"parameters":[],"extra":true}""",
            """{"parameters":[{"port":"r","path":"x"},{"port":"r","path":"y"}]}""",
        )
            write(manifest, invalid)
            @test_throws ArgumentError GraphOwner.bindings(manifest)
        end
    end
end

@testset "FITS HDU selection retains distinct prepared identities" begin
    mktempdir() do directory
        path = joinpath(directory, "parameters.fits")
        FITS(path, "w") do fits
            write(fits, Float32[1, 2])
            write(fits, Float32[3, 4])
        end
        entries = [
            GraphOwner.FITSBinding(port, PipeWireAORTC.Artifacts.FITSArtifact(path; hdu))
            for (port, hdu) in ((:first, 1), (:second, 2))
        ]
        formats = (;
            first = (; element_type = Float32, shape = (2,)),
            second = (; element_type = Float32, shape = (2,)),
        )
        artifacts = GraphOwner.prepare_artifacts(entries, formats)
        first_hdu, second_hdu = last.(artifacts)
        @test first_hdu.data == Float32[1, 2]
        @test second_hdu.data == Float32[3, 4]
        @test first_hdu.provenance["original_sha256"] ==
            second_hdu.provenance["original_sha256"] ==
            PipeWireAORTC.InstrumentCalibration.digest(path)
        @test first_hdu.provenance["sha256"] != second_hdu.provenance["sha256"]
        @test first_hdu.provenance["hdu"] == 1 && second_hdu.provenance["hdu"] == 2
        @test first_hdu.provenance["axes"] == second_hdu.provenance["axes"] == [1]
        updates = GraphOwner.prepare_bindings(entries, formats)
        @test first.(updates) == first.(artifacts)
        @test last.(updates) == [first_hdu.data, second_hdu.data]
    end
end

@testset "FITS values conform to the graph parameter type" begin
    mktempdir() do directory
        path = joinpath(directory, "values.fits")
        entry = GraphOwner.FITSBinding(:values, PipeWireAORTC.Artifacts.FITSArtifact(path))
        for (values, T) in (
            (Float32[0, 0.5], UInt16),
            (UInt8[0, 2], Bool),
            (Float32[0, Inf], Float32),
            (Float32[0, NaN], Float64),
        )
            isfile(path) && rm(path)
            FITS(path, "w") do fits
                write(fits, values)
            end
            @test_throws ArgumentError GraphOwner.prepare_bindings(
                [entry], (; values = (; element_type = T, shape = (2,)))
            )
        end
    end
end

@testset "installation qualifies supported graphs even with a cached workload" begin
    startup = PipeWireAORTC.GraphStartup
    mktempdir() do package
        workload = joinpath(package, startup.DIRECTORY, "controller")
        source = joinpath(workload, "ExportedGraphWarmup", "src")
        mkpath(source)
        observation = joinpath(package, "observed-calibration")
        calibration = joinpath(package, "calibration")
        write(joinpath(source, "ExportedGraphWarmup.jl"), """
            module ExportedGraphWarmup
            function qualify(args)
                args in (["--graph", "controller.conf"],
                         ["--graph", "controller.conf", "--qualify-at-install"]) ||
                    throw(ArgumentError("unexpected qualification arguments"))
                write($(repr(observation)), read($(repr(calibration))))
            end
            end
            """)
        julia = Base.julia_cmd().exec[1]
        owner = Dict("role" => "controller", "argv" => [julia, "-e", startup.ENTRY, "--"])
        push!(owner["argv"], "--graph", "controller.conf")
        for (revision, flags) in (("first", String[]), ("replacement", ["--qualify-at-install"]))
            append!(owner["argv"], flags)
            write(calibration, revision)
            startup.precompile!(julia, package, package, [owner])
            @test read(observation, String) == revision
        end
        owner["argv"][end] = "--qualify-at-install=true"
        redirect_stderr(devnull) do
            @test_throws ProcessFailedException startup.precompile!(julia, package, package, [owner])
        end
    end
end
