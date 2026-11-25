using Sockets, Test
using PipeWireAORTC, FilterGraphAlgorithms, FilterGraphPipeWire, FilterGraphs
using AdaptiveOpticsCalibration, AdaptiveOpticsSim, AdaptiveOpticsSimPipeWireHIL

const Calibration = PipeWireAORTC.InstrumentCalibration
const Control = PipeWireAORTC.ControlClient

@testset "Calibration projections retain the controller's FITS authority" begin
    mktempdir() do application
        rtc = mkpath(joinpath(application, "rtc"))
        write(joinpath(application, "deployment.conf"), "{}\n")
        write(joinpath(application, "instrument.json"), "{}\n")
        graph = joinpath(rtc, "graph.conf")
        write(
            graph,
            """
            filter.graph = {
                nodes = [
                    { name = pixels type = ndarray label = pixel-calibration-u16-f32
                      config = { image_size = [ 4 6 ] initial_flat = null initial_background = null } }
                    { name = conditioner type = ndarray label = pdm-command-f32
                      config = { actuator_count = 2 command_limits = [ -1 1 ] slew_limit = null
                                 initial_current = null quantization_origin = null
                                 quantization_step = null dither_seed = null } }
                ]
                links = []
                inputs = [ "pixels:raw" "pixels:background" "conditioner:requested" ]
                outputs = [ "pixels:calibrated" "conditioner:demanded" "conditioner:constraint-feedback" ]
            }
            """,
        )
        write(
            joinpath(rtc, "parameters.conf"),
            "parameters = [{ port = background path = background.fits hdu = 1 axes = [2 1] }]\n",
        )
        background = reshape(Float32.(1:24), 4, 6)
        Calibration.write_fits(joinpath(rtc, "background.fits"), background)
        replacement = joinpath(rtc, "captured-background.fits")
        Calibration.write_fits(replacement, 2 .* background)
        source = PipeWireAORTC.Artifacts.FITSArtifact(replacement; axes = (2, 1))
        input = (raw = "pixels:raw",)
        output = (calibrated = "pixels:calibrated",)

        @test_throws r"cannot be a probe/data cut" Calibration.calibration_graph(
            application;
            inputs = merge(input, (; background = "pixels:background")),
            outputs = output,
        )
        @test_throws r"does not reach a selected output" Calibration.calibration_graph(
            application;
            inputs = merge(input, (; extra = "conditioner:requested")),
            outputs = output,
        )
        @test_throws r"unknown external Parameter Port override" Calibration.calibration_graph(
            application;
            inputs = input,
            outputs = output,
            parameter_sources = Dict(:missing => source),
        )

        frontend = command = nothing
        try
            frontend = Calibration.calibration_graph(
                application;
                inputs = input,
                outputs = output,
                parameter_sources = Dict(:background => source),
            )
            command = Calibration.calibration_graph(
                application;
                inputs = (; requested = "conditioner:requested"),
                outputs = (:demanded, Symbol("constraint-feedback")),
            )
            format = FilterGraphs.output_formats(frontend.graph).calibrated
            @test format.element_type === Float32 && format.shape == size(background)
            @test frontend.parameters[:background] == 2 .* background
            @test frontend.parameter_sha256[:background] == Calibration.digest(replacement)
            @test frontend.source_graph_sha256 ==
                command.source_graph_sha256 == Calibration.digest(graph)
            @test Calibration.read_parameters(application)[:background] == background
            @test isempty(command.parameters)

            # A private path passes admission. The changed FITS snapshot must
            # be detected before starting a core connection or simulator.
            Calibration.write_fits(replacement, 3 .* background)
            chmod(application, 0o700)
            remote = joinpath(application, "unused.sock")
            socket = listen(remote)
            try
                @test_throws r"source changed after projection preparation" Calibration.prepare_initial_calibration(
                    application,
                    remote,
                    frontend,
                    command;
                    reference = zeros(Float32, 2),
                    name = "test.stale-calibration",
                    instance = Int64(81),
                    deadline = Control.monotonic() + 60,
                )
            finally
                close(socket)
            end
        finally
            frontend === nothing || close(frontend)
            command === nothing || close(command)
        end
    end
end
