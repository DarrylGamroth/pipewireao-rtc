#!/usr/bin/env julia
# Opt-in public-interface experiment; never connects to an existing core.
using Test, PipeWireAO
using PipeWireAODeployment
const C = PipeWireAODeployment.Common
include(joinpath(@__DIR__, "../julia/test/native_control_private_core.jl"))

length(ARGS) in (3,4) || error("expected WIREPLUMBER_SOURCE BUILD EVIDENCE_OUTPUT [delay-completion]")
const DELAY_COMPLETION = length(ARGS)==4
DELAY_COMPLETION && ARGS[4]!="delay-completion" && error("unknown probe mode")
wp_source, wp_build, evidence = abspath.(ARGS[1:3])
!ispath(evidence) || error("fresh evidence directory required")
mkpath(evidence; mode=0o700)
cp(@__FILE__,joinpath(evidence,"test_realization_links.jl"))
const SCOPE_NAME = "pipewireao.rtc.realization-links-probe"
const PROFILE = "pipewireao.rtc.realization/1"
const SCHEMA = "org.pipewireao.test.realization/1"
const FORMAT = NdArrayFormat(NdArray.U16_LE, (4,3); layout=NdArray.COLUMN_MAJOR,
    rate=SPA.Fraction(100,1))
# Test-only forwarding wrapper. The real native activation completes normally;
# only dispatch of its public completion to this policy is held for 500 ms.
const DELAY_PREFIX = raw"""
local NativeLink = Link
local function Link(...)
  local native = NativeLink(...)
  if not native then return native end
  local wrapper = {}
  setmetatable(wrapper, { __index = function(_, name)
    if name == "activate" then
      return function(_, features, completion)
        native:activate(features, function(object, error)
          local captured_id = native["bound-id"]
          print("PROBE_PENDING_ACTIVATION_HELD " .. tostring(captured_id))
          Core.timeout_add(500, function()
            print("PROBE_DELAYED_ACTIVATION_DELIVERED " .. tostring(captured_id))
            completion(object, error)
            return false
          end)
        end)
      end
    end
    local value = native[name]
    if type(value) == "function" then
      return function(_, ...) return value(native, ...) end
    end
    return value
  end })
  return wrapper
end

"""
identity(object) = (object.id, parse(UInt64, object.properties["object.serial"]))
native_struct(values) = SPA.Struct(Pod.(values))
native_identity(value) = native_struct((SPA.Id(value[1]), reinterpret(Int64,value[2])))
native_endpoint(node, port, owner) = native_struct((native_identity(node), native_identity(port), native_identity(owner)))
function snapshot(generation, phase, runtime, manager, output, input, passive; wrong_phase_type=false)
    row = native_struct((Int32(0), output, input, passive))
    return Pod(props_param(SPA.Props("version"=>Int32(1), "generation"=>Int64(generation),
        "phase"=>(wrong_phase_type ? Int32(phase) : SPA.Id(phase)), "runtime"=>native_identity(runtime),
        "manager"=>native_identity(manager), "links"=>native_struct((row,)))))
end

# The native Link Format can retain fixed Choice(None) wrappers. Reject every
# non-fixed choice before converting its single value through public SPA APIs.
function fixed_format(pod)
    object=pod_value(SPA.Parameter,pod).object
    properties=map(object.properties) do property
        if pod_type(property.value)==PipeWireAO.LibPipeWire.SPA_TYPE_Choice
            # Public owned POD bytes follow the native SPA POD ABI: header,
            # choice kind/flags, child header, then one child body. The generic
            # Choice decoder does not support Array/String children.
            data=property.value.data
            @assert length(data)>=24 "truncated native Choice"
            kind=only(reinterpret(UInt32,data[9:12]))
            child_size=only(reinterpret(UInt32,data[17:20]))
            @assert kind==UInt32(SPA.CHOICE_NONE) && length(data)==24+child_size "Link Format is not fixed"
            return SPA.Property(property.key,Pod(@view data[17:end]);flags=property.flags)
        end
        property
    end
    SPA.Parameter(SPA.Object(object.type,object.id,properties))
end

function probe(remote, directory, daemon)
    loop = ThreadLoop("realization-links-probe")
    context = core = registry = marker = nothing
    wp = nothing
    filters, bound_links, bound_clients = Any[], Any[], Any[]
    states, formats, cases = Any[], Any[], Any[]
    declaration = Dict{String,Any}()
    log = open(joinpath(evidence,"wireplumber.log"),"w+")
    success = false
    failure = nothing
    try
        cp(joinpath(directory,"configuration","private-core.conf"),joinpath(evidence,"private-core.conf"))
        cp(joinpath(directory,"configuration","client.conf"),joinpath(evidence,"client.conf"))
        with_thread_loop_lock(loop) do _
            context = Context(loop)
            core = CoreConnection(context; properties=Dict("remote.name"=>remote))
            registry = Registry(core)
            for (name, direction) in (("realization.source",:output),("realization.sink",:input))
                filter = Filter(core,name;properties=Dict("node.name"=>name,"media.type"=>"Application"),
                    on_state_changed=(f,old,new,detail)->push!(states,(name,string(new),detail)),
                    on_param_changed=(f,port,id,pod)->begin
                        if port !== nothing && id == SPA.PARAM_FORMAT && pod !== nothing
                            push!(formats,(name,pod))
                            update_params!(f,(Pod(buffers_param(buffers=2,blocks=1,size=payload_size(FORMAT))),
                                Pod(header_metadata_param()));port)
                        end
                        nothing
                    end)
                push!(filters,filter)
                add_port!(filter,direction;properties=Dict("port.name"=>direction==:output ? "output_1" : "input_1"),
                    params=(ndarray_format(FORMAT;schema=SCHEMA),))
                connect!(filter;flags=FILTER_ASYNC|FILTER_INACTIVE)
            end
        end
        start!(loop)
        globals(kind; properties=Dict{String,String}()) = with_thread_loop_lock(loop) do _
            find_globals(registry;interface="PipeWire:Interface:$kind",properties)
        end
        healthy() = (@assert process_running(daemon) && (wp===nothing || process_running(wp)) && isrunning(loop) "private probe child or loop stopped")
        wait_proof(()->length(globals("Node"))==2 && length(globals("Port"))==2,10,"inactive endpoints";check=healthy)
        source = only(globals("Node";properties=Dict("node.name"=>"realization.source")))
        sink = only(globals("Node";properties=Dict("node.name"=>"realization.sink")))
        output_port = only(globals("Port";properties=Dict("node.id"=>string(source.id))))
        input_port = only(globals("Port";properties=Dict("node.id"=>string(sink.id))))
        runtime = identity(only(filter(v->v.id==parse(UInt32,source.properties["client.id"]),globals("Client"))))
        @test source.properties["client.id"] == sink.properties["client.id"]
        output = native_endpoint(identity(source),identity(output_port),runtime)
        input = native_endpoint(identity(sink),identity(input_port),runtime)

        scripts=joinpath(directory,"scripts");mkpath(scripts)
        policy=read(joinpath(@__DIR__,"realization.lua"),String)
        write(joinpath(evidence,"realization.lua"),policy)
        loaded_policy=(DELAY_COMPLETION ? DELAY_PREFIX : "")*policy
        write(joinpath(scripts,"realization.lua"),loaded_policy)
        write(joinpath(evidence,"loaded-realization.lua"),loaded_policy)
        write(joinpath(directory,"wireplumber.conf"),"""
        context.properties = { library.use-fallback = false support.dbus = false }
        context.modules = [ { name = libpipewire-module-protocol-native } ]
        wireplumber.profiles = { ao-probe = { support.lua-scripting = required ao.realization = required } }
        wireplumber.components = [
          { name = libwireplumber-module-lua-scripting type = module provides = support.lua-scripting }
          { name = realization.lua type = script/lua provides = ao.realization
            requires = [ support.lua-scripting ] arguments = { node.name = "$SCOPE_NAME" } }
        ]
        """)
        cp(joinpath(directory,"wireplumber.conf"),joinpath(evidence,"wireplumber.conf"))
        environment=Dict("PIPEWIRE_REMOTE"=>remote,"PIPEWIREAO_REMOTE"=>remote,
            "WIREPLUMBER_MODULE_DIR"=>joinpath(wp_build,"modules"),"WIREPLUMBER_CONFIG_DIR"=>directory,
            "WIREPLUMBER_DATA_DIR"=>directory*":"*joinpath(wp_source,"src"),
            "LD_LIBRARY_PATH"=>joinpath(wp_build,"lib/wp")*":"*get(ENV,"LD_LIBRARY_PATH",""),"NOTIFY_SOCKET"=>"")
        selection=read(addenv(`ldd $(joinpath(wp_build,"src/wireplumber"))`,environment...),String)
        @test occursin("libpipewire-ao-0.3",selection)
        @test !occursin("libpipewire-0.3.so",selection)
        write(joinpath(evidence,"libraries.log"),selection)
        wp=run(pipeline(addenv(`stdbuf -oL $(joinpath(wp_build,"src/wireplumber")) -c wireplumber.conf -p ao-probe`,environment);
            stdout=log,stderr=log);wait=false)
        client_infos=Dict{UInt32,Any}()
        bound_client_ids=Set{UInt32}()
        function managers()
            clients=globals("Client")
            with_thread_loop_lock(loop) do _
                for value in clients
                    value.id in bound_client_ids && continue
                    push!(bound_client_ids,value.id)
                    push!(bound_clients,bind(registry,value,Client;on_info=(c,info)->(client_infos[value.id]=info)))
                end
                filter(v->haskey(client_infos,v.id) && get(client_infos[v.id].properties,"application.process.id","")==string(getpid(wp)),clients)
            end
        end
        wait_proof(()->length(managers())==1,10,"exact manager client";check=healthy)
        manager=identity(only(managers()))
        merge!(declaration,Dict("runtime"=>runtime,"manager"=>manager,"output_node"=>identity(source),
            "output_port"=>identity(output_port),"input_node"=>identity(sink),"input_port"=>identity(input_port)))
        function check_declaration()
            # Node provenance remains RTC's obligation. Recheck exact current
            # incarnations before projection and again before accepting READY.
            for (kind,expected) in (("Node",source),("Node",sink),("Port",output_port),("Port",input_port))
                current=only(filter(v->v.id==expected.id,globals(kind)))
                @assert identity(current)==identity(expected) "declared endpoint incarnation changed"
                if kind=="Node"
                    @assert current.properties["client.id"]==string(runtime[1]) "declared Node owner changed"
                else
                    @assert current.properties["node.id"]==expected.properties["node.id"] "declared Port Node changed"
                end
            end
            for owner in (runtime,manager)
                @assert identity(only(filter(v->v.id==owner[1],globals("Client"))))==owner "declared client incarnation changed"
            end
            nothing
        end
        markers()=globals("Node";properties=Dict("node.name"=>SCOPE_NAME))
        saw(value)=occursin(value,read(joinpath(evidence,"wireplumber.log"),String))
        modes=DELAY_COMPLETION ? ((6,false,:pending_withdraw),) :
            ((1,false,:withdraw),(2,true,:withdraw),(3,false,:first_withdraw),(4,false,:wrong_phase_type),(5,false,:destroy_link))
        for (generation,passive,mode) in modes
            first_withdraw=mode==:first_withdraw
            check_declaration()
            withdrawal_count=count("RTC_REALIZATION_WITHDRAWN ",read(joinpath(evidence,"wireplumber.log"),String))
            with_thread_loop_lock(loop) do _
                marker=Filter(core,SCOPE_NAME;properties=Dict("node.name"=>SCOPE_NAME,"media.class"=>"Control",
                    "pipewireao.rtc-realization.profile"=>PROFILE))
                connect!(marker;flags=FILTER_ASYNC|FILTER_INACTIVE,
                    params=(snapshot(generation,first_withdraw ? 2 : 0,runtime,manager,output,input,passive),))
            end
            if first_withdraw
                wait_proof(()->count("RTC_REALIZATION_WITHDRAWN ",read(joinpath(evidence,"wireplumber.log"),String))>withdrawal_count && isempty(markers()),
                    10,"first-observed Withdraw removal";check=healthy)
                @test isempty(globals("Link"))
                push!(cases,Dict("generation"=>generation,"first_observed_withdraw"=>true,"links_after_withdraw"=>0))
            else
                wait_proof(()->length(markers())==1,10,"Prepared marker";check=healthy)
                marker_identity=identity(only(markers()))
                scope_key="$(marker_identity[1]):$(marker_identity[2])"
                path="pipewireao/rtc-realization/$scope_key/0"
                wait_proof(()->saw("RTC_REALIZATION_PREPARED $scope_key"),10,"manager accepted Prepared";check=healthy)
                @test isempty(globals("Link"))
                if mode==:wrong_phase_type
                    with_thread_loop_lock(loop) do _
                        update_params!(marker,(snapshot(generation,1,runtime,manager,output,input,passive;wrong_phase_type=true),))
                    end
                    wait_proof(()->isempty(markers()) && isempty(globals("Link")) && saw("RTC_REALIZATION_WITHDRAWN $scope_key"),
                        10,"native type substitution fenced";check=healthy)
                    @test !saw("RTC_REALIZATION_LINKS_READY $scope_key")
                    push!(cases,Dict("generation"=>generation,"marker"=>marker_identity,"wrong_phase_type"=>true,
                        "links_after_withdraw"=>0))
                    with_thread_loop_lock(loop) do _;close(marker);marker=nothing;end
                    continue
                end
                with_thread_loop_lock(loop) do _
                    update_params!(marker,(snapshot(generation,1,runtime,manager,output,input,passive),))
                end
                if mode==:pending_withdraw
                    wait_proof(()->saw("PROBE_PENDING_ACTIVATION_HELD") && length(globals("Link"))==1,
                        10,"actual native activation completion held";check=healthy)
                    link_global=only(globals("Link"))
                    @test link_global.properties["client.id"]==string(manager[1])
                    @test link_global.properties["object.path"]==path
                    with_thread_loop_lock(loop) do _
                        update_params!(marker,(snapshot(generation,2,runtime,manager,output,input,passive),))
                    end
                    wait_proof(()->saw("RTC_REALIZATION_WITHDRAW $scope_key requested"),5,"Withdraw with pending callback";check=healthy)
                    @test !saw("PROBE_DELAYED_ACTIVATION_DELIVERED")
                    @test length(markers())==1 && !saw("RTC_REALIZATION_WITHDRAWN $scope_key")
                    wait_proof(()->saw("PROBE_DELAYED_ACTIVATION_DELIVERED") && isempty(markers()) &&
                        isempty(globals("Link")) && saw("RTC_REALIZATION_WITHDRAWN $scope_key"),
                        10,"delayed callback drained and marker acknowledged";check=healthy)
                    transcript=read(joinpath(evidence,"wireplumber.log"),String)
                    @test first(findfirst("PROBE_DELAYED_ACTIVATION_DELIVERED",transcript)) <
                        first(findfirst("RTC_REALIZATION_WITHDRAWN $scope_key",transcript))
                    @test !saw("RTC_REALIZATION_LINKS_READY $scope_key")
                    push!(cases,Dict("generation"=>generation,"marker"=>marker_identity,"link"=>identity(link_global),
                        "test_completion_delay_ms"=>500,"marker_present_while_pending"=>true,
                        "ack_after_delayed_delivery"=>true,"links_after_withdraw"=>0))
                    with_thread_loop_lock(loop) do _;close(marker);marker=nothing;end
                    continue
                end
                wait_proof(()->saw("RTC_REALIZATION_LINKS_READY $scope_key") && length(globals("Link"))==1,
                    15,"manager-created native Link";check=healthy)
                link_global=only(globals("Link"))
                check_declaration()
                @test link_global.properties["client.id"]==string(manager[1])
                @test link_global.properties["object.path"]==path
                link_infos=LinkInfo[]
                observed=with_thread_loop_lock(loop) do _
                    bind(registry,link_global,Link;on_info=(l,info)->push!(link_infos,info))
                end
                push!(bound_links,observed)
                wait_proof(()->with_thread_loop_lock(loop) do _
                    any(v->v.format!==nothing,link_infos)
                end,10,"negotiated Link Format";check=healthy)
                info=with_thread_loop_lock(loop) do _
                    last(filter(v->v.format!==nothing,link_infos))
                end
                @test get(info.properties,"link.passive","false")==string(passive)
                @test (info.output_node_id,info.output_port_id,info.input_node_id,info.input_port_id)==
                    (source.id,output_port.id,sink.id,input_port.id)
                fixed=fixed_format(info.format)
                negotiated=NdArrayFormat(fixed)
                @test negotiated.element_type==FORMAT.element_type && negotiated.shape==FORMAT.shape &&
                    negotiated.layout==FORMAT.layout && negotiated.rate==FORMAT.rate
                @test ndarray_schema(fixed)==SCHEMA
                with_thread_loop_lock(loop) do _
                    if mode==:destroy_link
                        destroy_global!(registry,link_global.id)
                    else
                        update_params!(marker,(snapshot(generation,2,runtime,manager,output,input,passive),))
                    end
                end
                wait_proof(()->isempty(markers()) && isempty(globals("Link")) &&
                    saw("RTC_REALIZATION_WITHDRAWN $scope_key"),10,"marker acknowledgement and zero links";check=healthy)
                @test isempty(markers()) && isempty(globals("Link"))
                push!(cases,Dict("generation"=>generation,"marker"=>marker_identity,"link"=>identity(link_global),
                    "passive"=>passive,"path"=>path,"external_link_destroy"=>mode==:destroy_link,"link_properties"=>info.properties,
                    "endpoint_ids"=>[info.output_node_id,info.output_port_id,info.input_node_id,info.input_port_id],
                    "negotiated_format"=>Dict("shape"=>collect(negotiated.shape),"schema"=>ndarray_schema(fixed),
                        "element_type"=>string(negotiated.element_type),"layout"=>string(negotiated.layout),
                        "rate"=>[negotiated.rate.num,negotiated.rate.denom]),"links_after_withdraw"=>0))
            end
            with_thread_loop_lock(loop) do _;close(marker);marker=nothing;end
        end
        DELAY_COMPLETION || @test cases[1]["marker"] != cases[2]["marker"]
        @test process_running(wp) && process_running(daemon) && isrunning(loop)
        counts=Test.get_test_counts(Test.get_testset())
        success=counts.fails==0 && counts.errors==0 && counts.cumulative_fails==0 && counts.cumulative_errors==0
    catch error
        failure=sprint(showerror,error,catch_backtrace())
        rethrow()
    finally
        C.write_json(joinpath(evidence,"receipt.json"),Dict("success"=>success,"failure"=>failure,
            "scope"=>"isolated native realization Links and acknowledged withdrawal; no RTC scientific, timing or hardware qualification",
            "test_completion_delay_ms"=>DELAY_COMPLETION ? 500 : 0,
            "delay_scope"=>"test-only public callback dispatch delay; not hardware/server worst-case cancellation",
            "cases"=>cases,"filter_states"=>states,"native_format_callbacks"=>length(formats),
            "declaration"=>declaration,
            "remote"=>remote,"wp_source"=>wp_source,"wp_build"=>wp_build,
            "wp_pid"=>wp===nothing ? nothing : getpid(wp),
            "registry"=>registry===nothing ? [] : with_thread_loop_lock(loop) do _
                [Dict("id"=>v.id,"interface"=>v.type,"properties"=>v.properties) for v in find_globals(registry)]
            end))
        wp===nothing || stop_proof_child!(wp,"probe WirePlumber")
        with_thread_loop_lock(loop) do _
            for resource in (marker,reverse(bound_links)...,reverse(bound_clients)...,reverse(filters)...,registry,core,context)
                resource===nothing || close(resource)
            end
        end
        close(loop);close(log)
        cp(joinpath(directory,"private-core.log"),joinpath(evidence,"private-core.log"))
    end
end

@testset "Native realization links and withdrawal" begin
    with_control_private_core(probe;allow_passive=true)
end
