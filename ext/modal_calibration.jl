# Finite, simulation-local modal calibration using existing AOS and FGA owners.
import LinearAlgebra
import FilterGraphAlgorithms
const IC = PipeWireAORTC.InstrumentConfiguration
const FGA = FilterGraphAlgorithms
const LA = LinearAlgebra

include("modal_completion.jl")

function modal_frame!(system, commands::NamedTuple)
    boundary = system.boundary
    sequence = HIL.hil_boundary_status(boundary).frame_sequence
    if sequence == 0
        all(c -> all(iszero,c), commands) || throw(ArgumentError("initial calibration frame must be flat"))
    else
        for name in keys(commands)
            copyto!(getproperty(HIL.hil_command_buffer(boundary),name),getproperty(commands,name))
        end
        HIL.adopt_hil_command!(boundary,sequence)
    end
    HIL.step_hil_frame!(boundary)
    return HIL.hil_frame_buffer(boundary)
end

function pupil_measurement!(pixels, mean, estimator, calibrated, raw, background, scale)
    @. calibrated = (raw-background)*scale
    # Match the controller's previous-frame normalization at a held exposure.
    for _ in 1:2
        FGA.process!(pixels,mean,estimator,calibrated) === nothing ||
            throw(ArgumentError("pyramid calibration measurement rejected"))
    end
    return vec(permutedims(pixels))
end

"Calibrate declared modal command projections against a deterministic optical plant."
function Calibration.calibrate_modal_system(source, recipe, output;
        target=AdaptiveOpticsSim.Backends.HostComputeDevice())
    ispath(output) && throw(ArgumentError("calibration output must be fresh"))
    any(entry -> entry["name"]==recipe["tiptilt"]["mirror"] && haskey(entry,"completion"),recipe["mirrors"]) &&
        throw(ArgumentError("annular completion cannot be combined with the fitted tip/tilt-coupled mirror basis"))
    declaration=IC.load_simulation(joinpath(source,recipe["simulation"]))
    settings=IC.settings(declaration,get(recipe,"settings",Dict()))
    prescription=IC.prescription_identity(declaration,settings)
    source_graph_sha256=Calibration.digest(joinpath(source,recipe["graph"]))
    system=IC.prepare_system(declaration.path;settings=IC._instrument_seal(settings),calibration=true,target)
    commands=map(zero,HIL.hil_command_buffer(system.boundary))
    flat=copy(modal_frame!(system,commands))
    sensor=declaration.instrument.document["wavefront_sensors"][recipe["sensor"]]
    layout=IC.sensor_layout(declaration,sensor)
    pupil_size=layout.pupil_shape
    obstruction=declaration.instrument.document["telescope"]["central_obstruction_ratio"]
    mask=[obstruction^2 < ((r-0.5)/pupil_size[1]*2-1)^2+((c-0.5)/pupil_size[2]*2-1)^2 <= 1
        for r in 1:pupil_size[1],c in 1:pupil_size[2]]
    origins=[collect(p) for p in layout.pupil_origins]
    estimator=FGA.prepare_algorithm(FGA.PyramidPupilImageF32,
        FGA.PyramidPupilImageF32Configuration(image_size=layout.detector_shape,
            pupil_size=pupil_size,pupil_origins=origins,pupil_mask=vec(permutedims(mask))))
    pixels=zeros(Float32,4,Base.count(mask));mean=zeros(Float32,1);calibrated=zeros(Float32,size(flat))
    background=fill(Float32(settings["adc"]["bias_adu"]),size(flat))
    science_rows=size(HIL.graph_output(system.graph,:detector_frame),1)
    background[science_rows+1:end,:] .= 0
    # Only sampled pupil regions enter normalization; padded rows have no contribution.
    detector=only(node for node in IC.graph_document(declaration,settings;calibration=true)["nodes"] if node["type"]=="emccd_detector_acquisition_f32")
    adc_scale=Float32(settings["adc"]["electrons_per_adu"])/Float32(detector["config"]["gain"])
    reference=pupil_measurement!(pixels,mean,estimator,calibrated,flat,background,adc_scale)
    mirror_specs=recipe["mirrors"]
    projections=Dict{String,Matrix{Float32}}()
    completions=Dict{String,Any}()
    for entry in mirror_specs
        name=entry["name"]
        mirror=IC.mirror(declaration,settings,name)
        if haskey(entry,"completion")
            completed=modal_completion(mirror.description,mirror.registration,entry["completion"];obstruction)
            completions[name]=completed
            projections[name]=completed.completion
            continue
        end
        count=entry["mode_count"]
        coords=IC.actuator_coordinates(mirror.description;pupil_registration=mirror.registration)
        count <= size(coords,2) || throw(DimensionMismatch("mode count exceeds physical commands"))
        selected=sortperm(vec(sum(abs2,coords;dims=1));alg=Base.Sort.MergeSort)[1:count]
        projection=zeros(Float32,size(coords,2),count)
        for (mode,actuator) in enumerate(selected)
            projection[actuator,mode]=1f0
        end
        projections[name]=projection
    end
    counts=Int[size(projections[entry["name"]],2) for entry in mirror_specs]
    n=sum(counts)
    stage=recipe["tiptilt"]
    stage_name=Symbol(stage["command_input"]);coupled=stage["mirror"]
    # Fit the existing simulator mirror response to the declared normalized-pupil ramps.
    poke=Float32(recipe["poke_m"])
    isfinite(poke) && poke>0 || throw(ArgumentError("poke_m must be positive and finite"))
    physical=getproperty(commands,Symbol(coupled))
    support=IC.binding_values(declaration,settings,Dict("kind"=>"pupil_support","resolution"=>"pupil_resolution"))
    xy=IC.binding_values(declaration,settings,Dict("kind"=>"pupil_coordinates","resolution"=>"pupil_resolution"))
    valid=findall(vec(support).!=0)
    response=zeros(Float32,length(valid),length(physical))
    for actuator in eachindex(physical)
        fill!(physical,0);physical[actuator]=poke
        modal_frame!(system,commands)
        response[:,actuator] .= vec(Array(HIL.graph_output(system.graph,Symbol(coupled*"_opd"))))[valid]./poke
    end
    fill!(physical,0)
    ramps=reshape(xy,:,2)[valid,:]
    fit=Float32.(Float64.(response) \ Float64.(ramps))
    base=projections[coupled]
    size(base,2)==size(base,1) || throw(ArgumentError("tiptilt-coupled mirror requires full modal span"))
    q=Matrix(LA.qr(hcat(fit,Matrix{Float32}(LA.I,size(base,1),size(base,1)))).Q)
    base[:,1:2] .= fit;base[:,3:end] .= q[:,3:size(base,2)]
    # Declare exactly how controller coordinates produce each complete command set.
    command_projection=map(c->zeros(Float32,length(c),n),commands)
    start=0
    for entry in mirror_specs
        name=entry["name"];projection=projections[name];count=size(projection,2)
        getproperty(command_projection,Symbol(name))[:,start+1:start+count] .= projection
        name==coupled && (getproperty(command_projection,Symbol(name))[:,start+1:start+2] .= 0;
            getproperty(command_projection,stage_name)[:,start+1:start+2] .= Matrix{Float32}(LA.I,2,2))
        start+=count
    end
    interaction=zeros(Float32,length(reference),n)
    mode_rms=zeros(Float32,n)
    for mode in 1:n
        sides=map((1f0,-1f0)) do sign
            for name in keys(commands)
                getproperty(commands,name) .= view(getproperty(command_projection,name),:,mode).*(sign*poke)
            end
            raw=modal_frame!(system,commands)
            if sign>0
                opd=vec(Array(HIL.graph_output(system.graph,:pupil_opd)))[valid]
                centered=opd .- sum(opd)/length(opd)
                mode_rms[mode]=sqrt(sum(abs2,centered)/length(centered))/poke
            end
            copy(pupil_measurement!(pixels,mean,estimator,calibrated,raw,background,adc_scale))
        end
        interaction[:,mode] .= (sides[1].-sides[2])./(2poke)
        mode%32==0 && (println("calibrated ",mode,"/",n);flush(stdout))
    end
    # Existing TSVD calibration implementation owns inversion and truncation.
    # Equal pupil-RMS OPD weighting prevents TT scale from setting the cutoff.
    weights=map(r -> r>sqrt(eps(Float32)) ? inv(r) : 0f0, mode_rms)
    weighted=interaction .* transpose(weights)
    inverse=AdaptiveOpticsCalibration.process(
        AdaptiveOpticsCalibration.prepare(AdaptiveOpticsCalibration.Reconstructors.TSVDInverse(rtol=Float32(recipe["tsvd_rtol"])),
            AdaptiveOpticsCalibration.Reconstructors.ReconstructorSpecification(length(reference),n,Float32)),
        AdaptiveOpticsCalibration.Reconstructors.SVDReconstructorInputs(weighted))
    reconstructor=weights .* AdaptiveOpticsCalibration.Reconstructors.reconstructor(inverse)
    mkdir(output)
    context=Dict("pwfs"=>Dict("pupil_size"=>collect(pupil_size),"pupil_origins"=>origins,
            "pupil_mask"=>vec(permutedims(mask)),"selected_pixel_count"=>Base.count(mask)),
        "temporal"=>Dict("modal_section_count"=>1,"tiptilt_section_count"=>1),
        "controller-to-tiptilt"=>Dict("schema"=>PipeWireAORTC.Schemas.CATALOG["controller_to_tip_tilt"]["id"]),
        String(stage_name)*"-to-"*coupled=>Dict("schema"=>PipeWireAORTC.Schemas.CATALOG["tip_tilt_to_actuators"]["id"]))
    dimensions=Dict("controller_command_count"=>n)
    for entry in mirror_specs
        name=entry["name"]
        dimensions[name*"_mode_count"]=size(projections[name],2)
    end
    rtc=IC.load_rtc(joinpath(source,recipe["rtc_configuration"]))
    publication=IC.json_value(IC.physical_definition(rtc.instrument))
    context_graph=PipeWireAORTC.InstrumentExport.graph_context(publication;
        dimensions=rtc.document["dimensions"],mirror_controls=rtc.controls["deformable_mirrors"],calibration=context)
    merge!(context_graph["rtc"]["dimensions"],dimensions)
    for entry in mirror_specs
        context[entry["name"]*"-command"]=Dict("slew_limit"=>nothing)
    end
    context["tiptilt-command"]=Dict("command_limits"=>recipe["tiptilt"]["command_limits_m"],"slew_limit"=>nothing)
    context_graph["calibration"]=context
    graph_source=PipeWireAORTC.DeploymentConfiguration.decode(joinpath(source,recipe["graph"]),"/opt/pipewireao")
    concrete=PipeWireAORTC.InstrumentExport.resolve_graph_configuration(graph_source,context_graph)
    graphpath=joinpath(output,"graph.conf")
    PipeWireAORTC.ScienceExport.write_spa_config(graphpath,concrete;header="Generated simulation calibration graph; edit source and regenerate.")
    graph=JuliaFilterGraph.prepare_graph(graphpath;algorithms=FGA.algorithms())
    parameters=Dict(name=>zeros(format.element_type,format.shape) for(name,format) in pairs(JuliaFilterGraph.parameter_formats(graph)))
    fill!(parameters[:flat],adc_scale);parameters[:background].=background
    parameters[Symbol("pupil-origins")] .= reduce(vcat,permutedims.(origins))
    parameters[Symbol("pupil-mask")] .= mask
    parameters[:reconstructor] .= reconstructor
    parameters[Symbol("modal-reference")] .= -(reconstructor*reference)
    parameters[Symbol("modal-filter-coefficients")][1,:,:] .= 1f0
    parameters[Symbol("tiptilt-filter-coefficients")][1,:,:] .= 1f0
    parameters[Symbol(String(stage_name)*"-to-"*coupled)] .= fit
    start=0
    for entry in mirror_specs
        name=entry["name"];projection=projections[name];count=size(projection,2)
        selection=parameters[Symbol(name*"-selection")]
        selection[:,start+1:start+count] .= Matrix{Float32}(LA.I,count,count)
        parameters[Symbol(name*"-vdm-to-controller")] .= transpose(selection)
        for suffix in ("active-to-full","full-to-active")
            matrix=parameters[Symbol(name*"-"*suffix)]
            matrix .= haskey(completions,name) ?
                (suffix=="active-to-full" ? completions[name].completion : completions[name].feedback) :
                Matrix{Float32}(LA.I,size(matrix)...)
        end
        if haskey(completions,name)
            parameters[Symbol(name*"-vdm-to-pdm")] .= Matrix{Float32}(LA.I,size(projection,1),size(projection,1))
            parameters[Symbol(name*"-pdm-to-vdm")] .= Matrix{Float32}(LA.I,size(projection,1),size(projection,1))
        else
            parameters[Symbol(name*"-vdm-to-pdm")] .= projection
            parameters[Symbol(name*"-pdm-to-vdm")] .= name==coupled ? LA.pinv(projection) : transpose(projection)
        end
        Calibration.initialize_shape_offsets!(parameters,name*"-")
        name==coupled && (parameters[Symbol("controller-to-tiptilt")][:,start+1:start+2] .= Matrix{Float32}(LA.I,2,2))
        start+=count
    end
    artifacts=joinpath(output,"artifacts");mkdir(artifacts)
    for(name,value) in parameters
        Calibration.write_fits(joinpath(artifacts,String(name)*".fits"),value)
    end
    for(name,value) in (("interaction-matrix",interaction),("singular-values",AdaptiveOpticsCalibration.Reconstructors.singular_values(inverse)),("flat-frame",flat))
        Calibration.write_fits(joinpath(artifacts,name*".fits"),value)
    end
    PipeWireAORTC.Common.write_yaml(joinpath(output,"context.yaml"),context;
        header="Generated from simulation-local push-pull calibration; edit recipe and regenerate.")
    IC.prescription_identity(IC.load_simulation(declaration.path),settings)==prescription || throw(ArgumentError("simulation prescription changed during calibration"))
    Calibration.digest(joinpath(source,recipe["graph"]))==source_graph_sha256 || throw(ArgumentError("controller graph changed during calibration"))
    report=Dict("source_prescription_identity"=>prescription,
        "source_graph_sha256"=>source_graph_sha256,
        "graph_sha256"=>Calibration.digest(graphpath),
        "backend"=>string(typeof(target)),
        "scope"=>"simulation-local; provisional Gaussian mirrors and ADC; not hardware calibration",
        "mode_count"=>n,"measurement_count"=>length(reference),"retained_rank"=>AdaptiveOpticsCalibration.Reconstructors.effective_rank(inverse),
        "dimensions"=>dimensions,
        "actuator_roles"=>Dict(name=>Dict("controlled"=>Base.count(==(UInt8(1)),value.roles),
            "extrapolated"=>Base.count(==(UInt8(2)),value.roles),"no_correction"=>Base.count(iszero,value.roles)) for (name,value) in completions),
        "tiptilt_fit_relative_residual"=>LA.norm(response*fit-ramps)/LA.norm(ramps),
        "tiptilt_fit_max_coefficient"=>maximum(abs,fit),
        "coupled_projection_condition"=>LA.cond(projections[coupled]),
        "mode_rms"=>mode_rms,"normalization"=>"piston-removed pupil RMS OPD",
        "poke_m"=>poke,"tsvd_rtol"=>recipe["tsvd_rtol"],
        "relative_inverse_residual"=>LA.norm(interaction*reconstructor*interaction-interaction)/LA.norm(interaction),
        "recipe"=>recipe,"artifact_sha256"=>Dict(name=>Calibration.digest(joinpath(artifacts,name)) for name in readdir(artifacts)))
    PipeWireAORTC.Common.write_yaml(joinpath(output,"result.yaml"),report;header="Generated simulation calibration receipt; do not edit.")
    return report
end
