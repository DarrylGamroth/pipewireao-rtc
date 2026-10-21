#!/usr/bin/env julia
# Refresh only the headless session runtime in a sealed development package.
using PipeWireAORTC
const D = PipeWireAORTC.DeploymentConfiguration
const C = PipeWireAORTC.Common
const E = PipeWireAORTC.ScienceExport

function main(args)
    length(args) == 7 || error("usage: PACKAGE PREFIX WP_SOURCE WP_BUILD RTC_NATIVE_SOURCE RTC_NATIVE_BUILD FRESH_OUTPUT")
    package, prefix, wp_source, wp_build, native_source, native_build, output = abspath.(args)
    spec = D.profile(joinpath(package, "deployment.conf"), prefix)
    D.registered_application(spec) && error("refresh a sealed runtime package, not a registered application")
    !ispath(output) && !islink(output) || error("fresh output required")
    original = copy(spec["artifacts"])
    cp(package, output; follow_symlinks=true)
    E.copy_deployment_runtime(output)
    E.stage_wireplumber!(output; source=wp_source, build=wp_build)
    E.stage_rtc!(output; native_source, native_build)
    spec["session-runtime"] = Dict("argv" => ["@PACKAGE@/rtc/bin/pipewireao-rtc",
        "-c", "@RUNTIME@/rtc/rtc.conf"], "environment" => Dict{String,String}())
    provenance = C.read_json(joinpath(output, "provenance.json"))
    provenance["session_runtime_test"] = Dict("source_package" => package,
        "source_descriptor_sha256" => C.sha256_file(joinpath(package, "deployment.conf")),
        "rtc_revision" => E.revision(PipeWireAORTC.package_root()),
        "wireplumber_revision" => E.revision(wp_source))
    C.write_json(joinpath(output, "provenance.json"), provenance)
    artifacts = Dict(relpath(joinpath(parent, file), output) => C.sha256_file(joinpath(parent, file))
        for (parent, _, files) in walkdir(output) for file in files
        if relpath(joinpath(parent, file), output) != "deployment.conf")
    for (relative, digest) in original
        relative == "provenance.json" || startswith(relative, "julia/") ||
            startswith(relative, "rtc/") || startswith(relative, "wireplumber/") ||
            get(artifacts, relative, nothing) == digest || error("scientific asset changed: $relative")
        C.sha256_file(joinpath(package, relative)) == digest || error("source package changed: $relative")
    end
    spec["artifacts"] = artifacts
    C.write_json(joinpath(output, "deployment.conf"), spec)
    D.profile(joinpath(output, "deployment.conf"), prefix)
    return joinpath(output, "deployment.conf")
end

abspath(PROGRAM_FILE) == abspath(@__FILE__) && println(main(ARGS))
