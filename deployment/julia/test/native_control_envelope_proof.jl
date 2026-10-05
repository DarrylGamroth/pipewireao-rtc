using Test
using PipeWireAO
using PipeWireAODeployment.NativeControlCodec

const ProofSPA = PipeWireAO.SPA
const PROOF_INSTANCE = Int64(23)
const PROOF_APPLY = UInt32(1)
const PROOF_QUERY = UInt32(2)
const PROOF_OWNER_NAME = "proof.control.filter"
const PROOF_CAP_NAMES = ("test.filter.cap.version", "test.filter.cap.instance")

include(joinpath(@__DIR__, "native_control_private_core.jl"))

function envelope_header_name(pod::PipeWireAO.Pod)
    object = PipeWireAO.pod_value(ProofSPA.Object, pod)
    object.type == ProofSPA.OBJECT_PROPS && object.id == ProofSPA.PARAM_PROPS || return nothing
    length(object.properties) == 1 || return nothing
    property = only(object.properties)
    property.key == ProofSPA.PROP_PARAMS && property.flags == 0 || return nothing
    outer = PipeWireAO.pod_value(ProofSPA.Struct, property.value)
    isempty(outer.values) && return nothing
    PipeWireAO.pod_type(outer.values[1]) == ProofSPA.POD_STRING || return nothing
    return PipeWireAO.pod_value(String, outer.values[1])
end

function assert_payload(payload::ProofSPA.Struct, adoptions::Int64, applied::Bool)
    @test length(payload.values) == 2
    @test PipeWireAO.pod_value(Int64, payload.values[1]) == adoptions
    @test PipeWireAO.pod_value(Bool, payload.values[2]) == applied
end

function run_native_control_envelope_proof(socket::String, directory::String, _daemon::Base.Process)
    binary = get(ENV, "NATIVE_CONTROL_PROOF_OWNER", "")
    isempty(binary) && error("set NATIVE_CONTROL_PROOF_OWNER to the built native_control_envelope_proof binary")
    isfile(binary) && isexecutable(binary) || error("NATIVE_CONTROL_PROOF_OWNER is not an executable file: $binary")

    owner_log = open(joinpath(directory, "native-owner.log"), "w+")
    owner = nothing
    loop = ThreadLoop("proof.native-envelope-client")
    context = core = registry = node = nothing
    node_info = Ref{Union{Nothing,NodeInfo}}(nothing)
    removed = Ref(false)
    failure = Ref{Union{Nothing,String}}(nothing)
    completion = Ref{Union{Nothing,Tuple{ReplyHeader,ProofSPA.Struct}}}(nothing)
    rejection = Ref{Union{Nothing,Tuple{ReplyHeader,ProofSPA.Struct}}}(nothing)
    cap_buffer = PropsBuffer(PROOF_CAP_NAMES, (Int32(0), Int64(0)))
    cap_values = Ref((Int32(0), Int64(0)))
    completions = Tuple{ReplyHeader,ProofSPA.Struct}[]
    rejections = Tuple{ReplyHeader,ProofSPA.Struct}[]
    controller = ControllerIdentity(UInt32(42), typemax(UInt64), Int64(9))
    function check_owner()
        failure[] === nothing || error("native envelope client callback failed: $(failure[])")
        owner !== nothing && Base.process_exited(owner) &&
            error("native envelope proof owner exited before observations completed")
        return nothing
    end
    function on_parameter(pod)
        name = envelope_header_name(pod)
        if name == "pipewireao.rtc.control.completion.header"
            value = decode_completion(pod; endpoint=:lifecycle)
            push!(completions, value)
            completion[] = value
        elseif name == "pipewireao.rtc.control.rejection.header"
            value = decode_rejection(pod; endpoint=:lifecycle)
            push!(rejections, value)
            rejection[] = value
        else
            parse_props!(cap_values, cap_buffer, pod)
        end
        return nothing
    end

    try
        owner = run(pipeline(Cmd([binary, socket, directory]); stdout=owner_log, stderr=owner_log);
            wait=false)
        owner_pid = getpid(owner)
        wait_proof(() -> isfile(joinpath(directory, "owner-ready")), 30,
            "native owner startup"; check=check_owner)
        @test parse(Int, read(joinpath(directory, "owner-ready"), String)) == owner_pid
        @test owner_pid != getpid()

        with_thread_loop_lock(loop) do _
            context = Context(loop)
            core = CoreConnection(context; properties=Dict("remote.name" => socket),
                on_error=(core, id, sequence, error) -> (failure[] = sprint(showerror, error); nothing))
            registry = Registry(core)
        end
        start!(loop)
        wait_proof(() -> with_thread_loop_lock(loop) do _
                length(find_globals(registry; interface="PipeWire:Interface:Node",
                    properties=("node.name" => PROOF_OWNER_NAME,))) == 1
            end, 10, "exact native proof node discovery"; check=check_owner)
        global_object = with_thread_loop_lock(loop) do _
            only(find_globals(registry; interface="PipeWire:Interface:Node",
                properties=("node.name" => PROOF_OWNER_NAME,)))
        end
        @test global_object.id > 0
        serial = parse(UInt64, global_object.properties["object.serial"])
        @test serial > 0
        with_thread_loop_lock(loop) do _
            node = bind(registry, global_object, Node;
                on_info=(proxy, info) -> begin
                    isempty(info.properties) || (node_info[] = info)
                    nothing
                end,
                on_removed=proxy -> (removed[] = true; nothing),
                on_error=(proxy, sequence, error) -> (failure[] = sprint(showerror, error); nothing),
                on_param=(proxy, sequence, id, index, next, pod) -> begin
                    if id == ProofSPA.PARAM_PROPS && pod !== nothing
                        try
                            on_parameter(pod)
                        catch error
                            # Non-envelope Props are expected; only strict errors
                            # after a recognized envelope are protocol failures.
                            try
                                name = envelope_header_name(pod)
                                if name in (
                                    "pipewireao.rtc.control.completion.header",
                                    "pipewireao.rtc.control.rejection.header",
                                )
                                    failure[] = sprint(showerror, error)
                                else
                                    parse_props!(cap_values, cap_buffer, pod)
                                end
                            catch nested
                                failure[] = sprint(showerror, nested)
                            end
                        end
                    end
                    nothing
                end)
        end
        wait_proof(() -> node_info[] !== nothing, 10, "native proof owner metadata"; check=check_owner)
        metadata = something(node_info[])
        @test metadata.id == global_object.id
        @test metadata.properties["object.serial"] == global_object.properties["object.serial"]
        @test metadata.properties["test.control.version"] == "1"
        @test metadata.properties["test.control.instance"] == string(PROOF_INSTANCE)
        @test metadata.properties["test.control.owner-pid"] == string(owner_pid)
        @test metadata.properties["test.control.profile"] == "diagnostic.rtc-envelope/1"
        @test metadata.n_input_ports == 0
        @test metadata.n_output_ports == 0

        with_thread_loop_lock(loop) do _
            subscribe_params!(node, (ProofSPA.PARAM_PROPS,))
            enum_params!(node, ProofSPA.PARAM_PROPS; count=UInt32(8))
        end
        wait_proof(() -> with_thread_loop_lock(loop) do _
                completion[] !== nothing && rejection[] !== nothing && cap_values[] == (Int32(1), PROOF_INSTANCE)
            end, 10, "initial completion, rejection and retained capability"; check=check_owner)
        initial_header, initial_payload = with_thread_loop_lock(loop) do _; something(completion[]); end
        @test initial_header == ReplyHeader(PROOF_INSTANCE, Int32(0))
        assert_payload(initial_payload, Int64(0), false)
        initial_rejection, initial_rejection_payload = with_thread_loop_lock(loop) do _; something(rejection[]); end
        @test initial_rejection == ReplyHeader(PROOF_INSTANCE, Int32(-22))
        @test isempty(initial_rejection_payload.values)
        @test cap_values[] == (Int32(1), PROOF_INSTANCE)

        apply_header = RequestHeader(controller, PROOF_INSTANCE, Int64(1), PROOF_APPLY, Int64(5_000_000_000))
        apply_payload = ProofSPA.Struct(PipeWireAO.Pod(Int32(7)))
        apply_pod = encode_request(apply_header, apply_payload)
        started = time_ns()
        with_thread_loop_lock(loop) do _; set_param!(node, ProofSPA.PARAM_PROPS, apply_pod); end
        wait_proof(() -> isfile(joinpath(directory, "request-staged")), 4,
            "apply staged before owner effect"; check=check_owner)
        stage_seconds = (time_ns() - started) / 1e9
        @test stage_seconds < 5
        @test with_thread_loop_lock(loop) do _; completion[] == (initial_header, initial_payload); end
        write(joinpath(directory, "allow-adoption"), "")
        wait_proof(() -> with_thread_loop_lock(loop) do _
                completion[] !== nothing && completion[][1].token == 1 && completion[][1].result == 0
            end, 10, "apply completion"; check=check_owner)
        applied_header, applied_payload = with_thread_loop_lock(loop) do _; something(completion[]); end
        @test applied_header == ReplyHeader(controller, PROOF_INSTANCE, Int64(1), PROOF_APPLY, Int32(0))
        assert_payload(applied_payload, Int64(1), true)

        # Replaying a completed request must return the retained completion and
        # must not perform a second owner adoption before a fresh query.
        with_thread_loop_lock(loop) do _; set_param!(node, ProofSPA.PARAM_PROPS, apply_pod); end

        other_controller = ControllerIdentity(UInt32(43), UInt64(1), Int64(10))
        collision = RequestHeader(other_controller, PROOF_INSTANCE, Int64(1), PROOF_APPLY,
            Int64(5_000_000_000))
        with_thread_loop_lock(loop) do _
            set_param!(node, ProofSPA.PARAM_PROPS, encode_request(collision, apply_payload))
        end
        wait_proof(() -> with_thread_loop_lock(loop) do _
                any(record -> record[1].controller == other_controller && record[1].token == 1 &&
                    record[1].result == -114, rejections)
            end, 10, "cross-controller token collision rejection"; check=check_owner)
        collision_reply = with_thread_loop_lock(loop) do _
            only(filter(record -> record[1].controller == other_controller && record[1].token == 1,
                rejections))
        end
        @test collision_reply[1] == ReplyHeader(other_controller, PROOF_INSTANCE,
            Int64(1), PROOF_APPLY, Int32(-114))
        @test isempty(collision_reply[2].values)
        @test with_thread_loop_lock(loop) do _; completion[] == (applied_header, applied_payload); end
        @test !any(record -> record[1].controller == controller && record[1].token == 1,
            rejections)

        query_header = RequestHeader(controller, PROOF_INSTANCE, Int64(2), PROOF_QUERY,
            Int64(5_000_000_000))
        with_thread_loop_lock(loop) do _
            set_param!(node, ProofSPA.PARAM_PROPS, encode_request(query_header, ProofSPA.Struct()))
        end
        wait_proof(() -> with_thread_loop_lock(loop) do _
                completion[] !== nothing && completion[][1].token == 2
            end, 10, "fresh query completion"; check=check_owner)
        query_reply = with_thread_loop_lock(loop) do _; something(completion[]); end
        @test query_reply[1] == ReplyHeader(controller, PROOF_INSTANCE, Int64(2), PROOF_QUERY, Int32(0))
        assert_payload(query_reply[2], Int64(1), true)
        @test with_thread_loop_lock(loop) do _; completion[] == query_reply; end

        unsupported = RequestHeader(controller, PROOF_INSTANCE, Int64(3), UInt32(999),
            Int64(5_000_000_000))
        with_thread_loop_lock(loop) do _
            set_param!(node, ProofSPA.PARAM_PROPS, encode_request(unsupported, ProofSPA.Struct()))
        end
        wait_proof(() -> with_thread_loop_lock(loop) do _
                any(record -> record[1].controller == controller && record[1].token == 3 &&
                    record[1].result == -22, rejections)
            end, 10, "unsupported operation correlated rejection"; check=check_owner)
        unsupported_reply = with_thread_loop_lock(loop) do _
            only(filter(record -> record[1].controller == controller && record[1].token == 3,
                rejections))
        end
        @test unsupported_reply[1] == ReplyHeader(controller, PROOF_INSTANCE,
            Int64(3), UInt32(999), Int32(-22))
        @test isempty(unsupported_reply[2].values)
        @test with_thread_loop_lock(loop) do _; completion[] == query_reply; end

        write(joinpath(directory, "owner-quit"), "")
        wait_proof(() -> removed[], 10, "native Filter removal"; check=()->nothing)
        wait_proof(() -> Base.process_exited(owner), 5, "native owner exit"; check=()->nothing)
        wait(owner)
        @test owner.exitcode == 0
        @test removed[]
        @test with_thread_loop_lock(loop) do _
            isempty(find_globals(registry; interface="PipeWire:Interface:Node",
                properties=("node.name" => PROOF_OWNER_NAME,)))
        end
        println("NATIVE_CONTROL_ENVELOPE_PROOF owner_pid=$owner_pid client_pid=$(getpid()) global_id=$(global_object.id) serial=$serial staged_seconds=$stage_seconds adoptions=1 duplicate=true collision=-114 unsupported=-22 query=2 removed=true ports=0")
    catch error
        println("NATIVE_CONTROL_ENVELOPE_DIAGNOSTIC completions=$(completions) rejections=$(rejections) cap=$(cap_values[]) failure=$(failure[])")
        rethrow()
    finally
        write(joinpath(directory, "owner-quit"), "")
        with_thread_loop_lock(loop) do _
            for resource in (node, registry, core, context)
                resource === nothing || close(resource)
            end
        end
        close(loop)
        if owner !== nothing
            stop_proof_child!(owner, "native proof owner")
        end
        flush(owner_log)
        seekstart(owner_log)
        print(read(owner_log, String))
        close(owner_log)
    end
end

println("PipeWireAO_VERSION=$(Base.pkgversion(PipeWireAO)) private_core=true separate_owner=true")
@testset "native fixed-envelope Julia to Rust Filter proof" begin
    @test Base.pkgversion(PipeWireAO) == v"0.6.16"
    with_control_private_core(run_native_control_envelope_proof)
end
