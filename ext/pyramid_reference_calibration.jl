# GPI pyramid references consume the normal FGA outputs unchanged. AOC owns
# means and negative pupil-major reconstruction; this file only sequences the
# existing native acquisition owner and records candidate FITS artifacts.

# Identifier authority: ReferenceFrames.PyramidReference (AOC DESIGN.md), FGA's
# reconstruction-pixels/mean-pupil-intensity Ports, existing command names and
# explicit selection matrices, and the retained pupil-RMS OPD calibration record.
# No centroid, ROI eligibility or new physical coordinate is introduced.
function pyramid_reference_figures(reference,options)
    names = options.command_input
    names isa Tuple && !isempty(names) && reference isa NamedTuple &&
        Set(keys(reference)) == Set(names) || throw(ArgumentError(
        "pyramid reference must explicitly name every simulator command input"))
    figures = map(names) do name
        values = getproperty(reference,name)
        values isa AbstractVector{Float32} &&
            length(values) == getproperty(options.command_count,name) &&
            all(isfinite,values) || throw(ArgumentError(
            "pyramid reference $name must match its finite Float32 physical command"))
        Base.require_one_based_indexing(values)
        return collect(values)
    end
    return NamedTuple{names}(figures)
end

function pyramid_reference_units(parameters,recipe,instrument,normalization)
    normalization == "piston-removed pupil RMS OPD" || throw(ArgumentError(
        "pyramid modal units require the retained pupil-RMS OPD calibration authority"))
    count = size(parameters[:reconstructor],1)
    units = fill("",count)
    mirrors = instrument["deformable_mirrors"]
    declared = String[]
    for entry in recipe["mirrors"]
        name = entry["name"]
        name in declared && throw(ArgumentError("duplicate pyramid calibration mirror"))
        push!(declared,name)
        haskey(mirrors,name) && mirrors[name]["units"] == "m OPD" || throw(ArgumentError(
            "pyramid calibration mirror must explicitly declare m OPD units"))
        selection = parameters[Symbol(name*"-selection")]
        ndims(selection) == 2 && size(selection,2) == count || throw(DimensionMismatch(
            "pyramid mirror selection must address the declared controller coordinates"))
        for row in axes(selection,1)
            coordinate = 0
            for column in axes(selection,2)
                value = selection[row,column]
                iszero(value) && continue
                value == 1 && coordinate == 0 || throw(ArgumentError(
                    "pyramid selections must be explicit one-hot controller coordinates"))
                coordinate = column
            end
            coordinate > 0 && isempty(units[coordinate]) || throw(ArgumentError(
                "pyramid selections must form a disjoint controller-coordinate partition"))
            units[coordinate] = mirrors[name]["units"]
        end
    end
    all(!isempty,units) || throw(ArgumentError(
        "pyramid selections must cover every declared reconstructor row"))
    return units
end

# Bind the normalization statement to the exact FITS images interpreted by
# the normal graph. A matching filename or opaque output schema is insufficient.
function pyramid_reference_unit_sources(bindings,recipe,calibration)
    files = get(calibration,"parameter_files",nothing)
    manifest = get(calibration,"artifact_sha256",nothing)
    files isa AbstractDict && manifest isa AbstractDict || throw(ArgumentError(
        "pyramid modal unit authority requires parameter_files and artifact_sha256"))
    ports = (:reconstructor,(Symbol(entry["name"]*"-selection") for entry in recipe["mirrors"])...)
    hashes = Dict{String,String}()
    for port in ports
        name = string(port)
        filename = get(files,name,nothing)
        filename isa AbstractString && occursin(r"^[A-Za-z0-9][A-Za-z0-9_.-]*\.fits$",filename) ||
            throw(ArgumentError("pyramid unit authority must identify a plain FITS filename for $name"))
        declared = get(manifest,filename,nothing)
        declared isa AbstractString && occursin(r"^[0-9a-f]{64}$",declared) || throw(ArgumentError(
            "pyramid unit authority must declare a SHA-256 for $name"))
        matching = filter(binding -> binding.port == port,bindings)
        length(matching) == 1 || throw(ArgumentError(
            "pyramid unit authority must bind $name exactly once"))
        source = only(matching).source
        source.hdu == 1 && source.axes == (2,1) || throw(ArgumentError(
            "pyramid unit authority requires HDU 1 and logical row/column FITS axes for $name"))
        observed = Calibration.digest(source.path)
        observed == declared || throw(ArgumentError(
            "pyramid bound $name bytes differ from the OPD normalization authority"))
        hashes[name] = observed
    end
    return hashes
end

function pyramid_reference_geometry(application,parameters,options,recipe,declaration)
    calibration = PipeWireAORTC.Common.read_yaml(joinpath(application,"calibration","result.yaml"))
    unit_parameter_hashes = pyramid_reference_unit_sources(
        GraphOwner.bindings(joinpath(application,"rtc","parameters.conf")),recipe,calibration)
    document = PipeWireAORTC.DeploymentConfiguration.decode(
        joinpath(application,"rtc","graph.conf"),get(ENV,"PIPEWIREAO_PREFIX","/opt/pipewireao"))
    graph = document["filter.graph"]
    nodes = Dict(node["name"]=>node for node in graph["nodes"])
    pixel = nodes["pixel-calibration"]
    pupil = nodes["pyramid"]
    reconstruction = nodes["reconstruction"]
    pixel["label"] == "pixel-calibration-u16-f32" &&
        pupil["label"] == "pyramid-pupil-image-f32" &&
        reconstruction["label"] == "pwfs-pupil-reconstructor-f32" || throw(ArgumentError(
        "pyramid references require the declared UInt16 calibration and pupil reconstruction path"))
    rows,columns = Tuple(pupil["config"]["image_size"])
    Tuple(pixel["config"]["image_size"]) == (rows,columns) == options.frame_shape ||
        throw(DimensionMismatch("pyramid detector geometry differs from the normal raw frame"))
    pupil_shape = Tuple(pupil["config"]["pupil_size"])
    mask = parameters[Symbol("pupil-mask")]
    origins = parameters[Symbol("pupil-origins")]
    size(parameters[:background]) == size(parameters[:flat]) == (rows,columns) &&
        eltype(mask) === Bool && size(mask) == pupil_shape && size(origins) == (4,2) ||
        throw(DimensionMismatch("pyramid parameter shapes differ from declared detector/pupil geometry"))
    selected = count(mask)
    selected > 0 && reconstruction["config"]["selected_pixel_count"] == selected ||
        throw(DimensionMismatch("pyramid selection differs from the retained reconstructor"))
    modes = reconstruction["config"]["reconstructed_count"]
    size(parameters[:reconstructor]) == (modes,4selected) &&
        size(parameters[Symbol("modal-reference")]) == (modes,) || throw(DimensionMismatch(
        "pyramid reconstructor must retain pupil-major columns and declared modal rows"))
    reconstruction["config"]["reconstructed_schema"] ==
        PipeWireAORTC.Schemas.CATALOG["controller_residual_error"]["id"] || throw(ArgumentError(
        "pyramid modal reference must use the declared controller residual coordinates"))
    external = Dict(calibration_port(port).name=>calibration_port(port) for port in graph["outputs"])
    external[Symbol("reconstruction-pixels")].endpoint == "pyramid:reconstruction-pixels" &&
        external[Symbol("mean-pupil-intensity")].endpoint == "pyramid:mean-pupil-intensity" ||
        throw(ArgumentError("pyramid diagnostic outputs must retain their normal scientific endpoints"))
    names = options.command_input
    commands = map(names) do name
        port = external[name]
        node = nodes[port.node]
        port.endpoint == port.node*":demanded" && node["label"] == "vector-conditioning-f32" &&
            node["config"]["count"] == getproperty(options.command_count,name) &&
            node["config"]["demanded_schema"] == getproperty(options.command_schema,name) ||
            throw(ArgumentError("pyramid command output must retain its declared physical conditioner"))
        return (;requested=port.node*":requested",demanded=name,
            feedback=port.node*":constraint-feedback")
    end
    # Validate shapes against the actual prepared normal graph, not vector lengths.
    authority = Calibration.controller_graph(application)
    try
        inputs = JuliaFilterGraph.input_formats(authority)
        outputs = JuliaFilterGraph.output_formats(authority)
        inputs.raw.element_type === UInt16 && inputs.raw.shape == (rows,columns) &&
            outputs[Symbol("reconstruction-pixels")].element_type === Float32 &&
            outputs[Symbol("reconstruction-pixels")].shape == (4,selected) &&
            outputs[Symbol("mean-pupil-intensity")].element_type === Float32 &&
            outputs[Symbol("mean-pupil-intensity")].shape == (1,) || throw(DimensionMismatch(
            "pyramid normal graph formats differ from the reference contract"))
    finally
        FilterGraphIsland.close_execution(authority)
    end
    normalization = get(calibration,"normalization",nothing)
    row_units = pyramid_reference_units(parameters,recipe,declaration.instrument.document,normalization)
    probe_command = Symbol(first(recipe["mirrors"])["name"])
    probe_command in names || throw(ArgumentError("first declared calibration mirror is not a command input"))
    return (;rows,columns,selected,modes,row_units,normalization,unit_parameter_hashes,probe_command,
        commands=NamedTuple{names}(commands))
end

# Sample storage is borrowed. One bounded AOC update consumes it synchronously.
function pyramid_reference_update!(state,plan,sample)
    arrays = sample.arrays
    input = ReferenceFrames.PyramidReferenceInputs(
        reshape(arrays.reconstruction_pixels,size(arrays.reconstruction_pixels)...,1),
        arrays.mean_pupil_intensity,reshape(arrays.raw,size(arrays.raw)...,1))
    AdaptiveOpticsCalibration.process!(state,plan,input)
    return nothing
end

# The EMCCD outputs electrons. The declared frame-layout node applies the ADC
# scale, bias, rounding and range; only its published UInt16 range defines a rail.
function pyramid_reference_adc(production,options)
    outputs = filter(output -> output["name"] == string(options.frame_output),production["outputs"])
    length(outputs) == 1 || throw(ArgumentError("pyramid ADC requires its declared frame output exactly once"))
    source = split(only(outputs)["source"],'.';keepempty=true)
    length(source) == 2 && source[2] == "frame" || throw(ArgumentError(
        "pyramid frame output must name a frame-layout frame endpoint"))
    layouts = filter(node -> node["name"] == source[1],production["nodes"])
    length(layouts) == 1 && only(layouts)["type"] == "detector_frame_layout_f32" ||
        throw(ArgumentError("pyramid frame output must come from the declared detector frame layout"))
    frame_layout = only(layouts)
    config = frame_layout["config"]
    get(config,"output_element_type",nothing) == "uint16" &&
        get(config,"rounding",nothing) == "nearest_even" || throw(ArgumentError(
        "pyramid raw ADC must retain UInt16 output with nearest-even rounding"))
    output_size = get(config,"output_size",nothing)
    output_size isa Union{Tuple,AbstractVector} && Tuple(output_size) == options.frame_shape &&
        get(config,"output_schema",nothing) == options.frame_schema || throw(DimensionMismatch(
        "pyramid frame layout must retain the declared raw frame shape and schema"))
    range = get(config,"range",nothing)
    range isa AbstractVector && length(range) == 2 &&
        all(value -> value isa Real && !(value isa Bool) && isfinite(value) && isinteger(value),range) &&
        0 <= range[1] < range[2] <= typemax(UInt16) || throw(ArgumentError(
        "pyramid ADC range must contain increasing nonnegative integral UInt16 bounds"))
    links = filter(link -> link["destination"] == source[1]*".detector_frame",production["links"])
    length(links) == 1 || throw(ArgumentError("pyramid ADC must have one declared detector-frame source"))
    detector_source = split(only(links)["source"],'.';keepempty=true)
    length(detector_source) == 2 && detector_source[2] == "frame" || throw(ArgumentError(
        "pyramid ADC input must name the declared detector frame"))
    detectors = filter(node -> node["name"] == detector_source[1],production["nodes"])
    length(detectors) == 1 && only(detectors)["type"] == "detector" || throw(ArgumentError(
        "pyramid ADC input must come from the declared detector"))
    detector = only(detectors)
    input_size = get(config,"input_size",nothing)
    get(config,"input_schema",nothing) == detector["config"]["frame_schema"] &&
        input_size isa Union{Tuple,AbstractVector} && Tuple(input_size) ==
            (detector["config"]["rows"],detector["config"]["columns"]) || throw(DimensionMismatch(
        "pyramid frame layout must retain the declared detector shape and electron schema"))
    return (;rail=UInt32(range[2]),detector,frame_layout)
end

function pyramid_references(application,output;remote,reference,run,timeout_s,cancelled,confirm)
    application_hashes = reference_application_hashes(application)
    function check_application()
        reference_application_hashes(application) == application_hashes ||
            error("built application changed during pyramid reference acquisition")
        return nothing
    end
    recipe = Calibration.read_recipe(application)
    counts = reference_counts(recipe)
    counts.lamp.discard >= 1 || throw(ArgumentError(
        "pyramid lamp training must discard its initial normalization exposure"))
    options = PipeWireAORTC.AOSOwner.configuration(joinpath(application,"simulation.conf"))
    options.backend === :cpu && options.frame_encoding === :uint16 || throw(ArgumentError(
        "pyramid references require the normal UInt16 CPU detector"))
    declaration = IC.load_simulation(options.plant.definition)
    declaration.document["id"] == "gpi2" || throw(ArgumentError(
        "pyramid reference procedure requires the declared GPI instrument"))
    options.command_input isa Tuple &&
        Threads.nthreads(:default) >= length(options.command_input)+2 || throw(ArgumentError(
        "named pyramid acquisition requires at least one thread per command plus frontend and control owners"))
    reference = pyramid_reference_figures(reference,options)
    parameters = Calibration.read_parameters(application)
    geometry = pyramid_reference_geometry(application,parameters,options,recipe,declaration)
    configured = IC.settings(declaration,options.plant.settings)
    adc = pyramid_reference_adc(IC.graph_document(declaration,configured),options)
    detector,frame_layout,rail = adc.detector,adc.frame_layout,adc.rail
    for condition in ("dark","internal-source")
        acquisition = pyramid_reference_adc(IC.graph_document(declaration,configured;simulation_graph=condition),options)
        acquisition.detector == detector && acquisition.frame_layout == frame_layout || throw(ArgumentError(
            "pyramid acquisition must preserve the normal detector and ADC layout in every reference stage"))
    end
    frozen_ports = (:flat,Symbol("pupil-mask"),Symbol("pupil-origins"),:reconstructor)
    frozen_parameter_hashes = Dict(string(entry.port)=>Calibration.digest(entry.source.path)
        for entry in GraphOwner.bindings(joinpath(application,"rtc","parameters.conf"))
        if entry.port in frozen_ports)
    Set(keys(frozen_parameter_hashes)) == Set(string.(frozen_ports)) || throw(ArgumentError(
        "pyramid frozen optical inputs must retain their original FITS bindings"))
    check_application()
    figure_hashes = Dict(string(name)=>bytes2hex(Calibration.sha256(
        PipeWireAORTC.Artifacts.packed_bytes(getproperty(reference,name)))) for name in keys(reference))
    configuration = (;
        application_sha256=bytes2hex(Calibration.sha256(codeunits(join(
            ["$path:$(application_hashes[path])" for path in sort!(collect(keys(application_hashes)))],"\n")))),
        prescription_identity=IC.prescription_identity(declaration,configured),
        simulation_sha256=Calibration.digest(joinpath(application,"simulation.conf")),
        reference_figure_sha256=bytes2hex(Calibration.sha256(codeunits(join(
            ["$name:$(figure_hashes[name])" for name in sort!(collect(keys(figure_hashes)))],"\n")))))
    dark_plan = AdaptiveOpticsCalibration.prepare(ReferenceFrames.DarkFrameMoments(),
        ReferenceFrames.DarkFrameSpecification(geometry.rows,geometry.columns,counts.dark.samples))
    dark_state = ReferenceFrames.DarkFrameState(dark_plan)
    lamp_plan = AdaptiveOpticsCalibration.prepare(ReferenceFrames.PyramidReference(rail),
        ReferenceFrames.PyramidReferenceSpecification(geometry.rows,geometry.columns,
            geometry.selected,counts.lamp.samples,parameters[:reconstructor];row_units=geometry.row_units))
    lamp_state = ReferenceFrames.PyramidReferenceState(lamp_plan)
    qualification_plan = counts.qualification.samples == counts.lamp.samples ? lamp_plan :
        AdaptiveOpticsCalibration.prepare(ReferenceFrames.PyramidReference(rail),
            ReferenceFrames.PyramidReferenceSpecification(geometry.rows,geometry.columns,
                geometry.selected,counts.qualification.samples,parameters[:reconstructor];row_units=geometry.row_units))
    qualification_state = ReferenceFrames.PyramidReferenceState(qualification_plan)
    frontend_outputs = (reconstruction_pixels=Symbol("reconstruction-pixels"),
        mean_pupil_intensity=Symbol("mean-pupil-intensity"))
    stage_options = (;frontend_outputs,commands=geometry.commands,
        probe_command=geometry.probe_command,measurements=:reconstruction_pixels)
    # Raw ADC moments use the correlated online consumer. The existing Collect
    # reply carries exposure metadata with no redundant full-image response mean.
    dark_options = merge(stage_options,(;frontend_outputs=(calibrated="pixel-calibration:calibrated",),
        measurements=nothing))
    cancelled() && throw(InterruptException())
    mkpath(dirname(output))
    return mktempdir(dirname(output);prefix=".pyramid-reference-candidate-") do temporary
        reports = Any[]
        artifacts = Dict{String,Any}()
        write_candidate(name,values) = reference_source!(temporary,name,values;artifacts)
        reference_artifacts = Dict{String,String}()
        for (name,figure) in pairs(reference)
            artifact_name = "reference-"*string(name)
            write_candidate(artifact_name,figure)
            reference_artifacts[string(name)] = artifact_name
        end
        push!(reports,reference_stage(application,remote.dark,Dict(),reference,UInt64(run),UInt64(1),
            "dark","dark",counts.dark,timeout_s,cancelled,confirm,configuration,check_application,
            (sample,exposure)->AdaptiveOpticsCalibration.process!(dark_state,dark_plan,sample.arrays.raw);
            dark_options...))
        dark = reference_product(dark_plan,dark_state)
        dark.status == ReferenceFrames.Valid || error("pyramid dark reduction is invalid")
        background = Float32.(dark.mean)
        sources = Dict{Symbol,PipeWireAORTC.Artifacts.FITSArtifact}(
            :background=>write_candidate("background",background))
        push!(reports,reference_stage(application,remote.lamp,sources,reference,UInt64(run),UInt64(2),
            "lamp-training","internal-source",counts.lamp,timeout_s,cancelled,confirm,configuration,check_application,
            (sample,exposure)->pyramid_reference_update!(lamp_state,lamp_plan,sample);stage_options...))
        lamp = reference_product(lamp_plan,lamp_state)
        modal_reference = Float32.(lamp.modal_reference)
        all(isfinite,modal_reference) || error("pyramid candidate modal reference is not representable by the normal Float32 Port")
        write_candidate("reference-pixels",lamp.reference_pixels)
        write_candidate("modal-reference",modal_reference)
        # The later reset-simulator window excludes all training exposures. Only
        # the candidate background is overridden; all optical inputs stay frozen.
        push!(reports,reference_stage(application,remote.qualification,sources,reference,UInt64(run),UInt64(3),
            "qualification","internal-source",counts.qualification,timeout_s,cancelled,confirm,
            configuration,check_application,
            (sample,exposure)->pyramid_reference_update!(qualification_state,qualification_plan,sample);stage_options...))
        qualification = reference_product(qualification_plan,qualification_state)
        write_candidate("qualification-reference-pixels",qualification.reference_pixels)
        write_candidate("qualification-modal-reference",qualification.modal_reference)
        valid = lamp.status == ReferenceFrames.Valid && qualification.status == ReferenceFrames.Valid
        difference = valid ? qualification.reference_pixels .- lamp.reference_pixels : nothing
        difference === nothing || write_candidate("qualification-reference-difference",difference)
        write_candidate("dark-mean",dark.mean)
        write_candidate("dark-variance",dark.variance)
        # FITS preserves numerical-failure diagnostics; YAML spells nonfinite
        # scalars explicitly without presenting them as a usable number.
        diagnostic(value) = isfinite(value) ? value : string(value)
        write_candidate("lamp-diagnostics",[lamp.adc_maximum,lamp.minimum_mean_pupil_intensity])
        write_candidate("qualification-diagnostics",[qualification.adc_maximum,qualification.minimum_mean_pupil_intensity])
        report = Dict{String,Any}("version"=>1,"product"=>"reference-candidate","sensor"=>"pyramid",
            "backend"=>"cpu","frame_encoding"=>"uint16",
            "application_graph_sha256"=>Calibration.digest(joinpath(application,"rtc","graph.conf")),
            "recipe_sha256"=>Calibration.digest(joinpath(application,"calibration","recipe.conf")),
            "configuration"=>Dict(string(key)=>value for (key,value) in pairs(configuration)),
            "application_files_sha256"=>application_hashes,
            "aoc_version"=>string(pkgversion(AdaptiveOpticsCalibration)),"run"=>UInt64(run),
            "reference_figure_artifacts"=>reference_artifacts,"reference_figure_sha256"=>figure_hashes,
            "probe_command"=>string(geometry.probe_command),
            "command_schemas"=>Dict(string(name)=>getproperty(options.command_schema,name) for name in keys(reference)),
            "detector"=>detector,"frame_layout"=>frame_layout,"adc_upper_rail"=>rail,
            "dark_status"=>string(dark.status),"lamp_status"=>string(lamp.status),
            "selected_pixel_count_per_pupil"=>geometry.selected,
            "reconstruction_pixel_axes"=>["pupil","selected-mask-pixel"],
            "reference_pixel_units"=>"dimensionless","modal_reference_units"=>"m OPD",
            "modal_unit_authority"=>Dict("normalization"=>geometry.normalization,
                "parameter_sha256"=>geometry.unit_parameter_hashes,
                "calibration_result_sha256"=>Calibration.digest(joinpath(application,"calibration","result.yaml")),
                "mirror_units"=>Dict(entry["name"]=>declaration.instrument.document["deformable_mirrors"][entry["name"]]["units"]
                    for entry in recipe["mirrors"]),
                "controller_coordinate_partition"=>[entry["name"]*"-selection" for entry in recipe["mirrors"]]),
            "normalization"=>"previous successful frame full-pupil mean, including masked pixels",
            "minimum_mean_diagnostic_frame"=>"current",
            "frozen_parameter_ports"=>string.(collect(frozen_ports)),
            "frozen_parameter_sha256"=>frozen_parameter_hashes,
            "overridden_parameter_ports"=>["background"],
            "lamp_adc_maximum"=>diagnostic(lamp.adc_maximum),
            "lamp_minimum_mean_pupil_intensity"=>diagnostic(lamp.minimum_mean_pupil_intensity),
            "qualification_status"=>string(qualification.status),
            "qualification_adc_maximum"=>diagnostic(qualification.adc_maximum),
            "qualification_minimum_mean_pupil_intensity"=>diagnostic(qualification.minimum_mean_pupil_intensity),
            "qualification_numerically_valid"=>valid,
            "qualification_reference_difference_rms_dimensionless"=>(difference === nothing ? nothing : sqrt(sum(abs2,difference)/length(difference))),
            "qualification_reference_difference_maximum_dimensionless"=>(difference === nothing ? nothing : maximum(abs,difference)),
            "interaction_matrix_accepted"=>false,"activation"=>"candidate-only",
            "stages"=>reports,"artifacts"=>artifacts)
        cancelled() && throw(InterruptException())
        PipeWireAORTC.Common.write_yaml(joinpath(temporary,"result.yaml"),report;
            header="Generated by InstrumentCalibration.calibrate_references; regenerate from the built GPI application and declared reference recipe.")
        check_application()
        mv(temporary,output)
        return report
    end
end
