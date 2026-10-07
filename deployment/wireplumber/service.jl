#!/usr/bin/env julia
module WirePlumberService
include("session.jl")
const W=WirePlumberSession
const D,C=W.D,W.C
const N=W.PipeWireAODeployment.NativeSupervisorClient
const Commands=W.PipeWireAODeployment.RunnerCommands
require(value,message)=W.require(value,message)

function unit_identity(unit)
    require(occursin(r"^pipewireao-rtc@[A-Za-z0-9_.-]+\.service$",unit),"Expected an instance RTC user unit")
    result=C.run_checked(["systemctl","--user","show",unit,"-p","ActiveState","-p","MainPID"];
        timeout=5,maximum_output_bytes=4096)
    require(result.returncode==0,"Cannot inspect RTC user unit")
    values=Dict(split(line,'=';limit=2) for line in split(strip(result.stdout),'\n'))
    pid=parse(Int,values["MainPID"])
    require(values["ActiveState"]=="active" && pid>0,"RTC user unit is not active")
    return pid
end

function supported_package(package,prefix)
    spec=D.profile(joinpath(package,"deployment.conf"),prefix)
    verify_supported(spec,C.read_json(joinpath(package,"provenance.json")))
    return spec
end
function verify_supported(spec,provenance)
    require(get(spec,"source-owner",nothing)=="simulator","Observer service requires an AOS HIL package")
    require(Set(owner["role"] for owner in spec["owners"]) in (Set(["simulator"]),Set(["simulator","julia"])),
        "Observer service supports simulator and optional Julia graph owners only")
    require(provenance["profile"]=="copper","Observer service is qualified only for Copper HIL")
    return spec
end

function verify_package_owner(pid,package)
    argv=split(read("/proc/$pid/cmdline",String),'\0';keepempty=false)
    index=findfirst(==("--deployment"),argv)
    require(index!==nothing && index<length(argv) &&
        realpath(argv[index+1])==realpath(joinpath(package,"deployment.conf")),
        "RTC unit does not run the selected deployment descriptor")
    return nothing
end

function observed_status(client;deadline)
    completion=N.request!(client,Commands.parse(["status"]);deadline)
    ready=N.render(completion;owner_pid=client.observation.owner_pid)
    require(ready["ok"] && ready["admitted"],"RTC unit has no fresh admitted session")
    return ready
end

verify_locator_owner(locator,pid)=require(locator.owner_pid==pid,"Locator belongs to another RTC unit incarnation")
verify_unit_owner(inspect,unit,pid)=require(inspect(unit)==pid,"RTC unit incarnation changed during preparation")
function verify_cohort(ready,final,uuid,current_uuid)
    require(final["processes"]==ready["processes"] && current_uuid==uuid,
        "Required owner cohort changed during preparation")
end

function configuration(arguments,remote)
    encoded=strip(String(C.JSON3.write(arguments)))
    address=String(C.JSON3.write(remote))
    return """
    context.properties = { library.use-fallback = false remote.name = $address }
    context.modules = [ { name = libpipewire-module-protocol-native } ]
    wireplumber.profiles = {
        ao-hil = { support.lua-scripting = required ao.hil-observer = required }
    }
    wireplumber.components = [
        { name = libwireplumber-module-lua-scripting type = module
          provides = support.lua-scripting }
        { name = hil-observer.lua type = script/lua
          provides = ao.hil-observer requires = [ support.lua-scripting ]
          arguments = $encoded }
    ]
    """
end

function prepare(package,runtime,unit,output,prefix; inspect=unit_identity)
    package,runtime,output,prefix=abspath.((package,runtime,output,prefix))
    require(isdir(output) && !islink(output),"Private observer RuntimeDirectory is missing")
    # A failed restart must never leave a previous executable configuration.
    config=joinpath(output,"wireplumber.conf")
    isfile(config) && rm(config)
    supported_package(package,prefix)
    D.validate_runtime(joinpath(package,"julia"))
    pid=inspect(unit)
    verify_package_owner(pid,package)
    locator=N.read_locator(joinpath(runtime,"control.json"))
    verify_locator_owner(locator,pid)
    deadline=time_ns()/1e9+30
    check()=verify_unit_owner(inspect,unit,pid)
    client=N.connect(locator;deadline,check)
    try
        uuid=N.live_uuid(client)
        ready=observed_status(client;deadline)
        arguments,required,nodes=W.manifest(W.registry(locator.remote;prefix),ready,package;prefix)
        check()
        final=observed_status(client;deadline)
        verify_cohort(ready,final,uuid,N.live_uuid(client))
        check()
        record=Dict("unit"=>unit,"owner_pid"=>pid,"deployment_uuid"=>uuid,
            "descriptor_sha256"=>C.sha256_file(joinpath(package,"deployment.conf")),
            "remote"=>locator.remote,"objects"=>arguments["objects"],
            "scope"=>"optional observation of RTC-admitted contracts; no science or link authority")
        C.write_json(joinpath(output,"binding.json"),record)
        temporary=joinpath(output,"wireplumber.conf.tmp")
        write(temporary,configuration(arguments,locator.remote))
        mv(temporary,config;force=true)
        println("WIREPLUMBER_PREPARED unit=$unit owner=$pid uuid=$uuid")
    finally
        close(client)
    end
end

function path_argument(path;search=false)
    path=abspath(path)
    require(!occursin(r"[\x00\r\n]",path) && (!search || !occursin(':',path)),"Unsupported path characters")
    return path
end
unit_quote(value;argument=false)=String(C.JSON3.write(replace(
    argument ? replace(value,"\$"=>"\$\$") : value,"%"=>"%%")))

function copy_libraries(source,destination)
    mkpath(destination)
    for name in readdir(source)
        occursin(r"\.so($|\.)",name) || continue
        cp(joinpath(source,name),joinpath(destination,name);follow_symlinks=true)
    end
end

function install(package,source,build,destination,prefix,cpu)
    package=path_argument(realpath(package)); source=path_argument(realpath(source);search=true)
    build=path_argument(realpath(build);search=true); destination=path_argument(destination;search=true)
    prefix=path_argument(realpath(prefix);search=true)
    require(!ispath(destination) && !islink(destination),"Fresh companion installation required")
    require(cpu>=2 && cpu<Sys.CPU_THREADS,"Observer CPU must exclude CPU0/1 and exist on this host")
    supported_package(package,prefix)
    D.validate_runtime(joinpath(package,"julia"))
    julia=D.selected_julia_executable(Base.julia_cmd().exec[1])
    paths=D.installed_paths(prefix)
    binary=joinpath(build,"src/wireplumber")
    require(isfile(binary) && isexecutable(binary),"WirePlumber build is missing")
    env=Dict("LD_LIBRARY_PATH"=>joinpath(build,"lib/wp")*":"*paths["library"])
    selection=C.run_checked(["ldd",binary];env,timeout=5,maximum_output_bytes=16384)
    require(selection.returncode==0 && occursin("libpipewire-ao-0.3",selection.stdout) &&
        !occursin("libpipewire-0.3.so",selection.stdout) && !occursin("not found",selection.stdout),
        "WirePlumber must resolve the selected AO libraries")
    mkpath(destination;mode=0o700)
    cp(binary,joinpath(destination,"wireplumber"))
    copy_libraries(joinpath(build,"lib/wp"),joinpath(destination,"lib"))
    copy_libraries(joinpath(build,"modules"),joinpath(destination,"modules"))
    cp(joinpath(source,"src/scripts"),joinpath(destination,"scripts");follow_symlinks=true)
    licenses=joinpath(destination,"licenses");mkpath(licenses)
    cp(joinpath(source,"LICENSE"),joinpath(licenses,"WirePlumber.txt"))
    # The qualified build embeds Lua. Preserve its upstream copyright/license
    # in the header, without copying or adapting algorithm implementations.
    wrap=read(joinpath(source,"subprojects/lua.wrap"),String)
    directory=only(match(r"(?m)^directory\s*=\s*(\S+)\s*$",wrap).captures)
    lua_header=joinpath(source,"subprojects",directory,"src/lua.h")
    require(isfile(lua_header),"Qualified bundled Lua license/header is missing")
    cp(lua_header,joinpath(licenses,"Lua.h"))
    for name in ("service.jl","session.jl","pipewireao-wireplumber@.service.in")
        cp(joinpath(@__DIR__,name),joinpath(destination,name))
    end
    cp(joinpath(@__DIR__,"hil-observer.lua"),joinpath(destination,"scripts/hil-observer.lua"))
    prepare=join(unit_quote.( [julia,"--startup-file=no","--compiled-modules=existing",
        "--project="*joinpath(package,"julia"),joinpath(destination,"service.jl")];argument=true)," ")
    replacements=Dict("@PREPARE@"=>prepare,"@PACKAGE@"=>unit_quote(package;argument=true),
        "@PREFIX@"=>unit_quote(prefix;argument=true),"@EXECUTABLE@"=>unit_quote(joinpath(destination,"wireplumber");argument=true),
        "@CPU@"=>string(cpu),
        "@LIBRARIES@"=>unit_quote("LD_LIBRARY_PATH="*joinpath(destination,"lib")*":"*paths["library"]),
        "@MODULES@"=>unit_quote("WIREPLUMBER_MODULE_DIR="*joinpath(destination,"modules")),
        "@DATA@"=>unit_quote("WIREPLUMBER_DATA_DIR="*destination),
        "@AO_MODULES@"=>unit_quote("PIPEWIREAO_MODULE_DIR="*paths["modules"]),
        "@AO_SPA@"=>unit_quote("PIPEWIREAO_SPA_PLUGIN_DIR="*paths["spa"]))
    template=read(joinpath(@__DIR__,"pipewireao-wireplumber@.service.in"),String)
    unit=replace(template,replacements...)
    write(joinpath(destination,"pipewireao-wireplumber@.service"),unit)
    C.write_json(joinpath(destination,"installation.json"),Dict("package"=>package,"prefix"=>prefix,"cpu"=>cpu,
        "source"=>source,"build"=>build,"julia"=>julia,"wireplumber_sha256"=>C.sha256_file(binary),
        "scope"=>"Copper HIL optional user service; no release or scientific qualification"))
    println(destination)
end

function main(args)
    length(args)==7 && args[1]=="install" && return install(args[2:6]...,parse(Int,args[7]))
    length(args)==6 && args[1]=="prepare" && return prepare(args[2:6]...)
    error("expected install PACKAGE WP_SOURCE WP_BUILD FRESH_DEST PREFIX CPU or prepare PACKAGE RTC_RUNTIME RTC_UNIT PRIVATE_OUTPUT PREFIX")
end
end
abspath(PROGRAM_FILE)==(@__FILE__) && WirePlumberService.main(ARGS)
