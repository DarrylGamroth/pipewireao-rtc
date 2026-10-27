function Calibration._validate_system(::Val{:shack_hartmann}, application, specification, calibration, destination;
        target=AdaptiveOpticsSim.Backends.HostComputeDevice(), steps=512, seed=1, r0=0.15)
    frames=steps
    ispath(destination) && throw(ArgumentError("result must be fresh"))
    frames > 128 || throw(ArgumentError("discard interval exceeds run"))
    K, Instruments = PipeWireAORTC.InstrumentCalibration, PipeWireAORTC.InstrumentConfiguration
    C, D = PipeWireAORTC.Common, PipeWireAORTC.DeploymentConfiguration
    K.require_prepared_application(application)
    harness_sha256 = K.digest(@__FILE__)
    preparation_path = joinpath(pkgdir(PipeWireAORTC), "src", "instrument_calibration.jl")
    preparation_sha256 = K.digest(preparation_path)
    extension_path = joinpath(pkgdir(PipeWireAORTC), "ext", "PipeWireAORTCCalibrationExt.jl")
    extension_sha256 = K.digest(extension_path)
    estimator = specification["estimator"]
    K.estimator_dimensions(application, estimator)
    declaration=Instruments.load_simulation(joinpath(application,specification["simulation"]))
    bundle=K.read_bundle(calibration)
    configured=calibration_settings(application,specification,declaration)
    Instruments.prescription_identity(declaration,configured)==bundle.report["source_prescription_identity"] ||
        throw(ArgumentError("calibration belongs to another source prescription"))
    K.digest(joinpath(application,specification["graph_source"]))==bundle.report["source_graph_sha256"] ||
        throw(ArgumentError("source controller graph differs from calibration"))
    scale=Float32(declaration.instrument.document["deformable_mirrors"][specification["mirror"]]["command_scale_m"])
    options = PipeWireAORTC.AOSOwner.configuration(joinpath(application, "simulation.conf"))
    options.command_scale == scale || throw(ArgumentError("controller/plant unit mismatch"))
    simulation = D.decode(joinpath(application, "simulation.conf"), get(ENV, "PIPEWIREAO_PREFIX", "/opt/pipewireao"))
    startup = calibration_settings!(simulation,specification,declaration)
    atmosphere = merge(get(startup, "atmosphere", Dict()), Dict("rng_seed" => seed, "r0" => r0))
    startup["atmosphere"] = atmosphere
    declaration_path = joinpath(application, simulation["plant"]["definition"])
    science = Instruments.prepare_system(declaration_path; settings=startup,
        target, execution=HIL.StreamGraphExecution())
    config = K.shack_hartmann_configuration(science)
    telescope = AdaptiveOpticsSim.Optics.prepare_telescope(config.telescope, science.target)
    mask = Array(AdaptiveOpticsSim.Optics.pupil_mask(telescope))
    declaration = Instruments.load_simulation(declaration_path)
    configured = Instruments.settings(declaration, startup)
    mirror_name = get(specification, "mirror", nothing)
    mirror_name === nothing && (mirror_name = only(keys(declaration.instrument.document["deformable_mirrors"])))
    mirror = Instruments.mirror(declaration, configured, mirror_name)
    xy = Instruments.actuator_coordinates(mirror.description; pupil_registration=mirror.registration)
    physical_count = size(xy, 2)
    rtc=Instruments.load_rtc(joinpath(application,specification["rtc_configuration"]))
    limiter=rtc.controls["deformable_mirrors"][mirror_name]["limiter"]
    limits=K.checked_command_limits(Float32,limiter["lower"],limiter["upper"],physical_count)
    lower, upper = Vector{Float32}(undef, physical_count), Vector{Float32}(undef, physical_count)
    lower .= limits.lower
    upper .= limits.upper
    central = findall(i -> hypot(xy[1,i], xy[2,i]) < config.telescope.central_obstruction, axes(xy, 2))
    rms, clips, central_clips = zeros(Float64, frames), zeros(Int, frames), zeros(Int, frames)
    clipped_by_actuator = zeros(Int, physical_count)
    peaks, central_peaks = zeros(Float32, frames), zeros(Float32, frames)
    roles = zeros(UInt8, physical_count)
    graph = bundle_graph(calibration)
    try
        storage = K.controller_storage(graph; raw_input=estimator["raw_input"], feedback_input=estimator["feedback_input"])
        size(storage.raw) == Tuple(estimator["detector_shape"]) || throw(DimensionMismatch("detector shape differs from estimator declaration"))
        for index in 1:frames
            stamp = HIL.step_hil_frame_at!(science.boundary, science.driver)
            stamp.sequence == index || error("plant sequence mismatch")
            storage.raw .= round.(eltype(storage.raw), HIL.hil_frame_buffer(science.boundary))
            if index == 1
                all(values(JuliaFilterGraph.process!(storage.outputs, graph, storage.inputs))) || error("warmup rejected")
                JuliaFilterGraph.reset!(graph)
                fill!(storage.feedback, 0)
            end
            all(values(JuliaFilterGraph.process!(storage.outputs, graph, storage.inputs))) || error("controller rejected frame")
            commanded = storage.outputs.demanded
            all(i -> isfinite(commanded[i]) && lower[i] <= commanded[i] <= upper[i], eachindex(commanded)) || error("invalid physical command")
            residual = getproperty(storage.outputs, Symbol("constraint-feedback"))
            for actuator in eachindex(residual)
                clipped_by_actuator[actuator] += !iszero(residual[actuator])
            end
            clips[index] = count(!iszero, residual)
            central_clips[index] = count(!iszero, residual[central])
            peaks[index] = maximum(abs, commanded)
            central_peaks[index] = maximum(abs, commanded[central]; init=0f0)
            copyto!(roles, getproperty(storage.outputs, Symbol("correction-role")))
            copyto!(storage.feedback, getproperty(storage.outputs, Symbol("controller-constraint-feedback")))
            opd = Float64.(Array(HIL.graph_output(science.graph, :pupil_opd))[mask])
            opd .-= sum(opd)/length(opd)
            rms[index] = sqrt(sum(abs2,opd)/length(opd)) * 1e9
            HIL.hil_command_buffer(science.boundary) .= commanded .* scale
            HIL.adopt_hil_command!(science.boundary, stamp.sequence)
            index % 256 == 0 && (println(basename(application), " seed=", seed, " r0=", r0,
                " frame=", index, " RMSnm=", sum(rms[max(1,index-255):index])/length(rms[max(1,index-255):index]),
                " clipped=", sum(clips[1:index])); flush(stdout))
        end
        finally
        FilterGraphIsland.close_execution(graph)
    end
    result = Dict("scope" => "Finite seeded simulation validation; no physical device qualification",
        "application" => abspath(application), "backend" => string(typeof(target)), "frames" => frames,
        "atmosphere_seed" => seed, "r0_m" => r0, "pupil_resolution" => configured["pupil_resolution"],
        "calibration_sha256" => K.digest(joinpath(calibration,"result.yaml")),
        "harness_sha256" => harness_sha256, "preparation_sha256" => preparation_sha256,
        "extension_sha256" => extension_sha256,
        "command_limits" => [limits.lower,limits.upper], "wire_to_plant_scale" => Float64(scale),
        "mean_rms_nm_after128" => sum(rms[129:end])/length(rms[129:end]), "rms_nm" => rms,
        "max_command" => maximum(peaks), "max_central_command" => maximum(central_peaks),
        "clipped_actuator_samples" => sum(clips), "clipped_frames" => count(>(0), clips),
        "central_clipped_samples" => sum(central_clips), "clipped_samples_by_actuator" => clipped_by_actuator,
        "correction_roles" => roles, "complete" => true)
    manifest = Base.active_project()
    manifest = manifest === nothing ? nothing : joinpath(dirname(manifest), "Manifest.toml")
    manifest !== nothing && isfile(manifest) && (result["manifest_sha256"] = K.digest(manifest))
    K.digest(@__FILE__) == harness_sha256 || error("validator changed during simulation")
    K.digest(preparation_path) == preparation_sha256 || error("preparation changed during simulation")
    K.digest(extension_path) == extension_sha256 || error("calibration extension changed during simulation")
    C.write_yaml(destination,result;header="Generated finite closed-loop validation receipt; do not edit.")
    println("RESULT ", basename(application), " RMSnm=", result["mean_rms_nm_after128"],
        " clipped=", result["clipped_actuator_samples"], " central=", result["central_clipped_samples"])
    return result
end
