module HeartExport

using ..Common
using ..Deployment
using ..ScienceExport
using ..HILExport
using ..HeartConfiguration

const ROOT = ScienceExport.resource_root()
const RAW_SCHEMA = "org.heart.std-wfs.raw-pixels/1"
const COMMAND_SCHEMA = "org.heart.std-dm.actuator-command/1"
const WORKERS = Dict("HOP0.wfs.w"=>4,"HOP0.proc.w"=>6,"HOP0.recon.w"=>8,
                     "WCC.tfc.w"=>10,"WCC.clwc.w"=>10,"WCC.dm0.w"=>14)

option(args,name::Symbol,default=nothing) = hasproperty(args,name) ? getproperty(args,name) : default

function readout_interval(instrument::AbstractString,requested,rate)
    readout = requested === nothing ? (instrument == "copper" ? 2000 : 0) : requested
    rate isa Int && !(rate isa Bool) && rate > 0 || throw(ArgumentError("wall rate must be a positive integer"))
    readout isa Int && !(readout isa Bool) && readout >= 0 && Int128(readout) * rate < 950000 ||
        throw(ArgumentError("readout must be nonnegative and below 95% of the frame period"))
    return readout
end

function bridge_session(instrument::AbstractString,rate::Integer)
    shape = instrument == "classic" ? [352,352] : [64,64]
    function node(name,port,direction,element,extent,schema)
        return Dict("ownership"=>"external","node.name"=>name,"ports"=>[Dict(
            "name"=>port,"direction"=>direction,"element-type"=>element,"shape"=>extent,
            "schema"=>schema,"rate"=>"$rate/1")])
    end
    return Dict{String,Any}("profile"=>"development","execution"=>"external-rtc","authority"=>"none",
        "claim"=>"development-characterization","rate"=>"$rate/1",
        "sources"=>[node("simulator-wfs","output_1","output","U16_LE",shape,RAW_SCHEMA),
                    node("heart-dm-source","command","output","F32_LE",[277],COMMAND_SCHEMA)],
        "graphs"=>Any[],
        "sinks"=>[node("heart-wfs-sink","frame","input","U16_LE",shape,RAW_SCHEMA),
                  node("simulator-command","input_1","input","F32_LE",[277],COMMAND_SCHEMA)],
        "execution-groups"=>Any[],"properties"=>Dict(),"parameters"=>Dict(),"observations"=>Any[],
        "links"=>[Dict("output"=>"simulator-wfs:output_1","input"=>"heart-wfs-sink:frame","passive"=>false),
                  Dict("output"=>"heart-dm-source:command","input"=>"simulator-command:input_1","passive"=>false)])
end

function _artifacts(package)
    artifacts = Dict{String,Any}()
    for (directory,_,files) in walkdir(package), file in files
        path = joinpath(directory,file)
        islink(path) && throw(ArgumentError("symlink in HEART export package: $path"))
        relative = relpath(path,package)
        relative == "deployment.conf" || (artifacts[relative] = ScienceExport.sha256(path))
    end
    return artifacts
end

function _cpu_map(text)
    replacement = Dict("HOP0.wfs.w"=>"4","HOP0.proc.w"=>"6","HOP0.recon.w"=>"8",
        "WCC.tfc.w"=>"10","WCC.clwc.w"=>"10","WCC.dm0.w"=>"14",
        "HOP0.wfs.pxStat"=>"3","HOP0.proc.gOpt"=>"3","WCC.clwc.pdm0"=>"3",
        "HOP0"=>"4, 6, 8","WCC"=>"10, 14","CMDS"=>"3","TELM"=>"3","MON"=>"3")
    for (name,cpus) in replacement
        pattern = Regex("(?m)^"*replace(name,"."=>"\\.")*raw"\s*=\s*\{[^}]*\}")
        count(_ -> true,eachmatch(pattern,text)) == 1 || throw(ArgumentError("expected one native CPU group: $name"))
        text = replace(text,pattern=>"$name = { $cpus }")
    end
    return text
end

function export_package(args)
    base = realpath(args.base_package)
    output = abspath(args.output)
    !ispath(output) && !islink(output) || throw(ArgumentError("export output must be new"))
    specification = Deployment.profile(joinpath(base,"deployment.conf"),args.pipewire_prefix)
    provenance = Common.read_json(joinpath(base,"provenance.json"))
    get(provenance,"engine",nothing) == "fgn" && get(get(provenance,"hil",Dict()),"backend",nothing) == "cpu" ||
        throw(ArgumentError("initial HEART HIL export requires a corrected FGN CPU HIL base"))
    instrument = provenance["profile"]
    instrument in ("classic","copper") && haskey(provenance["hil"],"simulated_calibration") ||
        throw(ArgumentError("HEART requires a maintained simulated-offset calibration base"))
    rate = provenance["hil"]["wall_rate_hz"]
    readout_us = readout_interval(instrument,option(args,:readout_us),rate)
    paths = Deployment.installed_paths(args.pipewire_prefix)
    plugin = joinpath(paths["spa"],"heart/libspa-heart.so")
    isfile(plugin) || throw(ArgumentError("installed HEART SPA plugin is missing"))
    mkpath(dirname(output))
    return mktempdir(dirname(output);prefix=".rtc-heart-export-") do temporary
        package = joinpath(temporary,"package")
        ScienceExport.copy_tree(base,package;ignored=Set(["__pycache__","systemd"]))
        for name in ("pipewireao-rtc-deploy","placement.py","pipewireao-rtc@.service.in")
            path = joinpath(package,"bin",name)
            isfile(path) && rm(path)
        end
        rm(joinpath(package,"graphs");force=true,recursive=true)
        mkpath(joinpath(package,"heart/bin"))
        for name in ("scaoTemplate","scaoTemplateCmdClient")
            source = joinpath(args.heart_root,"source/template/bin",name)
            isfile(source) && (stat(source).mode & 0o111) != 0 || throw(ArgumentError("missing native HEART executable: $source"))
            ScienceExport.copy_file(source,joinpath(package,"heart/bin",name))
        end
        ScienceExport.copy_file(args.rtc_binary,joinpath(package,"bin/pipewireao-rtc"))
        for name in ("simulator.jl","owner_protocol.jl","heart_owner.jl")
            source = joinpath(ROOT,"hil",name)
            destination = joinpath(package,"hil",name)
            isfile(destination) && rm(destination)
            ScienceExport.copy_file(source,destination)
        end
        # Ship the current Julia deployment graph with the HEART owner. The
        # installed owner entrypoint resolves this directory relative to hil/.
        ScienceExport.copy_deployment_runtime(package)
        if option(args,:adapter_root) !== nothing
            adapter = realpath(args.adapter_root)
            installed = joinpath(package,"hil/packages/AdaptiveOpticsSimPipeWireHIL")
            read(joinpath(adapter,"Project.toml")) == read(joinpath(installed,"Project.toml")) ||
                throw(ArgumentError("adapter override requires the base package's exact dependency declaration"))
            rm(installed;recursive=true)
            HILExport.copy_package(adapter,installed)
            provenance["hil"]["adapter_revision"] = ScienceExport.revision(adapter)
            provenance["hil"]["adapter_source"] = adapter
        end
        config = HeartConfiguration.prepare_heart_configuration(package,base,realpath(args.heart_source_config),
                                                                 realpath(args.calibration_root),rate)
        Common.write_json(joinpath(package,"session.conf.in"),bridge_session(instrument,rate))
        core = Deployment.decode(joinpath(package,specification["core"]),args.pipewire_prefix)
        core["context.spa-libs"]["api.heart.*"] = "heart/libspa-heart"
        shape = instrument == "classic" ? 352 : 64
        rows = instrument == "classic" ? 11 : 32
        push!(core["context.objects"],Dict("factory"=>"spa-node-factory","args"=>Dict{String,Any}(
            "factory.name"=>"api.heart.std-wfs.sink","node.name"=>"heart-wfs-sink","node.loop.name"=>"rtc-data-loop",
            "node.virtual"=>true,"object.linger"=>true,"api.heart.std-wfs.destination-address"=>"127.0.0.1",
            "api.heart.std-wfs.port"=>6000,"api.heart.std-wfs.source"=>0,"api.heart.std-wfs.pixel-type"=>"raw",
            "api.heart.std-wfs.width"=>shape,"api.heart.std-wfs.height"=>shape,
            "api.heart.std-wfs.roi-row-offset"=>config["detector_roi"]["row"],
            "api.heart.std-wfs.roi-column-offset"=>config["detector_roi"]["column"],
            "api.heart.std-wfs.frame-rate"=>"$rate/1","api.heart.std-wfs.network-byte-order"=>false,
            "api.heart.std-wfs.pixels-per-datagram"=>rows*shape,"api.heart.std-wfs.rows-per-datagram"=>true,
            "api.heart.std-wfs.readout-time"=>readout_us)))
        push!(core["context.objects"],Dict("factory"=>"spa-node-factory","args"=>Dict{String,Any}(
            "factory.name"=>"api.heart.std-dm.source","node.name"=>"heart-dm-source","node.loop.name"=>"rtc-data-loop",
            "node.virtual"=>true,"object.linger"=>true,"api.heart.std-dm.bind-address"=>"127.0.0.1",
            "api.heart.std-dm.port"=>6100,"api.heart.std-dm.target-id"=>0,"api.heart.std-dm.actuator-count"=>277,
            "api.heart.std-dm.frame-rate"=>"$rate/1")))
        ScienceExport.write_spa_config(joinpath(package,specification["core"]),core)
        rtc_client = Deployment.decode(joinpath(package,specification["client"]["rtc"]),args.pipewire_prefix)
        pop!(rtc_client["context.properties"],"context.data-loops",nothing)
        filter!(item -> item["name"] != "libpipewire-module-rt",rtc_client["context.modules"])
        ScienceExport.write_spa_config(joinpath(package,"client-heart-rtc.conf.in"),rtc_client)
        specification["client"]["rtc"] = "client-heart-rtc.conf.in"
        specification["placement"]["rtc"] = Dict("cpus"=>[14],"leader-cpu"=>14,"rt-priority"=>0,"threads"=>Any[],"locked-bytes"=>0)
        cpu = read(joinpath(@__DIR__,"assets/ryzen-6800h-classic.cpu"),String)
        write(joinpath(package,"heart/host.cpu"),_cpu_map(cpu))
        ScienceExport.copy_file(joinpath(@__DIR__,"assets/ryzen-6800h-classic.threads"),joinpath(package,"heart/host.threads"))
        Common.write_json(joinpath(package,"heart/placement.json"),Dict("cpus"=>[3,4,6,8,10,14],
            "allowed_priorities"=>[5,10,15,20],"workers"=>[Dict("name"=>name,"cpus"=>[cpu],"policy"=>1,"priority"=>15) for (name,cpu) in WORKERS]))
        markers = Dict(name=>"heart."*name for name in ("prepared","connect","connected","quit"))
        executable = Sys.which("julia")
        executable === nothing && throw(ArgumentError("Julia executable is an unresolved HEART owner prerequisite"))
        argv = String[realpath(executable),"--startup-file=no","--project=@PACKAGE@/julia","@PACKAGE@/hil/heart_owner.jl",
            "--executable","@PACKAGE@/heart/bin/scaoTemplate","--client","@PACKAGE@/heart/bin/scaoTemplateCmdClient",
            "--config","@PACKAGE@/heart/config.yaml.in","--runtime","@RUNTIME@/heart/native",
            "--cpu-map","@PACKAGE@/heart/host.cpu","--thread-map","@PACKAGE@/heart/host.threads",
            "--requirements","@PACKAGE@/heart/requirements.json","--calibration-root","@PACKAGE@/heart/calibration",
            "--placement","@PACKAGE@/heart/placement.json","--control-request","@RUNTIME@/heart.control.request",
            "--control-reply","@RUNTIME@/heart.control.reply"]
        for (option,key) in (("--prepared-event","prepared"),("--connect-request","connect"),
                             ("--connect-reply","connected"),("--quit-request","quit"))
            append!(argv,[option,"@RUNTIME@/"*markers[key]])
        end
        simulator = deepcopy(only([owner for owner in specification["owners"] if owner["role"] == specification["source-owner"]]))
        append!(simulator["argv"],["--transport","heart","--controller-request","@RUNTIME@/heart.control.request",
                                   "--controller-reply","@RUNTIME@/heart.control.reply"])
        specification["owners"] = [merge(Dict{String,Any}("role"=>"heart","argv"=>argv,
            "environment"=>Dict("HRT_MEMORY_HUGEPAGES"=>"0","HRT_DEFER_WFS_INGRESS"=>"0")),markers),simulator]
        specification["placement"]["simulator"] = Dict("cpus"=>[12],"leader-cpu"=>12,"rt-priority"=>0,"threads"=>Any[],"locked-bytes"=>0)
        specification["placement"]["heart"] = Dict("cpus"=>[3,4,6,8,10,14],"leader-cpu"=>3,"rt-priority"=>0,"threads"=>Any[],"locked-bytes"=>0)
        specification["client"]["heart"] = "client-simulator.conf.in"
        specification["environment"] = Dict{String,Any}()
        specification["name"] = "revolt-$instrument-heart-hil-cpu"
        provenance["engine"] = "heart"
        merge!(provenance["hil"],Dict("command_unit"=>"metre OPD","plant_command_scale"=>1.0,"transport"=>"heart"))
        provenance["heart"] = merge(config,Dict("revision"=>ScienceExport.revision(args.heart_root),
            "plugin_sha256"=>ScienceExport.sha256(plugin),"readout_us"=>readout_us,"packet_rows"=>rows,
            "numeric_equivalence"=>"not established by finite HIL deployment"))
        Common.write_json(joinpath(package,"provenance.json"),provenance)
        specification["artifacts"] = _artifacts(package)
        Common.write_json(joinpath(package,"deployment.conf"),specification)
        Deployment.profile(joinpath(package,"deployment.conf"),args.pipewire_prefix)
        mv(package,output)
        return joinpath(output,"deployment.conf")
    end
end

function main(argv=ARGS)
    installed_binary = joinpath(@__DIR__, "..", "bin", "pipewireao-rtc")
    default_binary = isfile(installed_binary) ? installed_binary :
        normpath(joinpath(@__DIR__, "..", "..", "target", "release", "pipewireao-rtc"))
    options = Common.cli_arguments(argv;required=["base-package","output","heart-root","heart-source-config","calibration-root"],
        allowed=["adapter-root","readout-us"],defaults=(rtc_binary=default_binary,
                                                         pipewire_prefix="/opt/pipewireao"))
    args = merge(options,(readout_us=hasproperty(options,:readout_us) ? parse(Int,options.readout_us) : nothing,))
    println(export_package(args))
    return 0
end

end # module
