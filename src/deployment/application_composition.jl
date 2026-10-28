# Compose already-built applications without introducing another runtime authority.
function sealed_application(path, prefix)
    root = checked_path(path)
    spec = D.decode(joinpath(root, "deployment.conf"), prefix)
    D.validate_application(spec, joinpath(root, "deployment.conf"), prefix)
    Set(application_files(root)) == union(Set(keys(spec["artifacts"])), Set(["deployment.conf"])) ||
        throw(ArgumentError("composition inputs must seal every application file"))
    return root, spec
end

function composition_environment(base, component, base_root, component_root)
    get(base, "runtime", nothing) == get(component, "runtime", nothing) ||
        throw(ArgumentError("composed applications require the same runtime declaration"))
    base["environment"] == component["environment"] ||
        throw(ArgumentError("composed application environments differ"))
    runtime = get(base, "runtime", nothing)
    runtime === nothing && return
    project = runtime["project"]
    main = TOML.parsefile(joinpath(base_root, project, "Project.toml"))
    extra = TOML.parsefile(joinpath(component_root, project, "Project.toml"))
    for (name, uuid) in get(extra, "deps", Dict())
        get(get(main, "deps", Dict()), name, nothing) == uuid ||
            throw(ArgumentError("base runtime must supply component dependency $name"))
        get(get(main, "compat", Dict()), name, nothing) == get(get(extra, "compat", Dict()), name, nothing) ||
            throw(ArgumentError("base and component compatibility bounds differ for $name"))
    end
    manifests = [joinpath(root, project, "Manifest.toml") for root in (base_root, component_root)]
    isfile(first(manifests)) == isfile(last(manifests)) ||
        throw(ArgumentError("both composition inputs must have a manifest, or neither"))
    if isfile(first(manifests))
        D.application_environment(base, base_root)
        D.application_environment(component, component_root)
        main_deps, extra_deps = (TOML.parsefile(path)["deps"] for path in manifests)
        for (name, records) in extra_deps
            get(main_deps, name, nothing) == records ||
                throw(ArgumentError("base runtime dependency closure differs for $name"))
        end
    end
end

composition_rebase(value::AbstractString, prefix) = replace(value, "@PACKAGE@/" => "@PACKAGE@/" * prefix * "/")
composition_rebase(value::AbstractVector, prefix) = [composition_rebase(item, prefix) for item in value]
composition_rebase(value::AbstractDict, prefix) = Dict(key => composition_rebase(item, prefix) for (key,item) in value)
composition_rebase(value, prefix) = value

function merge_composition_core(base, component)
    merged = deepcopy(base)
    for (key, value) in component
        if key in ("context.modules", "context.objects")
            target = get!(merged, key, Any[])
            for item in value
                item in target && continue
                if key == "context.modules"
                    name = get(item, "name", nothing)
                    name == "libpipewire-module-queue" ||
                        all(existing -> get(existing,"name",nothing) != name, target) ||
                        throw(ArgumentError("conflicting native core module $name"))
                else
                    node = get(get(item,"args",Dict()),"node.name",nothing)
                    node === nothing || all(existing -> get(get(existing,"args",Dict()),"node.name",nothing) != node, target) ||
                        throw(ArgumentError("conflicting native core node $node"))
                end
                push!(target, deepcopy(item))
            end
        elseif key == "context.properties"
            target = get!(merged, key, Dict{String,Any}())
            for (property, setting) in value
                if property == "context.data-loops"
                    loops = get!(target, property, Any[])
                    for loop in setting
                        matching = filter(item -> item["loop.name"] == loop["loop.name"], loops)
                        isempty(matching) ? push!(loops, deepcopy(loop)) :
                            only(matching) == loop || throw(ArgumentError("conflicting native data loop"))
                    end
                else
                    !haskey(target, property) || target[property] == setting ||
                        throw(ArgumentError("conflicting core property $property"))
                    target[property] = deepcopy(setting)
                end
            end
        else
            !haskey(merged, key) || merged[key] == value ||
                throw(ArgumentError("conflicting core configuration $key"))
            merged[key] = deepcopy(value)
        end
    end
    return merged
end

function merge_composition_session(base, component, links)
    merged = deepcopy(base)
    sections = ("sources", "graphs", "sinks", "links", "observations")
    for (key, value) in component
        if key in sections
            append!(get!(merged, key, Any[]), deepcopy(value))
        elseif key == "parameters"
            target = get!(merged, key, Dict{String,Any}())
            isempty(intersect(Set(keys(target)), Set(keys(value)))) ||
                throw(ArgumentError("component parameter names collide"))
            merge!(target, deepcopy(value))
        else
            !haskey(merged, key) || merged[key] == value ||
                throw(ArgumentError("conflicting session configuration $key"))
            merged[key] = deepcopy(value)
        end
    end
    names = [item["node.name"] for section in ("sources", "graphs", "sinks") for item in get(merged, section, [])]
    length(unique(names)) == length(names) || throw(ArgumentError("component node names collide"))
    links isa AbstractVector || throw(ArgumentError("composition links must be a list"))
    append!(get!(merged, "links", Any[]), deepcopy(links))
    return merged
end

# Opaque/undeclared ports retain existing admission. Compare only fields both
# endpoints explicitly declare; matching data does not prove native negotiation.
function validate_composition_links(session, links)
    nodes=Dict(node["node.name"]=>node for section in ("sources","graphs","sinks") for node in get(session,section,[]))
    function declared(endpoint, direction)
        endpoint isa AbstractString || return nothing
        parts=split(endpoint,':';keepempty=true)
        length(parts)==2 || return nothing
        node=get(nodes,first(parts),nothing)
        node===nothing && return nothing
        matches=filter(port->get(port,"name",nothing)==last(parts) && get(port,"direction",nothing)==direction,
            get(node,"ports",[]))
        return isempty(matches) ? nothing : only(matches)
    end
    for link in links
        output=declared(link["output"],"output")
        input=declared(link["input"],"input")
        (output===nothing || input===nothing) && continue
        for field in ("shape","element-type","layout","schema")
            if haskey(output,field) && haskey(input,field)
                output[field]==input[field] || throw(ArgumentError(
                    "composition link $field mismatch: $(link["output"]) → $(link["input"])"))
            end
        end
    end
    return nothing
end

"""
    compose(base, component, fresh_output; namespace, roles, links, overrides, owner_arguments, prefix)

Compose two fully sealed built applications under the base application's native
core and session authority. `roles` maps every component owner to a distinct role;
`links` declares cross-application links. Nonempty `overrides` explicitly maps
base-relative graph, parameter and configuration assets to prepared files. No
process is launched, and the component application remains unchanged beneath
`components/namespace`. The final seal binds both input receipts and overrides.
Optional `owner_arguments` maps existing base owner roles to complete, explicitly
prepared argument vectors; normal bootstrap validation also applies to replacements.
"""
function compose(base::AbstractString, component::AbstractString, destination::AbstractString;
        namespace::AbstractString, roles::AbstractDict, links::AbstractVector,
        overrides::AbstractDict, prefix::AbstractString, owner_arguments::AbstractDict=Dict(),
        sinks::AbstractVector=Any[], node_owners::AbstractDict=Dict())
    occursin(r"^[a-z][a-z0-9-]{0,31}$", namespace) || throw(ArgumentError("invalid component namespace"))
    isempty(overrides) && throw(ArgumentError("composition requires explicit prepared graph/configuration overrides"))
    base_root, main = sealed_application(base, prefix)
    component_root, extra = sealed_application(component, prefix)
    composition_environment(main, extra, base_root, component_root)
    isempty(get(extra, "analysis", [])) || throw(ArgumentError("component analysis processes are not supported"))
    Set(keys(roles)) == Set(owner["role"] for owner in extra["owners"]) ||
        throw(ArgumentError("roles must map every component owner exactly once"))
    target_roles = collect(values(roles))
    all(role -> role isa String && occursin(r"^[a-z][a-z0-9-]{0,31}$", role), target_roles) &&
        length(unique(target_roles)) == length(target_roles) &&
        isempty(intersect(Set(target_roles), Set(keys(main["placement"])))) ||
        throw(ArgumentError("component owner roles must be distinct and new"))
    get(extra, "source-owner", nothing) isa String || throw(ArgumentError("component requires a declared source owner"))
    Set(keys(owner_arguments)) ⊆ Set(owner["role"] for owner in main["owners"]) ||
        throw(ArgumentError("owner_arguments may replace only existing base owner argument vectors"))
    all(arguments -> arguments isa AbstractVector && all(arg -> arg isa String, arguments), values(owner_arguments)) ||
        throw(ArgumentError("owner_arguments must map roles to complete string argument vectors"))
    Set(keys(node_owners)) == Set(sink["node.name"] for sink in sinks) &&
        all(role -> role in (owner["role"] for owner in main["owners"]),values(node_owners)) ||
        throw(ArgumentError("additional sinks require exact existing base owner roles"))
    output = checked_path(destination)
    !ispath(output) || throw(ArgumentError("composition output must be fresh"))
    # Validate override paths before copying either application.
    selected = Dict{String,String}()
    runtime_files = haskey(main,"runtime") ? Set(normpath(joinpath(main["runtime"]["project"],file))
        for file in ("Project.toml","Manifest.toml")) : Set{String}()
    for (relative, source) in overrides
        relative isa String && !(relative in ("", ".", "..")) && !isabspath(relative) && normpath(relative) == relative &&
            !outside(relative) && !(relative in ("deployment.conf", "instrument.json", "Project.toml", "Manifest.toml")) &&
            !(relative in (main["session"], main["core"], get(main, "instrument", nothing))) &&
            !(relative in runtime_files) &&
            !startswith(relative, "components/") && !startswith(relative, "composition/") ||
            throw(ArgumentError("invalid composition override path"))
        !isdir(joinpath(base_root,relative)) || throw(ArgumentError("composition overrides cannot replace directories"))
        source isa AbstractString && isfile(source) && !islink(source) ||
            throw(ArgumentError("composition override must name a regular prepared file"))
        selected[relative] = abspath(source)
    end
    mkpath(dirname(output))
    mktempdir(dirname(output); prefix=".compose-") do staging
        package = joinpath(staging, "application")
        cp(base_root, package)
        component_prefix = "components/" * namespace
        mkpath(dirname(joinpath(package, component_prefix)))
        cp(component_root, joinpath(package, component_prefix))
        mkpath(joinpath(package, "composition"))
        cp(joinpath(base_root, "deployment.conf"), joinpath(package, "composition", "base-deployment.conf"))
        spec = deepcopy(main)
        runtime_project = haskey(spec,"runtime") ? normpath(spec["runtime"]["project"]) : "."
        shared_project = runtime_project=="." ? "@PACKAGE@" : "@PACKAGE@/"*runtime_project
        for owner in spec["owners"]
            haskey(owner_arguments, owner["role"]) && (owner["argv"] = deepcopy(owner_arguments[owner["role"]]))
        end
        for original in extra["owners"]
            owner = composition_rebase(original, component_prefix)
            old_role = original["role"]
            owner["role"] = roles[old_role]
            # The one shared registered runtime supplies both applications.
            owner["argv"] = [arg in ("--project="*shared_project,shared_project) ? arg :
                composition_rebase(arg, component_prefix) for arg in original["argv"]]
            owner["argv"] = replace.(owner["argv"],
                "@" * D.bootstrap_instance_key(old_role) * "@" => "@" * D.bootstrap_instance_key(owner["role"]) * "@")
            if D.native_bootstrap(owner)
                old_node = original["bootstrap-node"]
                owner["bootstrap-node"] = namespace * "." * old_node
                owner["argv"] = [arg == old_node ? owner["bootstrap-node"] : arg for arg in owner["argv"]]
            end
            push!(spec["owners"], owner)
            spec["placement"][owner["role"]] = deepcopy(extra["placement"][old_role])
            spec["client"][owner["role"]] = component_prefix * "/" * extra["client"][old_role]
        end
        auxiliary = get!(spec, "auxiliary-source-owners", String[])
        append!(auxiliary, [roles[role] for role in vcat([extra["source-owner"]], get(extra, "auxiliary-source-owners", String[]))])
        mapping = get!(spec, "node-owners", Dict{String,String}())
        for (node, role) in extra["node-owners"]
            haskey(mapping, node) && throw(ArgumentError("component node owner names collide"))
            haskey(roles, role) || throw(ArgumentError("component nodes must belong to its external owners"))
            mapping[node] = roles[role]
        end
        for (node,role) in node_owners
            haskey(mapping,node) && throw(ArgumentError("additional sink owner names collide"))
            mapping[node] = role
        end
        session = merge_composition_session(D.decode(joinpath(base_root, main["session"]), prefix),
            composition_rebase(D.decode(joinpath(component_root, extra["session"]), prefix), component_prefix), links)
        existing_nodes = Set(item["node.name"] for section in ("sources","graphs","sinks") for item in get(session,section,[]))
        isempty(intersect(existing_nodes,Set(keys(node_owners)))) || throw(ArgumentError("additional sink names collide"))
        append!(get!(session,"sinks",Any[]),deepcopy(sinks))
        validate_composition_links(session,links)
        core = merge_composition_core(D.decode(joinpath(base_root, main["core"]), prefix),
            composition_rebase(D.decode(joinpath(component_root, extra["core"]), prefix), component_prefix))
        for (relative, source) in selected
            target = joinpath(package, relative)
            mkpath(dirname(target)); cp(source, target; force=true)
        end
        ScienceExport.write_spa_config(joinpath(package, spec["session"]), session)
        ScienceExport.write_spa_config(joinpath(package, spec["core"]), core)
        Common.write_yaml(joinpath(package, "composition", "receipt.yaml"), Dict(
            "version"=>1, "namespace"=>namespace, "roles"=>Dict(roles), "links"=>links,
            "owner_arguments"=>Dict(owner_arguments),
            "sinks"=>sinks,"node_owners"=>Dict(node_owners),
            "base_deployment_sha256"=>Common.sha256_file(joinpath(base_root,"deployment.conf")),
            "component_deployment_sha256"=>Common.sha256_file(joinpath(component_root,"deployment.conf")),
            "overrides"=>Dict(relative=>Common.sha256_file(source) for (relative,source) in selected));
            header="Generated by PipeWireAORTC.InstrumentExport.compose from sealed built applications.")
        Common.write_json(joinpath(package, "deployment.conf"), spec)
        seal!(package)
        sealed_spec = Common.read_json(joinpath(package,"deployment.conf"))
        D.validate_application(sealed_spec, joinpath(package,"deployment.conf"), prefix)
        D.registered_application(sealed_spec) && D.application_environment(sealed_spec,package)
        mv(package, output)
    end
    return output
end
