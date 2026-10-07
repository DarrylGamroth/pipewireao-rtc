#!/usr/bin/env julia
# Opt-in public-interface experiment; never connects to an existing core.
using Test, PipeWireAO
using SHA
using PipeWireAODeployment
const C = PipeWireAODeployment.Common
include(joinpath(@__DIR__, "../julia/test/native_control_private_core.jl"))

length(ARGS) in (3,4) || error("expected WIREPLUMBER_SOURCE BUILD EVIDENCE_OUTPUT [probe mode]")
const PROBE_MODE = length(ARGS)==4 ? ARGS[4] : "normal"
PROBE_MODE in ("normal","delay-completion","empty-initial","empty-initial-coalesced",
    "empty-initial-roundtrip","delayed-marker-removal","rust-bootstrap","rust-marker-loss",
    "multi-links-2","multi-links-3") || error("unknown probe mode")
const DELAY_COMPLETION = PROBE_MODE in ("delay-completion","delayed-marker-removal","rust-marker-loss")
const LINK_COUNT = PROBE_MODE=="multi-links-2" ? 2 : PROBE_MODE=="multi-links-3" ? 3 : 1
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
function snapshot(generation, phase, runtime, manager, output, input, passive; wrong_phase_type=false,extra_rows=())
    row = native_struct((Int32(0), output, input, passive))
    return Pod(props_param(SPA.Props("version"=>Int32(1), "generation"=>Int64(generation),
        "phase"=>(wrong_phase_type ? Int32(phase) : SPA.Id(phase)), "runtime"=>native_identity(runtime),
        "manager"=>native_identity(manager), "links"=>native_struct((row,extra_rows...)))))
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
    wp = rust = nothing
    wp_pid = nothing
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
                for index in 1:LINK_COUNT
                    add_port!(filter,direction;properties=Dict("port.name"=>(direction==:output ? "output_$index" : "input_$index")),
                        params=(ndarray_format(FORMAT;schema=SCHEMA),))
                end
                connect!(filter;flags=FILTER_ASYNC|FILTER_INACTIVE)
            end
        end
        start!(loop)
        globals(kind; properties=Dict{String,String}()) = with_thread_loop_lock(loop) do _
            find_globals(registry;interface="PipeWire:Interface:$kind",properties)
        end
        healthy() = (@assert process_running(daemon) &&
            (wp===nothing || process_running(wp) || PROBE_MODE=="rust-marker-loss") &&
            isrunning(loop) "private probe child or loop stopped")
        wait_proof(()->length(globals("Node"))==2 && length(globals("Port"))==2*LINK_COUNT,10,"inactive endpoints";check=healthy)
        source = only(globals("Node";properties=Dict("node.name"=>"realization.source")))
        sink = only(globals("Node";properties=Dict("node.name"=>"realization.sink")))
        output_ports = sort(globals("Port";properties=Dict("node.id"=>string(source.id)));by=v->v.properties["port.name"])
        input_ports = sort(globals("Port";properties=Dict("node.id"=>string(sink.id)));by=v->v.properties["port.name"])
        output_port,input_port=first(output_ports),first(input_ports)
        runtime = identity(only(filter(v->v.id==parse(UInt32,source.properties["client.id"]),globals("Client"))))
        @test source.properties["client.id"] == sink.properties["client.id"]
        output = native_endpoint(identity(source),identity(output_port),runtime)
        input = native_endpoint(identity(sink),identity(input_port),runtime)
        extra_rows=Tuple(native_struct((Int32(index-1),
            native_endpoint(identity(source),identity(output_ports[index]),runtime),
            native_endpoint(identity(sink),identity(input_ports[index]),runtime),iseven(index))) for index in 2:LINK_COUNT)
        projection(generation,phase,passive;kwargs...)=snapshot(generation,phase,runtime,manager,output,input,passive;extra_rows,kwargs...)

        scripts=joinpath(directory,"scripts");mkpath(scripts)
        policy_source=get(ENV,"PIPEWIREAO_REALIZATION_POLICY_SOURCE",joinpath(@__DIR__,"realization.lua"))
        policy=read(policy_source,String)
        declaration["policy_source"]=policy_source
        declaration["policy_sha256"]=bytes2hex(SHA.sha256(policy))
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
        wp_pid=getpid(wp)
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
        declaration["cohort_ports"]=Dict("output"=>identity.(output_ports),"input"=>identity.(input_ports))
        function check_declaration()
            # Node provenance remains RTC's obligation. Recheck exact current
            # incarnations before projection and again before accepting READY.
            endpoints=[("Node",source),("Node",sink),[("Port",v) for v in output_ports]...,[("Port",v) for v in input_ports]...]
            for (kind,expected) in endpoints
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
        if PROBE_MODE in ("rust-bootstrap","rust-marker-loss")
            binary=get(ENV,"PIPEWIREAO_REALIZATION_TEST_BINARY",
                "/tmp/rtc-maintenance-target-20261006/debug/deps/pipewireao_rtc-f1c466bc19c821bb")
            isfile(binary) || error("compiled ignored Rust bootstrap test binary is missing")
            declaration["rust_binary_sha256"]=bytes2hex(open(SHA.sha256,binary))
            declaration["rust_binary_mtime"]=stat(binary).mtime
            write(joinpath(evidence,"rust-libraries.log"),read(`ldd $binary`,String))
            cp(joinpath(@__DIR__,"../../src/live/wireplumber.rs"),joinpath(evidence,"wireplumber-rust-source.rs"))
            rust_environment=Dict("PIPEWIREAO_REALIZATION_REMOTE"=>remote,
                "PIPEWIREAO_REALIZATION_MANAGER_ID"=>string(manager[1]),
                "PIPEWIREAO_REALIZATION_MANAGER_SERIAL"=>string(manager[2]),
                "PIPEWIREAO_REALIZATION_MARKER_NAME"=>SCOPE_NAME,
                "PIPEWIREAO_REALIZATION_LOG"=>joinpath(evidence,"wireplumber.log"),
                "PIPEWIRE_REMOTE"=>remote,"PIPEWIREAO_REMOTE"=>remote)
            test_name=PROBE_MODE=="rust-marker-loss" ? get(ENV,"PIPEWIREAO_REALIZATION_TEST_NAME","") :
                "live::wireplumber::tests::empty_marker_then_prepared_props_are_public_and_policy_recognized"
            isempty(test_name) && error("PIPEWIREAO_REALIZATION_TEST_NAME is required for rust-marker-loss")
            command=`$binary --ignored --exact $test_name --nocapture`
            write(joinpath(evidence,"rust-command.txt"),string(command)*"\n")
            rust_log_path=joinpath(evidence,PROBE_MODE*".log")
            open(rust_log_path,"w") do rust_log
                rust=run(pipeline(addenv(command,rust_environment);stdout=rust_log,stderr=rust_log);wait=false)
                wait_proof(()->Base.process_exited(rust),30,"ignored Rust bootstrap completion";check=healthy)
            end
            @test Base.success(rust)
            @test saw(PROBE_MODE=="rust-marker-loss" ? "PROBE_PENDING_ACTIVATION_HELD" :
                "RTC_REALIZATION_PREPARED ") && saw("RTC_REALIZATION_WITHDRAWN ")
            @test isempty(markers()) && isempty(globals("Link"))
            manager_present=any(v->identity(v)==manager,globals("Client"))
            if PROBE_MODE=="rust-marker-loss"
                rust_transcript=read(rust_log_path,String)
                @test occursin("RUST_MARKER_LOSS_UNKNOWN_RETAINED",rust_transcript)
                @test occursin("RUST_MARKER_LOSS_NEXT_REALIZATION_FENCED",rust_transcript)
                @test saw("PROBE_PENDING_ACTIVATION_HELD") && saw("PROBE_DELAYED_ACTIVATION_DELIVERED")
                @test !saw("RTC_REALIZATION_LINKS_READY ")
                if occursin("RUST_MARKER_LOSS_MANAGER_GONE_CLEANUP",rust_transcript)
                    @test !manager_present
                else
                    @test occursin("RUST_MARKER_LOSS_MANAGER_DESTROY_UNSUPPORTED",rust_transcript)
                end
            end
            push!(cases,Dict("rust_bootstrap"=>PROBE_MODE=="rust-bootstrap",
                "rust_marker_loss"=>PROBE_MODE=="rust-marker-loss","test_name"=>test_name,
                "binary"=>binary,"exit_code"=>rust.exitcode,"wp_running_after_test"=>process_running(wp),
                "exact_manager_present_after_test"=>manager_present,"links_after_withdraw"=>0))
        end
        modes=PROBE_MODE in ("rust-bootstrap","rust-marker-loss") ? () :
            PROBE_MODE=="delay-completion" ? ((6,false,:pending_withdraw),) :
            PROBE_MODE=="empty-initial" ? ((7,false,:empty_initial),) :
            PROBE_MODE=="empty-initial-coalesced" ? ((9,false,:empty_initial_coalesced),) :
            PROBE_MODE=="empty-initial-roundtrip" ? ((10,false,:empty_initial_roundtrip),) :
            PROBE_MODE=="delayed-marker-removal" ? ((8,false,:pending_marker_removal),) :
            LINK_COUNT>1 ? ((11,false,:multiple_links),) :
            ((1,false,:withdraw),(2,true,:withdraw),(3,false,:first_withdraw),(4,false,:wrong_phase_type),(5,false,:destroy_link))
        for (generation,passive,mode) in modes
            first_withdraw=mode==:first_withdraw
            empty_initial=mode in (:empty_initial,:empty_initial_coalesced,:empty_initial_roundtrip)
            immediate_realize=mode in (:empty_initial_coalesced,:empty_initial_roundtrip)
            check_declaration()
            declaration["intent_size_bytes"]=length(projection(generation,0,passive).data)
            withdrawal_count=count("RTC_REALIZATION_WITHDRAWN ",read(joinpath(evidence,"wireplumber.log"),String))
            with_thread_loop_lock(loop) do _
                marker=Filter(core,SCOPE_NAME;properties=Dict("node.name"=>SCOPE_NAME,"media.class"=>"Control",
                    "pipewireao.rtc-realization.profile"=>PROFILE),
                    on_state_changed=(f,old,new,detail)->push!(states,("marker-$generation",string(new),detail)))
                # empty-initial reproduces the Rust marker's INACTIVE-only
                # connect before discovery and the later first Props update.
                connect!(marker;flags=empty_initial ? FILTER_INACTIVE : FILTER_ASYNC|FILTER_INACTIVE,
                    params=empty_initial ? () :
                        (projection(generation,first_withdraw ? 2 : 0,passive),))
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
                if empty_initial
                    marker_global=only(markers())
                    marker_creator=identity(only(filter(v->v.id==parse(UInt32,marker_global.properties["client.id"]),globals("Client"))))
                    @test marker_creator==runtime
                    declaration["empty_initial_marker"] = marker_identity
                    declaration["discovered_marker_creator"] = marker_creator
                    immediate_realize && @test isempty(globals("Link"))
                    with_thread_loop_lock(loop) do _
                        update_params!(marker,(projection(generation,0,passive),))
                        if mode==:empty_initial_coalesced
                            update_params!(marker,(projection(generation,1,passive),))
                        end
                    end
                    if mode==:empty_initial_roundtrip
                        roundtrip(core)
                        with_thread_loop_lock(loop) do _
                            update_params!(marker,(projection(generation,1,passive),))
                        end
                    end
                end
                if !immediate_realize
                    wait_proof(()->saw("RTC_REALIZATION_PREPARED $scope_key"),10,"manager accepted Prepared";check=healthy)
                    @test isempty(globals("Link"))
                end
                if mode==:wrong_phase_type
                    with_thread_loop_lock(loop) do _
                        update_params!(marker,(projection(generation,1,passive;wrong_phase_type=true),))
                    end
                    wait_proof(()->isempty(markers()) && isempty(globals("Link")) && saw("RTC_REALIZATION_WITHDRAWN $scope_key"),
                        10,"native type substitution fenced";check=healthy)
                    @test !saw("RTC_REALIZATION_LINKS_READY $scope_key")
                    push!(cases,Dict("generation"=>generation,"marker"=>marker_identity,"wrong_phase_type"=>true,
                        "links_after_withdraw"=>0))
                    with_thread_loop_lock(loop) do _;close(marker);marker=nothing;end
                    continue
                end
                if !immediate_realize
                    with_thread_loop_lock(loop) do _
                        update_params!(marker,(projection(generation,1,passive),))
                    end
                end
                if mode in (:pending_withdraw,:pending_marker_removal)
                    wait_proof(()->saw("PROBE_PENDING_ACTIVATION_HELD") && length(globals("Link"))==1,
                        10,"actual native activation completion held";check=healthy)
                    link_global=only(globals("Link"))
                    @test link_global.properties["client.id"]==string(manager[1])
                    @test link_global.properties["object.path"]==path
                    with_thread_loop_lock(loop) do _
                        if mode==:pending_marker_removal
                            close(marker)
                            marker=nothing
                        else
                            update_params!(marker,(projection(generation,2,passive),))
                        end
                    end
                    reason=mode==:pending_marker_removal ? "runtime-removed" : "requested"
                    wait_proof(()->saw("RTC_REALIZATION_WITHDRAW $scope_key $reason"),5,"terminal marker event with pending callback";check=healthy)
                    @test !saw("PROBE_DELAYED_ACTIVATION_DELIVERED")
                    if mode==:pending_marker_removal
                        wait_proof(()->isempty(markers()),5,"owner removed marker";check=healthy)
                        @test !saw("RTC_REALIZATION_WITHDRAWN $scope_key") && process_running(wp)
                    else
                        @test length(markers())==1 && !saw("RTC_REALIZATION_WITHDRAWN $scope_key")
                    end
                    wait_proof(()->saw("PROBE_DELAYED_ACTIVATION_DELIVERED") && isempty(markers()) &&
                        isempty(globals("Link")) && saw("RTC_REALIZATION_WITHDRAWN $scope_key"),
                        10,"delayed callback drained and manager synchronization completed";check=healthy)
                    transcript=read(joinpath(evidence,"wireplumber.log"),String)
                    @test first(findfirst("PROBE_DELAYED_ACTIVATION_DELIVERED",transcript)) <
                        first(findfirst("RTC_REALIZATION_WITHDRAWN $scope_key",transcript))
                    @test !saw("RTC_REALIZATION_LINKS_READY $scope_key")
                    push!(cases,Dict("generation"=>generation,"marker"=>marker_identity,"link"=>identity(link_global),
                        "test_completion_delay_ms"=>500,"marker_present_while_pending"=>mode==:pending_withdraw,
                        "unexpected_owner_marker_removal"=>mode==:pending_marker_removal,
                        "acknowledgement_eligible"=>mode==:pending_withdraw,
                        "manager_drain_log_after_delayed_delivery"=>true,"links_after_withdraw"=>0))
                    with_thread_loop_lock(loop) do _;marker===nothing || close(marker);marker=nothing;end
                    continue
                end
                wait_proof(()->saw("RTC_REALIZATION_LINKS_READY $scope_key") && length(globals("Link"))==LINK_COUNT,
                    15,"manager-created native Link";check=healthy)
                check_declaration()
                verified=Any[]
                for index in 1:LINK_COUNT
                    expected_path="pipewireao/rtc-realization/$scope_key/$(index-1)"
                    link_global=only(filter(v->v.properties["object.path"]==expected_path,globals("Link")))
                    @test link_global.properties["client.id"]==string(manager[1])
                    @test link_global.properties["object.path"]==expected_path
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
                    expected_passive=index==1 ? passive : iseven(index)
                    @test get(info.properties,"link.passive","false")==string(expected_passive)
                    @test (info.output_node_id,info.output_port_id,info.input_node_id,info.input_port_id)==
                        (source.id,output_ports[index].id,sink.id,input_ports[index].id)
                    fixed=fixed_format(info.format)
                    negotiated=NdArrayFormat(fixed)
                    @test negotiated.element_type==FORMAT.element_type && negotiated.shape==FORMAT.shape &&
                        negotiated.layout==FORMAT.layout && negotiated.rate==FORMAT.rate
                    @test ndarray_schema(fixed)==SCHEMA
                    push!(verified,(link_global,info,fixed,negotiated,expected_passive))
                end
                link_global,info,fixed,negotiated,_=first(verified)
                with_thread_loop_lock(loop) do _
                    if mode==:destroy_link
                        destroy_global!(registry,link_global.id)
                    else
                        update_params!(marker,(projection(generation,2,passive),))
                    end
                end
                wait_proof(()->isempty(markers()) && isempty(globals("Link")) &&
                    saw("RTC_REALIZATION_WITHDRAWN $scope_key"),10,"marker acknowledgement and zero links";check=healthy)
                @test isempty(markers()) && isempty(globals("Link"))
                push!(cases,Dict("generation"=>generation,"marker"=>marker_identity,"link"=>identity(link_global),
                    "passive"=>passive,"path"=>path,"empty_initial_params"=>empty_initial,
                    "immediate_prepared_to_realize"=>immediate_realize,
                    "owner_roundtrip_before_realize"=>mode==:empty_initial_roundtrip,
                    "manager_observed_prepared"=>saw("RTC_REALIZATION_PREPARED $scope_key"),
                    "declared_link_count"=>LINK_COUNT,"intent_size_bytes"=>declaration["intent_size_bytes"],
                    "cohort"=>[Dict("link"=>identity(v[1]),"properties"=>v[2].properties,"passive"=>v[5],
                        "endpoint_ids"=>[v[2].output_node_id,v[2].output_port_id,v[2].input_node_id,v[2].input_port_id]) for v in verified],
                    "external_link_destroy"=>mode==:destroy_link,"link_properties"=>info.properties,
                    "endpoint_ids"=>[info.output_node_id,info.output_port_id,info.input_node_id,info.input_port_id],
                    "negotiated_format"=>Dict("shape"=>collect(negotiated.shape),"schema"=>ndarray_schema(fixed),
                        "element_type"=>string(negotiated.element_type),"layout"=>string(negotiated.layout),
                        "rate"=>[negotiated.rate.num,negotiated.rate.denom]),"links_after_withdraw"=>0))
            end
            with_thread_loop_lock(loop) do _;close(marker);marker=nothing;end
        end
        PROBE_MODE=="normal" && @test cases[1]["marker"] != cases[2]["marker"]
        @test (process_running(wp) || PROBE_MODE=="rust-marker-loss") && process_running(daemon) && isrunning(loop)
        counts=Test.get_test_counts(Test.get_testset())
        success=counts.fails==0 && counts.errors==0 && counts.cumulative_fails==0 && counts.cumulative_errors==0
    catch error
        failure=sprint(showerror,error,catch_backtrace())
        rethrow()
    finally
        C.write_json(joinpath(evidence,"receipt.json"),Dict("success"=>success,"failure"=>failure,
            "scope"=>"isolated native realization Links and acknowledged withdrawal; no RTC scientific, timing or hardware qualification",
            "probe_mode"=>PROBE_MODE,
            "marker_loss_scope"=>PROBE_MODE=="rust-marker-loss" ?
                "native Rust gate verifies unknown withdrawal retains Session and fences another realization; exact manager removal supplies an alternate cleanup fence when supported" :
                "unexpected owner marker removal proves manager drain only; it cannot establish RTC cleanup acknowledgement eligibility or same-runtime retry fencing",
            "test_completion_delay_ms"=>DELAY_COMPLETION ? 500 : 0,
            "delay_scope"=>"test-only public callback dispatch delay; not hardware/server worst-case cancellation",
            "cases"=>cases,"filter_states"=>states,"native_format_callbacks"=>length(formats),
            "declaration"=>declaration,
            "remote"=>remote,"wp_source"=>wp_source,"wp_build"=>wp_build,
            "wp_pid"=>wp_pid,
            "registry"=>registry===nothing ? [] : with_thread_loop_lock(loop) do _
                [Dict("id"=>v.id,"interface"=>v.type,"permissions"=>v.permissions,"properties"=>v.properties) for v in find_globals(registry)]
            end))
        rust===nothing || stop_proof_child!(rust,"ignored Rust bootstrap test")
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
