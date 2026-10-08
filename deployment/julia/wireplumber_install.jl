"""Install the WirePlumber session launcher and its systemd unit."""
module WirePlumberInstall

using PipeWireAODeployment
using JSON3

const D = PipeWireAODeployment.DeploymentConfiguration
const C = PipeWireAODeployment.Common

export install, main

function installed_launcher(julia::AbstractString)
    quoted = D.shell_quote(julia)
    return "#!/bin/sh\n" *
        "julia_dir=\"\$(dirname \"\$0\")/../julia\"\n" *
        "exec $quoted --startup-file=no --project=\"\$julia_dir\" " *
        "\"\$julia_dir/wireplumber_cli.jl\" \"\$@\"\n"
end

function required_assets(package)
    runtime = joinpath(package, "julia")
    for name in ("wireplumber_cli.jl", "wireplumber_launch.jl",
                 "wireplumber_configuration.jl", "wireplumber_install.jl",
                 "assets/deployment/pipewireao-session@.service.in")
        isfile(joinpath(runtime, name)) ||
            throw(ArgumentError("new session install requires $name in the sealed Julia runtime"))
    end
    return runtime
end

function session_spec(package, prefix)
    spec = D.profile(joinpath(package, "deployment.conf"), prefix)
    spec["cpu-latency-us"] === nothing ||
        throw(ArgumentError("WirePlumber session does not yet retain a CPU DMA latency lease; cpu-latency-us must be null"))
    get(spec, "source-owner", nothing) isa String ||
        throw(ArgumentError("new session install requires a declared held source owner"))
    haskey(spec, "node-owners") ||
        throw(ArgumentError("new session install requires exact node-owners in deployment.conf"))
    haskey(spec, "session-manager") ||
        throw(ArgumentError("new session install requires a packaged WirePlumber binary"))
    placement = spec["placement"]["wireplumber"]
    all(cpu -> cpu isa Int && cpu >= 2, placement["cpus"]) ||
        throw(ArgumentError("WirePlumber CPU placement must exclude CPU 0 and 1"))
    return spec
end

function session_assets(spec, package, prefix)
    bindings = Dict("PACKAGE" => package, "PREFIX" => prefix)
    environment = spec["session-manager"]["environment"]
    module_dir = D.substitute(environment["WIREPLUMBER_MODULE_DIR"], bindings)
    data_dir = D.substitute(environment["WIREPLUMBER_DATA_DIR"], bindings)
    for file in (joinpath(package, "wireplumber/bin/wireplumber"),
                 joinpath(package, "wireplumber/lib/wp/libwireplumber-0.5.so.0"),
                 joinpath(module_dir, "libwireplumber-module-ao-control-endpoint.so"),
                 joinpath(module_dir, "libwireplumber-module-lua-scripting.so"),
                 joinpath(data_dir, "scripts/ao/session.lua"))
        isfile(file) && isabspath(file) ||
            throw(ArgumentError("one-shot session requires packaged WirePlumber asset $file"))
    end
    return nothing
end

function install(options)
    source = realpath(options.package)
    prefix = realpath(options.pipewire_prefix)
    source_spec = session_spec(source, prefix)
    haskey(source_spec["artifacts"], "systemd/pipewireao-session@.service") &&
        throw(ArgumentError("export must not seal an installation-specific session unit"))
    required_assets(source)
    session_assets(source_spec, source, prefix)
    external = hasproperty(options, :wireplumber)
    wireplumber = external ? realpath(options.wireplumber) :
        joinpath(abspath(options.destination), "wireplumber/bin/wireplumber")
    preflight_binary = external ? wireplumber : joinpath(source, "wireplumber/bin/wireplumber")
    isfile(preflight_binary) && (stat(preflight_binary).mode & 0o111) != 0 ||
        throw(ArgumentError("selected WirePlumber executable is unavailable"))
    julia = D.selected_julia_executable(get(options, :julia_executable,
                                            Base.julia_cmd().exec[1]))
    wrappers = D.installed_wrappers(julia)
    for (name, script) in wrappers
        relative = "bin/$name"
        haskey(source_spec["artifacts"], relative) || continue
        read(joinpath(source, relative), String) == script ||
            throw(ArgumentError("sealed $relative differs from the selected Julia executable"))
    end
    destination = abspath(options.destination)
    !(ispath(destination) || islink(destination)) ||
        throw(ArgumentError("install destination must be new"))
    # Copy the sealed package without regenerating legacy coordinator units.
    # Rewriting an artifact here would invalidate its retained package hash.
    D.validate_runtime(required_assets(source))
    cp(source, destination; force=false, follow_symlinks=true)
    runtime = required_assets(destination)
    installed_spec = session_spec(destination, prefix)
    session_assets(installed_spec, destination, prefix)
    isfile(wireplumber) && (stat(wireplumber).mode & 0o111) != 0 ||
        throw(ArgumentError("installed WirePlumber executable is unavailable"))
    bin = joinpath(destination, "bin")
    mkpath(bin)
    for (name, script) in wrappers
        entrypoint = joinpath(bin, name)
        haskey(source_spec["artifacts"], "bin/$name") || write(entrypoint, script)
        chmod(entrypoint, 0o755)
    end
    launcher = joinpath(bin, "pipewireao-rtc-session")
    script = installed_launcher(julia)
    if haskey(source_spec["artifacts"], "bin/pipewireao-rtc-session")
        read(launcher, String) == script ||
            throw(ArgumentError("sealed session launcher differs from the selected Julia executable"))
    else
        write(launcher, script)
    end
    chmod(launcher, 0o755)
    quote_unit(value) = String(JSON3.write(replace(String(value), "%" => "%%")))
    template = read(joinpath(runtime, "assets/deployment/pipewireao-session@.service.in"), String)
    cpus = sort!(collect(installed_spec["placement"]["wireplumber"]["cpus"]))
    unit = replace(template,
        "@LAUNCHER@" => quote_unit(launcher),
        "@PACKAGE@" => quote_unit(destination),
        "@PIPEWIRE_PREFIX@" => quote_unit(prefix),
        "@WIREPLUMBER@" => quote_unit(wireplumber),
        "@SOURCE_ROLE@" => installed_spec["source-owner"],
        "@CPUS@" => join(cpus, " "))
    occursin(r"@[A-Z_]+@", unit) &&
        throw(ArgumentError("unresolved WirePlumber unit template binding"))
    systemd = joinpath(destination, "systemd")
    mkpath(systemd)
    write(joinpath(systemd, "pipewireao-session@.service"), unit)
    return destination
end

function main(argv=ARGS)
    args = C.cli_arguments(argv;
        required=["package", "destination", "pipewire-prefix"],
        allowed=["julia-executable", "wireplumber"])
    return install(args)
end

end # module
