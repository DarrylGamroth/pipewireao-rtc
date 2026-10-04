module CalibrationMethod

import ..Common: read_json, write_json, sha256_file, cli_arguments
import ..CalibrationCampaign as Campaign
import ..Deployment
import ..CalibrationExport
import ..HILExport

export validate_method, retained_startup, method, main

function validate_method(value)
    value isa AbstractDict && Set(keys(value)) in
        (Set(("version","run","order")),Set(("version","run","order","probe_basis"))) ||
        throw(ArgumentError("method requires version, run, order and optional probe_basis"))
    Campaign.isint(value["version"]) && value["version"]==1 ||
        throw(ArgumentError("unsupported method version"))
    Campaign.positive_integer(value["run"],"method run",typemax(UInt64))
    value["order"] in ("forward","reverse") || throw(ArgumentError("method order must be forward or reverse"))
    if haskey(value,"probe_basis")
        basis=value["probe_basis"]
        basis isa AbstractDict || throw(ArgumentError("probe_basis must be an object"))
        expected=Dict(
            "zonal"=>Set(("kind",)),"hadamard"=>Set(("kind",)),
            "modal"=>Set(("kind","positive_commands","mode_amplitudes")),
            "spatial_sine"=>Set(("kind","actuator_positions","spatial_frequencies",
                "mode_amplitudes","normalization","minimum_sampled_peak")))
        kind=get(basis,"kind",nothing)
        kind isa AbstractString && haskey(expected,kind) && Set(keys(basis))==expected[kind] ||
            throw(ArgumentError("unknown or incomplete probe basis"))
    end
    return deepcopy(value)
end

function retained_startup(base,prefix)
    specification=Deployment.profile(joinpath(base,"deployment.conf"),prefix)
    provenance=HILExport.campaign_json(base,"provenance.json")
    snapshot,graph,bindings=HILExport.classic_snapshot(base,provenance,prefix)
    HILExport.validate_startup_bindings(base,specification,provenance,graph,bindings)
    payloads=Any[]
    for (name,element,shape) in (("background","F32_LE",(352,352)),
                                 ("reference-slopes","F32_LE",(188,2)),
                                 ("active","Bool",(188,)))
        binding=bindings[name]
        path=HILExport.campaign_file(base,joinpath("calibration",binding["file"]),1024*1024)
        (!haskey(binding,"sha256") || sha256_file(path)==binding["sha256"]) ||
            throw(ArgumentError("retained startup binding hash differs: $name"))
        push!(payloads,HILExport.finite_payload(path,element,shape))
    end
    return payloads...,snapshot
end

function within(path,root)
    relative=relpath(abspath(path),abspath(root))
    return relative=="." || (relative!=".." && !startswith(relative,".."*Base.Filesystem.path_separator))
end

function analysis(action,output,package,julia,timeout;seal=nothing)
    argv=[julia,"--startup-file=no","--threads=2,0","--project="*joinpath(package,"hil"),
        joinpath(output,"analysis","calibration_method_analysis.jl"),action,output,package]
    seal===nothing || push!(argv,seal)
    Campaign.checked_analysis(argv,output,action,timeout)
end

function method(arguments)
    started=time_ns()
    Base.ENDIAN_BOM==0x04030201 || throw(ArgumentError("packed method results require little-endian host"))
    prefix=abspath(arguments.prefix)
    prefix=="/opt/pipewireao" || throw(ArgumentError("method supports /opt/pipewireao only"))
    recipe=Campaign.validate_recipe(read_json(arguments.recipe))
    declaration=validate_method(read_json(arguments.method))
    base=abspath(arguments.base_package)
    output=abspath(arguments.output)
    aoc=abspath(arguments.aoc_source)
    !ispath(output) && !islink(output) && !within(output,base) && !within(output,aoc) ||
        throw(ArgumentError("method output must be new and outside source packages"))
    runtime=abspath(arguments.runtime)
    !ispath(runtime) && !islink(runtime) && !within(runtime,base) && !within(runtime,aoc) &&
        !within(runtime,output) && !within(output,runtime) ||
        throw(ArgumentError("method runtime must be fresh and separate"))
    identity=Campaign.file_identity(base)
    source_identity=Campaign.orchestration_sources()
    aoc_identity=Campaign.file_identity(aoc)
    input_identity=Dict(abspath(path)=>sha256_file(Campaign.regular(path)) for path in
        (arguments.recipe,arguments.method,arguments.rtc_binary,arguments.calibration_binary))
    background,references,active,snapshot=retained_startup(base,prefix)
    mkpath(output)
    timing=Dict{String,Any}(name=>nothing for name in
        ("preparation","startup_readiness","acquisition","public_shutdown","reduction","total"))
    record=Dict{String,Any}("version"=>1,"phase"=>"preparing",
        "scope"=>"Classic CPU simulated method acquisition; unaccepted candidate","timing_ns"=>timing,
        "source_files"=>source_identity,"aoc_files"=>aoc_identity,"input_files"=>input_identity)
    check_inputs=()->begin
        Campaign.check_identity(base,identity)
        Campaign.file_identity(aoc)==aoc_identity && Campaign.orchestration_sources()==source_identity &&
            all(sha256_file(path)==hash for (path,hash) in input_identity) ||
            throw(ArgumentError("method source input changed"))
    end
    try
        write_json(joinpath(output,"recipe.json"),recipe)
        write_json(joinpath(output,"method.json"),declaration)
        cp(arguments.recipe,joinpath(output,"input-recipe.json"))
        cp(arguments.method,joinpath(output,"input-method.json"))
        write_json(joinpath(output,"base-identity.json"),Dict("files"=>identity,
            "startup_snapshot"=>snapshot,"source_recipe_sha256"=>sha256_file(arguments.recipe),
            "source_method_sha256"=>sha256_file(arguments.method)))
        base_copy=Campaign.stage_base(base,joinpath(output,"method-base"),recipe,"interaction",
            background,references,active,aoc,prefix)
        package=joinpath(output,"package")
        CalibrationExport.export_package((;base_package=base_copy,output=package,
            pipewire_prefix=prefix,deployment=true,rtc_binary=arguments.rtc_binary,
            calibration_binary=arguments.calibration_binary,illumination="lamp",
            calibration_stage="interaction",capture_max_bytes=nothing))
        scripts=joinpath(output,"analysis")
        mkdir(scripts)
        cp(joinpath(HILExport.ScienceExport.resource_root(),"hil","calibration_method_analysis.jl"),
           joinpath(scripts,"calibration_method_analysis.jl"))
        cp(joinpath(package,"hil","calibration_client.jl"),joinpath(scripts,"calibration_client.jl"))
        sources=joinpath(output,"orchestration-sources")
        mkdir(sources)
        for path in keys(Campaign.orchestration_sources())
            target=joinpath(sources,HILExport.ScienceExport.source_relative_path(path))
            mkpath(dirname(target))
            cp(path,target)
        end
        analysis("prepare",output,package,arguments.julia,recipe["stage_timeout_seconds"])
        check_inputs()
        frozen=Dict{String,String}()
        for path in readdir(output;join=true)
            isfile(path) && (frozen[basename(path)]=sha256_file(path))
        end
        for directory in (scripts,sources), (relative,hash) in Campaign.file_identity(directory)
            frozen[joinpath(relpath(directory,output),relative)]=hash
        end
        package_identity=Campaign.file_identity(package)
        write_json(joinpath(output,"prepared-identity.json"),Dict("files"=>frozen,
            "package_files"=>package_identity))
        seal=sha256_file(joinpath(output,"prepared-identity.json"))
        record["prepared_identity_sha256"]=seal
        timing["preparation"]=time_ns()-started
        record["phase"]="acquiring"
        check_inputs()
        acquired=Campaign.run_stage(package,joinpath(output,"evidence"),runtime,recipe,"interaction")
        record["stage"]=acquired
        for name in ("startup_readiness","acquisition","public_shutdown")
            timing[name]=acquired["timing_ns"][name]
        end
        all(get(acquired,name,false)===true for name in
            ("restoration_confirmed","release_confirmed","shutdown_confirmed")) &&
            !haskey(acquired,"failure") || throw(ArgumentError("method acquisition lifecycle incomplete"))
        sha256_file(joinpath(output,"prepared-identity.json"))==seal ||
            throw(ArgumentError("prepared identity changed"))
        all(sha256_file(joinpath(output,relative))==hash for (relative,hash) in frozen) ||
            throw(ArgumentError("prepared method input changed"))
        Campaign.check_identity(package,package_identity)
        check_inputs()
        reduced=time_ns()
        try
            analysis("reduce",output,package,arguments.julia,recipe["stage_timeout_seconds"];seal)
        finally
            timing["reduction"]=time_ns()-reduced
        end
        record["candidate"]=read_json(joinpath(output,"candidate-response.json"))
        record["phase"]="complete-candidate"
    catch error
        record["failure"]=sprint(showerror,error)
        rethrow()
    finally
        timing["preparation"]===nothing && (timing["preparation"]=time_ns()-started)
        evidence=joinpath(output,"evidence","stage-result.json")
        if isfile(evidence) && !haskey(record,"stage")
            record["stage"]=read_json(evidence)
            for name in ("startup_readiness","acquisition","public_shutdown")
                timing[name]=get(get(record["stage"],"timing_ns",Dict()),name,nothing)
            end
        end
        timing["total"]=time_ns()-started
        Deployment.atomic_record(joinpath(output,"method-result.json"),record)
    end
    return joinpath(output,"method-result.json")
end

function main(argv=ARGS)
    arguments=cli_arguments(argv;required=["base-package","recipe","method","output","aoc-source",
        "rtc-binary","calibration-binary","runtime"],defaults=(prefix="/opt/pipewireao",julia="julia"))
    println(method(arguments))
    return 0
end

end # module
