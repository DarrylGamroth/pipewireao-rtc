# No-service reproduction of the inherited systemd template classification.
# The observed fresh instance had LoadState=loaded, ActiveState=inactive,
# MainPID=0, and empty InvocationID/ControlGroup; FragmentPath named the
# global pipewireao-session@.service template. The old guard rejected it.
using PipeWireAODeployment

const Session = PipeWireAODeployment.WirePlumberSessionRuntime

mktempdir() do directory
    template = joinpath(directory, "pipewireao-session@.service")
    instance = joinpath(directory, "pipewireao-session@0123456789ab.service")
    root = joinpath(directory, "runtime")
    write(template, "template")
    write(instance, "instance")
    observed = Dict("LoadState" => "loaded", "ActiveState" => "inactive",
        "MainPID" => "0", "InvocationID" => "", "ControlGroup" => "",
        "FragmentPath" => template)

    @assert observed["LoadState"] != "not-found" # Original guard fails.
    @assert Session._unrun_fields(observed, root)
    println("inherited inactive template accepted as unrun instance")

    for (key, value) in (("ActiveState", "active"), ("MainPID", "41"),
            ("InvocationID", "0123456789abcdef0123456789abcdef"),
            ("ControlGroup", "/user.slice/private"), ("FragmentPath", instance))
        changed = copy(observed)
        changed[key] = value
        @assert !Session._unrun_fields(changed, root)
    end
    mkdir(root)
    @assert !Session._unrun_fields(observed, root)
    println("execution identity, exact instance, and runtime reuse rejected")

    link = joinpath(directory, "linked-instance.service")
    symlink(instance, link)
    @assert Session._exact_fragment(link, instance)
    @assert !Session._exact_fragment(template, instance)
    println("post-link fragment requires the exact installed instance")
end
