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
        state.sequence = 1
        @test_throws ArgumentError warm_report_writer!(options, science, recorder, state)
    end
end

@testset "HEART units and bounded reset acknowledgement" begin
    @test transport_contract((;)).command_scale == 1.0f-6
    heart = transport_contract((; transport=:heart))
    @test heart.command_scale == 1.0f0
    @test heart.frame_schema == "org.heart.std-wfs.raw-pixels/1"
    @test heart.command_schema == "org.heart.std-dm.actuator-command/1"
    @test heart.command_units == "metre OPD"
    mktempdir() do root
        options = (; transport=:heart, controller_request=joinpath(root,"request"),
            controller_reply=joinpath(root,"reply"), quit_request=joinpath(root,"quit"))
        Protocol.write_json_atomic(options.controller_reply,
            (; version=1,id=7,operation="reset",ok=true,state="paused",sequence=0))
        @test reset_controller!(options,7;timeout_seconds=0.1) === nothing
        Protocol.write_json_atomic(options.controller_reply,
            (; version=1,id=7,operation="reset",ok=false,state="paused",sequence=0))
        @test_throws ErrorException reset_controller!(options,7;timeout_seconds=0.1)
        @test_throws ErrorException reset_controller!(options,8;timeout_seconds=0.01)
        touch(options.quit_request)
        @test_throws ErrorException reset_controller!(options,9;timeout_seconds=0.1)
    end
end
