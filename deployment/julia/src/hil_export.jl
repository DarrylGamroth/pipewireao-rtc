module HILExport

using SHA
using TOML
using JSON3
using ..Common
using ..Deployment
using ..ScienceExport
import ..NativeControlClient, ..NativeOwnerBootstrapCodec

const PACKAGE_UUIDS = Dict(
    "AdaptiveOpticsCalibration" => "3c8b5851-926e-4ebb-af30-f8544b98d45f",
    "AdaptiveOpticsSim" => "002fb5eb-ad68-44a0-adbe-b299bfc2febc",
    "AdaptiveOpticsSimPipeWireHIL" => "355e2bce-7765-4934-ac1c-873e1c98ec3d",
    "REVOLTClassicSim" => "c09822aa-3d1e-4a1e-903c-d4d0f13badd1",
    "REVOLTCopperSim" => "1e096dfd-8d59-466f-967d-e58cf577fca9")
const MEASURED_ARTIFACTS = Dict(
    "measured-background.f32le" => ("F32_LE", [352,352], "ADC"),
    "measured-reference-slopes.f32le" => ("F32_LE", [188,2], "detector coordinate"),
    "measured-active.u8" => ("Bool", [188], "eligible ROI"),
    "measured-dark-variance.f64le" => ("F64_LE", [352,352], "ADC squared"),
    "measured-interaction-matrix.f32le" => ("F32_LE", [376,277], "detector coordinate / micrometre OPD"))

function campaign_file(root::AbstractString, relative::AbstractString, maximum::Integer)
    isabspath(relative) && throw(ArgumentError("absolute calibration input: $relative"))
    parts = splitpath(relative)
    any(part -> part == ".." || part == ".", parts) && throw(ArgumentError("unsafe calibration input: $relative"))
    path = abspath(root)
    parent = path
    while true
        islink(parent) && throw(ArgumentError("symlinked calibration root: $parent"))
        next = dirname(parent)
        next == parent && break
        parent = next
    end
    for part in parts
        path = joinpath(path, part)
        islink(path) && throw(ArgumentError("symlinked calibration input: $path"))
    end
    isfile(path) && filesize(path) <= maximum ||
        throw(ArgumentError("missing or oversized calibration input: $path"))
    return path
end

function campaign_json(root::AbstractString, relative::AbstractString)
    path = campaign_file(root, relative, 2 * 1024 * 1024)
    payload = read(path)
    length(payload) <= 2 * 1024 * 1024 || throw(ArgumentError("calibration record grew beyond its size bound"))
    _unique_json_keys(payload)
    value = Common.finite_json(Common.parse_json(String(payload)))
    value isa AbstractDict || throw(ArgumentError("calibration record requires an object: $relative"))
    return value
end

function _unique_json_keys(payload::Vector{UInt8})
    index = Ref(1)
    limit = length(payload)
    whitespace(b) = b in (0x20,0x09,0x0a,0x0d)
    function skip_space()
        while index[] <= limit && whitespace(payload[index[]])
            index[] += 1
        end
    end
    function string_token()
        start = index[]
        index[] <= limit && payload[index[]] == 0x22 || throw(ArgumentError("invalid JSON string"))
        index[] += 1
        while index[] <= limit
            b = payload[index[]]
            index[] += 1
            b == 0x22 && return String(payload[start:index[]-1])
            if b == 0x5c
                index[] <= limit || throw(ArgumentError("invalid JSON escape"))
                index[] += 1
            end
        end
        throw(ArgumentError("unterminated JSON string"))
    end
    function scan_value(depth)
        depth <= 128 || throw(ArgumentError("calibration JSON nesting exceeds bound"))
        skip_space()
        index[] <= limit || throw(ArgumentError("truncated calibration JSON"))
        b = payload[index[]]
        if b == 0x7b # object
            index[] += 1
            keys_seen = Set{String}()
            skip_space()
            if index[] <= limit && payload[index[]] == 0x7d
                index[] += 1
                return
            end
            while true
                key = JSON3.read(string_token(), String)
                key in keys_seen && throw(ArgumentError("duplicate calibration JSON field: $key"))
                push!(keys_seen,key)
                skip_space()
                index[] <= limit && payload[index[]] == 0x3a || throw(ArgumentError("invalid calibration JSON object"))
                index[] += 1
                scan_value(depth+1)
                skip_space()
                index[] <= limit || throw(ArgumentError("truncated calibration JSON object"))
                delimiter = payload[index[]]
                index[] += 1
                delimiter == 0x7d && return
                delimiter == 0x2c || throw(ArgumentError("invalid calibration JSON object delimiter"))
                skip_space()
            end
        elseif b == 0x5b # array
            index[] += 1
            skip_space()
            if index[] <= limit && payload[index[]] == 0x5d
                index[] += 1
                return
            end
            while true
                scan_value(depth+1)
                skip_space()
                index[] <= limit || throw(ArgumentError("truncated calibration JSON array"))
                delimiter = payload[index[]]
                index[] += 1
                delimiter == 0x5d && return
                delimiter == 0x2c || throw(ArgumentError("invalid calibration JSON array delimiter"))
            end
        elseif b == 0x22
            string_token()
        else
            start = index[]
            while index[] <= limit && !(payload[index[]] in (0x2c,0x5d,0x7d,0x20,0x09,0x0a,0x0d))
                index[] += 1
            end
            index[] > start || throw(ArgumentError("invalid calibration JSON value"))
        end
    end
    scan_value(0)
    skip_space()
    index[] == limit+1 || throw(ArgumentError("calibration JSON has trailing data"))
    return nothing
end

function finite_payload(path::AbstractString, element::AbstractString, shape)
    width = get(ScienceExport.TYPE_BYTES, element, nothing)
    width === nothing && throw(ArgumentError("unsupported calibration element type: $element"))
    all(x -> x isa Integer && !(x isa Bool) && x > 0, shape) || throw(ArgumentError("invalid calibration payload shape"))
    expected = ScienceExport.payload_bytes(shape, width)
    isfile(path) && filesize(path) == expected || throw(ArgumentError("wrong calibration payload shape: $(basename(path))"))
    data = read(path)
    length(data) == expected || throw(ArgumentError("calibration payload changed during read: $(basename(path))"))
    if element == "Bool"
        all(x -> x <= 0x01, data) && any(!iszero, data) || throw(ArgumentError("active mask requires Boolean entries and an observable ROI"))
    elseif element == "F32_LE"
        all(isfinite, reinterpret(Float32, data)) || throw(ArgumentError("nonfinite calibration payload: $(basename(path))"))
    elseif element == "F64_LE"
        all(isfinite, reinterpret(Float64, data)) || throw(ArgumentError("nonfinite calibration payload: $(basename(path))"))
    end
    return data
end

function copy_package(source::AbstractString, destination::AbstractString)
    isfile(joinpath(source, "Project.toml")) && !islink(source) || throw(ArgumentError("missing simulator package: $source"))
    mkpath(destination)
    for name in ("Project.toml", "src", "ext", "graphs", "LICENSE", "LICENSE.md")
        entry = joinpath(source, name)
        if isdir(entry)
            ScienceExport.copy_tree(entry, joinpath(destination, name))
        elseif isfile(entry)
            ScienceExport.copy_file(entry, joinpath(destination, name))
        end
    end
    return destination
end

function replace_staged_package(source::AbstractString, package::AbstractString, name::AbstractString)
    selected_source = realpath(source)
    isfile(joinpath(selected_source,"Project.toml")) ||
        throw(ArgumentError("missing simulator package: $selected_source"))
    selected = joinpath(package,"hil","packages",name)
    (ispath(selected) || islink(selected)) && rm(selected;recursive=true)
    return copy_package(selected_source,selected)
end

function classic_bindings(provenance::AbstractDict)
    expected = Dict(p.name => ScienceExport.parameter_dict(p) for p in ScienceExport.classic_parameters())
    bindings = Dict{String,Any}()
    for item in vcat(provenance["parameters"], get(provenance, "construction_parameters", Any[]))
        name = item["name"]
        (haskey(bindings, name) || any(value["endpoint"] == item["endpoint"] for value in values(bindings))) &&
            throw(ArgumentError("duplicate Classic calibration parameter bindings"))
        if haskey(expected, name)
            canonical = expected[name]
            all(get(item, key, nothing) == canonical[key] for key in ("file", "endpoint", "element_type", "schema")) &&
                get(item, "shape", nothing) == canonical["shape"] && get(item, "layout", "ROW_MAJOR") == "ROW_MAJOR" ||
                throw(ArgumentError("incompatible Classic calibration descriptor: $name"))
        end
        bindings[name] = item
    end
    required = Set(("background", "reference-slopes", "active", "subaperture-origins", "coordinates", "thresholds"))
    issubset(required, Set(keys(bindings))) || throw(ArgumentError("missing Classic calibration bindings"))
    Set(keys(bindings)) == Set(keys(expected)) || throw(ArgumentError("measured offsets require the bounded Classic parameter set"))
    return bindings
end

function _u32_pairs(data::Vector{UInt8})
    length(data) % 8 == 0 || throw(ArgumentError("invalid packed origins"))
    words = reinterpret(UInt32, data)
    return [[Int(words[i]), Int(words[i+1])] for i in 1:2:length(words)]
end
function _packed_origins(origins)
    data = UInt8[]
    for pair in origins, x in pair
        append!(data, reinterpret(UInt8, [UInt32(x)]))
    end
    return data
end

function classic_snapshot(package::AbstractString, provenance::AbstractDict, prefix::AbstractString)
    bindings = classic_bindings(provenance)
    graph_path = campaign_file(package, "graphs/graph.conf.in", 2 * 1024 * 1024)
    graph = Deployment.decode(graph_path, prefix)
    nodes = graph["filter.graph"]["nodes"]
    length(Set(node["name"] for node in nodes)) == length(nodes) || throw(ArgumentError("duplicate Classic graph node names"))
    selected = Dict{String,Any}()
    for (label, endpoint) in (("pixel-calibration-u16-f32", "pixel-calibration"),
                              ("shack-hartmann-image-f32", "shack-hartmann"),
                              ("pdm-command-f32", "pdm-command"))
        matches = [node for node in nodes if get(node, "label", nothing) == label]
        length(matches) == 1 && matches[1]["name"] == endpoint || throw(ArgumentError("Classic requires one $label at its maintained endpoint"))
        selected[label] = matches[1]
    end
    any(node -> occursin("system-flat", node["name"]) || occursin("system-flat", get(node, "label", "")), nodes) &&
        throw(ArgumentError("system-flat command origins are not supported for measured offsets"))
    config = selected["shack-hartmann-image-f32"]["config"]
    origins = get(config, "initial_subaperture_origins", nothing)
    if origins === nothing
        binding = bindings["subaperture-origins"]
        origins = _u32_pairs(finite_payload(campaign_file(package, "calibration/" * binding["file"], 1504), "U32_LE", [188,2]))
    end
    length(origins) == 188 && all(pair -> length(pair) == 2 && all(x -> x isa Int && !(x isa Bool) && x >= 0, pair), origins) &&
        origins == provenance["prepared_profile"]["subaperture_origins"] || throw(ArgumentError("Classic estimator origins differ from prepared profile"))
    all(pair -> pair[1] + 22 <= 352 && pair[2] + 22 <= 352, origins) || throw(ArgumentError("Classic estimator ROI lies outside detector"))
    if provenance["engine"] == "fgn"
        get(bindings["subaperture-origins"], "sha256", nothing) == bytes2hex(SHA.sha256(_packed_origins(origins))) ||
            throw(ArgumentError("Classic construction origins hash differs from binding"))
    elseif provenance["engine"] == "jfg"
        binding = bindings["subaperture-origins"]
        origins == _u32_pairs(finite_payload(campaign_file(package, "calibration/" * binding["file"], 1504), "U32_LE", [188,2])) ||
            throw(ArgumentError("Classic construction and startup origins differ"))
    else
        throw(ArgumentError("measured offsets require Classic FGN or JFG"))
    end
    configured = get(config, "active", nothing)
    if configured !== nothing
        length(configured) == 188 && all(x -> x isa Bool, configured) && any(configured) || throw(ArgumentError("invalid Classic construction active mask"))
        active = UInt8[x ? 1 : 0 for x in configured]
        if provenance["engine"] == "fgn"
            get(bindings["active"], "sha256", nothing) == bytes2hex(SHA.sha256(active)) || throw(ArgumentError("Classic construction mask hash differs from binding"))
        else
            binding = bindings["active"]
            active == finite_payload(campaign_file(package, "calibration/" * binding["file"], 188), "Bool", [188]) ||
                throw(ArgumentError("Classic construction and startup masks differ"))
        end
    else
        binding = bindings["active"]
        finite_payload(campaign_file(package, "calibration/" * binding["file"], 188), "Bool", [188])
    end
    snapshot = Dict{String,Any}("subaperture_origins" => origins)
    for (label, node) in selected
        snapshot[label] = Dict(key => value for (key, value) in node["config"] if !(key in ("rate", "active", "initial_subaperture_origins")))
    end
    geometry = snapshot["shack-hartmann-image-f32"]
    for (key, expected) in (("image_rows",352), ("image_columns",352), ("subaperture_count",188), ("subaperture_rows",22), ("subaperture_columns",22))
        get(geometry,key,nothing) == expected || throw(ArgumentError("incompatible Classic estimator geometry"))
    end
    for name in ("coordinates", "thresholds")
        binding = bindings[name]
        path = campaign_file(package, "calibration/" * binding["file"], 4096)
        finite_payload(path, binding["element_type"], binding["shape"])
        snapshot[name * "_sha256"] = ScienceExport.sha256(path)
    end
    return snapshot, graph, bindings
end

function validate_startup_bindings(package::AbstractString, specification::AbstractDict, provenance::AbstractDict,
                                   graph::AbstractDict, bindings::AbstractDict; owner_role="julia", graph_relative="graphs/graph.conf.in")
    if provenance["engine"] == "fgn"
        source = read(joinpath(package, graph_relative), String)
        for name in ("background", "reference-slopes", "coordinates", "thresholds")
            binding = bindings[name]
            key = "pipewireao.startup-parameter." * binding["endpoint"]
            length(findall(key, source)) == 1 && get(graph, key, nothing) == "@PACKAGE@/calibration/" * binding["file"] ||
                throw(ArgumentError("invalid FGN startup binding: $name"))
        end
        !occursin("pipewireao.startup-parameter." * bindings["active"]["endpoint"], source) ||
            throw(ArgumentError("FGN active selection must use its construction field"))
    elseif provenance["engine"] == "jfg"
        owners = [owner for owner in specification["owners"] if owner["role"] == owner_role]
        length(owners) == 1 || throw(ArgumentError("JFG requires one science owner"))
        argv = owners[1]["argv"]
        supplied = Dict{String,Any}()
        for i in eachindex(argv)
            startswith(argv[i], "--parameter=") && throw(ArgumentError("unsupported JFG parameter spelling"))
            if argv[i] == "--parameter"
                i + 4 <= length(argv) || throw(ArgumentError("incomplete JFG startup binding"))
                values = argv[i+1:i+4]
                haskey(supplied, values[1]) && throw(ArgumentError("duplicate JFG startup binding"))
                supplied[values[1]] = values[2:4]
            end
        end
        for name in ("background", "reference-slopes", "coordinates", "thresholds", "active", "subaperture-origins")
            binding = bindings[name]
            expected = [ScienceExport.JULIA_TYPES[binding["element_type"]], join(binding["shape"], ","), "@PACKAGE@/calibration/" * binding["file"]]
            get(supplied, name, nothing) == expected || throw(ArgumentError("invalid JFG startup binding: $name"))
        end
    else
        throw(ArgumentError("measured offsets require Classic FGN or JFG"))
    end
    return nothing
end

zero_reference(value) = value isa AbstractVector && length(value) == 277 &&
    all(x -> x isa Real && !(x isa Bool) && isfinite(x) && iszero(x), value)

function plant_configuration(path::AbstractString, rate::Integer)
    text = read(path,String)
    graph = TOML.parse(text)
    atmosphere = only([node for node in graph["nodes"] if node["name"] == "atmosphere"])
    detector = only([node for node in graph["nodes"] if node["name"] == "detector"])
    exposure = round(Int,detector["config"]["exposure_duration_s"] * 1_000_000_000)
    period = round(Int,1_000_000_000 / rate)
    0 < exposure <= period || throw(ArgumentError("instrument exposure must be positive and no longer than model period"))
    atmosphere["config"]["atmosphere_step"] > 0 || throw(ArgumentError("instrument model has invalid atmosphere step"))
    matches = collect(eachmatch(r"(?m)^atmosphere_step\s*=\s*[^\n]+$",text))
    length(matches) == 1 || throw(ArgumentError("expected one instrument atmosphere step"))
    return replace(text,r"(?m)^atmosphere_step\s*=\s*[^\n]+$" => "atmosphere_step = $(repr(period / 1_000_000_000))"),exposure
end

function hil_session(base::AbstractDict)
    value = deepcopy(base)
    get(value,"execution",nothing) == "complete-frame" || throw(ArgumentError("HIL currently requires complete-frame science"))
    source,sink = value["sources"][1],value["sinks"][1]
    source_name,source_port = source["node.name"],source["ports"][1]["name"]
    sink_name,sink_port = sink["node.name"],sink["ports"][1]["name"]
    source["ports"][1]["name"] = "output_1"
    sink["ports"][1]["name"] = "input_1"
    value["sources"][1] = Dict("ownership"=>"external","node.name"=>"simulator-wfs","ports"=>source["ports"])
    value["sinks"][1] = Dict("ownership"=>"external","node.name"=>"simulator-command","ports"=>sink["ports"])
    for link in value["links"]
        if link["output"] == "$source_name:$source_port"
            link["output"] = "simulator-wfs:output_1"
            link["passive"] = true
        end
        link["input"] == "$sink_name:$sink_port" && (link["input"] = "simulator-command:input_1")
    end
    for group in value["execution-groups"]
        filter!(name -> name != source_name && name != sink_name,group["nodes"])
    end
    return value
end

function hil_core(base::AbstractDict; detector_observation::Bool=false)
    value = Dict{String,Any}(deepcopy(base))
    value["context.properties"] = Dict{String,Any}(value["context.properties"])
    loops = value["context.properties"]["context.data-loops"]
    Set(loop["loop.name"] for loop in loops) == Set(["rtc-data-loop","source-loop","sink-loop"]) ||
        throw(ArgumentError("base core requires the maintained RTC, source and sink loops"))
    loops = Any[loop for loop in loops if loop["loop.name"] == "rtc-data-loop"]
    value["context.properties"]["context.data-loops"] = loops
    if detector_observation
        # Generic acquisition compares the raw default class string as well
        # as its parsed classes. Scalar data.rt scores above the observer's
        # empty class list; explicit names still select either loop.
        only(loops)["loop.class"] = "data.rt"
        push!(loops, Dict("loop.name"=>"observer-loop", "thread.name"=>"observer-loop",
            "loop.class"=>String[], "loop.idle"=>"eventfd", "loop.rt-prio"=>83,
            "thread.affinity"=>[14]))
        push!(value["context.modules"], Dict("name"=>"libpipewire-module-queue", "args"=>Dict(
            "queue.max-buffers"=>1, "queue.overflow"=>"drop-oldest", "queue.storage"=>"copy",
            "queue.media"=>"application/ndarray",
            "capture.props"=>Dict("node.name"=>"simulator-detector-queue-input","node.loop.name"=>"rtc-data-loop"),
            "playback.props"=>Dict("node.name"=>"simulator-detector-queue-output",
                "media.name"=>"detector-image", "media.class"=>"Data/Source",
                "device.api"=>"pipewireao.queue", "node.loop.name"=>"observer-loop"))))
    end
    return value
end

function environment(package::AbstractString,plant::AbstractString,backend::AbstractString)
    project = TOML.parsefile(joinpath(ScienceExport.resource_root(),"hil/Project.toml"))
    dependencies = copy(project["deps"])
    delete!(dependencies,"REVOLTClassicSim"); delete!(dependencies,"REVOLTCopperSim")
    for name in ("AdaptiveOpticsCalibration","AdaptiveOpticsSim","AdaptiveOpticsSimPipeWireHIL",plant)
        dependencies[name] = PACKAGE_UUIDS[name]
    end
    compat = copy(get(project,"compat",Dict{String,Any}()))
    for name in ("REVOLTClassicSim","REVOLTCopperSim")
        name == plant || delete!(compat,name)
    end
    compat["AdaptiveOpticsCalibration"] = "0.17"
    if backend == "cuda"
        dependencies["CUDA"] = "052768ef-5323-5732-b1bb-66c8b64840ba"; compat["CUDA"] = "6"
    elseif backend == "amdgpu"
        dependencies["AMDGPU"] = "21141c5a-9bdb-4563-92ae-f87d6854732e"; compat["AMDGPU"] = "2.7"
    end
    text = "[deps]\n" * join(("$name = \"$uuid\"\n" for (name,uuid) in sort(collect(dependencies))), "")
    text *= "\n[sources]\n" * join(("$name = {path = \"packages/$name\"}\n" for name in
        ("AdaptiveOpticsCalibration","AdaptiveOpticsSim","AdaptiveOpticsSimPipeWireHIL","PipeWireAO","FilterGraphAlgorithms",plant)), "")
    text *= "\n[compat]\n" * join(("$name = \"$version\"\n" for (name,version) in sort(collect(compat))), "")
    write(joinpath(package,"hil/Project.toml"),text)
end

function add_bootstrap_dependency!(path::AbstractString)
    definition = TOML.parsefile(path)
    dependencies = get!(definition, "deps", Dict{String,Any}())
    uuid = "811555cd-349b-4f26-b7bc-1f208b848042"
    get(dependencies,"ThreadPinning",uuid) == uuid || throw(ArgumentError("ThreadPinning dependency identity differs"))
    dependencies["ThreadPinning"] = uuid
    get!(definition, "compat", Dict{String,Any}())["ThreadPinning"] = "1"
    open(path, "w") do io
        TOML.print(io, definition; sorted=true)
    end
    return nothing
end

function julia_owner_environment(package::AbstractString; refresh=false)
    path = joinpath(package,"jfg/deployment/Project.toml")
    definition = TOML.parsefile(path)
    sources = get!(definition, "sources", Dict{String,Any}())
    expected = Dict("path"=>"../../hil/packages/PipeWireAO")
    (!haskey(sources,"PipeWireAO") || (refresh && sources["PipeWireAO"] == expected)) ||
        throw(ArgumentError("base Julia owner already overrides PipeWireAO"))
    sdk_path = joinpath(package,"hil/packages/PipeWireAO/Project.toml")
    isfile(sdk_path) || throw(ArgumentError("staged PipeWireAO Project.toml is missing"))
    sdk = TOML.parsefile(sdk_path)
    uuid = "5d815c25-fdf3-4508-8205-db8be38ea5d0"
    get(sdk,"name",nothing) == "PipeWireAO" && get(sdk,"uuid",nothing) == uuid ||
        throw(ArgumentError("staged PipeWireAO package identity differs"))
    version_text = get(sdk,"version",nothing)
    version = version_text isa AbstractString ? tryparse(VersionNumber,version_text) : nothing
    version === nothing && throw(ArgumentError("staged PipeWireAO version is invalid"))
    dependencies = get!(definition,"deps",Dict{String,Any}())
    get(dependencies,"PipeWireAO",uuid) == uuid ||
        throw(ArgumentError("Julia owner PipeWireAO dependency identity differs"))
    dependencies["PipeWireAO"] = uuid
    get!(definition,"compat",Dict{String,Any}())["PipeWireAO"] = "=" * string(version)
    sources["PipeWireAO"] = expected
    open(path,"w") do io
        TOML.print(io,definition;sorted=true)
    end
    add_bootstrap_dependency!(path)
end

const LEGACY_BOOTSTRAP_FLAGS = (("--prepared-event","prepared"),("--connect-request","connect"),
    ("--connect-reply","connected"),("--quit-request","quit"))

"Bind an exported ordinary owner to its distinct cold endpoint."
function bind_bootstrap_owner!(owner)
    role = owner["role"]
    node = "pipewireao.rtc.bootstrap." * role
    ncodeunits(node) <= 128 || throw(ArgumentError("bootstrap node name exceeds its bound"))
    owner["bootstrap-protocol"] = NativeControlClient.profile_name(NativeOwnerBootstrapCodec.PROFILE)
    owner["bootstrap-node"] = node
    append!(owner["argv"], ["--bootstrap-node", node, "--bootstrap-instance",
        "@" * Deployment.bootstrap_instance_key(role) * "@"])
    return owner
end

"Upgrade only the maintained sealed JFG marker descriptor, offline."
function upgrade_legacy_julia_owner!(owner)
    owner["role"] == "julia" || throw(ArgumentError("unsupported legacy external owner"))
    argv = owner["argv"]
    script = "@PACKAGE@/jfg/deployment/run_island.jl"
    count(==(script),argv) == 1 || throw(ArgumentError("legacy owner lacks the maintained JFG entrypoint"))
    "--session-run-control" in argv || throw(ArgumentError("legacy JFG owner lacks session run control"))
    for (flag,key) in LEGACY_BOOTSTRAP_FLAGS
        marker = "julia." * key
        get(owner,key,nothing) == marker || throw(ArgumentError("legacy JFG marker differs: $key"))
        positions = findall(arg->first(split(arg,'=';limit=2)) == flag,argv)
        length(positions) == 1 && argv[only(positions)] == flag && only(positions) < length(argv) &&
            argv[only(positions)+1] == "@RUNTIME@/" * marker || throw(ArgumentError("legacy JFG marker argument differs: $flag"))
    end
    for flag in ("--control-request","--control-reply","--bootstrap-node","--bootstrap-instance")
        !any(arg->first(split(arg,'=';limit=2)) == flag,argv) || throw(ArgumentError("unexpected legacy owner control: $flag"))
    end
    remotes = findall(==("--remote"),argv)
    length(remotes) == 1 && only(remotes) < length(argv) && argv[only(remotes)+1] == "@REMOTE@" ||
        throw(ArgumentError("legacy JFG remote differs"))
    for (flag,key) in LEGACY_BOOTSTRAP_FLAGS
        index = only(findall(==(flag),argv))
        deleteat!(argv,index:index+1)
        delete!(owner,key)
    end
    argv[only(findall(==(script),argv))] = "@PACKAGE@/hil/jfg_owner.jl"
    argv[only(findall(==("--remote"),argv))+1] = "@RUNTIME@/@REMOTE@"
    return bind_bootstrap_owner!(owner)
end

function bootstrap_placement!(placement)
    threads = placement["threads"]
    any(thread->get(thread,"name",nothing) == "rtc-bootstrap",threads) &&
        throw(ArgumentError("duplicate bootstrap placement"))
    push!(threads,Dict("cpus"=>[placement["leader-cpu"]],"policy"=>"other","priority"=>0,
        "count"=>1,"name"=>"rtc-bootstrap"))
    return placement
end

function simulator_environment(backend::AbstractString)
    value = Dict("OPENBLAS_NUM_THREADS"=>"1","JULIA_NUM_THREADS"=>"2,0")
    backend == "amdgpu" && (value["HSA_OVERRIDE_CPU_AFFINITY_DEBUG"] = "0")
    return value
end

function calibration_inputs(package::AbstractString,provenance::AbstractDict,prefix::AbstractString)
    instrument = provenance["profile"]
    parameters = Dict(item["name"]=>item for item in provenance["parameters"])
    artifact(name,units) = Dict("path"=>"../calibration/"*parameters[name]["file"],"shape"=>parameters[name]["shape"],
        "element_type"=>parameters[name]["element_type"],"layout"=>"ROW_MAJOR","units"=>units)
    background = instrument == "classic" ? artifact("background","ADC") :
        Dict("path"=>"../calibration/parameter-background.f32","shape"=>[64,64],"element_type"=>"F32_LE","layout"=>"ROW_MAJOR","units"=>"ADC")
    result = Dict{String,Any}("version"=>1,"profile"=>instrument,"artifacts"=>Dict{String,Any}("background"=>background))
    if instrument == "copper"
        result["artifacts"]["system_flat"] = artifact("system-flat","micrometre OPD")
        return result
    end
    graph = Deployment.decode(joinpath(package,"graphs/graph.conf.in"),prefix)["filter.graph"]
    nodes = [node for node in graph["nodes"] if get(node,"label",nothing) == "shack-hartmann-image-f32"]
    length(nodes) == 1 || throw(ArgumentError("Classic calibration requires one complete-image Shack-Hartmann estimator"))
    config = nodes[1]["config"]
    active = get(config,"active",nothing)
    if active === nothing
        values = read(joinpath(package,"calibration",parameters["active"]["file"]))
        all(x -> x <= 1,values) || throw(ArgumentError("Classic active mask requires zero/one bytes"))
        active = Bool.(values)
    end
    origins = get(config,"initial_subaperture_origins",nothing)
    origins === nothing && (origins = _u32_pairs(read(joinpath(package,"calibration",parameters["subaperture-origins"]["file"]))))
    origins == provenance["prepared_profile"]["subaperture_origins"] || throw(ArgumentError("Classic estimator origins differ from prepared profile"))
    result["artifacts"]["reference_slopes"] = artifact("reference-slopes","detector coordinate")
    result["artifacts"]["optical_flat"] = Dict("path"=>"../calibration/simulated-optical-flat.f32le","shape"=>background["shape"],
                                               "element_type"=>"F32_LE","layout"=>"ROW_MAJOR","units"=>"ADC")
    result["shack_hartmann"] = Dict("detector_height"=>config["image_rows"],"detector_width"=>config["image_columns"],
        "subaperture_height"=>config["subaperture_rows"],"subaperture_width"=>config["subaperture_columns"],
        "subaperture_origins"=>origins,"coordinates"=>artifact("coordinates","detector coordinate"),
        "thresholds"=>artifact("thresholds","ADC"),"active"=>active)
    return result
end

function adopt_simulated_calibration(package::AbstractString,specification::AbstractDict,provenance::AbstractDict,
                                     inputs::AbstractDict,result::AbstractDict)
    get(result,"version",nothing) == 1 && get(result,"profile",nothing) == provenance["profile"] &&
        get(result,"model_sha256",nothing) == ScienceExport.sha256(joinpath(package,"hil/plant.toml")) ||
        throw(ArgumentError("simulated calibration does not describe the installed plant"))
    Set(keys(get(result,"artifacts",Dict()))) == Set(keys(inputs["artifacts"])) ||
        throw(ArgumentError("simulated calibration artifact set differs from the request"))
    for (name,descriptor) in inputs["artifacts"]
        actual = result["artifacts"][name]
        all(get(actual,key,nothing) == value for (key,value) in descriptor) || throw(ArgumentError("simulated calibration descriptor differs for $name"))
        path = realpath(joinpath(package,"hil",descriptor["path"]))
        dirname(path) == realpath(joinpath(package,"calibration")) || throw(ArgumentError("simulated calibration must remain in package calibration directory"))
        parameter = ScienceExport.Parameter(name,"",descriptor["element_type"],descriptor["shape"],basename(path))
        ScienceExport.validate_parameter(dirname(path),parameter)
        ScienceExport.sha256(path) == get(actual,"sha256",nothing) || throw(ArgumentError("simulated calibration hash differs for $name"))
    end
    if provenance["profile"] == "copper"
        parameter = ScienceExport.Parameter("background","calibrate:background","F32_LE",[64,64],"parameter-background.f32")
        !any(item -> item["name"] == "background",provenance["parameters"]) || throw(ArgumentError("Copper base has a background parameter"))
        push!(provenance["parameters"],ScienceExport.parameter_dict(parameter))
        graph = joinpath(package,"graphs/graph.conf.in")
        text = read(graph,String)
        if provenance["engine"] == "fgn"
            length(findall("    filter.graph =",text)) == 1 || throw(ArgumentError("Copper graph requires one filter.graph declaration"))
            initialization = "    \"pipewireao.startup-parameter.calibrate:background\" = \"@PACKAGE@/calibration/parameter-background.f32\"\n"
            write(graph,replace(text,"    filter.graph ="=>initialization*"    filter.graph =";count=1))
        else
            declaration = "\"calibrate:raw\"\n"
            length(findall(declaration,text)) == 1 || throw(ArgumentError("Copper Julia graph requires one raw input declaration"))
            write(graph,replace(text,declaration=>declaration*"            \"calibrate:background\"\n";count=1))
            owner = only([owner for owner in specification["owners"] if owner["role"] == "julia"])
            append!(owner["argv"],["--parameter","background","Float32","64,64","@PACKAGE@/calibration/parameter-background.f32"])
        end
    end
    return nothing
end

function _checked(argv;timeout=1800)
    result = Common.run_checked(argv;timeout)
    result.returncode == 0 || throw(ArgumentError("Julia package preparation failed: $(result.stderr)"))
    return result
end

function simulated_calibration(package,specification,provenance,prefix,executable,dark_frames)
    inputs = calibration_inputs(package,provenance,prefix)
    input_path,result_path = joinpath(package,"hil/calibration-input.json"),joinpath(package,"hil/calibration-result.json")
    Common.write_json(input_path,inputs)
    original = Dict(name => (isfile(joinpath(package,"hil",item["path"])) ? ScienceExport.sha256(joinpath(package,"hil",item["path"])) : nothing)
                    for (name,item) in inputs["artifacts"])
    _checked([executable,"--startup-file=no","--threads=1,0","--project="*joinpath(package,"hil"),
              joinpath(package,"hil/calibrate_detector.jl"),"--graph",joinpath(package,"hil/plant.toml"),
              "--profile",provenance["profile"],"--specification",input_path,"--output",result_path,
              "--dark-frames",string(dark_frames)])
    result = Common.read_json(result_path)
    get(result,"dark_frames",nothing) == dark_frames || throw(ArgumentError("simulated calibration dark count differs from the request"))
    adopt_simulated_calibration(package,specification,provenance,inputs,result)
    return Dict("mode"=>"historical-simulated-offset-fixture","source"=>"simulated detector and zero-command plant",
        "report"=>"hil/calibration-result.json","report_sha256"=>ScienceExport.sha256(result_path),
        "replaced_artifact_sha256"=>original,"artifacts"=>result["artifacts"],
        "retained_calibration"=>"recorded reconstructor and projections; hybrid, convergence unqualified")
end

function operational_calibration(package::AbstractString,specification::AbstractDict,provenance::AbstractDict,
                                 prefix::AbstractString,campaign::AbstractString)
    provenance["profile"] == "classic" && provenance["engine"] in ("fgn","jfg") ||
        throw(ArgumentError("measured offsets currently require Classic CPU FGN/JFG"))
    campaign = abspath(campaign)
    result = campaign_json(campaign,"campaign-result.json")
    campaign_module = getfield(parentmodule(HILExport),:CalibrationCampaign)
    recipe = campaign_module.validate_recipe(campaign_json(campaign,"recipe.json"))
    stages = ("dark","training","qualification","interaction")
    get(result,"version",nothing) === 1 && get(result,"phase",nothing) == "complete-candidate" &&
        !get(result,"failure",false) && Set(keys(get(result,"stages",Dict()))) == Set(stages) &&
        Set(keys(get(result,"artifacts",Dict()))) == Set(keys(MEASURED_ARTIFACTS)) ||
        throw(ArgumentError("operational calibration requires a complete version-1 candidate campaign"))
    zero_reference(recipe["reference"]) || throw(ArgumentError("measured offsets support only an actual zero 277-command reference"))
    payloads = Dict{String,Vector{UInt8}}()
    artifacts = Dict{String,Any}()
    for (name,(element,shape,units)) in MEASURED_ARTIFACTS
        path = campaign_file(campaign,name,1024*1024)
        payloads[name] = finite_payload(path,element,shape)
        ScienceExport.sha256(path) == result["artifacts"][name] || throw(ArgumentError("measured calibration hash differs: $name"))
        artifacts[name] = Dict("sha256"=>result["artifacts"][name],"shape"=>shape,"element_type"=>element,"layout"=>"ROW_MAJOR","units"=>units)
    end
    target_snapshot,graph,bindings = classic_snapshot(package,provenance,prefix)
    validate_startup_bindings(package,specification,provenance,graph,bindings)
    target_model = TOML.parsefile(joinpath(package,"hil/plant.toml"))
    target_nodes = Dict(node["name"]=>node for node in target_model["nodes"])
    target_detector = target_nodes["detector"]["config"]
    campaign_module.validate_detector_rail(target_detector,recipe)
    sources = Dict{String,Any}(); differences = Any[]
    measured_mask = payloads["measured-active.u8"]
    for stage in stages
        record = result["stages"][stage]
        disk_record = campaign_json(campaign,"$stage-evidence/stage-result.json")
        disk_record == record && get(record,"stage",nothing) == stage && !get(record,"failure",false) &&
            !get(record,"recovery_failure",false) &&
            all(get(record,key,nothing) === true for key in ("restoration_confirmed","release_confirmed","shutdown_confirmed")) &&
            get(record,"launcher_exit",nothing) === 0 || throw(ArgumentError("campaign stage lifecycle is not confirmed: $stage"))
        startup = record["startup_report"]
        model_path = campaign_file(campaign,"$stage-package/hil/plant.toml",1024*1024)
        source_model = TOML.parsefile(model_path)
        source_nodes = Dict(node["name"]=>node for node in source_model["nodes"])
        detector = source_nodes["detector"]["config"]
        campaign_module.validate_detector_rail(detector,recipe)
        valid_startup = get(startup,"version",nothing) === 1 && get(startup,"profile",nothing) == "classic" &&
            get(startup,"backend",nothing) == "cpu" && !get(startup,"failure",false) &&
            get(startup,"calibration_stage",nothing) == stage &&
            get(startup,"illumination",nothing) == (stage == "dark" ? "dark" : "lamp") &&
            get(startup,"command_transport_units",nothing) == "micrometre OPD" &&
            get(startup,"plant_command_units",nothing) == "metre OPD" &&
            get(startup,"graph_sha256",nothing) == ScienceExport.sha256(model_path) &&
            get(startup,"detector_config",nothing) == detector &&
            get(detector,"photon_noise",nothing) === true && get(detector,"readout_noise",nothing) === true &&
            get(detector,"rng_seed",nothing) == recipe["seeds"][stage] &&
            source_nodes["shwfs"]["config"]["source_magnitude"] == recipe["lamp_magnitude"]
        valid_startup || throw(ArgumentError("campaign detector/illumination snapshot differs: $stage"))
        Dict(k=>v for (k,v) in detector if k != "rng_seed") == Dict(k=>v for (k,v) in target_detector if k != "rng_seed") ||
            throw(ArgumentError("target detector/exposure configuration differs from measured source"))
        source_comparable,target_comparable = deepcopy(source_model),deepcopy(target_model)
        changes = Dict{String,Any}()
        for (node,field) in (("detector","rng_seed"),("atmosphere","atmosphere_step"),("shwfs","source_magnitude"))
            source_config = only([n for n in source_comparable["nodes"] if n["name"] == node])["config"]
            target_config = only([n for n in target_comparable["nodes"] if n["name"] == node])["config"]
            changes["$node.$field"] = Dict("source"=>pop!(source_config,field),"target"=>pop!(target_config,field))
        end
        source_comparable == target_comparable || throw(ArgumentError("target plant geometry/physics differs from measured source"))
        source_relative = "$stage-base"
        source_package = joinpath(campaign,source_relative)
        source_provenance = campaign_json(campaign,"$source_relative/provenance.json")
        source_deployment = campaign_json(campaign,"$source_relative/deployment.conf")
        get(source_provenance,"profile",nothing) == "classic" && get(source_provenance,"mode",nothing) == "frame" &&
            get(source_provenance,"engine",nothing) in ("fgn","jfg") &&
            get(get(source_provenance,"hil",Dict()),"backend",nothing) == "cpu" &&
            get(get(source_provenance,"campaign_stage_inputs",Dict()),"recipe",nothing) == recipe ||
            throw(ArgumentError("incompatible source campaign package: $stage"))
        snapshot,source_graph,source_bindings = classic_snapshot(source_package,source_provenance,prefix)
        validate_startup_bindings(source_package,source_deployment,source_provenance,source_graph,source_bindings)
        snapshot == target_snapshot || throw(ArgumentError("target detector/ROI coordinates or thresholds differ from measured source"))
        for relative in ("provenance.json","graphs/graph.conf.in","calibration/"*source_bindings["coordinates"]["file"],
                         "calibration/"*source_bindings["thresholds"]["file"])
            path = campaign_file(source_package,relative,2*1024*1024)
            get(source_deployment["artifacts"],relative,nothing) == ScienceExport.sha256(path) ||
                throw(ArgumentError("stale source package binding: $stage/$relative"))
        end
        expected_active = stage in ("dark","training") ? UInt8[x ? 1 : 0 for x in recipe["candidate_mask"]] : measured_mask
        wfs = only([node for node in source_graph["filter.graph"]["nodes"] if node["label"] == "shack-hartmann-image-f32"])
        actual_active = haskey(wfs["config"],"active") ? UInt8[x ? 1 : 0 for x in wfs["config"]["active"]] :
            finite_payload(campaign_file(source_package,"calibration/"*source_bindings["active"]["file"],188),"Bool",[188])
        actual_active == expected_active && get(startup,"wfs_active",nothing) == Bool.(expected_active) &&
            get(startup,"wfs_active_sha256",nothing) == bytes2hex(SHA.sha256(expected_active)) ||
            throw(ArgumentError("source active mask differs: $stage"))
        deployed_relative = "$stage-package"
        deployed_package = joinpath(campaign,deployed_relative)
        deployed_provenance = campaign_json(campaign,"$deployed_relative/provenance.json")
        deployed_specification = campaign_json(campaign,"$deployed_relative/deployment.conf")
        get(deployed_provenance,"source_provenance_sha256",nothing) == ScienceExport.sha256(joinpath(source_package,"provenance.json")) &&
            get(deployed_provenance,"source_graph_sha256",nothing) == ScienceExport.sha256(joinpath(source_package,"graphs/graph.conf.in")) &&
            get(deployed_provenance,"source_deployment_sha256",nothing) == ScienceExport.sha256(joinpath(source_package,"deployment.conf")) &&
            get(deployed_provenance,"source_provenance",nothing) == source_provenance ||
            throw(ArgumentError("deployed campaign source identity differs: $stage"))
        for relative in ("hil/plant.toml","graphs/wfs.conf.in","calibration/wfs-active.u8")
            path = campaign_file(deployed_package,relative,2*1024*1024)
            get(deployed_specification["artifacts"],relative,nothing) == ScienceExport.sha256(path) ||
                throw(ArgumentError("stale deployed campaign binding: $stage/$relative"))
        end
        deployed_wfs = Deployment.decode(joinpath(deployed_package,"graphs/wfs.conf.in"),prefix)
        validate_startup_bindings(deployed_package,deployed_specification,source_provenance,deployed_wfs,source_bindings;
                                  owner_role="julia-wfs",graph_relative="graphs/wfs.conf.in")
        source_wfs_nodes = [node for node in source_graph["filter.graph"]["nodes"] if node["label"] in ("pixel-calibration-u16-f32","shack-hartmann-image-f32")]
        deployed_wfs["filter.graph"]["nodes"] == source_wfs_nodes && read(joinpath(deployed_package,"calibration/wfs-active.u8")) == expected_active ||
            throw(ArgumentError("deployed estimator differs from source package: $stage"))
        for name in ("background","reference-slopes","coordinates","thresholds")
            relative = "calibration/"*source_bindings[name]["file"]
            path = campaign_file(deployed_package,relative,495616)
            read(path) == read(joinpath(source_package,relative)) && get(deployed_specification["artifacts"],relative,nothing) == ScienceExport.sha256(path) ||
                throw(ArgumentError("deployed estimator parameter differs: $stage/$name"))
        end
        for (name,expected) in (("background",stage == "dark" ? zeros(UInt8,495616) : payloads["measured-background.f32le"]),
                                ("reference-slopes",stage in ("dark","training") ? zeros(UInt8,1504) : payloads["measured-reference-slopes.f32le"]))
            path = campaign_file(source_package,"calibration/"*source_bindings[name]["file"],495616)
            read(path) == expected && get(source_deployment["artifacts"],"calibration/"*basename(path),nothing) == ScienceExport.sha256(path) ||
                throw(ArgumentError("source startup offsets differ: $stage/$name"))
        end
        if stage != "interaction"
            for (action,kind) in (("adopt","adopted"),("restore","restored"))
                requests = [entry for entry in record["requests"] if entry["request"]["action"]["kind"] == action]
                length(requests) == 1 || throw(ArgumentError("missing actual calibration reference command"))
                request,reply = requests[1]["request"],requests[1]["reply"]
                completion = reply["result"]
                all(key -> get(request,key,nothing) isa Int && get(reply,key,nothing) isa Int && request[key] == reply[key],("version","run","serial")) &&
                    request["version"] == 1 && zero_reference(get(request["action"],"figure",nothing)) &&
                    get(completion,"kind",nothing) == kind && get(completion,"clipped",nothing) === false &&
                    zero_reference(get(completion,"figure",nothing)) ||
                    throw(ArgumentError("actual calibration reference is nonzero, clipped or unconfirmed"))
            end
        end
        sources[stage] = Dict("deployment_sha256"=>ScienceExport.sha256(joinpath(source_package,"deployment.conf")),
            "provenance_sha256"=>ScienceExport.sha256(joinpath(source_package,"provenance.json")),
            "graph_sha256"=>ScienceExport.sha256(joinpath(source_package,"graphs/graph.conf.in")),
            "model_sha256"=>ScienceExport.sha256(model_path),"detector_config"=>detector,"illumination"=>startup["illumination"],
            "stage_result_sha256"=>ScienceExport.sha256(joinpath(campaign,"$stage-evidence/stage-result.json")),
            "analysis_sha256"=>ScienceExport.sha256(campaign_file(campaign,"$stage-evidence/analysis.json",2*1024*1024)),
            "deployed_wfs_sha256"=>ScienceExport.sha256(joinpath(deployed_package,"graphs/wfs.conf.in")),
            "deployed_deployment_sha256"=>ScienceExport.sha256(joinpath(deployed_package,"deployment.conf")))
        push!(differences,Dict("stage"=>stage,"settings"=>changes,"illumination"=>Dict("source"=>startup["illumination"],"target"=>"atmosphere")))
    end
    plan = campaign_json(campaign,"interaction-plan.json")
    get(plan,"version",nothing) === 1 && zero_reference(get(plan,"reference",nothing)) && get(plan,"measurements",nothing) == 376 ||
        throw(ArgumentError("interaction plan does not bind the zero reference"))
    dark = campaign_json(campaign,"dark-evidence/analysis.json")
    training = campaign_json(campaign,"training-evidence/analysis.json")
    qualification = campaign_json(campaign,"qualification-evidence/analysis.json")
    interaction = campaign_json(campaign,"interaction-evidence/analysis.json")
    get(dark,"status",nothing) == "valid" && get(dark,"units",nothing) == "ADC" &&
        get(dark,"background_sha256",nothing) == artifacts["measured-background.f32le"]["sha256"] &&
        get(dark,"variance_sha256",nothing) == artifacts["measured-dark-variance.f64le"]["sha256"] &&
        get(training,"status",nothing) == "valid" && get(training,"reference_sha256",nothing) == artifacts["measured-reference-slopes.f32le"]["sha256"] &&
        get(training,"mask_sha256",nothing) == artifacts["measured-active.u8"]["sha256"] &&
        get(training,"eligible",nothing) == Bool.(measured_mask) &&
        get(qualification,"status",nothing) == "qualified-frozen-reference" && get(qualification,"mask_reselection",nothing) === false &&
        get(interaction,"status",nothing) == "valid-structured-estimate" && get(interaction,"shape",nothing) == [376,277] &&
        get(interaction,"layout",nothing) == "ROW_MAJOR" && get(interaction,"sha256",nothing) == artifacts["measured-interaction-matrix.f32le"]["sha256"] ||
        throw(ArgumentError("measured artifact analysis identity/shape/layout differs"))
    original = Dict(relpath(path,package)=>ScienceExport.sha256(path) for path in readdir(joinpath(package,"calibration");join=true) if isfile(path))
    original_graph = ScienceExport.sha256(joinpath(package,"graphs/graph.conf.in"))
    for (name,source) in (("background","measured-background.f32le"),("reference-slopes","measured-reference-slopes.f32le"),("active","measured-active.u8"))
        binding = bindings[name]
        write(joinpath(package,"calibration",binding["file"]),payloads[source])
        binding["sha256"] = artifacts[source]["sha256"]
    end
    wfs = only([node for node in graph["filter.graph"]["nodes"] if node["label"] == "shack-hartmann-image-f32"])
    if provenance["engine"] == "fgn" || haskey(wfs["config"],"active")
        calibration_export = getfield(parentmodule(HILExport),:CalibrationExport)
        wfs["config"]["active"] = Bool.(measured_mask)
        write(joinpath(package,"graphs/graph.conf.in"),calibration_export.spa_json(graph)*"\n")
    end
    final_snapshot,final_graph,final_bindings = classic_snapshot(package,provenance,prefix)
    validate_startup_bindings(package,specification,provenance,final_graph,final_bindings)
    final_snapshot == target_snapshot || throw(ArgumentError("measured offset adoption changed estimator settings"))
    return Dict("mode"=>"operational-measured-offsets","source"=>campaign,
        "campaign_result_sha256"=>ScienceExport.sha256(joinpath(campaign,"campaign-result.json")),
        "recipe_sha256"=>ScienceExport.sha256(joinpath(campaign,"recipe.json")),
        "interaction_plan_sha256"=>ScienceExport.sha256(joinpath(campaign,"interaction-plan.json")),
        "artifacts"=>artifacts,"source_stages"=>sources,"target_differences"=>differences,
        "reference_command"=>recipe["reference"],"reference_units"=>"micrometre OPD",
        "runtime_command_origin"=>"zero physical reference; no additional system-flat; controller state starts at zero",
        "original_base_artifact_sha256"=>original,"original_target_graph_sha256"=>original_graph,
        "target_estimator"=>target_snapshot,"target_model_sha256"=>ScienceExport.sha256(joinpath(package,"hil/plant.toml")),
        "target_graph_sha256"=>ScienceExport.sha256(joinpath(package,"graphs/graph.conf.in")),
        "target_bindings"=>Dict(name=>merge(Dict(bindings[name]),Dict("path"=>"calibration/"*bindings[name]["file"])) for name in ("background","reference-slopes","active")),
        "reconstructor_acceptance"=>"not established; reconstructor and coordinate maps retained from base",
        "scientific_correction"=>"not established by offset preservation")
end

option(args,name::Symbol,default=nothing) = hasproperty(args,name) ? getproperty(args,name) : default

function _package_artifacts(package)
    artifacts = Dict{String,Any}()
    for (directory,_,files) in walkdir(package)
        for file in files
            path = joinpath(directory,file)
            islink(path) && throw(ArgumentError("symlink in export package: $path"))
            relative = relpath(path,package)
            relative == "deployment.conf" || (artifacts[relative] = ScienceExport.sha256(path))
        end
    end
    return artifacts
end

function export_package(args)
    output = abspath(args.output)
    !ispath(output) && !islink(output) || throw(ArgumentError("export output must be new"))
    adapter_project = TOML.parsefile(joinpath(args.adapter_root,"Project.toml"))
    adapter_version = tryparse(VersionNumber,get(adapter_project,"version",""))
    adapter_version !== nothing && adapter_version >= v"0.1.2" ||
        throw(ArgumentError("HIL export requires AdaptiveOpticsSimPipeWireHIL 0.1.2 or newer for the explicit source buffer contract"))
    args.rate_hz isa Int && 1 <= args.rate_hz <= 500 && args.frames isa Int && 1 <= args.frames <= 256 ||
        throw(ArgumentError("rate must be 1..500 Hz and finite batch 1..256 frames"))
    total = option(args,:total_exchanges,args.frames)
    total isa Int && args.frames <= total <= 65536 || throw(ArgumentError("total exchanges must cover prefix and be at most 65536"))
    wall_rate = option(args,:wall_rate,"default")
    wall_rate isa AbstractString || throw(ArgumentError("wall rate must be default, unpaced or an integer rate"))
    wall_rate in ("default","unpaced") || (occursin(r"^[0-9]+$",wall_rate) && tryparse(Int,wall_rate) !== nothing && 1 <= parse(Int,wall_rate) <= args.rate_hz) ||
        throw(ArgumentError("paced wall rate must be 1..model rate"))
    args.dark_frames isa Int && 1 <= args.dark_frames <= 4096 || throw(ArgumentError("dark calibration must use 1..4096 exposures"))
    args.backend in ("cpu","cuda","amdgpu") || throw(ArgumentError("unsupported HIL backend"))
    base = realpath(args.base_package)
    specification = Deployment.profile(joinpath(base,"deployment.conf"),args.pipewire_prefix;legacy_export_input=true)
    provenance = Common.read_json(joinpath(base,"provenance.json"))
    get(provenance,"mode",nothing) == "frame" && get(provenance,"profile",nothing) in ("classic","copper") ||
        throw(ArgumentError("base must be a maintained Classic/Copper complete-frame package"))
    !haskey(provenance,"hil") || throw(ArgumentError("base must be a recorded-input package, not a previous HIL export"))
    correction = option(args,:correction_diagnostics,false)
    correction isa Bool || throw(ArgumentError("correction diagnostics must be a Boolean"))
    detector_observation = option(args,:detector_observation,false)
    detector_observation isa Bool || throw(ArgumentError("detector observation must be a Boolean"))
    operational = option(args,:operational_calibration)
    if operational !== nothing
        provenance["profile"] == "classic" && args.backend == "cpu" && provenance["engine"] in ("fgn","jfg") ||
            throw(ArgumentError("correction diagnostics and operational offsets currently require Classic CPU FGN/JFG"))
    end
    if operational !== nothing
        _,base_graph,base_bindings = classic_snapshot(base,provenance,args.pipewire_prefix)
        validate_startup_bindings(base,specification,provenance,base_graph,base_bindings)
        for (name,binding) in base_bindings
            provenance["engine"] == "fgn" && name in ("active","subaperture-origins") && continue
            path = campaign_file(base,"calibration/"*binding["file"],2*1024*1024)
            finite_payload(path,binding["element_type"],binding["shape"])
        end
    end
    instrument = provenance["profile"]
    plant = instrument == "classic" ? "REVOLTClassicSim" : "REVOLTCopperSim"
    model_source = joinpath(args.plant_root,"graphs","revolt_$(instrument)_hil_grid_gaussian.toml")
    model,exposure = plant_configuration(model_source,args.rate_hz)
    executable = Sys.which("julia")
    executable === nothing && throw(ArgumentError("Julia executable is an unresolved deployment prerequisite"))
    executable = realpath(executable)
    mkpath(dirname(output))
    return mktempdir(dirname(output);prefix=".rtc-hil-export-") do temporary
        package = joinpath(temporary,"package")
        ScienceExport.copy_tree(base,package;ignored=Set(["__pycache__","input.fits","systemd"]))
        ScienceExport.copy_deployment_runtime(package)
        for name in ("pipewireao-rtc-deploy","placement.py","pipewireao-rtc@.service.in")
            path = joinpath(package,"bin",name)
            isfile(path) && rm(path)
        end
        session = hil_session(Common.read_json(joinpath(package,"session.conf.in")))
        session["rate"] = "$(args.rate_hz)/1"
        for item in vcat(session["sources"],session["graphs"],session["sinks"]), port in item["ports"]
            haskey(port,"rate") && (port["rate"] = session["rate"])
        end
        Common.write_json(joinpath(package,"session.conf.in"),session)
        for path in readdir(joinpath(package,"graphs");join=true)
            endswith(path,".conf.in") || continue
            text = read(path,String)
            write(path,replace(text,r"\brate\s*=\s*\[\s*\d+\s+1\s*\]"=>"rate = [ $(args.rate_hz) 1 ]"))
        end
        legacy_roles = String[]
        for owner in specification["owners"]
            push!(legacy_roles,owner["role"])
            upgrade_legacy_julia_owner!(owner)
            bootstrap_placement!(specification["placement"][owner["role"]])
            index = findfirst(==("--rate"),owner["argv"])
            index === nothing || (owner["argv"][index+1] = session["rate"])
        end
        mkpath(joinpath(package,"hil"))
        for name in readdir(joinpath(ScienceExport.resource_root(),"hil"))
            endswith(name,".jl") && !startswith(name,"test_") || continue
            ScienceExport.copy_file(joinpath(ScienceExport.resource_root(),"hil",name),joinpath(package,"hil",name))
        end
        for (name,source) in (("AdaptiveOpticsCalibration",args.aoc_root),("AdaptiveOpticsSim",args.aos_root),
                              ("AdaptiveOpticsSimPipeWireHIL",args.adapter_root),("PipeWireAO",args.pipewireao_jl_root),
                              ("FilterGraphAlgorithms",args.calibration_algorithms_root),(plant,args.plant_root))
            replace_staged_package(source,package,name)
        end
        write(joinpath(package,"hil/plant.toml"),model)
        environment(package,plant,args.backend)
        calibration = operational === nothing ? nothing :
            operational_calibration(package,specification,provenance,args.pipewire_prefix,operational)
        _checked([executable,"--startup-file=no","--threads=1,0","--project="*joinpath(package,"hil"),
                  "-e","using Pkg; Pkg.instantiate(; update_registry=false, allow_autoprecomp=false)"])
        operational === nothing && (calibration = simulated_calibration(package,specification,provenance,
                                                     args.pipewire_prefix,executable,args.dark_frames))
        if args.backend != "cpu"
            backend_package = args.backend == "cuda" ? "CUDA" : "AMDGPU"
            _checked([executable,"--startup-file=no","--threads=1,0","--project="*joinpath(package,"hil"),
                      "-e","using Pkg; Pkg.precompile([\"$backend_package\"])"])
        end
        if provenance["engine"] == "jfg"
            julia_owner_environment(package)
            _checked([executable,"--startup-file=no","--threads=1,0","--project="*joinpath(package,"jfg/deployment"),
                      "-e","using Pkg; Pkg.resolve(); Pkg.instantiate(; update_registry=false, allow_autoprecomp=false)"])
        end
        argv = String[executable,"--startup-file=no","--threads=2,0","--project=@PACKAGE@/hil","@PACKAGE@/hil/simulator.jl",
                      "--profile",instrument,"--backend",args.backend,"--graph","@PACKAGE@/hil/plant.toml",
                      "--rate",string(args.rate_hz),"--exposure-ns",string(exposure),"--frames",string(args.frames),
                      "--remote","@RUNTIME@/@REMOTE@","--output","@RUNTIME@/simulator-result.json", "--control-node","simulator-wfs"]
        correction && append!(argv,["--correction-diagnostics","true"])
        detector_observation && append!(argv,["--detector-observation","true"])
        (total > args.frames || wall_rate != "default") &&
            append!(argv,["--total-exchanges",string(total),"--wall-rate",wall_rate])
        push!(specification["owners"],bind_bootstrap_owner!(Dict{String,Any}("role"=>"simulator","argv"=>argv,
            "environment"=>simulator_environment(args.backend),"control-protocol"=>"pipewireao.source-control/1",
            "control-node"=>"simulator-wfs")))
        specification["source-owner"] = "simulator"
        detector_observation && (specification["detector-observation"] = true)
        specification["name"] = "revolt-$instrument-$(provenance["engine"])-hil-$(args.backend)"
        specification["placement"]["simulator"] = bootstrap_placement!(Dict("cpus"=>[6,14],"leader-cpu"=>6,"rt-priority"=>0,"threads"=>Any[],"locked-bytes"=>0))
        specification["placement"]["core"] = ScienceExport.placement([2,14],provenance["engine"] == "fgn" ? [2] : Int[])
        detector_observation && push!(specification["placement"]["core"]["threads"],
            Dict("cpus"=>[14], "policy"=>"fifo", "priority"=>83, "count"=>1, "name"=>"observer-loop"))
        core_path = joinpath(package,specification["core"])
        ScienceExport.write_spa_config(core_path,hil_core(Deployment.decode(core_path,args.pipewire_prefix);detector_observation))
        specification["client"]["simulator"] = "client-simulator.conf.in"
        ScienceExport.copy_file(joinpath(ScienceExport.resource_root(),"templates/client-simulator.conf.in"),joinpath(package,"client-simulator.conf.in"))
        provenance["hil"] = Dict{String,Any}("backend"=>args.backend,"wall_rate_hz"=>(wall_rate == "default" ? args.rate_hz : wall_rate == "unpaced" ? 0 : parse(Int,wall_rate)),"model_rate_hz"=>args.rate_hz,
            "model_period_ns"=>round(Int,1_000_000_000/args.rate_hz),"exposure_ns"=>exposure,
            "frames"=>args.frames,"total_exchanges"=>total,"wall_rate"=>wall_rate,"frame_encoding"=>"UInt16 ADC codes, row-major","command_unit"=>"micrometre OPD",
            "plant_command_scale"=>1e-6,"instrument_model"=>"provisional grid-Gaussian HSDM277",
            "aos_revision"=>ScienceExport.revision(args.aos_root),"plant_revision"=>ScienceExport.revision(args.plant_root),
            "adaptive_optics_calibration_revision"=>ScienceExport.revision(args.aoc_root),
            "adapter_revision"=>ScienceExport.revision(args.adapter_root),"original_model_sha256"=>ScienceExport.sha256(model_source),
            "pipewireao_jl_revision"=>ScienceExport.revision(args.pipewireao_jl_root),
            "base_deployment_sha256"=>ScienceExport.sha256(joinpath(base,"deployment.conf")),
            "base_provenance_sha256"=>ScienceExport.sha256(joinpath(base,"provenance.json")),
            "base_graph_sha256"=>ScienceExport.sha256(joinpath(base,"graphs/graph.conf.in")),
            "calibration_algorithms_revision"=>ScienceExport.revision(args.calibration_algorithms_root),
            (operational === nothing ? "simulated_calibration" : "operational_calibration")=>calibration,
            "scientific_convergence"=>"not established by deployment exchange")
        correction && (provenance["hil"]["correction_diagnostics"] = "direct public OPD witness; source diagnostic overhead excludes cadence qualification")
        detector_observation && (provenance["hil"]["detector_observation"] = "raw transported ADC behind capacity-one copy/drop-oldest queue; optional observer")
        provenance["runtime_requires"] = ["selected PipeWireAO prefix","Julia resolved HIL environment","selected simulator device"]
        provenance["hil"]["owner_bootstrap"] = Dict(
            "protocol"=>NativeControlClient.profile_name(NativeOwnerBootstrapCodec.PROFILE),
            "converted_legacy_roles"=>legacy_roles,
            "helpers_sha256"=>Dict(name=>ScienceExport.sha256(joinpath(package,"hil",name)) for name in
                ("simulator.jl","simulator_owner.jl","native_owner_bootstrap.jl","jfg_owner.jl")))
        Common.write_json(joinpath(package,"provenance.json"),provenance)
        specification["artifacts"] = _package_artifacts(package)
        Common.write_json(joinpath(package,"deployment.conf"),specification)
        Deployment.profile(joinpath(package,"deployment.conf"),args.pipewire_prefix)
        mv(package,output)
        return joinpath(output,"deployment.conf")
    end
end

function main(argv=ARGS)
    options = Common.cli_arguments(argv;required=["output","base-package","aoc-root","aos-root","plant-root",
        "adapter-root","pipewireao-jl-root","calibration-algorithms-root"],flags=["correction-diagnostics"],
        allowed=["operational-calibration","pipewire-prefix","total-exchanges","wall-rate","detector-observation"],defaults=(backend="cpu",rate_hz="10",frames="16",dark_frames="256"))
    observation = hasproperty(options,:detector_observation) ? options.detector_observation : "false"
    observation in ("true","false") || throw(ArgumentError("--detector-observation must be true or false"))
    args = merge(options,(rate_hz=parse(Int,options.rate_hz),frames=parse(Int,options.frames),
                          dark_frames=parse(Int,options.dark_frames),detector_observation=observation == "true",
                          total_exchanges=hasproperty(options,:total_exchanges) ? parse(Int,options.total_exchanges) : parse(Int,options.frames),
                          wall_rate=hasproperty(options,:wall_rate) ? options.wall_rate : "default",
                          pipewire_prefix=hasproperty(options,:pipewire_prefix) ? options.pipewire_prefix : "/opt/pipewireao"))
    println(export_package(args))
    return 0
end

end # module
