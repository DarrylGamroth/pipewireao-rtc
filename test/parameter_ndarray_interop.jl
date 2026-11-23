# Opt-in receiver for the Rust producer integration. The rendezvous carries
# fixture identities and a result digest. All ndarray bytes travel in PipeWire.
using PipeWireAORTC, PipeWireAO, Clocks, SHA
const RTC = PipeWireAORTC
const Parameter = RTC.ParameterSource
const Runner = RTC.RunnerCodec
const Codec = RTC.ControlCodec
const Endpoint = RTC.ControlEndpoint
const Bootstrap = RTC.OwnerBootstrapCodec
const C = RTC.Common
include("control_private_core.jl")

struct InteropTransfer{T}
    transport::T
end
function Parameter.check_parameter_ticket(::InteropTransfer, _, active)
    Int64(time_ns()) < active.deadline || error("private interop transfer expired")
    return nothing
end

case = abspath(only(ARGS))
isdir(case) || error("create a private rendezvous directory before starting the fixture")
modules = "{ name = libpipewire-module-spa-node-factory }"
with_control_private_core(; modules, temporary_prefix = "rtc-parameter-interop-") do socket, directory, _
    chmod(dirname(socket), 0o700)
    transport = Endpoint.Transport(Bootstrap.PROFILE, socket, "parameter-interop-bootstrap", Int64(17), Bootstrap.Preparing)
    endpoint = wake = driver = marker = nothing
    try
        wake = Base.Event(true)
        with_thread_loop_lock(transport.loop) do _
            driver = create_object(transport.core, "spa-node-factory", Node; properties = Dict(
                "factory.name" => "support.node.driver", "node.name" => "test-parameter-driver",
                "priority.driver" => "200000", "node.group" => "test-parameter-driver",
            ))
            name = "pipewireao.rtc.parameters.private-interop"
            marker = Filter(transport.core, name; properties = Dict(
                "node.name" => name,
                "pipewireao.rtc-control.protocol" => RTC.ControlClient.PROTOCOL,
                "pipewireao.rtc-control.profile" => "pipewireao.rtc.parameter-source/1",
                "pipewireao.rtc-control.instance" => "42",
                "pipewireao.rtc-control.owner-pid" => string(getpid()),
            ))
            connect!(marker; flags=FILTER_INACTIVE)
        end
        endpoint = (; loop=transport.loop, registry=something(transport.endpoint.registry), instance=Int64(42))
        source_identity = Ref{Union{Nothing,Tuple{UInt32,UInt64}}}(nothing)
        wait_proof(10, "parameter owner registry identity") do
            with_thread_loop_lock(transport.loop) do _
                node = PipeWireAO.find_global(endpoint.registry, node_id(marker))
                node === nothing && return false
                serial = tryparse(UInt64, get(node.properties, "object.serial", ""))
                serial === nothing && return false
                source_identity[] = (node.id, serial)
                return true
            end
        end
        owner_id, owner_serial = something(source_identity[])
        schema = "pipewireao/private-parameter-transport/1"
        C.write_json(joinpath(case, "ready.json"), Dict(
            "remote" => socket, "shape" => [8192], "schema" => schema, "layout" => "row-major",
            "owner_id" => owner_id, "owner_serial" => string(owner_serial),
        ); atomic = true)
        input = joinpath(case, "producer.json")
        wait_proof(() -> isfile(input), 300, "Rust parameter producer rendezvous")
        identify = C.read_json(input)
        parse_serial(value) = parse(UInt64, string(value))
        controller = Codec.ControllerIdentity(
            UInt32(identify["controller_id"]), parse_serial(identify["controller_serial"]), Int64(identify["controller_instance"]),
        )
        output = Runner.ParameterStream(
            UInt32(identify["output_node_id"]), parse_serial(identify["output_node_serial"]),
            UInt32(identify["output_port_id"]), parse_serial(identify["output_port_serial"]),
        )
        declaration = joinpath(directory, "parameter-source.json")
        C.write_json(declaration, Dict("version" => 1, "sources" => [Dict(
            "node_name" => "test-declared-parameter", "graph" => "graph", "inlet" => "reference",
            "element_type" => "F32_LE", "shape" => [8192], "layout" => "row-major", "schema" => schema,
        )]))
        source = only(Parameter.read_declarations(declaration, wake))
        active = (; header = (; token = Int64(1)), deadline = Int64(time_ns()) + 20_000_000_000)
        Parameter.receive_parameter!(InteropTransfer(transport), endpoint, active, source, controller, output)
        C.write_json(joinpath(case, "received.json"), Dict("bytes" => length(source.bytes), "sha256" => bytes2hex(sha256(source.bytes))); atomic=true)
    finally
        with_thread_loop_lock(transport.loop) do _
            marker === nothing || close(marker)
            driver === nothing || close(driver)
        end
        close(transport)
    end
end
