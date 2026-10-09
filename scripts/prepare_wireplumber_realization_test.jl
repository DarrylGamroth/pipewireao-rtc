#!/usr/bin/env julia
# Development-only package refresh for the WirePlumber realization test.
using PipeWireAODeployment

const D = PipeWireAODeployment.Deployment
const C = PipeWireAODeployment.Common
const H = PipeWireAODeployment.HILExport

require(condition, message) = condition || error(message)

function copy_shared_libraries(source, destination)
    isdir(source) || error("missing shared-library directory: $source")
    mkpath(destination)
    for name in readdir(source)
        isfile(joinpath(source,name)) && occursin(r"\.so($|\.)", name) || continue
        cp(joinpath(source, name), joinpath(destination, name); follow_symlinks=true)
    end
end

function copy_wireplumber(source, build, destination, prefix)
    executable = joinpath(build, "src/wireplumber")
    require(isfile(executable) && isexecutable(executable), "WirePlumber build executable is missing")
    paths = D.installed_paths(prefix)
    env = Dict("LD_LIBRARY_PATH" => joinpath(build, "lib/wp") * ":" * paths["library"])
    selection = C.run_checked(["ldd", executable]; env, timeout=5, maximum_output_bytes=16384)
    require(selection.returncode == 0 && occursin("libpipewire-ao-0.3", selection.stdout) &&
        !occursin("libpipewire-0.3.so", selection.stdout) && !occursin("not found", selection.stdout),
        "WirePlumber must resolve the selected AO libraries under the installed prefix")

    root = joinpath(destination, "wireplumber")
    mkpath(root)
    cp(executable, joinpath(root, "wireplumber"))
    copy_shared_libraries(joinpath(build, "lib/wp"), joinpath(root, "lib"))
    copy_shared_libraries(joinpath(build, "modules"), joinpath(root, "modules"))
    cp(joinpath(source, "src/scripts"), joinpath(root, "scripts"); follow_symlinks=true)
    candidate = normpath(joinpath(@__DIR__, "../deployment/wireplumber/realization.lua"))
    require(isfile(candidate), "current realization candidate is missing")
    cp(candidate, joinpath(root, "scripts/realization.lua"); force=true)

    licenses = joinpath(root, "licenses")
    mkpath(licenses)
    cp(joinpath(source, "LICENSE"), joinpath(licenses, "WirePlumber.txt"))
    wrap = read(joinpath(source, "subprojects/lua.wrap"), String)
    directory = only(match(r"(?m)^directory\s*=\s*(\S+)\s*$", wrap).captures)
    lua_header = joinpath(source, "subprojects", directory, "src/lua.h")
    require(isfile(lua_header), "bundled Lua license/header is missing")
    cp(lua_header, joinpath(licenses, "Lua.h"))
    return executable
end

function verify_preserved(package, hashes)
    for (path, digest) in hashes
        C.sha256_file(joinpath(package, path)) == digest || error("accepted scientific artifact changed: $path")
    end
end

function main(args)
    length(args) == 5 || error("usage: ACCEPTED_INSTALLED RUNNER_BINARY WP_SOURCE WP_BUILD FRESH_OUTPUT")
    accepted, runner, wp_source, wp_build, output = abspath.(args)
    require(isdir(accepted), "accepted installed package is missing")
    require(isfile(runner) && isexecutable(runner), "runner binary is missing or not executable")
    wp_source = realpath(wp_source)
    wp_build = realpath(wp_build)
    require(!ispath(output) && !islink(output), "fresh output directory required")

    accepted_descriptor = joinpath(accepted, "deployment.conf")
    output_descriptor = joinpath(output, "deployment.conf")
    prefix = "/opt/pipewireao"
    spec = D.profile(accepted_descriptor, prefix)
    provenance = C.read_json(joinpath(accepted, "provenance.json"))
    original_artifacts = copy(spec["artifacts"])
    protected = Dict(path => digest for (path, digest) in original_artifacts
        if !(startswith(path, "julia/src/") || path == "bin/pipewireao-rtc" ||
             path == "provenance.json" || startswith(path, "wireplumber/")))

    cp(accepted, output; follow_symlinks=true)

    # Refresh SDK implementation sources only. The accepted environment and
    # scientific package identity remain byte-for-byte as installed.
    sdk_source = normpath(joinpath(@__DIR__, "../src"))
    sdk_destination = joinpath(output, "julia/src")
    require(isdir(sdk_source) && isdir(sdk_destination), "deployment Julia SDK source is missing")
    rm(sdk_destination; recursive=true)
    cp(sdk_source, sdk_destination; follow_symlinks=true)

    cp(runner, joinpath(output, "bin/pipewireao-rtc"); force=true)
    chmod(joinpath(output, "bin/pipewireao-rtc"), 0o755)
    wp_executable = copy_wireplumber(wp_source, wp_build, output, prefix)
    rtc_client_template = D.relative_asset(accepted, spec["client"]["rtc"])
    wireplumber_client = joinpath(output, "wireplumber/client.conf.in")
    cp(rtc_client_template, wireplumber_client)

    spec["session-manager"] = Dict(
        "argv" => ["@PACKAGE@/wireplumber/wireplumber", "-c", "@RUNTIME@/wireplumber/wireplumber.conf", "-p", "ao-rtc"],
        "environment" => Dict(
            "WIREPLUMBER_MODULE_DIR" => "@PACKAGE@/wireplumber/modules",
            "WIREPLUMBER_DATA_DIR" => "@PACKAGE@/wireplumber",
            "LD_LIBRARY_PATH" => "@PACKAGE@/wireplumber/lib:/opt/pipewireao/lib/x86_64-linux-gnu"),
        "marker-node" => "pipewireao.rtc.realization." * spec["name"])
    spec["placement"]["wireplumber"] = Dict("cpus" => [6], "leader-cpu" => 6,
        "rt-priority" => 0, "threads" => Any[], "locked-bytes" => 0)
    spec["client"]["wireplumber"] = "wireplumber/client.conf.in"

    source_revision = strip(read(`git -C $(@__DIR__) rev-parse HEAD`, String))
    refreshed_sdk = Dict(path => digest for (path, digest) in H._package_artifacts(output)
        if startswith(path, "julia/src/"))
    provenance["wireplumber_realization_test"] = Dict(
        "accepted_package" => accepted,
        "accepted_descriptor_sha256" => C.sha256_file(accepted_descriptor),
        "source_revision" => source_revision,
        "runner_sha256" => C.sha256_file(runner),
        "wireplumber_sha256" => C.sha256_file(wp_executable),
        "wireplumber_source_revision" => strip(read(`git -C $wp_source rev-parse HEAD`, String)),
        "wireplumber_source_artifacts" => Dict(path => C.sha256_file(joinpath(wp_source,path))
            for path in ("lib/wp/spa-pod.c", "tests/wp/spa-pod.c")),
        "julia_sdk_source_artifacts" => refreshed_sdk,
        "sdk_source" => sdk_source,
        "scope" => "development-only WirePlumber realization; accepted scientific package bytes preserved")

    spec["artifacts"] = H._package_artifacts(output)
    verify_preserved(output, protected)
    for (path, digest) in protected
        spec["artifacts"][path] == digest || error("sealed accepted artifact hash changed: $path")
    end
    provenance["wireplumber_realization_test"]["replaced_artifact_sha256"] = Dict(
        path => spec["artifacts"][path] for path in ("bin/pipewireao-rtc", "wireplumber/wireplumber"))
    provenance["wireplumber_realization_test"]["wireplumber_resource_artifacts"] = Dict(
        path => digest for (path, digest) in spec["artifacts"] if startswith(path, "wireplumber/"))
    C.write_json(joinpath(output, "provenance.json"), provenance)
    spec["artifacts"] = H._package_artifacts(output)
    C.write_json(output_descriptor, spec)
    D.profile(output_descriptor, prefix)
    verify_preserved(accepted, original_artifacts)
    println(output_descriptor)
end

abspath(PROGRAM_FILE) == (@__FILE__) && main(ARGS)
