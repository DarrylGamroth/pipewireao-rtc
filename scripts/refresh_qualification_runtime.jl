#!/usr/bin/env julia
# Cold qualification preparation: preserve admitted science, refresh deployment
# and SDK code, resolve self-contained environments, then use the public installer.
using PipeWireAODeployment, TOML, Pkg

const C = PipeWireAODeployment.Common
const S = PipeWireAODeployment.ScienceExport
const H = PipeWireAODeployment.HILExport
const D = PipeWireAODeployment.Deployment

runtime_file(path) = startswith(path, "julia/") ||
    startswith(path, "systemd/") || startswith(path, "hil/packages/PipeWireAO/") ||
    path in ("provenance.json", "bin/pipewireao-rtc", "pipewireao-rtc@.service.in",
        "hil/Project.toml", "hil/Manifest.toml",
        "jfg/deployment/Project.toml", "jfg/deployment/Manifest.toml")

function verify_seals(package, spec)
    for (path, hash) in spec["artifacts"]
        C.sha256_file(joinpath(package, path)) == hash || error("artifact changed: $package/$path")
    end
end

function resolve_environment(package, relative, sdk_path)
    project_path = joinpath(package, relative, "Project.toml")
    manifest_path = joinpath(dirname(project_path), "Manifest.toml")
    previous_dependencies = TOML.parsefile(manifest_path)["deps"]
    project = TOML.parsefile(project_path)
    project["compat"]["PipeWireAO"] = "=0.6.17"
    project["sources"]["PipeWireAO"] = Dict("path" => sdk_path)
    open(io -> TOML.print(io, project; sorted=true), project_path, "w")
    Pkg.activate(dirname(project_path))
    Pkg.resolve()
    Pkg.instantiate(; update_registry=false, allow_autoprecomp=false)
    manifest = TOML.parsefile(manifest_path)
    dependency = only(manifest["deps"]["PipeWireAO"])
    dependency["version"] == "0.6.17" || error("wrong resolved SDK version")
    realpath(joinpath(dirname(project_path), dependency["path"])) ==
        realpath(joinpath(package, "hil/packages/PipeWireAO")) || error("SDK is not self-contained")
    for key in ("repo-url", "repo-rev", "git-tree-sha1")
        !haskey(dependency, key) || error("resolved SDK still uses an external source")
    end
    without_sdk(deps) = Dict(name => value for (name, value) in deps if name != "PipeWireAO")
    without_sdk(previous_dependencies) == without_sdk(manifest["deps"]) ||
        error("dependency other than SDK changed: $relative")
end

function main(args)
    length(args) == 5 || error("usage: SOURCE FRESH_OUTPUT RUNNER SDK RTC_ROOT")
    source, output, runner, sdk, rtc = abspath.(args)
    isfile(runner) || error("runner executable required")
    !ispath(output) && !ispath(output * "-installed") || error("fresh output required")
    before = C.read_json(joinpath(source, "deployment.conf"))
    D.profile(joinpath(source, "deployment.conf"), "/opt/pipewireao")
    verify_seals(source, before)
    cp(source, output)
    S.copy_deployment_runtime(output)
    H.replace_staged_package(sdk, output, "PipeWireAO")
    cp(runner, joinpath(output, "bin/pipewireao-rtc"); force=true)
    chmod(joinpath(output, "bin/pipewireao-rtc"), 0o755)
    resolve_environment(output, "julia", "../hil/packages/PipeWireAO")
    resolve_environment(output, "hil", "packages/PipeWireAO")
    resolve_environment(output, "jfg/deployment", "../../hil/packages/PipeWireAO")
    isdir(joinpath(output, "systemd")) && rm(joinpath(output, "systemd"); recursive=true)
    protected = Dict(path => hash for (path, hash) in before["artifacts"] if !runtime_file(path))
    verify_seals(output, Dict("artifacts" => protected))
    after = H._package_artifacts(output)
    changes = [Dict("path" => path, "before" => get(before["artifacts"], path, nothing),
        "after" => get(after, path, nothing))
        for path in sort!(collect(union(keys(before["artifacts"]), keys(after))))
        if get(before["artifacts"], path, nothing) != get(after, path, nothing)]
    all(change -> runtime_file(change["path"]), changes) || error("change outside declared runtime scope")
    provenance = C.read_json(joinpath(output, "provenance.json"))
    receipt = Dict("original" => source,
        "original_descriptor_sha256" => C.sha256_file(joinpath(source, "deployment.conf")),
        "rtc_revision" => readchomp(`git -C $rtc rev-parse HEAD`),
        "sdk_revision" => readchomp(`git -C $sdk rev-parse HEAD`),
        "helper_sha256" => C.sha256_file(@__FILE__),
        "runner_sha256" => C.sha256_file(runner), "protected_count" => length(protected),
        "protected_files" => protected, "runtime_changes" => changes,
        "scope" => "deployment/runtime/SDK only; all other sealed bytes unchanged")
    provenance["native_control_runtime_refresh"] = receipt
    C.write_json(joinpath(output, "provenance.json"), provenance)
    descriptor = copy(before)
    descriptor["name"] = basename(output)
    descriptor["artifacts"] = H._package_artifacts(output)
    C.write_json(joinpath(output, "deployment.conf"), descriptor)
    D.profile(joinpath(output, "deployment.conf"), "/opt/pipewireao")
    installed = D.install((; package=output, destination=output * "-installed", pipewire_prefix="/opt/pipewireao"))
    sealed = C.read_json(joinpath(installed, "deployment.conf"))
    verify_seals(installed, sealed)
    verify_seals(source, before)
    receipt["installed"] = installed
    receipt["installed_seal_count"] = length(sealed["artifacts"])
    receipt["installed_descriptor_sha256"] = C.sha256_file(joinpath(installed, "deployment.conf"))
    C.write_json(output * "-proof.json", receipt)
    println(installed)
end

main(ARGS)
