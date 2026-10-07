#!/usr/bin/env julia
# Opt-in public-interface experiment; never connects to an existing core.
using Test, PipeWireAO
using PipeWireAODeployment
const C = PipeWireAODeployment.Common
include(joinpath(@__DIR__, "../julia/test/native_control_private_core.jl"))

length(ARGS) == 3 || error("expected WIREPLUMBER_SOURCE BUILD EVIDENCE_OUTPUT")
wp_source, wp_build, evidence = abspath.(ARGS)
!ispath(evidence) || error("fresh evidence directory required")
mkpath(evidence; mode=0o700)
const SCOPE_NAME = "pipewireao.rtc.realization-probe"
snapshot(generation, phase) = Pod(props_param(SPA.Props(
    "version" => Int32(1), "generation" => Int64(generation), "phase" => SPA.Id(phase))))

function probe(remote, directory, daemon)
    loop = ThreadLoop("realization-probe")
    context = core = registry = marker = nothing
    wp = nothing
    log = open(joinpath(evidence, "wireplumber.log"), "w+")
    states = Any[]
    identities = Any[]
    try
        with_thread_loop_lock(loop) do _
            context = Context(loop)
            core = CoreConnection(context; properties=Dict("remote.name"=>remote))
            registry = Registry(core)
        end
        start!(loop)
        scripts = joinpath(directory, "scripts"); mkpath(scripts)
        cp(joinpath(@__DIR__, "realization-lifetime-probe.lua"), joinpath(scripts, "realization-lifetime-probe.lua"))
        write(joinpath(directory, "wireplumber.conf"), """
        context.properties = { library.use-fallback = false support.dbus = false }
        context.modules = [ { name = libpipewire-module-protocol-native } ]
        wireplumber.profiles = {
            ao-probe = { support.lua-scripting = required ao.realization-probe = required }
        }
        wireplumber.components = [
            { name = libwireplumber-module-lua-scripting type = module provides = support.lua-scripting }
            { name = realization-lifetime-probe.lua type = script/lua
              provides = ao.realization-probe requires = [ support.lua-scripting ]
              arguments = { node.name = "$SCOPE_NAME" } }
        ]
        """)
        environment = Dict("PIPEWIRE_REMOTE"=>remote, "PIPEWIREAO_REMOTE"=>remote,
            "WIREPLUMBER_MODULE_DIR"=>joinpath(wp_build,"modules"),
            "WIREPLUMBER_CONFIG_DIR"=>directory, "WIREPLUMBER_DATA_DIR"=>directory*":"*joinpath(wp_source,"src"),
            "LD_LIBRARY_PATH"=>joinpath(wp_build,"lib/wp")*":"*ENV["LD_LIBRARY_PATH"], "NOTIFY_SOCKET"=>"")
        selection=read(addenv(`ldd $(joinpath(wp_build,"src/wireplumber"))`,environment...),String)
        @test occursin("libpipewire-ao-0.3",selection)
        @test !occursin("libpipewire-0.3.so",selection)
        write(joinpath(evidence,"libraries.log"),selection)
        wp=run(pipeline(addenv(`stdbuf -oL $(joinpath(wp_build,"src/wireplumber")) -c wireplumber.conf -p ao-probe`,environment);
            stdout=log,stderr=log);wait=false)
        function healthy()
            @assert process_running(wp) "WirePlumber exited; inspect retained log"
        end
        function saw(text)
            flush(log)
            return occursin(text, read(joinpath(evidence,"wireplumber.log"),String))
        end
        function current()
            with_thread_loop_lock(loop) do _
                find_globals(registry; interface="PipeWire:Interface:Node", properties=Dict("node.name"=>SCOPE_NAME))
            end
        end
        for generation in 1:2
            with_thread_loop_lock(loop) do _
                marker=Filter(core,SCOPE_NAME;properties=Dict("node.name"=>SCOPE_NAME,"media.class"=>"Control"),
                    on_state_changed=(filter,old,new,detail)->push!(states,(generation,string(new),detail)))
                connect!(marker;flags=FILTER_ASYNC|FILTER_INACTIVE,params=[snapshot(generation,0)])
            end
            wait_proof(()->length(current())==1,10,"bound realization";check=healthy)
            identity=only(current()); push!(identities,(identity.id,identity.properties["object.serial"]))
            wait_proof(()->saw("PROBE_PHASE $generation 0"),10,"prepared snapshot";check=healthy)
            @test length(current())==1 # Prepared cannot be withdrawn prematurely.
            with_thread_loop_lock(loop) do _; update_params!(marker,[snapshot(generation,1)]); end
            wait_proof(()->saw("PROBE_PHASE $generation 1"),10,"realize snapshot update";check=healthy)
            with_thread_loop_lock(loop) do _; update_params!(marker,[snapshot(generation,2)]); end
            wait_proof(()->saw("PROBE_DESTROY_REQUESTED $generation") && isempty(current()),10,
                "remote exported Filter destruction";check=healthy)
            @test process_running(wp) && isrunning(loop) && process_running(daemon)
            @test isempty(current())
            with_thread_loop_lock(loop) do _; close(marker); marker=nothing; end
        end
        @test identities[1] != identities[2]
        C.write_json(joinpath(evidence,"receipt.json"),Dict("success"=>true,
            "scope"=>"typed Props updates, remote destruction and two incarnations only; no links/admission/withdrawal drain qualification",
            "identities"=>identities,"filter_states"=>states,"wp_pid"=>getpid(wp)))
    finally
        wp===nothing || stop_proof_child!(wp,"probe WirePlumber")
        with_thread_loop_lock(loop) do _
            for resource in (marker,registry,core,context)
                resource===nothing || close(resource)
            end
        end
        close(loop)
        close(log)
        cp(joinpath(directory,"private-core.log"),joinpath(evidence,"private-core.log"))
    end
end

@testset "Realization Filter lifetime primitive" begin
    with_control_private_core(probe)
end
