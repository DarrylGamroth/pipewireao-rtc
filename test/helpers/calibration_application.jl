function write_calibration_controller(application, background)
    rtc = mkpath(joinpath(application, "rtc"))
    write(joinpath(application, "deployment.conf"), "{}\n")
    write(joinpath(application, "instrument.json"), "{}\n")
    rows, columns = size(background)
    graph = joinpath(rtc, "graph.conf")
    write(
        graph,
        """
        filter.graph = {
            nodes = [
                { name = pixels type = ndarray label = pixel-calibration-u16-f32
                  config = { image_size = [ $rows $columns ] initial_flat = null initial_background = null } }
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
    PipeWireAORTC.InstrumentCalibration.write_fits(joinpath(rtc, "background.fits"), background)
    return graph
end
