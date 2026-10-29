# Cold optical calibration orchestration. AOC owns basis construction and TSVD;
# the callbacks retain the existing simulator's mirror and propagation owners.
# Mathematical names follow ext/modal_calibration.jl and AOC ProbeBases and
# Reconstructors: D[:,j]=(I(+hP[:,j])-I(-hP[:,j]))/(2h), a=R*(I-I₀).

include("optical_expectation.jl")
include("optical_chopped.jl")

"Prepare only the declared physical mirror response, with its exact bindings."
function physical_mirror_response(upstream,upstream_configuration,mirror;simulation_graph="calibration",
        target=AdaptiveOpticsSim.Backends.HostComputeDevice())
    geometry = IC.mirror(upstream,upstream_configuration,mirror)
    document = IC.graph_document(upstream,upstream_configuration;simulation_graph)
    nodes = filter(node -> node["name"] == mirror,document["nodes"])
    length(nodes) == 1 || throw(ArgumentError("calibration must select one declared upstream mirror component"))
    node = only(nodes)
    # Select the existing typed node unchanged, including its construction and
    # parameter bindings. This preserves grid/coordinate/measured response and
    # physical command order instead of recreating an influence-function model.
    inputs = filter(entry -> entry["destination"] == mirror*".pdm_command",document["inputs"])
    length(inputs) == 1 || throw(ArgumentError("mirror must have one complete physical command input"))
    selected_input = merge(only(inputs),Dict("name"=>"command"))
    parameters = filter(entry -> startswith(entry["destination"],mirror*"."),get(document,"parameters",[]))
    response_document = Dict("schema_version"=>1,"name"=>"optical_calibration_mirror",
        "nodes"=>[node],"inputs"=>[selected_input],"parameters"=>parameters,
        "outputs"=>[Dict("name"=>"opd","source"=>mirror*".surface_opd")])
    owner = Base.get_extension(PipeWireAORTC,:PipeWireAORTCAOSExt)
    owner === nothing && throw(ArgumentError("AOS optical preparation extension is unavailable"))
    factories = owner.configured_graph_node_types()
    names = unique(vcat([Symbol(selected_input["binding"])],
        Symbol[Symbol(entry["binding"]) for entry in parameters],
        owner.configuration_binding_names(response_document,factories)))
    bindings = owner.prepare_bindings(upstream,upstream_configuration,names;target,target_names=names)
    definition = HIL.load_algorithm_graph(response_document;bindings,node_types=factories)
    execution = owner.instrument_execution(target,nothing)
    mirror_graph = HIL.prepare_algorithm_graph(definition;target,execution)

    surface = command -> begin
        HIL._with_prepared_device_execution_context(mirror_graph.context) do
            copyto!(HIL.graph_input(mirror_graph,:command),command)
        end
        HIL.step_graph!(mirror_graph)
        HIL._with_prepared_device_execution_context(mirror_graph.context) do
            Array(HIL.graph_output(mirror_graph,:opd))
        end
    end
    return (;geometry,node,mirror_graph,surface)
end

"Prepare existing native mirror and optical graph owners without a core or service."
function optical_callbacks(upstream_simulation::AbstractString, optical_simulation::AbstractString;
        mirror::AbstractString, branches::NamedTuple, upstream_settings=Dict(), settings=Dict(),
        target=AdaptiveOpticsSim.Backends.HostComputeDevice(), chopping=NamedTuple(), publication_plan=nothing)
    target isa Union{AdaptiveOpticsSim.Backends.HostComputeDevice,
        AdaptiveOpticsSim.Backends.AcceleratorComputeDevice{AdaptiveOpticsSim.Backends.AMDGPUBackend},
        AdaptiveOpticsSim.Backends.AcceleratorComputeDevice{AdaptiveOpticsSim.Backends.CUDABackend}} ||
        throw(ArgumentError("optical calibration supports explicit host, AMDGPU or CUDA targets"))
    upstream = IC.load_simulation(upstream_simulation)
    optical = IC.load_simulation(optical_simulation)
    upstream_configuration = IC.settings(upstream,upstream_settings)
    output = get(upstream.instrument.document,"optical_output",nothing)
    input = get(optical.instrument.document,"optical_input",nothing)
    output isa AbstractDict && input isa AbstractDict &&
        all(key -> haskey(output,key) && haskey(input,key) && output[key] == input[key],
            ("plane","diameter_m","curvature","registration")) ||
        throw(ArgumentError("upstream and optical instrument pupil interfaces must explicitly match"))
    response=physical_mirror_response(upstream,upstream_configuration,mirror;target)
    (;geometry,node,mirror_graph,surface)=response
    systems = map(branch -> IC.prepare_system(optical_simulation;settings,
        simulation_graph=String(branch),target),branches)
    unfringed_systems = map(chopping) do selection
        IC.prepare_system(optical_simulation;settings,simulation_graph=selection.unfringed_graph,target)
    end
    amplitude = Matrix{Float32}(IC.binding_values(upstream,upstream_configuration,
        Dict("kind"=>"pupil_amplitude","resolution"=>"pupil_resolution","type"=>"Float32")))
    support = IC.binding_values(upstream,upstream_configuration,
        Dict("kind"=>"pupil_support","resolution"=>"pupil_resolution")) .!= 0
    packet = zeros(Float32,2,size(amplitude,2),size(amplitude,1))
    for system in (values(systems)...,values(unfringed_systems)...)
        size(HIL.graph_input(system.graph,:pupil_opd)) == size(packet)[2:3] ||
            throw(DimensionMismatch("upstream and optical pupil grids differ"))
        HIL._with_prepared_device_execution_context(system.graph.context) do
            optical_pupil_inputs!(HIL.graph_input(system.graph,:pupil_opd),
                HIL.graph_input(system.graph,:pupil_amplitude),packet,zeros(Float32,size(amplitude)),amplitude)
        end
    end
    observe_system = (system,opd) -> begin
        HIL._with_prepared_device_execution_context(system.graph.context) do
            optical_pupil_inputs!(HIL.graph_input(system.graph,:pupil_opd),
                HIL.graph_input(system.graph,:pupil_amplitude),packet,opd,amplitude)
        end
        HIL.step_graph!(system.graph)
        HIL._with_prepared_device_execution_context(system.graph.context) do
            Array(HIL.graph_output(system.graph,:intensity))
        end
    end
    frontends = NamedTuple()
    chopped_references = NamedTuple()
    if !isempty(chopping)
        publication_plan === nothing && throw(ArgumentError("chopped calibration requires retained authored measurement graphs"))
        flat_opd = surface(zeros(Float32,length(HIL.graph_input(mirror_graph,:command))))
        flats = map(keys(chopping)) do name
            fringed = optical_image(observe_system(getproperty(systems,name),flat_opd))
            unfringed = optical_image(observe_system(getproperty(unfringed_systems,name),flat_opd))
            size(fringed) == size(unfringed) || throw(DimensionMismatch("chopped optical variants differ in image shape"))
            difference = fringed .- unfringed
            all(isfinite,difference) || throw(ArgumentError("chopped reference difference must remain finite Float32"))
            (;fringed,unfringed,difference)
        end
        chopped_references = NamedTuple{keys(chopping)}(flats)
        frontends = NamedTuple{keys(chopping)}(map(keys(chopping)) do name
            physical = optical.instrument.document["optical_paths"][string(name)]["sensor"]
            duration = round(Int64,optical.instrument.document["wavefront_sensors"][physical]["acquisition"]["exposure_duration_s"]*1e9)
            document = optical_chopped_template(publication_plan,name)
            prepare_optical_chopped_frontend(document,name,getproperty(chopped_references,name).difference,
                duration,getproperty(chopping,name).trigger_high_is_fringed)
        end)
    end
    observe = opd -> NamedTuple{keys(systems)}(map(keys(systems)) do name
        fringed = observe_system(getproperty(systems,name),opd)
        hasproperty(frontends,name) ? optical_chopped_measurement!(getproperty(frontends,name),fringed,
            observe_system(getproperty(unfringed_systems,name),opd)) : fringed
    end)
    coordinates = permutedims(IC.actuator_coordinates(geometry.description;
        pupil_registration=geometry.registration))
    provenance = Dict("upstream_prescription_identity"=>IC.prescription_identity(upstream,upstream_configuration),
        "optical_prescription_identity"=>IC.prescription_identity(optical,IC.settings(optical,settings)),
        "mirror_component"=>String(mirror),"mirror_node_type"=>node["type"],
        "branches"=>Dict(string(name)=>String(branch) for (name,branch) in pairs(branches)),
        "pupil_registration"=>IC.json_value(geometry.registration),"backend"=>string(typeof(target)),
        "pupil_coordinates"=>"upstream[x,y] via native PupilOutput.pack! to packet[quantity,y,x] and optical input[y,x]",
        "mirror_opd_element_type"=>string(eltype(HIL.graph_output(mirror_graph,:opd))),
        "optical_intensity_element_type"=>Dict(string(name)=>string(eltype(HIL.graph_output(system.graph,:intensity)))
            for (name,system) in pairs(systems)))
    if !isempty(chopping)
        provenance["chopping"] = IC.json_value(chopping)
        provenance["measurement_frontend_identity"] = Dict(string(name)=>optical_frontend_identity(frontend.document)
            for (name,frontend) in pairs(frontends))
        provenance["chopped_reference_identity"] = Dict(string(name)=>
            PipeWireAORTC.InstrumentDefinition.scientific_identity(IC.canonical(reference.difference))
            for (name,reference) in pairs(chopped_references))
        provenance["measurement_scope"] = "matched static F/U pairs; no exposure-command feedforward or concurrent-loop qualification"
    end
    return (;surface,observe,mirror_graph,systems,unfringed_systems,
        actuator_coordinates=coordinates,pupil_support=support,provenance,chopped_references)
end

function optical_pupil_inputs!(opd_destination,amplitude_destination,packet,opd,amplitude)
    owner = Base.get_extension(PipeWireAORTC,:PipeWireAORTCAOSExt)
    owner === nothing && throw(ArgumentError("native scientific pupil publisher is unavailable"))
    owner.PupilOutput.pack!(packet,Matrix{Float32}(opd),amplitude)
    copyto!(opd_destination,Matrix{eltype(opd_destination)}(view(packet,1,:,:)))
    copyto!(amplitude_destination,Matrix{eltype(amplitude_destination)}(view(packet,2,:,:)))
    return nothing
end

# This is a content identity, separate from the writer's exact FITS-byte hashes.
# Encode finite Float32 calibration arrays in a fixed little-endian representation.
function optical_identity(projection, physical_to_modes, branches)
    io = IOBuffer()
    for (name,array) in (("command-projection",projection),("physical-to-modes",physical_to_modes),
            ((string(name)*"-"*field,getproperty(branch,Symbol(field)))
                for (name,branch) in pairs(branches) for field in ("reconstructor","reference","mask"))...)
        write(io,string(name,":",join(size(array),","),"\n"))
        if eltype(array) === Bool
            write(io,UInt8.(vec(array)))
        else
            write(io,reinterpret(UInt8,htol.(reinterpret(UInt32,vec(Float32.(array))))))
        end
    end
    return "sha256:"*bytes2hex(Calibration.sha256(take!(io)))
end

function optical_image(image; signed::Bool=false)
    image isa AbstractMatrix{<:AbstractFloat} && !isempty(image) &&
        all(isfinite,image) && (signed || all(>=(0),image)) || throw(ArgumentError(
        "optical observation must be finite, and intensity observations must be nonnegative"))
    converted = Matrix{Float32}(image)
    all(isfinite,converted) || throw(ArgumentError("optical intensity must remain finite Float32"))
    return converted
end

function optical_pixels(image, mask)
    size(image) == size(mask) || throw(DimensionMismatch("optical pixel mask differs from image"))
    return Float32[image[row,column] for row in axes(image,1) for column in axes(image,2) if mask[row,column]]
end

function optical_surface(surface, command, support)
    opd = surface(command)
    opd isa AbstractMatrix{<:AbstractFloat} && size(opd) == size(support) &&
        all(isfinite,opd) || throw(ArgumentError("mirror response must be a finite pupil OPD image"))
    return Matrix{Float64}(opd)
end

function optical_authority(branch_modes, mode_count)
    branch_modes isa NamedTuple && !isempty(branch_modes) ||
        throw(ArgumentError("branch_modes must explicitly name the optical branches"))
    selections = map(branch_modes) do modes
        values = collect(modes)
        !isempty(values) && all(i -> i isa Integer && !(i isa Bool) && 1 <= i <= mode_count,values) &&
            length(unique(values)) == length(values) || throw(ArgumentError("invalid branch mode selection"))
        return Int.(values)
    end
    combined = vcat(values(selections)...)
    sort(combined) == collect(1:mode_count) || throw(ArgumentError(
        "branch mode selections must form an explicit disjoint complete partition"))
    return selections
end

"""
    InstrumentCalibration.calibrate_optical(surface, observe, command_projection;
        pupil_support, branch_modes, pixel_masks, poke_m, tsvd_rtol, ...)

Finite model-derived calibration in explicit physical command order. `surface`
maps a complete metre-OPD physical command vector to the actual upstream mirror
OPD image; `observe` maps that image through the prepared optical graphs to a
NamedTuple of intensity images. Both callbacks must hold all other configuration
fixed and return the response to the supplied command, independent of call order.
No camera calibration, acquisition timing, chopping or hardware claim is inferred.

The supplied projection is dimensionless, physical-command by mode. Its columns
are normalized using the actual mirror's piston-removed RMS over `pupil_support`,
so reconstructed coefficients have metre-OPD pupil-RMS units. Every branch is
calibrated against every mode before unowned reconstructor rows are zeroed.
`require_observable=false` returns a rejected candidate with diagnostics for
exploration; rejected candidates cannot be written as accepted bundles.
"""
function Calibration.calibrate_optical(surface, observe, command_projection::AbstractMatrix;
        pupil_support::AbstractMatrix{Bool}, branch_modes::NamedTuple, pixel_masks::NamedTuple,
        poke_m::Real, tsvd_rtol::Real, derivative_tolerance::Real=0.05,
        reconstruction_tolerance::Real=0.05, require_observable::Bool=true,
        provenance::AbstractDict=Dict{String,Any}(), held_out_coefficients=nothing,
        signed_measurements::Tuple{Vararg{Symbol}}=())
    Base.require_one_based_indexing(command_projection,pupil_support)
    !isempty(command_projection) && all(isfinite,command_projection) && any(pupil_support) ||
        throw(ArgumentError("optical command projection and pupil support must be finite and nonempty"))
    h = Float32(poke_m)
    isfinite(h) && h > 0 && h/2 > 0 || throw(ArgumentError("poke_m must be finite positive Float32"))
    isfinite(tsvd_rtol) && 0 < tsvd_rtol < 1 || throw(ArgumentError("invalid optical TSVD cutoff"))
    all(x -> isfinite(x) && 0 < x < 1,(derivative_tolerance,reconstruction_tolerance)) ||
        throw(ArgumentError("optical tolerances must be finite and between zero and one"))
    projection = Matrix{Float32}(command_projection)
    n = size(projection,2)
    authority = optical_authority(branch_modes,n)
    length(unique(signed_measurements)) == length(signed_measurements) &&
        all(name -> haskey(authority,name),signed_measurements) ||
        throw(ArgumentError("signed optical measurements must name distinct declared branches"))
    keys(pixel_masks) == keys(authority) || throw(ArgumentError("pixel masks must name every branch in order"))
    command = zeros(Float32,size(projection,1))
    flat_opd = optical_surface(surface,command,pupil_support)
    reference_images = observe(flat_opd)
    reference_images isa NamedTuple && keys(reference_images) == keys(authority) ||
        throw(ArgumentError("optical observation branches differ from branch_modes"))
    signed = NamedTuple{keys(authority)}(map(name -> name in signed_measurements, keys(authority)))
    references = map((image,allowed)->optical_image(image;signed=allowed),reference_images,signed)
    masks = map(pixel_masks,references) do mask,image
        mask isa AbstractMatrix{Bool} && size(mask) == size(image) && any(mask) ||
            throw(ArgumentError("each branch requires a nonempty explicit image pixel mask"))
        Matrix{Bool}(mask)
    end
    pupil_modes = zeros(Float64,count(pupil_support),n)
    normalization = zeros(Float64,n)
    for j in 1:n
        command .= h .* view(projection,:,j)
        response = (optical_surface(surface,command,pupil_support) .- flat_opd)[pupil_support] ./ h
        response .-= sum(response)/length(response)
        rms = sqrt(sum(abs2,response)/length(response))
        isfinite(rms) && rms > sqrt(eps(Float32)) || throw(ArgumentError("optical mode $j has null mirror response"))
        normalization[j] = rms
        projection[:,j] ./= rms
        pupil_modes[:,j] .= response ./ rms
    end
    all(isfinite,projection) || throw(ArgumentError("normalized optical projection overflowed Float32"))
    projection_inverse = AdaptiveOpticsCalibration.process(
        AdaptiveOpticsCalibration.prepare(
            AdaptiveOpticsCalibration.Reconstructors.TSVDInverse(rtol=Float32(tsvd_rtol)),
            AdaptiveOpticsCalibration.Reconstructors.ReconstructorSpecification(size(projection,1),n,Float32)),
        AdaptiveOpticsCalibration.Reconstructors.SVDReconstructorInputs(projection))
    AdaptiveOpticsCalibration.Reconstructors.effective_rank(projection_inverse) == n ||
        throw(ArgumentError("physical command projection does not retain every declared mode"))
    physical_to_modes = Matrix(AdaptiveOpticsCalibration.Reconstructors.reconstructor(projection_inverse))
    interactions = map(mask -> zeros(Float32,count(mask),n),masks)
    half_interactions = map(similar,interactions)
    for (amplitude,matrices) in ((h,interactions),(h/2,half_interactions)), j in 1:n
        measurements = map((1f0,-1f0)) do sign
            command .= (sign*amplitude) .* view(projection,:,j)
            images = observe(optical_surface(surface,command,pupil_support))
            images isa NamedTuple && keys(images) == keys(authority) || throw(ArgumentError("optical branches changed during calibration"))
            map(images,masks,signed) do image,mask,allowed
                optical_pixels(optical_image(image;signed=allowed),mask)
            end
        end
        for name in keys(authority)
            getproperty(matrices,name)[:,j] .=
                (getproperty(measurements[1],name) .- getproperty(measurements[2],name)) ./ (2amplitude)
        end
    end
    branches = map(keys(authority)) do name
        D = getproperty(interactions,name)
        half = getproperty(half_interactions,name)
        inverse = AdaptiveOpticsCalibration.process(
            AdaptiveOpticsCalibration.prepare(
                AdaptiveOpticsCalibration.Reconstructors.TSVDInverse(rtol=Float32(tsvd_rtol)),
                AdaptiveOpticsCalibration.Reconstructors.ReconstructorSpecification(size(D,1),n,Float32)),
            AdaptiveOpticsCalibration.Reconstructors.SVDReconstructorInputs(D))
        reconstructor = Matrix(AdaptiveOpticsCalibration.Reconstructors.reconstructor(inverse))
        selected = getproperty(authority,name)
        selection = zeros(Float32,n,n)
        for j in selected
            selection[j,j] = 1
        end
        for j in setdiff(1:n,selected)
            reconstructor[j,:] .= 0
        end
        recovery = reconstructor*D
        recovery_error = LA.norm(recovery-selection)/sqrt(length(selected))
        derivative_error = LA.norm(D-half)/max(LA.norm(half),eps(Float32))
        unowned = setdiff(1:n,selected)
        cross_talk = isempty(unowned) ? 0.0 : LA.norm(recovery[selected,unowned])/sqrt(length(selected))
        accepted = recovery_error <= reconstruction_tolerance && derivative_error <= derivative_tolerance
        return (;reference=getproperty(references,name),mask=getproperty(masks,name),
            interaction=D,half_interaction=half,reconstructor,selection,recovery,
            modes=selected,retained_rank=AdaptiveOpticsCalibration.Reconstructors.effective_rank(inverse),
            singular_values=AdaptiveOpticsCalibration.Reconstructors.singular_values(inverse),
            recovery_error,derivative_error,cross_talk,accepted)
    end
    branches = NamedTuple{keys(authority)}(branches)
    accepted = all(branch -> branch.accepted,branches)
    report = Dict{String,Any}("status"=>accepted ? "accepted" : "rejected",
        "scope"=>"simulation-local relative-intensity optical calibration; not hardware calibration",
        "normalization"=>"piston-removed pupil RMS OPD", "coefficient_units"=>"m OPD",
        "measurement_element_type"=>"Float32","reconstructor_element_type"=>"Float32",
        "command_count"=>size(projection,1),"mode_count"=>n,"poke_m"=>h,
        "tsvd_rtol"=>tsvd_rtol,"derivative_tolerance"=>derivative_tolerance,
        "reconstruction_tolerance"=>reconstruction_tolerance,"provenance"=>Dict(provenance),
        "branches"=>Dict(string(name)=>Dict("modes"=>branch.modes,"retained_rank"=>branch.retained_rank,
            "recovery_error"=>branch.recovery_error,"derivative_error"=>branch.derivative_error,
            "cross_talk"=>branch.cross_talk,"accepted"=>branch.accepted)
            for (name,branch) in pairs(branches)))
    for (name,branch) in pairs(branches)
        report["branches"][string(name)]["image_shape"] = collect(size(branch.reference))
        report["branches"][string(name)]["measurement_kind"] = name in signed_measurements ?
            "chopped-pixel-residual" : "intensity"
        report["branches"][string(name)]["selected_pixel_count"] = count(branch.mask)
        report["branches"][string(name)]["pixel_order"] = "row-major"
        report["branches"][string(name)]["singular_values"] = branch.singular_values
        report["branches"][string(name)]["condition_number"] = maximum(branch.singular_values)/max(minimum(branch.singular_values),eps(Float32))
    end
    report["physical_projection"] = Dict("command_projection"=>"artifacts/command-projection.fits",
        "physical_to_modes"=>"artifacts/physical-to-modes.fits","axes"=>[2,1],"type"=>"Float32",
        "storage_order"=>"row-major","command_projection_shape"=>collect(size(projection)),
        "physical_to_modes_shape"=>collect(size(physical_to_modes)),
        "relative_inverse_residual"=>LA.norm(physical_to_modes*projection-Matrix{Float32}(LA.I,n,n))/sqrt(n))
    report["calibration_identity"] = "sha256:"*bytes2hex(Calibration.sha256(join((
        optical_identity(projection,physical_to_modes,branches),
        PipeWireAORTC.InstrumentDefinition.scientific_identity(IC.canonical(Dict(provenance)))),"\n")))
    candidate = (;projection,physical_to_modes,pupil_modes,normalization,pupil_support=Matrix{Bool}(pupil_support),branches,report)
    coefficients = held_out_coefficients === nothing ?
        Float32[h/(4sqrt(n)) * (column == 1 ? 1 : column == 2 ? (-1)^j : cos(j))
            for j in 1:n,column in 1:3] : held_out_coefficients
    validation = Calibration.validate_optical(surface,observe,candidate;
        coefficients,reconstruction_tolerance)
    report["validated_operating_domain"] = Dict("kind"=>"finite-held-out-mixtures",
        "coefficient_units"=>"m OPD","probe_amplitudes_m"=>[h,h/2],
        "held_out_coefficients_m"=>[collect(row) for row in eachrow(coefficients)],
        "held_out_coefficient_norms_m"=>[LA.norm(column) for column in eachcol(coefficients)],
        "held_out_maximum_absolute_coefficient_m"=>maximum(abs,coefficients),
        "scope"=>"only the listed finite mixtures; no complete coefficient box or concurrent-loop qualification")
    report["held_out"] = Dict("accepted"=>validation.accepted,
        "reconstruction_errors"=>validation.reconstruction_errors,"pupil_rms_ratios"=>validation.pupil_rms_ratios,
        "scope"=>validation.scope)
    accepted &= validation.accepted
    report["status"] = accepted ? "accepted" : "rejected"
    require_observable && !accepted && throw(ArgumentError(
        "optical calibration rejected: " * join(("$name rank=$(getproperty(branches,name).retained_rank) recovery=$(getproperty(branches,name).recovery_error) derivative=$(getproperty(branches,name).derivative_error)" for name in keys(branches)),"; ") *
        "; held-out errors=$(validation.reconstruction_errors), pupil RMS ratios=$(validation.pupil_rms_ratios)"))
    return merge(candidate,(;held_out_coefficients=Matrix{Float32}(coefficients),validation))
end

"Construct the explicit AOC sinusoidal physical-command basis before calibration."
function Calibration.calibrate_optical(surface, observe;
        actuator_coordinates::AbstractMatrix, controlled_actuators::AbstractVector{Bool},
        spatial_frequencies::AbstractMatrix, provenance::AbstractDict=Dict{String,Any}(), kwargs...)
    size(actuator_coordinates,1) == length(controlled_actuators) && size(actuator_coordinates,2) == 2 ||
        throw(DimensionMismatch("actuator coordinates require physical-command rows and x,y columns"))
    any(controlled_actuators) || throw(ArgumentError("optical calibration requires controlled physical actuators"))
    count = 2size(spatial_frequencies,1)
    method = AdaptiveOpticsCalibration.ProbeBases.SpatialSinusoidalPushPull(ones(Float32,count);
        normalization=:peak,minimum_sampled_peak=1e-6)
    plan = AdaptiveOpticsCalibration.prepare(method,
        AdaptiveOpticsCalibration.ProbeBases.SpatialSinusoidalSpecification(actuator_coordinates,spatial_frequencies))
    projection = Matrix{Float32}(transpose(plan.basis))
    projection[.!controlled_actuators,:] .= 0
    provenance = merge(Dict{String,Any}(provenance),Dict("basis"=>Dict(
        "kind"=>"spatial-sinusoidal","spatial_frequencies"=>[collect(row) for row in eachrow(spatial_frequencies)],
        "coordinate_units"=>"normalized pupil radius","mode_order"=>"sine, cosine per frequency",
        "controlled_physical_commands"=>findall(controlled_actuators))))
    return Calibration.calibrate_optical(surface,observe,projection;provenance,kwargs...)
end

"""
Validate held-out modal mixtures with a fresh forward observation. Each column of
`coefficients` is one metre-OPD modal mixture. The combined disjoint branch estimate
must recover it, and applying its negative physical command must reduce pupil RMS.
This finite model test does not validate concurrent fast-loop reference handling.
"""
function Calibration.validate_optical(surface, observe, calibration;
        coefficients::AbstractMatrix, reconstruction_tolerance::Real=0.1)
    P = calibration.projection
    size(coefficients,1) == size(P,2) && size(coefficients,2)>0 && all(isfinite,coefficients) ||
        throw(ArgumentError("held-out coefficients must be finite mode-by-mixture values"))
    isfinite(reconstruction_tolerance) && 0 < reconstruction_tolerance < 1 ||
        throw(ArgumentError("invalid held-out reconstruction tolerance"))
    support = calibration.pupil_support
    flat = optical_surface(surface,zeros(Float32,size(P,1)),support)
    errors = Float64[]; ratios = Float64[]
    for column in eachcol(coefficients)
        LA.norm(column)>0 || throw(ArgumentError("held-out mixture must be nonzero"))
        command = P*Float32.(column)
        opd = optical_surface(surface,command,support)
        images = observe(opd)
        keys(images) == keys(calibration.branches) || throw(ArgumentError("held-out optical branches differ"))
        estimate = zeros(Float32,size(P,2))
        for (name,branch) in pairs(calibration.branches)
            signed = get(calibration.report["branches"][string(name)],"measurement_kind","intensity") == "chopped-pixel-residual"
            residual = optical_pixels(optical_image(getproperty(images,name);signed),branch.mask) .-
                optical_pixels(branch.reference,branch.mask)
            estimate .+= branch.reconstructor*residual
        end
        push!(errors,LA.norm(estimate-column)/LA.norm(column))
        corrected = optical_surface(surface,command-P*estimate,support)
        before = (opd-flat)[support]; after = (corrected-flat)[support]
        before .-= sum(before)/length(before); after .-= sum(after)/length(after)
        push!(ratios,LA.norm(after)/max(LA.norm(before),eps(Float64)))
    end
    accepted = maximum(errors) <= reconstruction_tolerance && maximum(ratios) < 1
    return (;accepted,reconstruction_errors=errors,pupil_rms_ratios=ratios,
        scope="held-out optical simulation with upstream fast loop held; no timing or hardware qualification")
end

function optical_reference_measurement!(outputs, frontend, inputs, frame)
    eltype(frame) === UInt16 || throw(ArgumentError("upstream optical reference must retain raw UInt16 ADC frames"))
    copyto!(inputs.raw,Array(frame))
    JuliaFilterGraph.reset!(frontend.graph)
    # The deployed pyramid uses its previous successful frame's flux. Two
    # evaluations of the same held acquisition reach its declared held-flux state.
    for _ in 1:2
        status = JuliaFilterGraph.process!(outputs,frontend.graph,inputs)
        status isa NamedTuple && all(values(status)) ||
            throw(ArgumentError("deployed upstream reconstruction rejected a held UInt16 frame"))
    end
    return copy(outputs.residual)
end

# Keep this ratio invariant under a change of physical units. In particular,
# metre-valued residuals must not be floored at unitless eps(Float32).
function optical_reference_prediction_error(measured, predicted)
    magnitude = LA.norm(measured)
    return iszero(magnitude) ? Inf : LA.norm(measured-predicted)/magnitude
end

function optical_flat_parameters(application)
    hashes = Dict{String,String}()
    for binding in PipeWireAORTC.GraphOwner.bindings(joinpath(application,"rtc","parameters.conf"))
        name = string(binding.port)
        (endswith(name,"-offset") || endswith(name,"-system-flat")) || continue
        bytes = PipeWireAORTC.Artifacts.snapshot(binding.source.path;check=()->nothing)
        PipeWireAORTC.Artifacts.FITSIO.FITS(bytes,"r") do file
            all(iszero,read(file[binding.source.hdu])) || throw(ArgumentError(
                "flat upstream reference calibration requires zero deployed $name"))
        end
        hashes[name] = bytes2hex(Calibration.sha256(bytes))
    end
    return hashes
end

function optical_upstream_execution(application,simulation,overrides)
    path = PipeWireAORTC.DeploymentConfiguration.relative_asset(application,"simulation.conf")
    execution = PipeWireAORTC.DeploymentConfiguration.decode(path,get(ENV,"PIPEWIREAO_PREFIX","/opt/pipewireao"))
    plant = execution["plant"]
    selected = PipeWireAORTC.DeploymentConfiguration.relative_asset(application,plant["definition"])
    selected == simulation || throw(ArgumentError("upstream reference simulation differs from the executed plant"))
    declaration = IC.load_simulation(simulation)
    effective = IC.settings(declaration,plant["settings"])
    schema = deepcopy(declaration.document["settings_schema"])
    merge!(schema["properties"],get(declaration.document["profiles"][effective["profile"]],"settings_schema",Dict()))
    requested = IC.settings(declaration,IC.merge_settings(effective,overrides,schema))
    requested == effective || throw(ArgumentError("upstream calibration settings differ from the executed plant"))
    identity(value) = PipeWireAORTC.InstrumentDefinition.scientific_identity(IC.canonical(value))
    graph = String(plant["graph"])
    document = IC.graph_document(declaration,effective;simulation_graph=graph)
    return (;declaration,effective,graph,execution_graph=document,configuration_sha256=Calibration.digest(path),
        effective_settings_identity=identity(effective),execution_graph_identity=identity(document))
end

function optical_sensor_configuration(document)
    return Dict(node["name"]=>node["config"] for node in document["nodes"]
        if haskey(node["config"],"source_magnitude") || node["type"] == "detector" || haskey(node["config"],"rounding"))
end

# Shared acquisition/reduction for a prepared native upstream plant and the exact
# deployed frontend. Diagnostic callers may supply an explicitly altered native
# graph without changing built files. Holdouts always retain the optical domain.
function optical_reference_response(system,frontend,calibration,commands,name,amplitudes,derivative_tolerance)
    keys(frontend.graph.input_formats) == (:raw,) || throw(ArgumentError("upstream frontend must have one explicit raw input"))
    frontend.graph.input_formats.raw.element_type === UInt16 ||
        throw(ArgumentError("upstream frontend must consume UInt16 ADC pixels"))
    inputs = map(format -> zeros(format.element_type,format.shape),frontend.graph.input_formats)
    outputs = map(format -> zeros(format.element_type,format.shape),frontend.graph.output_formats)
    measure = command -> begin
        getproperty(commands,name) .= command
        frame = Array(modal_frame!(system,commands))
        (;frame,residual=optical_reference_measurement!(outputs,frontend,inputs,frame))
    end
    return optical_reference_response(measure,calibration,amplitudes,derivative_tolerance)
end

function optical_reference_response(measure,calibration,amplitudes,derivative_tolerance)
    reference = measure(zeros(Float32,size(calibration.projection,1)))
    flat_frame,flat = reference.frame,reference.residual
    eltype(flat_frame) === UInt16 || throw(ArgumentError("upstream reference must retain UInt16 ADC exposures"))
    count = size(calibration.projection,2)
    trials = Dict{String,Any}[]
    responses = []
    chosen = nothing
    for h in amplitudes
        matrices = (zeros(Float32,length(flat),count),zeros(Float32,length(flat),count))
        changed_pixels = zeros(Int,2,count)
        peak_difference_adu = zeros(Int,2,count)
        raw_peaks = zeros(Int,2,count,2)
        for (index,amplitude) in enumerate((h,h/2)),j in 1:count
            measurements = map((1f0,-1f0)) do sign
                measure((sign*amplitude) .* view(calibration.projection,:,j))
            end
            raw = map(measurement -> measurement.frame,measurements)
            all(frame->eltype(frame)===UInt16,raw) || throw(ArgumentError("upstream reference exposure type changed"))
            matrices[index][:,j] .= (measurements[1].residual.-measurements[2].residual)./(2amplitude)
            difference = Int32.(raw[1]) .- Int32.(raw[2])
            for side in 1:2
                raw_peaks[index,j,side] = maximum(raw[side])
            end
            changed_pixels[index,j] = Base.count(!iszero,difference)
            peak_difference_adu[index,j] = maximum(abs,difference)
        end
        C,half = matrices
        derivative_error = optical_reference_prediction_error(half,C)
        holdouts = calibration.held_out_coefficients
        errors = Float64[]; before = Float64[]; after = Float64[]; held_out_raw_peaks = Int[]
        for coefficients in eachcol(holdouts)
            measured = measure(calibration.projection*coefficients)
            eltype(measured.frame) === UInt16 || throw(ArgumentError("upstream reference exposure type changed"))
            push!(held_out_raw_peaks,maximum(measured.frame))
            residual = measured.residual .- flat
            correction = C*coefficients
            push!(before,LA.norm(residual))
            push!(after,LA.norm(residual-correction))
            push!(errors,optical_reference_prediction_error(residual,correction))
        end
        accepted = isfinite(derivative_error) && LA.norm(C)>0 &&
            derivative_error <= derivative_tolerance && maximum(errors) <= derivative_tolerance
        trial = Dict{String,Any}("poke_m"=>h,"derivative_error"=>derivative_error,
            "held_out_errors"=>errors,"held_out_coefficients_m"=>[collect(row) for row in eachrow(holdouts)],
            "uncompensated_residual_norm"=>before,
            "compensated_residual_norm"=>after,"changed_raw_pixel_count"=>[collect(row) for row in eachrow(changed_pixels)],
            "peak_raw_difference_adu"=>[collect(row) for row in eachrow(peak_difference_adu)],
            "peak_raw_adu"=>[[collect(raw_peaks[index,:,side]) for side in 1:2] for index in 1:2],
            "held_out_peak_raw_adu"=>held_out_raw_peaks,"accepted"=>accepted)
        push!(trials,trial)
        push!(responses,(;interaction=C,half_interaction=half,poke_m=h))
        if accepted
            chosen = (;interaction=C,half_interaction=half,flat_frame,flat_residual=flat,
                reference_sign=-1f0,poke_m=h,trial)
            break
        end
    end
    return (;chosen,trials,responses,flat_frame,flat_residual=flat)
end

"""
Calibrate `C_fast[:,j] = (r(+hP[:,j])-r(-hP[:,j]))/(2h)` using the built
upstream AOS calibration plant and the existing projected deployed UInt16
pixel-calibration/pyramid/reconstruction frontend. Probe the explicitly supplied
amplitudes in order, retaining every derivative and quantization result. A
candidate needs both h/h2 agreement and held-out residual prediction agreement.
The returned `fast_reference` retains C and sign −1 for the observed additive
upstream OPD/mirror composition. This is reference-response evidence with the
upstream controller held, not a simultaneous closed-loop qualification.

`method="host-expectation"` requires an explicit Host target and one probe
amplitude. It combines `Detectors.emccd_mean` with the executed native UInt16
detector/frontend and an exact linear-flux control variate for independent
previous-frame normalization. Distinct fixed training/validation seeds,
conditional arithmetic bounds, and actual complete-frontend rounding samples
contribute to the unchanged gate. The reported three-vector-standard-error
bounds are statistical estimates under the declared ideal independent
Poisson/Gaussian simulation law, not finite-PRNG or hardware certificates.
"""
function Calibration.calibrate_optical_reference(upstream_application::AbstractString, calibration;
        simulation="simulation/definition.yaml",settings=Dict(),mirror="tweeter",
        raw_endpoint="pixel-calibration:raw",residual_endpoint="reconstruction:reconstructed",
        poke_amplitudes_m=[5e-9,1e-8,2e-8],derivative_tolerance=0.05,
        method="held-frame",samples=512,rounding_samples=128,
        training_seed=200002,validation_seed=400002,
        target=AdaptiveOpticsSim.Backends.HostComputeDevice())
    calibration.report["status"] == "accepted" || throw(ArgumentError("upstream reference requires an accepted optical calibration"))
    target isa Union{AdaptiveOpticsSim.Backends.HostComputeDevice,
        AdaptiveOpticsSim.Backends.AcceleratorComputeDevice{AdaptiveOpticsSim.Backends.AMDGPUBackend}} ||
        throw(ArgumentError("upstream optical reference supports explicit host or AMDGPU targets"))
    method in ("held-frame","host-expectation") || throw(ArgumentError("unsupported upstream reference method"))
    if method == "host-expectation"
        optical_expectation_options(samples,rounding_samples,training_seed,validation_seed)
        target isa AdaptiveOpticsSim.Backends.HostComputeDevice ||
            throw(ArgumentError("host expectation reference acquisition requires explicit Host target"))
        length(poke_amplitudes_m)==1 ||
            throw(ArgumentError("host expectation requires one explicit probe amplitude and independent validation"))
    end
    application = optical_application(upstream_application)
    Calibration.require_prepared_application(application)
    baseline_hashes = optical_flat_parameters(application)
    amplitudes = Float32.(poke_amplitudes_m)
    1 <= length(amplitudes) <= 8 && all(h -> isfinite(h) && h/2>0,amplitudes) ||
        throw(ArgumentError("upstream reference requires bounded positive finite amplitudes"))
    isfinite(derivative_tolerance) && 0 < derivative_tolerance < 1 ||
        throw(ArgumentError("upstream reference derivative tolerance must be between zero and one"))
    path = PipeWireAORTC.DeploymentConfiguration.relative_asset(application,simulation)
    execution = optical_upstream_execution(application,path,settings)
    declaration = execution.declaration
    configured = execution.effective
    prescription = IC.prescription_identity(declaration,configured)
    graph = IC.graph_document(declaration,configured;calibration=true)
    chain = method == "host-expectation" ? optical_expectation_chain(execution.execution_graph,graph,
        declaration.document["hil"]["frame_output"]) : nothing
    system = IC.prepare_system(path;settings=configured,calibration=true,target)
    commands = map(command -> zeros(eltype(command),size(command)),HIL.hil_command_buffer(system.boundary))
    name = Symbol(mirror)
    hasproperty(commands,name) && length(getproperty(commands,name)) == size(calibration.projection,1) ||
        throw(DimensionMismatch("upstream mirror commands differ from the optical physical projection"))
    # Establish sign from the declared composition, not from an assumed DM convention.
    linked = any(get(graph,"links",[])) do link
        link["source"] == mirror*".surface_opd" && endswith(link["destination"],".surface_opd") || return false
        destination = first(split(link["destination"],'.'))
        any(node -> node["name"] == destination && node["type"] == "pupil_opd_composition_f32",graph["nodes"])
    end
    linked ||
        throw(ArgumentError("upstream reference needs the declared additive pupil OPD composition"))
    frontend = Calibration.calibration_graph(application;
        inputs=(raw=String(raw_endpoint),),outputs=(residual=String(residual_endpoint),))
    try
        acquired = method == "held-frame" ?
            optical_reference_response(system,frontend,calibration,commands,name,amplitudes,derivative_tolerance) :
            optical_expected_reference((;plant=system,application),frontend,calibration,commands,name,
                only(amplitudes),execution.execution_graph;samples,rounding_samples,
                training_seed,validation_seed,tolerance=derivative_tolerance)
        chosen,trials = acquired.chosen,acquired.trials
        chosen === nothing && throw(ArgumentError("upstream optical reference rejected every explicit amplitude: "*repr(trials)))
        current_execution = optical_upstream_execution(application,path,settings)
        current = current_execution.declaration
        IC.prescription_identity(current,current_execution.effective) == prescription &&
            current_execution.configuration_sha256 == execution.configuration_sha256 &&
            current_execution.effective_settings_identity == execution.effective_settings_identity &&
            current_execution.execution_graph_identity == execution.execution_graph_identity ||
            throw(ArgumentError("upstream prescription changed during reference calibration"))
        parameter_hashes = Dict(string(name)=>hash for (name,hash) in frontend.parameter_sha256)
        optical_flat_parameters(application) == baseline_hashes ||
            throw(ArgumentError("upstream static command parameters changed during reference calibration"))
        provenance = Dict("upstream_prescription_identity"=>prescription,
            "source_graph_sha256"=>frontend.source_graph_sha256,"parameter_sha256"=>parameter_hashes,
            "raw_endpoint"=>raw_endpoint,"residual_endpoint"=>residual_endpoint,
            "raw_element_type"=>"UInt16","normalization"=>"deployed frontend, twice at held exposure",
            "baseline"=>"flat simulator commands; deployed static command offsets and system flats verified zero",
            "baseline_parameter_sha256"=>baseline_hashes,
            "adc_settings"=>get(configured,"adc",Dict()),"reference_sign"=>-1,
            "effective_settings"=>configured,"effective_settings_identity"=>execution.effective_settings_identity,
            "simulation_configuration_sha256"=>execution.configuration_sha256,"execution_graph"=>execution.graph,
            "execution_graph_identity"=>execution.execution_graph_identity,
            "calibration_graph_identity"=>PipeWireAORTC.InstrumentDefinition.scientific_identity(IC.canonical(graph)),
            "native_sensor_configuration"=>optical_sensor_configuration(graph),
            "modes_to_reference"=>"artifacts/modes-to-reference.fits","shape"=>collect(size(chosen.interaction)),
            "axes"=>[2,1],"type"=>"Float32","storage_order"=>"row-major",
            "trials"=>trials,"scope"=>"finite upstream reference response; upstream controller held")
        if method == "host-expectation"
            merge!(provenance,acquired.report)
            provenance["native_sensor_configuration"] = optical_sensor_configuration(execution.execution_graph)
            provenance["sensor_chain"] = chain
        else
            provenance["method"] = method
        end
        io = IOBuffer()
        write(io,calibration.report["calibration_identity"],"\n",prescription,"\n",frontend.source_graph_sha256,"\n")
        write(io,execution.effective_settings_identity,"\n",execution.execution_graph_identity,"\n",
            provenance["calibration_graph_identity"],"\n")
        write(io,PipeWireAORTC.InstrumentDefinition.scientific_identity(IC.canonical(provenance)),"\n")
        for name in sort!(collect(keys(parameter_hashes)))
            write(io,name,":",parameter_hashes[name],"\n")
        end
        for name in sort!(collect(keys(baseline_hashes)))
            write(io,name,":",baseline_hashes[name],"\n")
        end
        write(io,reinterpret(UInt8,htol.(reinterpret(UInt32,vec(chosen.interaction)))))
        calibration.report["calibration_identity"] = "sha256:"*bytes2hex(Calibration.sha256(take!(io)))
        calibration.report["upstream_reference"] = provenance
        return merge(calibration,(;fast_reference=chosen))
    finally
        FilterGraphIsland.close_execution(frontend.graph)
    end
end

"Write an accepted optical result using the existing row-major FITS bundle writer."
function Calibration.calibrate_optical(calibration, output::AbstractString;
        report::AbstractDict, context::AbstractDict, concrete_graph::AbstractDict, branch::Union{Nothing,Symbol}=nothing)
    calibration.report["status"] == "accepted" || throw(ArgumentError("cannot publish a rejected optical calibration"))
    parameters = Dict{String,Any}("command-projection"=>calibration.projection)
    diagnostics = Dict{String,Any}("pupil-modes"=>calibration.pupil_modes,
        "pupil-support"=>calibration.pupil_support,"mirror-response-rms"=>calibration.normalization,
        "held-out-coefficients"=>calibration.held_out_coefficients,"physical-to-modes"=>calibration.physical_to_modes)
    if hasproperty(calibration,:fast_reference)
        reference = calibration.fast_reference
        diagnostics["modes-to-reference"] = reference.interaction
        diagnostics["half-modes-to-reference"] = reference.half_interaction
        diagnostics["upstream-flat-frame"] = reference.flat_frame
        diagnostics["upstream-flat-residual"] = reference.flat_residual
    end
    branch === nothing || hasproperty(calibration.branches,branch) || throw(ArgumentError("unknown optical bundle branch"))
    for (name,measurement) in pairs(calibration.branches)
        prefix = string(name)*"-"
        if branch === nothing || name === branch
            parameters[prefix*"reconstructor"] = measurement.reconstructor
            parameters[prefix*"modal-reference"] = -(measurement.reconstructor*optical_pixels(measurement.reference,measurement.mask))
            if hasproperty(calibration,:chopped_references) && hasproperty(calibration.chopped_references,name)
                all(iszero,measurement.reference) || throw(ArgumentError("chopped frontend must subtract its exact flat reference before reconstruction"))
                reference = getproperty(calibration.chopped_references,name)
                parameters[prefix*"reference-difference"] = optical_pixels(reference.difference,trues(size(reference.difference)))
                diagnostics[prefix*"flat-fringed"] = reference.fringed
                diagnostics[prefix*"flat-unfringed"] = reference.unfringed
                diagnostics[prefix*"flat-difference"] = reference.difference
            end
        end
        diagnostics[prefix*"reference-image"] = measurement.reference
        diagnostics[prefix*"pixel-mask"] = measurement.mask
        diagnostics[prefix*"interaction-matrix"] = measurement.interaction
        diagnostics[prefix*"half-interaction-matrix"] = measurement.half_interaction
        diagnostics[prefix*"recovery"] = measurement.recovery
        diagnostics[prefix*"singular-values"] = measurement.singular_values
    end
    if branch !== nothing
        mask = getproperty(calibration.branches,branch).mask
        diagnostics["selection-mask"] = mask
        context = deepcopy(context)
        mktempdir() do directory
            path = joinpath(directory,"selection-mask.fits")
            Calibration.write_fits(path,mask)
            context["pixel_selection_mask"] = Dict("kind"=>"fits","path"=>"artifacts/selection-mask.fits",
                "hdu"=>1,"axes"=>[2,1],"shape"=>collect(size(mask)),"type"=>"Bool",
                "sha256"=>Calibration.digest(path),"storage_order"=>"row-major")
        end
    end
    merged = merge(Dict{String,Any}(report),calibration.report)
    return Calibration.write_bundle(output,merged,context,concrete_graph,parameters;diagnostics)
end

function optical_recipe(application, recipe)
    recipe isa AbstractString && !isabspath(recipe) &&
        !PipeWireAORTC.InstrumentExport.outside(normpath(recipe)) ||
        throw(ArgumentError("optical recipe must remain inside its built application"))
    path = PipeWireAORTC.DeploymentConfiguration.relative_asset(application,recipe)
    document = PipeWireAORTC.Common.read_yaml(path)
    required = ("version","kind","upstream_simulation","optical_simulation","mirror","branches",
        "spatial_frequencies","branch_modes","controlled_actuators","pixels","poke_m","tsvd_rtol",
        "derivative_tolerance","reconstruction_tolerance")
    optional = ("upstream_settings","settings","held_out_coefficients","upstream_reference","measurements")
    IC.fields(document,(required...,optional...),required,"optical calibration recipe")
    document["version"] === 1 && document["kind"] == "relative-intensity-optical" ||
        throw(ArgumentError("optical recipe requires version 1 and kind relative-intensity-optical"))
    for key in ("upstream_simulation","optical_simulation","mirror")
        document[key] isa AbstractString && !isempty(strip(document[key])) ||
            throw(ArgumentError("optical recipe $key must be nonempty text"))
    end
    branches = document["branches"]
    branches isa AbstractDict && 1 <= length(branches) <= 8 &&
        all(pair -> pair.first isa String && occursin(r"^[a-z][a-z0-9_]*$",pair.first) &&
            pair.second isa String && !isempty(strip(pair.second)),pairs(branches)) ||
        throw(ArgumentError("optical recipe branches must explicitly name at most eight graph selections"))
    names = Tuple(Symbol.(sort!(collect(keys(branches)))))
    branch_selection = NamedTuple{names}(Tuple(branches[string(name)] for name in names))
    measurements = get(document,"measurements",Dict())
    measurements isa AbstractDict && Set(keys(measurements)) ⊆ Set(keys(branches)) ||
        throw(ArgumentError("measurements must name declared optical branches"))
    for row in values(measurements)
        IC.fields(row,("kind",),("kind",),"optical measurement")
        row["kind"] == "chopped-pixel-residual" || throw(ArgumentError("unsupported optical measurement kind"))
    end
    rows = document["spatial_frequencies"]
    rows isa AbstractVector && 1 <= length(rows) <= 32 &&
        all(row -> row isa AbstractVector && length(row)==2 && all(IC.isfinite_real,row),rows) ||
        throw(ArgumentError("optical recipe requires 1:32 finite two-coordinate spatial frequencies"))
    frequencies = reduce(vcat,permutedims.(Float64.(row) for row in rows))
    all(isfinite,frequencies) && all(row -> any(!iszero,row),eachrow(frequencies)) ||
        throw(ArgumentError("optical spatial frequencies must remain finite Float64 and exclude DC"))
    modes = document["branch_modes"]
    modes isa AbstractDict && Set(keys(modes)) == Set(keys(branches)) ||
        throw(ArgumentError("optical branch_modes must name exactly the selected branches"))
    all(values -> values isa AbstractVector,values(modes)) ||
        throw(ArgumentError("each optical branch_modes selection must be a vector"))
    authority = optical_authority(NamedTuple{names}(Tuple(modes[string(name)] for name in names)),2length(rows))
    for (key,kind) in (("controlled_actuators","declared-pupil"),("pixels","full-image"))
        IC.fields(document[key],("kind",),("kind",),"optical recipe $key")
        document[key]["kind"] == kind || throw(ArgumentError("optical $key currently supports only $kind"))
    end
    for key in ("poke_m","tsvd_rtol","derivative_tolerance","reconstruction_tolerance")
        value = document[key]
        IC.isfinite_real(value) && value > 0 && isfinite(Float32(value)) && Float32(value)>0 ||
            throw(ArgumentError("optical $key must be finite positive Float32"))
        key == "poke_m" || value < 1 || throw(ArgumentError("optical $key must be below one"))
    end
    Float32(document["poke_m"])/2 > 0 || throw(ArgumentError("optical half-poke must remain positive Float32"))
    for key in ("settings","upstream_settings")
        get(document,key,Dict()) isa AbstractDict || throw(ArgumentError("optical $key must be a mapping"))
    end
    held_out = nothing
    if haskey(document,"held_out_coefficients")
        rows = document["held_out_coefficients"]
        rows isa AbstractVector && length(rows) == size(frequencies,1)*2 &&
            all(row -> row isa AbstractVector && 1 <= length(row) <= 32 && all(IC.isfinite_real,row),rows) &&
            length(unique(length.(rows))) == 1 ||
            throw(ArgumentError("held_out_coefficients must be finite mode rows by 1:32 mixtures"))
        held_out = reduce(vcat,permutedims.(Float32.(row) for row in rows))
        all(isfinite,held_out) && all(column -> any(!iszero,column),eachcol(held_out)) ||
            throw(ArgumentError("held-out mixtures must remain finite nonzero Float32"))
    end
    if haskey(document,"upstream_reference")
        reference = document["upstream_reference"]
        IC.fields(reference,("raw_endpoint","residual_endpoint","poke_amplitudes_m","derivative_tolerance",
                "method","samples","rounding_samples","training_seed","validation_seed"),
            ("raw_endpoint","residual_endpoint","poke_amplitudes_m","derivative_tolerance"),"upstream optical reference")
        all(key -> reference[key] isa String && !isempty(strip(reference[key])),
            ("raw_endpoint","residual_endpoint")) || throw(ArgumentError("upstream reference requires exact frontend endpoints"))
        amplitudes = reference["poke_amplitudes_m"]
        amplitudes isa AbstractVector && 1 <= length(amplitudes) <= 8 &&
            all(h -> IC.isfinite_real(h) && isfinite(Float32(h)) && Float32(h)/2>0,amplitudes) ||
            throw(ArgumentError("upstream reference requires 1:8 positive finite poke amplitudes"))
        tolerance = reference["derivative_tolerance"]
        IC.isfinite_real(tolerance) && 0 < tolerance < 1 || throw(ArgumentError("invalid upstream derivative tolerance"))
        method = get(reference,"method","held-frame")
        method in ("held-frame","host-expectation") || throw(ArgumentError("unsupported upstream reference method"))
        if method == "host-expectation"
            length(amplitudes)==1 || throw(ArgumentError("host expectation requires one explicit probe amplitude"))
            optical_expectation_options(get(reference,"samples",512),get(reference,"rounding_samples",128),
                get(reference,"training_seed",200002),get(reference,"validation_seed",400002))
        else
            any(key->haskey(reference,key),("samples","rounding_samples","training_seed","validation_seed")) &&
                throw(ArgumentError("sampling controls require the host-expectation reference method"))
        end
    end
    return (;path,document,branches=branch_selection,branch_modes=authority,frequencies,held_out)
end

function optical_application(application)
    path = PipeWireAORTC.InstrumentExport.checked_path(application)
    for name in ("deployment.conf","instrument.json")
        isfile(joinpath(path,name)) || throw(ArgumentError(
            "optical calibration requires a built application (missing $name)"))
        PipeWireAORTC.DeploymentConfiguration.relative_asset(path,name)
    end
    return path
end

"""
    calibrate_optical(upstream_application, optical_application; recipe="calibration/optical.yaml", target=HostComputeDevice())

Consume two built applications and the bounded version-1 optical recipe in the
optical application. Return `calibration` (including physical `projection` P,
`physical_to_modes` Q and every branch's reconstruction data), `report`, and the
prepared `callbacks`. This preparation result is not a deployable application.
The recipe selects native graphs, explicit declared-pupil physical commands and,
when declared, the retained chopped pixel-residual measurement prefix. Chopped
calibration evaluates matched static F/U roles, not a live acquisition or session.
"""
function Calibration.calibrate_optical(upstream_application::AbstractString,
        optical_application_path::AbstractString; recipe="calibration/optical.yaml",
        target=AdaptiveOpticsSim.Backends.HostComputeDevice(),diagnostic::Bool=false,publication_plan=nothing)
    upstream = optical_application(upstream_application)
    optical = optical_application(optical_application_path)
    Calibration.require_prepared_application(upstream)
    selected = optical_recipe(optical,recipe)
    document = selected.document
    options = PipeWireAORTC.AOSOwner.configuration(joinpath(optical,"simulation.conf"))
    chopping = options.plant.chopping
    Set(keys(get(document,"measurements",Dict()))) == Set(string.(keys(chopping))) ||
        throw(ArgumentError("chopped optical execution requires exactly matching chopped measurement selections"))
    all(name -> getproperty(selected.branches,name) == string(name),keys(chopping)) ||
        throw(ArgumentError("chopped measurements must select their declared physical optical path"))
    if !isempty(chopping) && publication_plan === nothing
        publication_plan = optical_publication_plan(optical,selected;graphs=nothing,
            configuration="calibration/materialize.yaml",prefix=get(ENV,"PIPEWIREAO_PREFIX","/opt/pipewireao"))
    end
    upstream_simulation = PipeWireAORTC.DeploymentConfiguration.relative_asset(upstream,document["upstream_simulation"])
    optical_simulation = PipeWireAORTC.DeploymentConfiguration.relative_asset(optical,document["optical_simulation"])
    recipe_sha256 = Calibration.digest(selected.path)
    haskey(document,"upstream_reference") && optical_flat_parameters(upstream)
    execution = optical_upstream_execution(upstream,upstream_simulation,get(document,"upstream_settings",Dict()))
    callbacks = optical_callbacks(upstream_simulation,optical_simulation;
        mirror=document["mirror"],branches=selected.branches,
        upstream_settings=execution.effective,settings=get(document,"settings",Dict()),target,chopping,publication_plan)
    declaration = execution.declaration
    mirror = declaration.instrument.document["deformable_mirrors"][document["mirror"]]
    get(mirror,"units",nothing) == "m OPD" || throw(ArgumentError("optical mirror commands must declare m OPD"))
    pupil = get(mirror,"pupil",nothing)
    pupil isa AbstractDict && all(key -> haskey(pupil,key) && IC.isfinite_real(pupil[key]),
        ("outer_radius","inner_radius")) && 0 <= pupil["inner_radius"] < pupil["outer_radius"] ||
        throw(ArgumentError("declared-pupil calibration requires explicit inner and outer mirror pupil radii"))
    radius_squared = vec(sum(abs2,callbacks.actuator_coordinates;dims=2))
    controlled = (pupil["inner_radius"]^2 .< radius_squared) .& (radius_squared .<= pupil["outer_radius"]^2)
    images = callbacks.observe(zeros(Float32,size(callbacks.pupil_support)))
    calibration = Calibration.calibrate_optical(callbacks.surface,callbacks.observe;
        actuator_coordinates=callbacks.actuator_coordinates,controlled_actuators=controlled,spatial_frequencies=selected.frequencies,
        pupil_support=callbacks.pupil_support,branch_modes=selected.branch_modes,pixel_masks=map(image->trues(size(image)),images),
        poke_m=document["poke_m"],tsvd_rtol=document["tsvd_rtol"],
        derivative_tolerance=document["derivative_tolerance"],reconstruction_tolerance=document["reconstruction_tolerance"],
        held_out_coefficients=selected.held_out,provenance=callbacks.provenance,require_observable=!diagnostic,
        signed_measurements=keys(chopping))
    calibration = merge(calibration,(;chopped_references=callbacks.chopped_references))
    if !diagnostic && calibration.report["status"] == "accepted" && haskey(document,"upstream_reference")
        reference = document["upstream_reference"]
        method = get(reference,"method","held-frame")
        calibration = Calibration.calibrate_optical_reference(upstream,calibration;
            simulation=document["upstream_simulation"],settings=execution.effective,
            mirror=document["mirror"],raw_endpoint=reference["raw_endpoint"],
            residual_endpoint=reference["residual_endpoint"],poke_amplitudes_m=reference["poke_amplitudes_m"],
            derivative_tolerance=reference["derivative_tolerance"],method,
            samples=get(reference,"samples",512),rounding_samples=get(reference,"rounding_samples",128),
            training_seed=get(reference,"training_seed",200002),validation_seed=get(reference,"validation_seed",400002),
            target=method=="host-expectation" ? AdaptiveOpticsSim.Backends.HostComputeDevice() : target)
    end
    if diagnostic
        calibration.report["deployable"] = false
        calibration.report["upstream_reference_status"] = "not acquired in optical-only diagnostic mode"
    end
    Calibration.digest(selected.path) == recipe_sha256 || throw(ArgumentError("optical recipe changed during calibration"))
    current_execution = optical_upstream_execution(upstream,upstream_simulation,get(document,"upstream_settings",Dict()))
    current_execution.configuration_sha256 == execution.configuration_sha256 &&
        current_execution.effective_settings_identity == execution.effective_settings_identity &&
        current_execution.execution_graph_identity == execution.execution_graph_identity ||
        throw(ArgumentError("upstream executed configuration changed during optical acquisition"))
    for (path,key,settings_key) in ((upstream_simulation,"upstream_prescription_identity","upstream_settings"),
            (optical_simulation,"optical_prescription_identity","settings"))
        current = IC.load_simulation(path)
        overrides = settings_key == "upstream_settings" ? execution.effective : get(document,settings_key,Dict())
        IC.prescription_identity(current,IC.settings(current,overrides)) == callbacks.provenance[key] ||
            throw(ArgumentError("optical calibration prescription changed during acquisition"))
    end
    # Bind the matrix content identity to both prepared prescriptions and the
    # retained exact recipe. Arrays themselves have independent FITS-byte hashes.
    content = calibration.report["calibration_identity"]
    identity = "sha256:"*bytes2hex(Calibration.sha256(join((content,recipe_sha256,
        callbacks.provenance["upstream_prescription_identity"],callbacks.provenance["optical_prescription_identity"],
        execution.effective_settings_identity,execution.execution_graph_identity),"\n")))
    calibration.report["calibration_identity"] = identity
    report = merge(Dict{String,Any}("recipe"=>document,"recipe_sha256"=>recipe_sha256,
        "source_prescription_identity"=>callbacks.provenance["optical_prescription_identity"],
        "upstream_prescription_identity"=>callbacks.provenance["upstream_prescription_identity"],
        "upstream_effective_settings_identity"=>execution.effective_settings_identity,
        "upstream_execution_graph_identity"=>execution.execution_graph_identity,
        "source_graph_sha256"=>Calibration.digest(optical_simulation),
        "built_application_calibration"=>true,"application_accepted"=>false,
        "diagnostic"=>diagnostic,"deployable"=>!diagnostic),calibration.report)
    return (;calibration,report,callbacks)
end

"""
    calibrate_optical(upstream, optical, output; recipe="calibration/optical.yaml", kwargs...)

Calibrate two sealed built applications and publish an ordinary bundle per branch.
By default, `configuration="calibration/materialize.yaml"` selects the retained
branch graph templates. Their contexts are resolved from the actual measured
masks, native sensor contracts and cold RTC dimensions, without bootstrap matrices.
`graphs` may instead supply an explicit branch-to-template path mapping. Existing
callers may still supply both `concrete_graphs` and `contexts` NamedTuples.
Neither preparation nor publication starts a service. Numerical acceptance remains
separate from application and physical-loop qualification.
"""
function Calibration.calibrate_optical(upstream_application::AbstractString,
        optical_application_path::AbstractString, output::AbstractString;
        concrete_graphs=nothing, contexts=nothing, graphs=nothing,
        configuration="calibration/materialize.yaml", recipe="calibration/optical.yaml",
        prefix=get(ENV,"PIPEWIREAO_PREFIX","/opt/pipewireao"),
        target=AdaptiveOpticsSim.Backends.HostComputeDevice())
    destination = Calibration._calibration_output((upstream_application,optical_application_path),output)
    Export = PipeWireAORTC.InstrumentExport
    upstream, _ = Export.sealed_application(upstream_application,prefix)
    optical, _ = Export.sealed_application(optical_application_path,prefix)
    selected = optical_recipe(optical,recipe)
    explicit = concrete_graphs !== nothing || contexts !== nothing
    plan = if explicit
        graphs === nothing || throw(ArgumentError("choose concrete graphs or authored templates"))
        validate_optical_graphs(concrete_graphs,contexts,keys(selected.branches))
        nothing
    else
        optical_publication_plan(optical,selected;graphs,configuration,prefix)
    end
    snapshots = map(path->Calibration.digest(joinpath(path,"deployment.conf")),(upstream,optical))
    result = Calibration.calibrate_optical(upstream,optical;recipe,target,publication_plan=plan)
    for (path,snapshot) in zip((upstream,optical),snapshots)
        Export.sealed_application(path,prefix)
        Calibration.digest(joinpath(path,"deployment.conf")) == snapshot ||
            throw(ArgumentError("built application changed during optical calibration"))
    end
    if !explicit
        prepared = optical_publication_graphs(plan,result.calibration)
        concrete_graphs, contexts = prepared.graphs, prepared.contexts
    end
    return publish_optical_bundles(result,destination,concrete_graphs,contexts)
end
