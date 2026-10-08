using PipeWireAODeployment, Test, UUIDs
const E = PipeWireAODeployment.ScienceExport
const H = PipeWireAODeployment.HILExport
const C = PipeWireAODeployment.Common
const W = PipeWireAODeployment.WirePlumberSessionRuntime
const R = PipeWireAODeployment.RunnerCommands
const S = PipeWireAODeployment.SystemdOwners
engine = ARGS[1]
package = "/tmp/rtc-wireplumber-$(engine)-20261007-package"
spec = C.read_json(joinpath(package, "deployment.conf"))
retired = Set(["bin/pipewireao-rtc", "bin/pipewireao-rtc-deploy", "bin/placement.py", "bin/pipewireao-rtc@.service.in", "bin/pipewireao-rtc-systemd@.service.in", "pipewireao-rtc@.service.in", "pipewireao-rtc-systemd@.service.in"])
science = Dict(path => hash for (path, hash) in spec["artifacts"] if !startswith(path, "julia/") && !startswith(path, "wireplumber/") && !(path in retired))
for (path, hash) in science
    C.sha256_file(joinpath(package, path)) == hash || error("old package seal differs: $path")
end
E.copy_deployment_runtime(package)
E.stage_wireplumber!(package; prefix="/opt/pipewireao")
spec["artifacts"] = H._package_artifacts(package)
for (path, hash) in science
    C.sha256_file(joinpath(package, path)) == hash || error("scientific artifact changed: $path")
end
C.write_json(joinpath(package, "deployment.conf"), spec)
base = "/tmp/rtc-installed-$(engine)-20261008-session-" * first(string(uuid4()), 8)
handle = W.start!(package, base; prefix="/opt/pipewireao")
C.write_json(joinpath(base, "probe-handle.json"), Dict("unit"=>handle.unit,"invocation"=>handle.invocation))
try
    ready = W.control!(handle, R.parse(["status"]))
    @test ready["ok"] && ready["state"] == "Ready"
    ledger = C.read_json(joinpath(handle.runtime_root, handle.invocation, "launch.json"))
    @test ledger["cohort_unit"] == S.cohort_name(handle.invocation)
    @test all(isfile(entry["path"]) for entry in values(ledger["unit_files"]))
    wp_pid = ledger["wireplumber_pid"]
    maps = join(readlines("/proc/$wp_pid/maps"; keep=true))
    @test occursin(joinpath(base, "installed/wireplumber/lib/wp/libwireplumber-0.5.so.0"), maps)
    for name in ("lua-scripting", "ao-control-endpoint")
        @test occursin(joinpath(base, "installed/wireplumber/modules/libwireplumber-module-$name.so"), maps)
    end
    @test occursin("/opt/pipewireao/lib/x86_64-linux-gnu/libpipewire-ao-0.3.so", maps)
    @test !occursin(r"/libpipewire-0\.3\.so", maps)
    @test !occursin("/tmp/wp-installed-runtime-20261008/build", maps)
    paths = filter(line -> occursin(r"wireplumber|pipewire.*so|libspa", line), split(maps, '\n'))
    for (role, owner) in ledger["owners"]
        owner_maps = join(readlines("/proc/$(owner["pid"])/maps"; keep=true))
        @test occursin("/opt/pipewireao/lib/x86_64-linux-gnu/libpipewire-ao-0.3.so", owner_maps)
        @test !occursin("/tmp/pwao-linktrace", owner_maps)
        append!(paths, ["$role: " * line for line in split(owner_maps, '\n') if occursin(r"libpipewire.*so|libspa", line)])
    end
    write(joinpath(base, "loaded-runtime.txt"), join(paths, '\n') * "\n")
    C.write_json(joinpath(base, "runtime-check.json"), Dict("engine"=>engine,
        "prefix"=>"/opt/pipewireao", "scientific_artifacts_preserved"=>length(science),
        "manager_pid"=>wp_pid, "unit"=>handle.unit, "invocation"=>handle.invocation))
    println("READY ", engine, " ", handle.unit)
    flush(stdout)
    graph = "revolt-copper-$(engine)-frame-graph"
    gain_property = engine == "fgn" ? "control:gain" : "correction:gain"
    parameter_port = engine == "fgn" ? "reconstruct:reconstructor" : "reconstructor"
    gain = W.control!(handle, R.parse(["properties-set",graph,gain_property,"float","0.01"]))
    @test gain["ok"]
    @test W.control!(handle, R.parse(["session-start"]))["state"] == "Running"
    sleep(1)
    update = W.control!(handle, R.parse(["properties-set",graph,gain_property,"float","0.02"]))
    @test update["ok"]
    @test W.control!(handle, R.parse(["session-stop"]))["ok"]
    @test W.control!(handle, R.parse(["status"]))["state"] == "Ready"
    @test W.control!(handle, R.parse(["parameter",graph,parameter_port,"F32_LE","253x3600",
        "org.calculon.ao.pwfs-reconstructor/1",joinpath(base,"installed/calibration/parameter-reconstructor.f32")]))["ok"]
    @test W.control!(handle, R.parse(["reset"]))["ok"]
    @test W.control!(handle, R.parse(["session-start"]))["state"] == "Running"
    sleep(1)
    @test W.control!(handle, R.parse(["session-stop"]))["ok"]
    println("CONTROLS ", engine, " passed"); flush(stdout)
    final = W.shutdown!(handle)
    @test final["cleanup_complete"]
    @test final["unit_files_removed"]
    @test isempty(S.listed_jobs(handle.invocation))
    @test all(S.quiescent_unit, S.listed_units(handle.invocation))
    println("SHUTDOWN ", engine, " passed ", base); flush(stdout)
catch error
    if !handle.stop_attempted && !handle.shutdown_attempted
        try W.stop!(handle) catch cleanup_error; showerror(stderr,cleanup_error);println(stderr) end
    end
    rethrow(error)
end
