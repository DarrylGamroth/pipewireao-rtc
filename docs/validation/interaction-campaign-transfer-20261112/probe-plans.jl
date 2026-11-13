using PipeWireAORTC, AdaptiveOpticsSim, AdaptiveOpticsSimPipeWireHIL, SHA
using AdaptiveOpticsCalibration, FilterGraphAlgorithms, FilterGraphPipeWire, FilterGraphs
const IC = PipeWireAORTC.InstrumentConfiguration
const HIL = AdaptiveOpticsSim.AlgorithmGraphs
const FFTW = AdaptiveOpticsSim.Backends.FFTW
application, mode, label = ARGS
FFTW.set_num_threads(1)
FFTW.forget_wisdom()
if mode == "replay"
    FFTW.import_wisdom(ENV["GPI2_FFT_WISDOM"])
end
mode == "estimate" && include("fft-control.jl")
function probe(application, label)
    C = PipeWireAORTC.InstrumentCalibration
    recipe = C.read_recipe(application)
    source = joinpath(application, recipe["simulation"])
    declaration = IC.load_simulation(source)
    settings = IC.settings(declaration, get(recipe, "settings", Dict()))
    system = IC.prepare_system(source; settings, calibration=true)
    commands = map(zero, HIL.hil_command_buffer(system.boundary))
    for k in 0:12
        if k > 0
            fill!(commands.woofer, 0)
            commands.woofer[k] = Float32(recipe["poke_m"])
        end
        C.calibration_frame!(system, commands)
        for name in (:pupil_opd, :photon_rate, :frame)
            data = Array(HIL.graph_output(system.graph, name))
            open(joinpath(label, "$k-$name.bin"), "w") do io
                write(io,data)
            end
        end
    end
    FFTW.export_wisdom(joinpath(label, "wisdom"))
end
Base.invokelatest(probe, application, label)
