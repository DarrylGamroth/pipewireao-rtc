# Shack-Hartmann interaction calibration. Numerical operations preserve the
# verified Classic coordinate ordering, scaling and central completion policy.
using AdaptiveOpticsCalibration.InteractionMatrices: ZonalPushPull, ResponseSpecification, interaction_matrix
using AdaptiveOpticsCalibration.Reconstructors: TSVDInverse, ReconstructorSpecification,
    SVDReconstructorInputs, reconstructor, singular_values, effective_rank
using LinearAlgebra: I, norm

function calibration_scale(simulation, declaration, mirror)
    scale=Float32(declaration.instrument.document["deformable_mirrors"][mirror]["command_scale_m"])
    isfinite(scale) && scale>0 && scale==Float32(simulation["command_scale"]) ||
        throw(ArgumentError("calibration wire-to-plant scale differs from the simulation command scale"))
    return scale
end

function calibration_settings!(simulation, specification, declaration)
    Instruments = PipeWireAORTC.InstrumentConfiguration
    base = Instruments.settings(declaration, simulation["plant"]["settings"])
    overrides = get(specification, "settings", Dict())
    schema = Instruments.settings_description(declaration, merge(base, overrides))["schema"]
    startup = Instruments.merge_settings(base, overrides, schema)
    configured = Instruments.settings(declaration, startup)
    simulation["plant"]["settings"] = configured
    return configured
end

# Match acquisition settings when checking source identity during replay/staging.
function calibration_settings(application, recipe, declaration)
    kind=IC.sensor_kind(declaration.instrument.document["wavefront_sensors"][recipe["sensor"]])
    kind isa Val{:shack_hartmann} || return IC.settings(declaration,get(recipe,"settings",Dict()))
    simulation=PipeWireAORTC.DeploymentConfiguration.decode(joinpath(application,"simulation.conf"),
        get(ENV,"PIPEWIREAO_PREFIX","/opt/pipewireao"))
    return calibration_settings!(simulation,recipe,declaration)
end

function Calibration._calibrate_system(::Val{:shack_hartmann}, source, specification, output;
        target=AdaptiveOpticsSim.Backends.HostComputeDevice())
    ispath(output) && throw(ArgumentError("calibration output must be fresh"))
    return mktempdir() do temporary
    K, Instruments = Calibration, IC
    C, D = PipeWireAORTC.Common, PipeWireAORTC.DeploymentConfiguration
    calibrator_sha256 = K.digest(@__FILE__)
    preparation_path = joinpath(pkgdir(PipeWireAORTC), "src", "instrument_calibration.jl")
    preparation_sha256 = K.digest(preparation_path)
    extension_path = joinpath(pkgdir(PipeWireAORTC), "ext", "PipeWireAORTCCalibrationExt.jl")
    extension_sha256 = K.digest(extension_path)
    simulation = D.decode(joinpath(source, "simulation.conf"), get(ENV, "PIPEWIREAO_PREFIX", "/opt/pipewireao"))
    declaration_path = joinpath(source, simulation["plant"]["definition"])
    declaration = Instruments.load_simulation(declaration_path)
    scale = calibration_scale(simulation, declaration, specification["mirror"])
    configured = calibration_settings!(simulation, specification, declaration)
    prescription = IC.prescription_identity(declaration,configured)
    source_graph_sha256 = K.digest(joinpath(source,specification["graph_source"]))
    parameters = K.read_parameters(source)
    mirror_name = get(specification, "mirror", nothing)
    mirror_name === nothing && (mirror_name = only(keys(declaration.instrument.document["deformable_mirrors"])))
    mirror = Instruments.mirror(declaration, configured, mirror_name)
    system = Instruments.prepare_system(declaration_path; settings=configured, calibration=true,
        target, execution=HIL.StreamGraphExecution())
    config = K.shack_hartmann_configuration(system)
    obstruction = config.telescope.central_obstruction
    original_spec = specification["source_completion"]
    original = K.source_completion(joinpath(source, original_spec["path"]);
        expected_sha256=original_spec["sha256"], shape=Tuple(original_spec["shape"]), axes=Tuple(original_spec["axes"]))
    allocation = K.central_completion(original, obstruction, mirror.description;
        pupil_registration=mirror.registration)
    completion, controlled = allocation.completion, allocation.controlled
    n, physical_count = length(controlled), size(completion, 1)
    estimator = specification["estimator"]
    measurement_count = K.estimator_dimensions(source, estimator).measurement_count
    rtc = IC.load_rtc(joinpath(source,specification["rtc_configuration"]))
    limiter = rtc.controls["deformable_mirrors"][mirror_name]["limiter"]
    limits = K.checked_command_limits(Float64,limiter["lower"],limiter["upper"],physical_count)
    poke, rtol = Float32(specification["poke_m"] / scale), Float32(specification["tsvd_rtol"])
    parameters[Symbol("vdm-to-pdm")] == Matrix{Float32}(I, physical_count, physical_count) ||
        throw(ArgumentError("nonidentity physical command projection"))
    parameters[Symbol("pdm-to-vdm")] == Matrix{Float32}(I, physical_count, physical_count) ||
        throw(ArgumentError("nonidentity physical command feedback"))
    K.allocation_parameters(parameters, completion, controlled; measurement_count)
    fill!(parameters[:background], 0)
    fill!(parameters[Symbol("reference-slopes")], 0)
    fill!(parameters[:active], true)
    working = joinpath(temporary,"application")
    cp(source, working)
    C.write_json(joinpath(working, "simulation.conf"), simulation)
    isfile(joinpath(working, ".git")) && rm(joinpath(working, ".git"))
    K.replace_dimensions!(working, parameters, n; measurement_count, command_limits=limits, mirror=mirror_name)
    graph = K.controller_graph(working)
    physical = zeros(Float32, physical_count)
    flat, flat_flux = nothing, nothing
    try
        storage = K.controller_storage(graph; raw_input=estimator["raw_input"], feedback_input=estimator["feedback_input"])
        size(storage.raw) == Tuple(estimator["detector_shape"]) || throw(DimensionMismatch("detector shape differs from estimator declaration"))
        flat = copy(K.calibration_frame!(system, physical))
        flat_output = K.measure!(storage, graph, flat)
        parameters[Symbol("reference-slopes")] = copy(getproperty(flat_output, Symbol(estimator["slopes_output"])))
        parameters[:active] = copy(getproperty(flat_output, Symbol(estimator["validity_output"])))
        flat_flux = copy(getproperty(flat_output, Symbol(estimator["flux_output"])))
    finally
        FilterGraphIsland.close_execution(graph)
    end
    K.replace_dimensions!(working, parameters, n; measurement_count, command_limits=limits, mirror=mirror_name)
    graph = K.controller_graph(working)
    try
        storage = K.controller_storage(graph; raw_input=estimator["raw_input"], feedback_input=estimator["feedback_input"])
        responses = zeros(Float32, 2n, measurement_count)
        for coordinate in 1:n
            for (side, sign) in enumerate((1f0, -1f0))
                physical .= view(completion, :, coordinate) .* (sign * poke * scale)
                frame = K.calibration_frame!(system, physical)
                slopes = getproperty(K.measure!(storage, graph, frame), Symbol(estimator["slopes_output"]))
                copyto!(view(responses, 2coordinate - 2 + side, :), vec(permutedims(slopes)))
            end
            coordinate % 32 == 0 && (println("calibrated ", coordinate, "/", n); flush(stdout))
        end
        interaction = AdaptiveOpticsCalibration.process(
            AdaptiveOpticsCalibration.prepare(ZonalPushPull(fill(poke, n)), ResponseSpecification(measurement_count)), responses)
        interaction_values = interaction_matrix(interaction)
        inverse = AdaptiveOpticsCalibration.process(
            AdaptiveOpticsCalibration.prepare(TSVDInverse(; rtol), ReconstructorSpecification(measurement_count, n, Float32)),
            SVDReconstructorInputs(interaction_values))
        parameters[:reconstructor] = reconstructor(inverse)
        K.replace_dimensions!(working, parameters, n; measurement_count, command_limits=limits, mirror=mirror_name)
        diagnostics = Dict("interaction-matrix"=>interaction_values,
            "controller-to-physical"=>completion,"push-pull-responses"=>responses,
            "singular-values"=>singular_values(inverse),"flat-frame"=>flat,"flat-flux"=>flat_flux)
        report = Dict("recipe"=>specification,"source_prescription_identity"=>prescription,
            "source_graph_sha256"=>source_graph_sha256,
            "scope"=>"Finite simulation-local calibration; no physical device qualification",
            "backend"=>string(typeof(target)),"mode_count"=>n,"measurement_count"=>measurement_count,
            "dimensions"=>Dict("controller_command_count"=>n,"active_vdm_count"=>n),
            "retained_rank"=>effective_rank(inverse),"poke_m"=>specification["poke_m"],
            "tsvd_rtol"=>specification["tsvd_rtol"],"controlled_actuators"=>controlled,
            "source_completion_sha256"=>original_spec["sha256"],
            "generator_sha256"=>calibrator_sha256,"preparation_sha256"=>preparation_sha256,
            "extension_sha256"=>extension_sha256,
            "relative_inverse_residual"=>norm(interaction_values*parameters[:reconstructor]*interaction_values-interaction_values)/norm(interaction_values))
        IC.prescription_identity(IC.load_simulation(declaration.path),configured)==prescription ||
            throw(ArgumentError("source prescription changed during calibration"))
        K.digest(joinpath(source,specification["graph_source"]))==source_graph_sha256 ||
            throw(ArgumentError("source graph changed during calibration"))
        concrete=D.decode(joinpath(working,"rtc/graph.conf"),get(ENV,"PIPEWIREAO_PREFIX","/opt/pipewireao"))
        # The shape-offset algorithm initializes this optional startup port to zero.
        # Seal that neutral value explicitly so the bundle covers every graph parameter.
        get!(parameters,Symbol("shape-offset"),zeros(Float32,physical_count))
        return K.write_bundle(output,report,rtc.calibration,concrete,parameters;diagnostics)
    finally
        FilterGraphIsland.close_execution(graph)
    end
    end
end
