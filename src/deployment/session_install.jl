"""Install the headless RTC session launcher and its systemd unit."""
module SessionInstall

import ..PipeWireAORTC
using JSON3

const D = PipeWireAORTC.DeploymentConfiguration
const C = PipeWireAORTC.Common

export install, main

function installed_launcher(julia::AbstractString; environment=nothing)
    quoted = D.shell_quote(julia)
    if environment !== nothing
        return "#!/bin/sh\n" *
            "exec $quoted --startup-file=no --project=" * D.shell_quote(environment) *
            " -e 'using PipeWireAORTC; exit(PipeWireAORTC.SessionCLI.main(ARGS))' -- \"\$@\"\n"
    end
    return "#!/bin/sh\n" *
        "julia_dir=\"\$(dirname \"\$0\")/../julia\"\n" *
        "exec $quoted --startup-file=no --project=\"\$julia_dir\" " *
        "\"\$julia_dir/session_cli.jl\" \"\$@\"\n"
end

function required_assets(package)
    runtime = joinpath(package, "julia")
    for name in ("session_cli.jl", "session_launch.jl",
                 "session_configuration.jl", "session_install.jl",
                 "assets/deployment/pipewireao-session@.service.in")
        isfile(joinpath(runtime, name)) ||
            throw(ArgumentError("new session install requires $name in the sealed Julia runtime"))
    end
    return runtime
end

function session_spec(package, prefix)
    spec = D.profile(joinpath(package, "deployment.conf"), prefix)
    spec["cpu-latency-us"] === nothing ||
        throw(ArgumentError("headless RTC session does not yet retain a CPU DMA latency lease; cpu-latency-us must be null"))
    get(spec, "source-owner", nothing) isa String ||
        throw(ArgumentError("new session install requires a declared held source owner"))
    haskey(spec, "node-owners") ||
        throw(ArgumentError("new session install requires exact node-owners in deployment.conf"))
    haskey(spec, "session-runtime") ||
        throw(ArgumentError("new session install requires a packaged headless RTC executable"))
    placement = spec["placement"]["session"]
    all(cpu -> cpu isa Int && cpu >= 2, placement["cpus"]) ||
        throw(ArgumentError("RTC CPU placement must exclude CPU 0 and 1"))
    return spec
end

function session_assets(spec, package, prefix)
    registered = D.registered_application(spec)
    if !registered
        PipeWireAORTC.ScienceExport.validate_wireplumber(joinpath(package, "wireplumber"))
        PipeWireAORTC.ScienceExport.validate_rtc(joinpath(package, "rtc"))
    end
    binary = D.session_executable(spec, package, prefix)
    isfile(binary) && !islink(binary) && (stat(binary).mode & 0o111) != 0 ||
        throw(ArgumentError("headless RTC native executable is unavailable: $binary"))
    if registered
        paths = D.installed_paths(prefix)
        for file in (joinpath(paths["library"], "libwireplumber-0.5.so.0"),
                (joinpath(prefix, "lib/pipewireao-rtc/modules", "libwireplumber-module-$name.so")
                    for name in PipeWireAORTC.ScienceExport.RTC_MODULES)...,
                (joinpath(prefix, "share/pipewireao-rtc/scripts", relative)
                    for relative in PipeWireAORTC.ScienceExport.RTC_SCRIPTS)...,
                (joinpath(paths["library"], "wireplumber-0.5", "libwireplumber-module-$name.so")
                    for name in PipeWireAORTC.ScienceExport.WIREPLUMBER_MODULES)...)
            isfile(file) || throw(ArgumentError("installed session asset is unavailable: $file"))
        end
    end
    return nothing
end

function validate_sealed_wrappers(source, source_spec, wrappers)
    for (name, script) in wrappers
        relative = "bin/$name"
        haskey(source_spec["artifacts"], relative) || continue
        # Old sealed calibrations retain their Rust executable. Never rewrite
        # that artifact or treat it as a newly generated Julia entrypoint.
        if name == "rtc-calibrate"
            provenance = C.read_json(joinpath(source, "provenance.json"))
            command = get(provenance, "calibration_command", nothing)
            command === nothing && continue
            get(command, "implementation", nothing) == "julia" || continue
        end
        read(joinpath(source, relative), String) == script ||
            throw(ArgumentError("sealed $relative differs from the selected Julia executable"))
    end
    return nothing
end

"""
    install(options)

Validate and copy a sealed session package into a fresh `options.destination`.
Supply absolute `package` and `pipewire_prefix` paths; optional `julia_executable`
selects the Julia client executable. Return the
installation path. Service activation remains a separate operator action.
"""
function install(options)
    source = realpath(options.package)
    prefix = realpath(options.pipewire_prefix)
    source_spec = session_spec(source, prefix)
    haskey(source_spec["artifacts"], "systemd/pipewireao-session@.service") &&
        throw(ArgumentError("export must not seal an installation-specific session unit"))
    registered = D.registered_application(source_spec)
    registered || required_assets(source)
    session_assets(source_spec, source, prefix)
    hasproperty(options, :wireplumber) &&
        throw(ArgumentError("WirePlumber daemon overrides are not session runtimes"))
    executable = D.session_executable(source_spec, abspath(options.destination), prefix)
    julia = D.selected_julia_executable(get(options, :julia_executable,
                                            Base.julia_cmd().exec[1]))
    wrappers = D.installed_wrappers(julia)
    validate_sealed_wrappers(source, source_spec, wrappers)
    destination = abspath(options.destination)
    !(ispath(destination) || islink(destination)) ||
        throw(ArgumentError("install destination must be new"))
    # Copy the sealed package without regenerating legacy coordinator units.
    # Rewriting an artifact here would invalidate its retained package hash.
    registered || D.validate_runtime(required_assets(source))
    cp(source, destination; force=false, follow_symlinks=true)
    runtime = registered ? PipeWireAORTC.package_root() : required_assets(destination)
    installed_spec = session_spec(destination, prefix)
    session_assets(installed_spec, destination, prefix)
    isfile(executable) && (stat(executable).mode & 0o111) != 0 ||
        throw(ArgumentError("installed RTC native executable is unavailable"))
    bin = joinpath(destination, "bin")
    mkpath(bin)
    for (name, script) in (registered ? Dict{String,String}() : wrappers)
        entrypoint = joinpath(bin, name)
        haskey(source_spec["artifacts"], "bin/$name") || write(entrypoint, script)
        chmod(entrypoint, 0o755)
    end
    launcher = joinpath(bin, "pipewireao-rtc-session")
    environment = registered ? D.application_environment(installed_spec, destination) : nothing
    script = installed_launcher(julia; environment)
    if haskey(source_spec["artifacts"], "bin/pipewireao-rtc-session")
        read(launcher, String) == script ||
            throw(ArgumentError("sealed session launcher differs from the selected Julia executable"))
    else
        write(launcher, script)
    end
    chmod(launcher, 0o755)
    quote_unit(value) = String(JSON3.write(replace(String(value), "%" => "%%")))
    template = read(joinpath(runtime, "assets/deployment/pipewireao-session@.service.in"), String)
    cpus = sort!(collect(installed_spec["placement"]["session"]["cpus"]))
    unit = replace(template,
        "@LAUNCHER@" => quote_unit(launcher),
        "@PACKAGE@" => quote_unit(destination),
        "@PIPEWIRE_PREFIX@" => quote_unit(prefix),
        "@RTC_EXECUTABLE@" => quote_unit(executable),
        "@SOURCE_ROLE@" => installed_spec["source-owner"],
        "@CPUS@" => join(cpus, " "),
        "TimeoutStartSec=300" => "TimeoutStartSec=" * string(D.startup_timeout_ms(installed_spec) / 1000))
    occursin(r"@[A-Z_]+@", unit) &&
        throw(ArgumentError("unresolved RTC unit template binding"))
    systemd = joinpath(destination, "systemd")
    mkpath(systemd)
    write(joinpath(systemd, "pipewireao-session@.service"), unit)
    return destination
end

"""
    main(argv=ARGS)

Parse installer arguments and return the installed package path. Required flags
are `--package`, `--destination` and `--pipewire-prefix`; validation errors throw.
"""
function main(argv=ARGS)
    args = C.cli_arguments(argv;
        required=["package", "destination", "pipewire-prefix"],
        allowed=["julia-executable"])
    return install(args)
end

end # module
