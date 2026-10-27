# Optional cold negative selector: no optical stepping or PipeWire connection.
# Run with --threads=3 and PIPEWIREAORTC_CALIBRATION_APPLICATION set to a built
# Classic application in the scientific environment.
module InitialCalibrationBindingsTests

using Test, Sockets
using PipeWireAORTC, FilterGraphIsland, JuliaFilterGraph
using AdaptiveOpticsSim, AdaptiveOpticsSimPipeWireHIL, AdaptiveOpticsCalibration

const Calibration = PipeWireAORTC.InstrumentCalibration
const Native = PipeWireAORTC.NativeControlClient

@testset "same graph cannot admit stale projected FITS values" begin
    application = ENV["PIPEWIREAORTC_CALIBRATION_APPLICATION"]
    frontend = command = nothing
    try
        frontend = Calibration.calibration_graph(application;
            inputs=(raw="pixel-calibration:raw",), outputs=(:slopes, :flux, :validity))
        command = Calibration.calibration_graph(application;
            inputs=(requested="pdm-command:requested",),
            outputs=(:demanded, Symbol("constraint-feedback")))
        parameters = copy(frontend.parameters)
        background = copy(parameters[:background])
        background[begin] += one(eltype(background))
        parameters[:background] = background
        stale = merge(frontend, (; parameters))
        @test stale.source_graph_sha256 == command.source_graph_sha256 ==
            Calibration.digest(joinpath(application, "rtc", "graph.conf"))
        @test size(background) == size(frontend.parameters[:background])
        @test !isequal(background, frontend.parameters[:background])

        # The builder rejects before plant allocation or any connection. This
        # owned socket supplies only the existing private-path validation proof.
        mktempdir() do directory
            chmod(directory, 0o700)
            remote = joinpath(directory, "unused.sock")
            socket = listen(remote)
            try
                count = only(JuliaFilterGraph.input_formats(command.graph).requested.shape)
                error = try
                    Calibration.prepare_initial_calibration(application, remote, stale, command;
                        reference=zeros(Float32, count), name="test.stale-calibration",
                        instance=Int64(81), deadline=Native.monotonic()+10)
                    nothing
                catch caught
                    caught
                end
                @test error isa ArgumentError
                @test occursin("parameters differ from the selected FITS inputs", sprint(showerror, error))
            finally
                close(socket)
            end
        end
    finally
        frontend === nothing || FilterGraphIsland.close_execution(frontend.graph)
        command === nothing || FilterGraphIsland.close_execution(command.graph)
    end
    @test !any(id.name in ("CUDA", "AMDGPU") for id in keys(Base.loaded_modules))
end

end
