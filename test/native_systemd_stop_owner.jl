# Cold native session stand-in for the ExecStop integration test. No science,
# hardware, links, or CUDA are loaded; production ordering is owned by Lua.
using PipeWireAO, PipeWireAODeployment
const Client = PipeWireAODeployment.NativeControlClient
const Endpoint = PipeWireAODeployment.NativeControlEndpoint
const Profile = PipeWireAODeployment.NativeSessionProfile
const Codec = PipeWireAODeployment.NativeSessionCodec
const Envelope = PipeWireAODeployment.NativeControlCodec
const S = PipeWireAODeployment.SystemdOwners
const C = PipeWireAODeployment.Common
Client.decode_request(::Profile.Profile, header, payload::SPA.Struct) = Codec.Runner.decode_request(header, payload)
Client.encode_rejection(::Profile.Profile, header, lifecycle) =
    Envelope.encode_rejection(header, SPA.Struct(Pod(""), Pod("request rejected"), Pod(SPA.Id(UInt32(lifecycle)))))
Client.encode_failure(::Profile.Profile, header, lifecycle) =
    Envelope.encode_completion(header, SPA.Struct(Pod(""), Pod("request expired"), Pod(SPA.Id(UInt32(lifecycle)))))

function main(root, remote, unit, mode)
# Forced-stop cases measure systemd's native ordering; avoid Julia's diagnostic
# shutdown/finalizers introducing a second independent wait in this stand-in.
ccall(:signal, Ptr{Cvoid}, (Cint, Ptr{Cvoid}), Base.SIGTERM, C_NULL)
invocation = ENV["INVOCATION_ID"]
runtime = joinpath(root, invocation)
mkpath(runtime)
uuid = "a5555555-5555-4555-8555-555555555555"
event(name) = write(joinpath(root, name), string(time_ns()))
loop = ThreadLoop("test-systemd-stop")
context = core = endpoint = nothing
try
    with_thread_loop_lock(loop) do _
        context = Context(loop)
        core = CoreConnection(context; properties=Dict("remote.name"=>remote))
        endpoint = Endpoint.Endpoint(Profile.Profile(), Codec.RunnerCommand, loop, core,
            "pipewireao.rtc.session.stop-test", Int64(42), Codec.Runner.Running;
            properties_extra=Dict("pipewireao.rtc.session.session-uuid"=>uuid))
    end
    start!(loop)
    C.write_json(joinpath(runtime, "launch.json"), Dict(
        "unit"=>unit, "invocation"=>invocation, "runtime"=>runtime,
        "wireplumber_pid"=>getpid(), "wireplumber_start_ticks"=>S.start_ticks(getpid()),
        "session_control_instance"=>42, "session_uuid"=>uuid, "remote"=>remote,
        "name"=>"stop-test"); atomic=true)
    event("ready")
    while true
        Endpoint.poll!(endpoint)
        ticket = Endpoint.take!(endpoint)
        if ticket !== nothing
            header = Envelope.ReplyHeader(ticket.header.controller, endpoint.instance,
                ticket.header.token, ticket.header.operation, Int32(0))
            if ticket.header.operation == 3
                state = mode == "fault" ? Codec.Runner.Fault : Codec.Runner.Running
                details = SPA.Struct(Pod(true), Pod(Int64(1)), Pod(Int64(1)), Pod(Int64(0)), Pod(SPA.Struct()))
                Endpoint.complete!(endpoint, ticket, Envelope.encode_completion(header,
                    SPA.Struct(Pod(SPA.Id(UInt32(state))), Pod(SPA.Id(UInt32(2))), Pod(details))))
            elseif ticket.header.operation == 1
                event("quit-entry")
                if mode == "unknown"
                    close(endpoint)
                    endpoint = nothing
                    while true; sleep(0.01); end
                end
                # Parent gates the adopted command. ExecStop must keep this
                # process and its core alive throughout the in-flight interval.
                while !isfile(joinpath(root, "adopt-command"))
                    Endpoint.check_ticket(endpoint, ticket)
                    sleep(0.002)
                end
                event("command-adopted")
                event("graph-stopped")
                event("links-withdrawn")
                event("report-written")
                Endpoint.retain_controller!(endpoint, ticket)
                Endpoint.complete!(endpoint, ticket, Envelope.encode_completion(header,
                    SPA.Struct(Pod(SPA.Id(UInt32(1))), Pod(SPA.Id(UInt32(1))), Pod(SPA.Struct(Pod(true)))));
                    terminal=true)
                Endpoint.wait_terminal_release!(endpoint, ticket)
                event("terminal-consumed")
                break
            else
                error("unexpected test command")
            end
        end
        sleep(0.002)
    end
finally
    endpoint === nothing || close(endpoint)
    with_thread_loop_lock(loop) do _
        core === nothing || close(core)
        context === nothing || close(context)
    end
    close(loop)
end
end
main(ARGS...)
