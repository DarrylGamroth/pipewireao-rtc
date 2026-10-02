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
