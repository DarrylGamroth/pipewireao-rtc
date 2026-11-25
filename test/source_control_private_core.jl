module SourceControlPrivateCoreTests

using Test, PipeWireAO, PipeWireAORTC
include("control_private_core.jl")

const Source = PipeWireAORTC.SourceControl
const INSTANCE = Int64(59)
const NAME = "test.finite-source"
const INITIAL_RECEIPT = Source.snapshot_values(INSTANCE, Source.INITIAL, Int64(0), Int32(0),
    Int64(1), Int64(0), false, false, Int64(1), Int64(0))

function check_source(socket)
    loop = ThreadLoop("source-control-test")
    context = owner_core = client_core = registry = filter = proxy = nothing
    inbox = Source.Mailbox(INSTANCE; revocation=true)
    snapshot = PropsBuffer(Source.SNAPSHOT_NAMES, INITIAL_RECEIPT)
    rejection = PropsBuffer(Source.REJECTION_NAMES, INITIAL_RECEIPT)
    ack = PropsBuffer(Source.REVOKE_ACK_NAMES, (Source.VERSION, INSTANCE, Int64(0), Int64(1), Int64(0), Int64(0)))
    committed = Ref(INITIAL_RECEIPT)
    rejected = Ref(INITIAL_RECEIPT)
    revoked = Ref((Source.VERSION, INSTANCE, Int64(0), Int64(1), Int64(0), Int64(0)))
    snapshot_buffer = Ref(INITIAL_RECEIPT)
    ack_buffer = Ref(revoked[])
    function observe(_, sequence, id, index, next, pod)
        if id == SPA.PARAM_PROPS && pod !== nothing
            if parse_props!(snapshot_buffer, snapshot, pod) == 0
                committed[] = snapshot_buffer[]
            elseif parse_props!(snapshot_buffer, rejection, pod) == 0
                rejected[] = snapshot_buffer[]
            elseif parse_props!(ack_buffer, ack, pod) == 0
                revoked[] = ack_buffer[]
            end
        end
        return nothing
    end
    wait_for(f, label) = wait_proof(() -> with_thread_loop_lock(_ -> f(), loop), 15, label)
    submit(pod) = with_thread_loop_lock(_ -> set_param!(proxy, SPA.PARAM_PROPS, pod), loop)
    paused = (; sequence=UInt64(5), acquired_sequence=UInt64(6), running=false, completed=false)
    try
        with_thread_loop_lock(loop) do _
            context = Context(loop)
            owner_core = CoreConnection(context; properties=Dict("remote.name" => socket))
            client_core = CoreConnection(context; properties=Dict("remote.name" => socket))
            registry = Registry(client_core)
            filter = Filter(owner_core, NAME;
                properties=merge(Source.source_properties(inbox), Dict("node.name" => NAME)),
                on_param_changed=Source.ParameterChanged(inbox))
            connect!(filter; flags=FILTER_INACTIVE, params=inbox.parameters.params)
        end
        start!(loop)
        objects() = find_globals(registry; interface="PipeWire:Interface:Node",
            properties=("node.name" => NAME,))
        wait_for(() -> length(objects()) == 1, "finite source publication")
        with_thread_loop_lock(loop) do _
            proxy = bind(registry, only(objects()), Node; on_param=observe)
            subscribe_params!(proxy, (SPA.PARAM_PROPS,))
        end

        submit(run_control_request(1, :running))
        wait_for(() -> inbox.ready[], "Run staged")
        with_thread_loop_lock(loop) do _
            @test Source.pending(inbox) == (Source.RUN, 1, true)
            Source.report_ready!(inbox, Int64(1), UInt64(4))
            Source.publish!(inbox, filter, Source.RUN, Int64(1), Int32(0),
                merge(paused, (; running=true)), Int64(1))
        end
        wait_for(() -> committed[][4] == 1, "native Run receipt")
        @test committed[] == Source.snapshot_values(INSTANCE, Source.RUN, Int64(1),
            Int32(0), Int64(1), Int64(5), true, false, Int64(1), Int64(4))

        # Revoke overtakes a pending Reset. Both outcomes must reach the client.
        submit(reset_control_request(2))
        wait_for(() -> Source.pending(inbox) == (Source.RESET, 2, false), "Reset staged")
        request = PropsBuffer(Source.REVOKE_NAMES, Source.query_values(Int64(3), INSTANCE))
        submit(request.pod)
        wait_for(() -> inbox.pending_revoke == 3, "Revoke staged")
        with_thread_loop_lock(loop) do _
            @test Source.pending(inbox) == (Source.REVOKE, 3, false)
            Source.publish!(inbox, filter, Source.REVOKE, Int64(3), Int32(0), paused, Int64(1))
            Source.publish_rejection!(inbox, filter, paused, Int64(1))
            @test !inbox.ready[]
        end
        wait_for(() -> revoked[][3] == 3 && rejected[][4] == 2, "Revoke and cancelled Reset receipts")
        @test revoked[] == (Source.VERSION, INSTANCE, 3, 1, 6, 5)
        @test committed[][3:8] == (Source.REVOKE, 3, 0, 1, 5, false)
        @test rejected[][3:5] == (Source.RESET, 2, -Base.Libc.ECANCELED)

        query = PropsBuffer(Source.QUERY_NAMES, Source.query_values(Int64(4), INSTANCE))
        submit(query.pod)
        wait_for(() -> Source.pending(inbox) == (Source.QUERY, 4, false), "Query staged")
        with_thread_loop_lock(loop) do _
            Source.publish!(inbox, filter, Source.QUERY, Int64(4), Int32(0), paused, Int64(1))
        end
        wait_for(() -> committed[][4] == 4, "Query receipt")
        @test committed[][3:end] == (Source.QUERY, 4, 0, 1, 5, false, false, 1, 4)

        submit(reset_control_request(5))
        wait_for(() -> Source.pending(inbox) == (Source.RESET, 5, false), "fresh Reset staged")
        with_thread_loop_lock(loop) do _
            next_generation = merge(paused, (; sequence=UInt64(0), acquired_sequence=UInt64(0)))
            Source.publish!(inbox, filter, Source.RESET, Int64(5), Int32(0), next_generation, Int64(2))
        end
        wait_for(() -> committed[][4] == 5, "Reset receipt")
        @test committed[][3:end] == (Source.RESET, 5, 0, 2, 0, false, false, 1, 4)
    finally
        with_thread_loop_lock(loop) do _
            for resource in (proxy, filter, registry, client_core, owner_core, context)
                resource === nothing || close(resource)
            end
        end
        close(loop)
    end
end

@testset "Native finite source Run, Revoke and Query" begin
    with_control_private_core() do socket, _, _
        check_source(socket)
    end
end

end
