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
    for spec in values(declaration.document["deformable_mirrors"])
        push!(paths,spec["description"])
        for basis in spec["shape_control"]["bases"]
            definition = basis["definition"]
            definition["kind"] == "sampled" && push!(paths,definition["artifact"]["path"])
        end
    end
    for spec in values(declaration.document["wavefront_sensors"])
        push!(paths,spec["subaperture_origins"]["path"])
    end
    for name in selected_binding_names(declaration,configured)
        binding = declaration.document["bindings"][name]
        get(binding,"kind",nothing)=="fits" && push!(paths,binding["path"])
        get(binding,"kind",nothing)=="measured_influences" &&
            push!(paths,setting(configured,binding["setting"])["path"])
    end
    return paths
end

function prescription_identity(declaration,configured)
    schema = settings_description(declaration,configured)["schema"]
    structural = Dict(key=>configured[key] for (key,field) in schema["properties"]
        if get(field,"readOnly",false))
    graph_hashes = Dict(name=>Common.sha256_file(D.relative_asset(declaration.directory,path))
        for (name,path) in declaration.document["graphs"])
    assets = Dict{String,String}()
    for path in artifact_paths(declaration,configured)
        file = D.relative_asset(declaration.directory,path)
        filesize(file) <= Artifacts.MAX_FITS_BYTES || throw(ArgumentError("instrument artifact exceeds 512 MiB"))
        assets[path] = Common.sha256_file(file)
    end
    body = (;declaration=canonical(declaration.document),graphs=canonical(graph_hashes),
        settings=canonical(structural),artifacts=canonical(assets))
    return InstrumentDefinition.scientific_identity(body)
end

function sensor_layout(declaration,spec)
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
    return (; detector_shape, subaperture_shape=shape, subaperture_origins=positions,
        provenance=spec["provenance"])
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

"Resolve immutable geometry and scientific identities without preparing a frame."
function scientific_definition(path::AbstractString,overrides=NamedTuple())
    declaration = load(path)
    configured = settings(declaration,overrides)
    mirror_keys = sort!(collect(keys(declaration.document["deformable_mirrors"])))
    mirror_names = Tuple(Symbol.(mirror_keys))
    mirrors = map(mirror_keys) do name
        spec = declaration.document["deformable_mirrors"][name]
        geometry = mirror(declaration,configured,name)
        description,registration = geometry.description,geometry.registration
        source = source_grid_coordinates(description)
        coordinates = actuator_coordinates(description; pupil_registration=registration)
        bases = Tuple(resolve_basis(declaration,basis,description,source) for basis in spec["shape_control"]["bases"])
        InstrumentDefinition.validate_shape_control(json_value((;bases)),spec["units"],length(description.layout.command_positions))
        result = (; layout=description.layout,shape_control=(;bases),pupil_registration=registration,
            pupil_coordinates=Tuple(Tuple(column) for column in eachcol(coordinates)))
        active = selected_binding_names(declaration,configured)
        bindings = [binding for (binding_name,binding) in declaration.document["bindings"]
            if binding_name in active && get(binding,"kind",nothing)=="measured_influences" &&
                get(binding,"mirror",nothing)==name]
        length(bindings)<=1 || throw(ArgumentError("mirror declares multiple selected influence calibrations"))
        if !isempty(bindings)
            result = merge(result,(;influence_functions=measured_influences(declaration,configured,only(bindings)).provenance))
        end
        return result
    end
    sensor_keys = sort!(collect(keys(declaration.document["wavefront_sensors"])))
    sensor_names = Tuple(Symbol.(sensor_keys))
    sensors = Tuple((;layout=sensor_layout(declaration,declaration.document["wavefront_sensors"][name])) for name in sensor_keys)
    return (; schema_version=1,id=declaration.document["id"],
        deformable_mirrors=NamedTuple{mirror_names}(Tuple(mirrors)),
        wavefront_sensors=NamedTuple{sensor_names}(sensors),
        prescription_identity=prescription_identity(declaration,configured))
end

limit_values(value::Real,count) = ntuple(_->Float64(value),count)
limit_values(value::AbstractVector,count) = length(value)==count ? Tuple(value) :
    throw(DimensionMismatch("mirror limits must be command-sized"))
limit_values(value,count) = throw(ArgumentError("mirror limits must be numeric scalars or arrays"))

"Materialize the RTC's existing sealed publication from the authoring declaration."
function publication(path,overrides;calibration_identity)
    declaration = load(path)
    scientific = scientific_definition(path,overrides)
    mirrors = NamedTuple{keys(scientific.deformable_mirrors)}(Tuple(
        map(keys(scientific.deformable_mirrors)) do name
            spec = declaration.document["deformable_mirrors"][String(name)]
            dm = getproperty(scientific.deformable_mirrors,Symbol(name))
            n = length(dm.layout.command_positions)
            return (;layout=dm.layout,units=spec["units"],command_scale_m=spec["command_scale_m"],
                pupil_coordinates=dm.pupil_coordinates,
                limiter=(;kind=spec["limiter"]["kind"],
                    lower=limit_values(spec["limiter"]["lower"],n),upper=limit_values(spec["limiter"]["upper"],n)),
                shape_control=dm.shape_control)
        end))
    sensors = NamedTuple{keys(scientific.wavefront_sensors)}(Tuple(
        (;layout=merge(getproperty(scientific.wavefront_sensors,Symbol(name)).layout,
            (;expected_schema=declaration.document["wavefront_sensors"][String(name)]["expected_schema"])))
        for name in keys(scientific.wavefront_sensors)))
    result = (;schema_version=2,id=scientific.id,calibration_identity,
        scientific_identity=InstrumentDefinition.scientific_identity(scientific),
        deformable_mirrors=mirrors,wavefront_sensors=sensors)
    InstrumentDefinition.validate(json_value(result))
    return result
end

function prepare_publication(application::AbstractString;simulation="simulation.conf")
    config = D.decode(D.relative_asset(application,simulation),get(ENV,"PIPEWIREAO_PREFIX","/opt/pipewireao"))
    config["version"] == 3 || throw(ArgumentError("declarative instrument publication requires simulator version 3"))
    plant = config["plant"]
    path = D.relative_asset(application,plant["definition"])
    output = joinpath(application,config["instrument"])
    abspath(output) == abspath(path) && throw(ArgumentError("instrument publication must differ from its authoring declaration"))
    body = publication(path,plant["settings"]; calibration_identity=config["calibration_identity"])
    # Validate the output location even on first generation.
    isabspath(config["instrument"]) && throw(ArgumentError("publication must be application-relative"))
    startswith(abspath(output),realpath(application)*"/") || throw(ArgumentError("publication escapes application"))
    ncodeunits(JSON.json(body)) + 1 <= InstrumentDefinition.MAX_BYTES ||
        throw(ArgumentError("instrument publication exceeds 256 KiB"))
    Common.write_json(output,body;atomic=true)
    return output
end
