# Scientific metadata and provenance are resolved from the same declaration
# used to prepare the plant; operator views contain only references to it.
canonical(value::AbstractDict) = NamedTuple{Tuple(Symbol.(sort!(collect(keys(value)))))}(
    Tuple(canonical(value[key]) for key in sort!(collect(keys(value)))))
canonical(value::AbstractVector) = Tuple(canonical(item) for item in value)
canonical(value) = value

function selected_binding_names(declaration,configured)
    names = Set{String}()
    for calibration in (false,true)
        graph = graph_document(declaration,configured;calibration)
        for (section,field) in (("inputs","binding"),("parameters","binding"),("delayed_links","initial"))
            for entry in get(graph,section,[])
                push!(names,entry[field])
            end
        end
    end
    return names
end

function artifact_paths(declaration,configured)
    paths = Set{String}()
    for spec in values(declaration.instrument.document["deformable_mirrors"])
        push!(paths,spec["description"])
    end
    for spec in values(declaration.instrument.document["wavefront_sensors"])
        union!(paths,sensor_artifact_paths(sensor_kind(spec),spec))
    end
    for name in selected_binding_names(declaration,configured)
        binding = declaration.document["bindings"][name]
        get(binding,"kind",nothing)=="fits" && push!(paths,binding["path"])
        get(binding,"kind",nothing)=="measured_influences" &&
            push!(paths,setting(configured,binding["setting"])["path"])
    end
    return paths
end

sensor_artifact_paths(::Val{:shack_hartmann},spec) = (spec["subaperture_origins"]["path"],)
sensor_artifact_paths(::Val{:pyramid},spec) = ()

graph_source_identity(directory, source::AbstractString) = Common.sha256_file(D.relative_asset(directory, source))
graph_source_identity(directory, source::AbstractDict) = InstrumentDefinition.scientific_identity(canonical(source))

# Hash selected settings catalogs as well as their resolved declarations. A
# catalog change after loading must also change startup prescription identity.
simulation_catalog_name(value::AbstractString) = String(value)
simulation_catalog_name(value::AbstractDict) = simulation_catalog_selector(get(value, "template", nothing))
simulation_catalog_name(value) = nothing
simulation_catalog_selector(value::AbstractString) = String(value)
simulation_catalog_selector(value) = nothing

function simulation_catalog_identities(authoring)
    identities = Dict{String,String}()
    selections = Any[get(authoring, "settings_schema", nothing)]
    append!(selections, (get(profile, "settings_schema", nothing) for profile in values(authoring["profiles"])))
    any(profile -> get(profile, "template", nothing) == "measured", values(authoring["profiles"])) &&
        push!(selections, "measured_influences")
    for selection in selections
        name = simulation_catalog_name(selection)
        name === nothing && continue
        catalog_document("simulation", name) # validate the bounded catalog name/path
        path = joinpath(@__DIR__, "..", "..", "data", "simulation", name * ".yaml")
        identities[name] = Common.sha256_file(path)
    end
    return identities
end

function prescription_identity(declaration,configured)
    schema = settings_description(declaration,configured)["schema"]
    structural = Dict(key=>configured[key] for (key,field) in schema["properties"]
        if get(field,"readOnly",false))
    graph_hashes = Dict(name=>graph_source_identity(declaration.directory, source)
        for (name,source) in declaration.document["graphs"])
    templates = Dict(name=>Common.sha256_file(component_template_path(name)) for name in declaration.templates)
    catalogs = simulation_catalog_identities(declaration.authoring)
    assets = Dict{String,String}()
    for path in artifact_paths(declaration,configured)
        file = mirror_description_path(declaration.directory,path)
        filesize(file) <= Artifacts.MAX_FITS_BYTES || throw(ArgumentError("instrument artifact exceeds 512 MiB"))
        assets[path] = Common.sha256_file(file)
    end
    body = (;instrument=canonical(declaration.instrument.document),
        simulation=canonical(declaration.document),graphs=canonical(graph_hashes),
        resolved_graphs=canonical(declaration.graphs),templates=canonical(templates),catalogs=canonical(catalogs),
        settings=canonical(structural),artifacts=canonical(assets))
    return InstrumentDefinition.scientific_identity(body)
end

sensor_layout(declaration,spec) = sensor_layout(sensor_kind(spec),declaration,spec)
sensor_layout(::Val{:pyramid},declaration,spec) = merge((;kind="pyramid"),pyramid_geometry(spec))

function sensor_layout(::Val{:shack_hartmann},declaration,spec)
    source = spec["subaperture_origins"]
    shape = Tuple(spec["subaperture_shape"])
    detector_shape = Tuple(spec["detector_shape"])
    # The artifact holds ordered [row,column] origins; its axis permutation
    # is explicit and independent of the detector's image-axis convention.
    artifact = Artifacts.FITSArtifact(D.relative_asset(declaration.directory,source["path"]);
        hdu=source["hdu"],axes=source["axes"])
    T = get(Dict(string(T)=>T for T in Artifacts.TARGET_TYPES),source["type"],nothing)
    T === nothing && throw(ArgumentError("unknown subaperture origin element type"))
    source_shape = Tuple(source["shape"])
    origins = Artifacts.prepare(artifact,T,source_shape).data
    size(origins,2) == 2 || throw(DimensionMismatch("subaperture origins require [row,column] columns"))
    positions = Tuple((Int(origins[i,1]),Int(origins[i,2])) for i in axes(origins,1))
    length(unique(positions)) == length(positions) || throw(ArgumentError("duplicate subaperture origin"))
    all(p -> all(axis -> 0 <= p[axis] && p[axis]+shape[axis] <= detector_shape[axis],1:2),positions) ||
        throw(ArgumentError("subaperture region lies outside the detector"))
    return (; detector_shape, subaperture_shape=shape, subaperture_origins=positions)
end

function resolve_basis(declaration, basis, description, source)
    definition = basis["definition"]
    kind = definition["kind"]
    resolved = if kind == "zernike"
        (;kind,positions=source.zernike_positions,modes=_instrument_seal(definition["modes"]))
    elseif kind == "fourier"
        columns,rows = description.layout.grid_shape
        cap = definition["max_frequency"]
        max_x,max_y = min(cap,max(0,(columns-2)÷2)),min(cap,max(0,(rows-2)÷2))
        # Bound the descriptor before constructing it; never truncate a basis.
        count = max_x + max_y * (2 * max_x + 1)
        1 <= count <= 256 || throw(ArgumentError("Fourier basis requires 1:256 frequencies; reduce max_frequency"))
        frequencies = Tuple((x,y) for y in 0:max_y for x in -max_x:max_x if y > 0 || x > 0)
        (;kind,positions=source.fourier_positions,frequencies,axis_units="cycles / source axis")
    else
        artifact = definition["artifact"]
        shape = Tuple(artifact["shape"])
        shape[1] == length(description.layout.command_positions) || throw(DimensionMismatch("sampled basis artifact rows must match mirror command count"))
        T = only(T for T in Artifacts.TARGET_TYPES if string(T) == artifact["type"])
        selected = Artifacts.FITSArtifact(D.relative_asset(declaration.directory,artifact["path"]);
            hdu=artifact["hdu"],axes=artifact["axes"])
        prepared = Artifacts.prepare(selected,T,shape)
        # Published samples are Float32 and dimensionless. The declared row
        # order is already mirror command order; no remapping or normalization.
        modes = Tuple((;name,values=Tuple(Float32.(view(prepared.data,:,column))))
            for (column,name) in enumerate(definition["names"]))
        (;kind,modes,artifact_sha256=prepared.provenance["original_sha256"])
    end
    return merge(_instrument_seal(basis),(;definition=resolved))
end

"Resolve immutable physical geometry without a simulator or RTC control definition."
function physical_definition(declaration)
    document = declaration.document
    mirror_keys = sort!(collect(keys(document["deformable_mirrors"])))
    mirrors = map(mirror_keys) do name
        geometry = mirror(declaration,NamedTuple(),name)
        description,registration = geometry.description,geometry.registration
        coordinates = actuator_coordinates(description; pupil_registration=registration)
        return (;layout=description.layout,pupil_registration=registration,
            pupil_coordinates=Tuple(Tuple(column) for column in eachcol(coordinates)))
    end
    sensor_keys = sort!(collect(keys(document["wavefront_sensors"])))
    sensors = Tuple((;layout=sensor_layout(declaration,document["wavefront_sensors"][name])) for name in sensor_keys)
    telescope = haskey(document,"telescope") ? (;telescope=_instrument_seal(document["telescope"])) : NamedTuple()
    return (;telescope...,schema_version=1,id=document["id"],
        deformable_mirrors=NamedTuple{Tuple(Symbol.(mirror_keys))}(Tuple(mirrors)),
        wavefront_sensors=NamedTuple{Tuple(Symbol.(sensor_keys))}(sensors))
end

"Resolve simulation geometry and prescription identity independently of RTC mirror controls."
function scientific_definition(path::AbstractString,overrides=NamedTuple())
    declaration = load_simulation(path)
    configured = settings(declaration,overrides)
    result = physical_definition(declaration.instrument)
    mirrors = map(keys(result.deformable_mirrors)) do name
        geometry = getproperty(result.deformable_mirrors,name)
        active = selected_binding_names(declaration,configured)
        bindings = [binding for (binding_name,binding) in declaration.document["bindings"]
            if binding_name in active && get(binding,"kind",nothing)=="measured_influences" &&
                get(binding,"mirror",nothing)==String(name)]
        length(bindings)<=1 || throw(ArgumentError("mirror declares multiple selected influence calibrations"))
        return isempty(bindings) ? geometry : merge(geometry,
            (;influence_functions=measured_influences(declaration,configured,only(bindings)).provenance))
    end
    result = merge(result,(;deformable_mirrors=NamedTuple{keys(result.deformable_mirrors)}(Tuple(mirrors))))
    if hasproperty(result,:telescope)
        result = merge(result,(;telescope=merge(result.telescope,(;resolution=configured["pupil_resolution"]))))
    end
    return merge(result,(;prescription_identity=prescription_identity(declaration,configured)))
end

limit_values(value::Real,count) = ntuple(_->Float64(value),count)
limit_values(value::AbstractVector,count) = length(value)==count ? Tuple(value) :
    throw(DimensionMismatch("mirror limits must be command-sized"))
limit_values(value,count) = throw(ArgumentError("mirror limits must be numeric scalars or arrays"))

"Materialize the RTC publication from physical geometry and RTC-owned mirror controls."
function publication(path)
    declaration = load_rtc(path)
    calibration_identity = declaration.document["calibration_identity"]
    scientific = physical_definition(declaration.instrument)
    mirrors = NamedTuple{keys(scientific.deformable_mirrors)}(Tuple(
        map(keys(scientific.deformable_mirrors)) do name
            spec = declaration.instrument.document["deformable_mirrors"][String(name)]
            control = declaration.controls["deformable_mirrors"][String(name)]
            dm = getproperty(scientific.deformable_mirrors,name)
            description = mirror(declaration,NamedTuple(),String(name)).description
            source = source_grid_coordinates(description)
            bases = Tuple(resolve_basis(declaration,basis,description,source) for basis in control["shape_control"]["bases"])
            n = length(dm.layout.command_positions)
            controlled = if haskey(control["shape_control"],"controlled_actuators")
                Base.require(Main,:FilterGraphIsland)
                Base.invokelatest(controlled_actuators,declaration,control["shape_control"]["controlled_actuators"],n)
            else
                ntuple(_ -> true,n)
            end
            shape_control = (;bases,controlled_actuators=controlled)
            InstrumentDefinition.validate_shape_control(json_value(shape_control),spec["units"],n)
            pupil = hasproperty(scientific,:telescope) && hasproperty(scientific.telescope,:central_obstruction_ratio) ?
                (;pupil=(;outer_radius=1.0,inner_radius=scientific.telescope.central_obstruction_ratio)) : NamedTuple()
            return (;layout=dm.layout,units=spec["units"],command_scale_m=spec["command_scale_m"],
                pupil_coordinates=dm.pupil_coordinates,
                pupil...,
                limiter=(;kind=control["limiter"]["kind"],
                    lower=limit_values(control["limiter"]["lower"],n),upper=limit_values(control["limiter"]["upper"],n)),
                shape_control)
        end))
    sensors = NamedTuple{keys(scientific.wavefront_sensors)}(Tuple(
        (;layout=merge(getproperty(scientific.wavefront_sensors,name).layout,
            (;expected_schema=declaration.instrument.document["wavefront_sensors"][String(name)]["expected_schema"])))
        for name in keys(scientific.wavefront_sensors)))
    identity = InstrumentDefinition.scientific_identity((;physical=scientific,mirrors))
    result = (;schema_version=2,id=scientific.id,calibration_identity,
        scientific_identity=identity,deformable_mirrors=mirrors,wavefront_sensors=sensors)
    InstrumentDefinition.validate(json_value(result))
    return result
end

"Resolve simulator references in a copied application before its existing parser runs."
function prepare_simulation_configuration!(application::AbstractString; simulation="simulation.conf", configuration=nothing)
    path = D.relative_asset(application, simulation)
    source = D.decode(path, get(ENV, "PIPEWIREAO_PREFIX", "/opt/pipewireao"))
    source["version"] == 3 || throw(ArgumentError("declarative instrument publication requires simulator version 3"))
    plant = source["plant"]
    declaration = load_simulation(D.relative_asset(application, plant["definition"]))
    configured = settings(declaration, get(plant, "settings", Dict()))
    source["rtc_configuration"] = something(configuration, source["rtc_configuration"])
    rtc = load_rtc(D.relative_asset(application, source["rtc_configuration"]))
    rtc.instrument.path == declaration.instrument.path ||
        throw(ArgumentError("simulation and RTC must reference the same physical instrument"))
    context = configuration_context(declaration, configured)
    context["rtc"] = rtc.document
    concrete = Common.configuration_value(source, context)
    concrete["instrument"] = rtc.document["publication"]
    concrete["calibration_identity"] = rtc.document["calibration_identity"]
    concrete["prescription_identity"] = prescription_identity(declaration, configured)
    if concrete != source
        temporary, io = mktemp(dirname(path))
        try
            write(io, "# Generated by PipeWireAORTC from instrument configuration.\n", JSON.json(concrete), "\n")
            close(io)
            mv(temporary, path; force=true)
        finally
            isopen(io) && close(io)
            ispath(temporary) && rm(temporary)
        end
    end
    return concrete
end

function prepare_publication(application::AbstractString; configuration="rtc/configuration.yaml")
    path = D.relative_asset(application, configuration)
    rtc = load_rtc(path)
    name = rtc.document["publication"]
    !isabspath(name) && endswith(name,".json") ||
        throw(ArgumentError("publication must be an application-relative .json file distinct from authoring inputs"))
    output = abspath(joinpath(application,name))
    startswith(output,realpath(application)*"/") && !islink(output) || throw(ArgumentError("publication escapes application"))
    protected = Set([path, rtc.instrument.path, D.relative_asset(application, rtc.document["mirror_controls"])])
    for mirror in values(rtc.instrument.document["deformable_mirrors"])
        push!(protected,mirror_description_path(application,mirror["description"]))
    end
    for sensor in values(rtc.instrument.document["wavefront_sensors"])
        for asset in sensor_artifact_paths(sensor_kind(sensor), sensor)
            push!(protected, D.relative_asset(application, asset))
        end
    end
    haskey(rtc.document, "calibration") && push!(protected, D.relative_asset(application, rtc.document["calibration"]))
    for control in values(rtc.controls["deformable_mirrors"])
        shape=control["shape_control"]
        haskey(shape,"controlled_actuators") || continue
        for field in ("graph","bindings")
            push!(protected,D.relative_asset(application,shape["controlled_actuators"][field]))
        end
    end
    for control in values(rtc.controls["deformable_mirrors"]), basis in control["shape_control"]["bases"]
        definition = basis["definition"]
        definition["kind"] == "sampled" && push!(protected,D.relative_asset(application,definition["artifact"]["path"]))
    end
    output in protected && throw(ArgumentError("publication must differ from its authoring inputs"))
    body = publication(path)
    ncodeunits(JSON.json(body)) + 1 <= InstrumentDefinition.MAX_BYTES ||
        throw(ArgumentError("instrument publication exceeds 1 MiB"))
    Common.write_json(output,body;atomic=true)
    return output
end
