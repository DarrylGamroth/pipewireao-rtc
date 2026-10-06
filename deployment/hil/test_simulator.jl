using Test
include("simulator.jl")

@testset "plant model period uses nanosecond driver precision" begin
    mktempdir() do root
        graph = joinpath(root, "plant.toml")
        period_ns = UInt64(Protocol.rounded_period(30))
        options = (; graph, rate=30, period_ns)
        write(graph, """
        [[nodes]]
        name = "atmosphere"
        [nodes.config]
        atmosphere_step = $(period_ns / 1e9)
        """)
        @test period_ns == 33_333_333
        @test validate_graph_timing(options) === nothing
        write(graph, """
        [[nodes]]
        name = "atmosphere"
        [nodes.config]
        atmosphere_step = $(1 / 30)
        """)
        @test_throws ErrorException validate_graph_timing(options)
        write(graph, """
        [[nodes]]
        name = "atmosphere"
        [nodes.config]
        atmosphere_step = 0.002
        """)
        @test_throws ErrorException validate_graph_timing(options)
    end
end

# Keep the production serializer and atomic rename. This more specific path
# method adds a deterministic observer at each JSON publication boundary.
# It does not replace the report writer or simulate a live transport loop.
const REPORT_PUBLICATION_OBSERVER = Ref{Union{Nothing,Function}}(nothing)
function Protocol.write_json_atomic(path::String, value; maximum=Protocol.MAX_REPLY_BYTES)
    observer = REPORT_PUBLICATION_OBSERVER[]
    observer === nothing || observer(:before, path, value)
    invoke(Protocol.write_json_atomic, Tuple{AbstractString,Any}, path, value; maximum)
    observer === nothing || observer(:after, path, value)
    return nothing
end

@testset "observer sees fresh prefix before companion publication" begin
    plant = load_plant(:classic)
    mktempdir() do root
        options = (profile=:classic, backend=:cpu, graph=Base.invokelatest(plant.graph_path, :grid_gaussian),
            rate=500, period_ns=UInt64(2_000_000), exposure_ns=UInt64(1_896_000), frames=1,
            remote="no-transport", output=joinpath(root, "observed.json"), total_exchanges=3,
            wall_rate=500, wall_period_ns=UInt64(2_000_000), sustained=true)
        science = Base.invokelatest(prepare_science, options, plant, load_target(:cpu))
        recorder = Recorder(options, science.boundary)
        run = SustainedRun.Run(options, nothing; detector_bits=installed_detector_bits(options))
        state = Protocol.OwnerState()
        summary_path = options.output * ".sustained.json"
        frame = zeros(Float32, 2, 2)
        command = zeros(Float32, 277)
        publication_events = Tuple{Symbol,String}[]
        observation_count = Ref(0)
        expected_failure = Ref{Union{Nothing,String}}(nothing)
        expected_completed = Ref(false)
        failed_publication_path = Ref{Union{Nothing,String}}(nothing)
        REPORT_PUBLICATION_OBSERVER[] = function (stage, path, value)
            push!(publication_events, (stage, path))
            stage === :before && path == failed_publication_path[] &&
                throw(ErrorException("injected prefix publication failure"))
            path == summary_path || return nothing
            # Check immediately before the actual summary rename and again
            # after it, as an observer seeing the new summary would do.
            prefix = Protocol.JSON3.read(read(options.output, String))
            @test prefix.completed_frames == recorder.count
            @test prefix.owner_sequence == state.sequence
            @test prefix.failure == expected_failure[]
            @test prefix.completed == (recorder.count == options.frames)
            @test read(prefix.frame.file) == collect(reinterpret(UInt8, recorder.frames[1:length(hil_frame_buffer(science.boundary))*recorder.count]))
            @test read(prefix.command.file) == collect(reinterpret(UInt8, vec(recorder.commands[:, 1:recorder.count])))
            @test bytes2hex(open(sha256, prefix.frame.file)) == prefix.frame.sha256
            @test bytes2hex(open(sha256, prefix.command.file)) == prefix.command.sha256
            @test value.completed == expected_completed[]
            @test value.failure == expected_failure[]
            @test value.retained_prefix_frames == recorder.count
            @test value.completed_frames == value.completed_commands == run.metrics.count
            @test value.missed_wall_periods == run.missed_wall_periods
            if stage === :after
                published = Protocol.JSON3.read(read(summary_path, String))
                @test published.completed == expected_completed[]
                @test published.failure == expected_failure[]
                @test published.retained_prefix_frames == prefix.completed_frames
                observation_count[] += 1
            end
            return nothing
        end
        try
            # Initial, incomplete report has no payload and no completion claim.
            write_report(options, science, recorder, state; sustained_run=run)
            @test publication_events == [(:before, options.output), (:after, options.output),
                (:before, summary_path), (:after, summary_path)]
            empty!(publication_events)
            # Fresh nonzero prefix bytes must replace the initial empty files
            # before an incomplete tail report becomes visible.
            recorder.count = 1
            recorder.sequences[1] = 1
            fill!(recorder.frames, UInt16(17))
            recorder.commands[1, 1] = 0.2f-6
            recorder.missed_wall_periods = 0
            for sequence in UInt64(1):UInt64(2)
                pub = Int64(sequence * options.period_ns)
                timing = (; sequence, source_published_nanoseconds=pub,
                    command_received_nanoseconds=pub + 100, end_to_end_latency_nanoseconds=UInt64(100))
                SustainedRun.observe!(run, sequence, Int64((sequence - 1) * options.period_ns),
                    options.period_ns, timing, UInt64(200), command, frame)
            end
            state.sequence = 2
            state.running = true
            run.missed_wall_periods = 4
            write_report(options, science, recorder, state; sustained_run=run)
            @test publication_events == [(:before, options.output), (:after, options.output),
                (:before, summary_path), (:after, summary_path)]
            empty!(publication_events)
            # The completed companion is published only after the new prefix
            # report identifies the completed owner and its current payload.
            sequence = UInt64(3)
            timing = (; sequence, source_published_nanoseconds=Int64(6_000_000),
                command_received_nanoseconds=Int64(6_000_100), end_to_end_latency_nanoseconds=UInt64(100))
            SustainedRun.observe!(run, sequence, Int64(4_000_000), options.period_ns,
                timing, UInt64(200), command, frame)
            state.sequence = 3
            state.running = false
            state.completed = true
            expected_completed[] = true
            recorder.frames[1] = 23
            recorder.commands[1, 1] = 0.3f-6
            run.missed_wall_periods = 6
            write_report(options, science, recorder, state; sustained_run=run)
            @test publication_events == [(:before, options.output), (:after, options.output),
                (:before, summary_path), (:after, summary_path)]
            prefix = Protocol.JSON3.read(read(options.output, String))
            summary = Protocol.JSON3.read(read(summary_path, String))
            @test prefix.missed_wall_periods == 0 && summary.missed_wall_periods == 6
            empty!(publication_events)
            # A late owner failure updates both reports, leaving the retained
            # prefix complete while explicitly rejecting total completion.
            state.completed = false
            expected_completed[] = false
            expected_failure[] = "injected failure after retained prefix"
            write_report(options, science, recorder, state; failure=expected_failure[], sustained_run=run)
            @test publication_events == [(:before, options.output), (:after, options.output),
                (:before, summary_path), (:after, summary_path)]
            @test observation_count[] == 4
            # A failure injected at the prefix publication boundary must stop
            # companion publication. Earlier payload writes remain observable.
            empty!(publication_events)
            blocked_path = joinpath(root, "blocked.json")
            failed_publication_path[] = blocked_path
            blocked_options = merge(options, (; output=blocked_path))
            @test_throws ErrorException write_report(blocked_options, science, recorder, state;
                failure=expected_failure[], sustained_run=run)
            @test publication_events == [(:before, blocked_path)]
            @test !isfile(blocked_path * ".sustained.json")
            @test isfile(joinpath(root, "blocked.frames.u16le"))
            @test isfile(joinpath(root, "blocked.commands.f32le"))
        finally
            REPORT_PUBLICATION_OBSERVER[] = nothing
        end
    end
end

@testset "private failure report warmup" begin
    plant = load_plant(:classic)
    mktempdir() do root
        options = (
            profile=:classic, backend=:cpu,
            graph=Base.invokelatest(plant.graph_path, :grid_gaussian),
            rate=500, period_ns=UInt64(2_000_000), exposure_ns=UInt64(1_896_000),
            frames=1, remote="no-pipewire-connection", output=joinpath(root, "result.json"),
        )
        science = Base.invokelatest(prepare_science, options, plant, load_target(:cpu))
        recorder = Recorder(options, science.boundary)
        state = Protocol.OwnerState()
        @test warm_report_writer!(options, science, recorder, state) === nothing
        report = Protocol.JSON3.read(read(options.output, String))
        @test report.failure === nothing
        @test report.sequence == report.completed_frames == report.completed_commands == 0
        @test report.state == "paused" && !report.completed
        @test sort(readdir(root)) == ["result.commands.f32le", "result.frames.u16le", "result.json"]
        @test filesize(joinpath(root, "result.frames.u16le")) == 0
        @test filesize(joinpath(root, "result.commands.f32le")) == 0
        @test graph_step_sequence(science.graph) == model_time_sequence(science.driver) == 0
        write_report(options, science, recorder, state; failure="focused transport failure")
        @test Protocol.JSON3.read(read(options.output, String)).failure == "focused transport failure"
        sustained_options = merge(options, (; total_exchanges=3, wall_rate=0,
            wall_period_ns=UInt64(0), sustained=true))
        run = SustainedRun.Run(sustained_options, nothing;
            detector_bits=installed_detector_bits(sustained_options))
        @test warm_report_writer!(sustained_options, science, recorder, state; sustained_run=run) === nothing
        prefix = Protocol.JSON3.read(read(options.output, String))
        summary = Protocol.JSON3.read(read(options.output * ".sustained.json", String))
        @test prefix.failure === summary.failure === nothing
        @test prefix.sequence == summary.sequence == prefix.completed_frames == summary.completed_frames == 0
        @test !prefix.completed && !summary.completed
        @test summary.requested_exchanges == 3 && summary.retained_prefix_frames == 0
        @test summary.metrics.measured_count == 0 && summary.metrics.wall_period_nanoseconds == 0
        @test sort(readdir(root)) == ["result.commands.f32le", "result.frames.u16le", "result.json", "result.json.sustained.json"]
        @test graph_step_sequence(science.graph) == model_time_sequence(science.driver) == run.metrics.count == 0
        state.sequence = 1
        @test_throws ArgumentError warm_report_writer!(options, science, recorder, state)
    end
end

mutable struct NativeResetFixture
    previous::HILHeartControl.Codec.HeartSnapshot
    deadlines::Vector{Float64}
    fail::Bool
end

function HILHeartControl.Heart.status(client::NativeResetFixture; deadline::Float64, check)
    check()
    deadline > HILHeartControl.Client.monotonic() || error("expired native status request")
    push!(client.deadlines, deadline)
    return client.previous
end

function HILHeartControl.Heart.reset!(client::NativeResetFixture, previous; deadline::Float64, check)
    check()
    push!(client.deadlines, deadline)
    client.fail && error("injected native reset failure")
    return HILHeartControl.Codec.HeartSnapshot(previous.generation + 1,
        previous.child_pid + UInt32(1), nothing, true, previous.ingress,
        true, true, "/new/report", "b"^64)
end

@testset "HEART units and native reset authority" begin
    @test transport_contract((;)).command_scale == 1.0f-6
    heart = transport_contract((; transport=:heart))
    @test heart.command_scale == 1.0f0
    @test heart.frame_schema == "org.heart.std-wfs.raw-pixels/1"
    @test heart.command_schema == "org.heart.std-dm.actuator-command/1"
    @test heart.command_units == "metre OPD"
    mktempdir() do root
        snapshot = HILHeartControl.Codec.HeartSnapshot(Int64(1), UInt32(123), nothing,
            true, HILHeartControl.Codec.Streaming, true, true, "/report", "a"^64)
        client = NativeResetFixture(snapshot, Float64[], false)
        options = (; transport=:heart, controller_control=client, quit_request=joinpath(root,"quit"))
        result = reset_controller!(options,7;timeout_seconds=0.1)
        @test result.generation == 2 && result.child_pid == 124
        @test length(client.deadlines) == 2 && client.deadlines[1] == client.deadlines[2]
        @test isempty(readdir(root))
        client.fail = true
        @test_throws ErrorException reset_controller!(options,7;timeout_seconds=0.1)
        @test_throws ErrorException reset_controller!(options,8;timeout_seconds=0)
        touch(options.quit_request)
        @test_throws ErrorException reset_controller!(options,9;timeout_seconds=0.1)
    end
end

@testset "sustained report retains an honest prefix" begin
    plant = load_plant(:classic)
    mktempdir() do root
        options = (profile=:classic,backend=:cpu,graph=Base.invokelatest(plant.graph_path,:grid_gaussian),
            rate=500,period_ns=UInt64(2_000_000),exposure_ns=UInt64(1_896_000),frames=1,
            remote="no-transport",output=joinpath(root,"result.json"),total_exchanges=3,
            wall_rate=0,wall_period_ns=UInt64(0),sustained=true)
        science = Base.invokelatest(prepare_science,options,plant,load_target(:cpu))
        recorder = Recorder(options,science.boundary)
        recorder.count = 1;recorder.sequences[1] = 1
        run = SustainedRun.Run(options,nothing;detector_bits=installed_detector_bits(options))
        command = zeros(Float32,277);frame = zeros(Float32,2,2)
        for sequence in UInt64(1):UInt64(3)
            pub = Int64(sequence * 10_000_000)
            timing = (;sequence,source_published_nanoseconds=pub,command_received_nanoseconds=pub+100,
                end_to_end_latency_nanoseconds=UInt64(100))
            SustainedRun.observe!(run,sequence,Int64((sequence-1)*options.period_ns),options.period_ns,timing,UInt64(200),command,frame)
        end
        state = Protocol.OwnerState();state.sequence = 3;state.completed = true
        write_report(options,science,recorder,state;sustained_run=run)
        prefix = Protocol.JSON3.read(read(options.output,String))
        summary = Protocol.JSON3.read(read(options.output * ".sustained.json",String))
        @test prefix.version == 1 && prefix.completed
        @test prefix.requested_frames == prefix.completed_frames == prefix.sequence == 1
        @test prefix.owner_sequence == 3
        @test summary.version == 2 && summary.completed
        @test summary.completed_frames == summary.completed_commands == summary.sequence == 3
        @test summary.retained_prefix_frames == 1
        @test summary.metrics.wall_period_nanoseconds == 0
        @test summary.metrics.comparison_period_nanoseconds == 2_000_000
        @test summary.metrics.measured_count == 2
        @test filesize(prefix.frame.file) == 2 * 352 * 352
        @test filesize(prefix.command.file) == 4 * 277
        @test ncodeunits(read(options.output * ".sustained.json",String)) < 256 * 1024
        state.completed = false
        write_report(options,science,recorder,state;failure="injected late failure",sustained_run=run)
        failed = Protocol.JSON3.read(read(options.output * ".sustained.json",String))
        @test !failed.completed && failed.failure == "injected late failure"
    end
end
