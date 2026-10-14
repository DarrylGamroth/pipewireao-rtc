# One-shot ordinary unit installation, startup reconciliation and removal.
# This code does not admit a session or release scientific ingress.
save_unit_record!(runtime, record) = Common.write_json(joinpath(runtime, "launch.json"), record; atomic=true)

function runtime_unit_directory()
    root = get(ENV, "XDG_RUNTIME_DIR", "")
    isabspath(root) && isdir(root) && !islink(root) &&
        stat(root).uid == ccall(:getuid, Cuint, ()) || fail("user runtime directory is unavailable")
    directory = joinpath(root, "systemd", "user")
    mkpath(directory)
    islink(dirname(directory)) || islink(directory) ?
        fail("runtime systemd unit directory must not be a symlink") : nothing
    stat(directory).uid == ccall(:getuid, Cuint, ()) ||
        fail("runtime systemd unit directory belongs to another user")
    return directory
end

function install_fragment!(unit, text, runtime, record)
    path = joinpath(runtime, "units", unit)
    link = joinpath(runtime_unit_directory(), unit)
    ispath(path) || islink(path) || ispath(link) || islink(link) ?
        fail("invocation unit name is already reserved: $unit") : nothing
    properties(unit)["LoadState"] == "not-found" || fail("unit name is already loaded: $unit")
    mkpath(dirname(path); mode=0o700)
    temporary, io = mktemp(dirname(path); cleanup=false)
    try
        chmod(temporary, 0o600)
        write(io, text)
        close(io)
        mv(temporary, path)
    finally
        isopen(io) && close(io)
        ispath(temporary) && rm(temporary)
    end
    record["unit_files"][unit] = Dict("path" => path, "sha256" => Common.sha256_file(path))
    save_unit_record!(runtime, record) # Retain intent before installing the manager link.
    symlink(path, link) # Exclusive creation; never replace an existing unit.
    return path
end

function verify_fragment!(unit, record)
    entry = record["unit_files"][unit]
    path = entry["path"]
    extra = "FragmentPath,DropInPaths"
    service = endswith(unit, ".service")
    service && (extra *= ",Type,Restart,KillMode,CPUAffinity,LimitRTPRIO,LimitMEMLOCK,UMask")
    values = properties(unit; extra)
    values["LoadState"] == "loaded" && isempty(values["DropInPaths"]) &&
        isfile(values["FragmentPath"]) && realpath(values["FragmentPath"]) == realpath(path) &&
        Common.sha256_file(path) == entry["sha256"] || fail("loaded unit definition differs: $unit")
    if service
        role = unit[ncodeunits(PREFIX * record["invocation"] * "-")+1:end-8]
        placement = record["owners"][role]["placement"]
        values["Type"] == "exec" && values["Restart"] == "no" &&
            values["KillMode"] == "control-group" && values["UMask"] == "0077" &&
            values["CPUAffinity"] == string(placement["leader-cpu"]) &&
            values["LimitRTPRIO"] == "95" && values["LimitMEMLOCK"] == "4294967296" ||
            fail("loaded owner resource/lifetime policy differs: $unit")
    end
    return nothing
end

function reload_fragments!(record)
    result = checked(["systemctl", "--user", "daemon-reload"]; timeout=20)
    result.returncode == 0 || fail("cannot load invocation service definitions")
    for unit in keys(record["unit_files"])
        verify_fragment!(unit, record)
    end
end

function start_services!(services, unit, runtime, record)
    for service in services
        service.state = :launching
        merge!(record["owners"][service.role], SystemdOwners.record(service))
    end
    save_unit_record!(runtime, record) # All roles retained before a single submission.
    errors = String[]
    try
        result = checked(["systemctl", "--user", "start", unit]; timeout=20)
        result.returncode == 0 || push!(errors, "systemd start failed for $unit")
    catch error
        push!(errors, "systemd start outcome uncertain: " * sprint(showerror, error))
    end
    # A failed target transaction can leave running owners. Reconcile all of
    # them before reporting failure; target activation alone proves nothing.
    for service in services
        try
            verify_fragment!(service.unit, record)
            retain!(service, properties(service.unit))
            verify!(service)
        catch error
            service.state = :uncertain
            service.error = sprint(showerror, error)
            push!(errors, service.role * ": " * service.error)
        end
        merge!(record["owners"][service.role], SystemdOwners.record(service))
        save_unit_record!(runtime, record)
    end
    isempty(errors) || fail(join(errors, "; "))
    return nothing
end

function cancel_start_jobs!(invocation, deadline)
    while monotonic() < deadline
        jobs = listed_jobs(invocation; deadline)
        isempty(jobs) && return nothing
        for job in jobs
            cancel_job(job.first; deadline)
        end
    end
    fail("invocation start jobs did not quiesce")
end

function remove_fragments!(runtime, record, deadline)
    files = get(record, "unit_files", Dict())
    isempty(files) && return nothing # Older launch records have transient services.
    directory = runtime_unit_directory()
    prefix = PREFIX * record["invocation"] * "-"
    removing = get(record, "unit_file_removal_started", false)
    # Validate the entire set before removing any file. The ledger alone is
    # insufficient: links, contents and manager definitions must still match.
    for (unit, entry) in files
        (unit == cohort_name(record["invocation"]) ||
            unit in (prefix * role * ".service" for role in keys(record["owners"]))) ||
            fail("cleanup ledger names a foreign unit")
        path = joinpath(runtime, "units", unit)
        entry["path"] == path && !islink(path) &&
            ((isfile(path) && Common.sha256_file(path) == entry["sha256"]) ||
                (removing && !ispath(path))) || fail("cleanup unit fragment differs: $unit")
        link = joinpath(directory, unit)
        (islink(link) && readlink(link) == path) ||
            (!ispath(link) && !islink(link)) || fail("cleanup unit link differs: $unit")
        values = properties(unit; extra="FragmentPath,DropInPaths", deadline)
        isempty(values["DropInPaths"]) &&
            (values["LoadState"] == "not-found" ||
                (isfile(values["FragmentPath"]) && realpath(values["FragmentPath"]) == path) ||
                (removing && !ispath(path) && values["FragmentPath"] in (path, link))) ||
            fail("cleanup loaded unit definition differs: $unit")
        quiescent_unit(unit; deadline) || fail("cleanup unit remains active: $unit")
    end
    record["unit_file_removal_started"] = true
    save_unit_record!(runtime, record) # Recovery can recognize our own partial removal.
    for (unit, entry) in files
        link = joinpath(directory, unit)
        islink(link) && rm(link)
        isfile(entry["path"]) && rm(entry["path"])
    end
    result = checked(["systemctl", "--user", "daemon-reload"]; timeout=20, deadline)
    result.returncode == 0 || fail("cannot unload invocation service definitions")
    record["unit_files_removed"] = true
    return nothing
end

