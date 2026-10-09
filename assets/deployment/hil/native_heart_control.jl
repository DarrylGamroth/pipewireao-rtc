"""Load the shared native wrapper protocol in the installed HIL environment."""
module HILHeartControl

# The HIL environment and deployment environment have different scientific
# dependencies. Both execute the same deployed native protocol implementation.
# Sealed SDK owners live in hil/ beside julia/; package resources live
# in assets/deployment/hil/ inside the same named Julia package.
const SOURCE = let sdk = normpath(joinpath(@__DIR__, "..", "julia", "src"))
    isdir(sdk) ? sdk : normpath(joinpath(@__DIR__, "..", "..", "..", "src"))
end
include(joinpath(SOURCE, "native_control_codec.jl"))
include(joinpath(SOURCE, "native_control_client.jl"))
include(joinpath(SOURCE, "native_heart_codec.jl"))
include(joinpath(SOURCE, "native_heart_client.jl"))

const Client = NativeControlClient
const Heart = NativeHeartClient
const Codec = NativeHeartCodec

function with_controller(f, options)
    get(options, :transport, :scientific) === :heart || return f(options)
    check = get(options, :owner_check, () -> nothing)
    client = Heart.connect(options.remote, options.controller_node, options.controller_pid,
        options.controller_instance; deadline=Client.monotonic() + 14.0, check)
    try
        return f(merge(options, (; controller_control=client)))
    finally
        close(client)
    end
end

function reset!(options; timeout_seconds=14, deadline::Union{Nothing,Float64}=nothing)
    deadline = deadline === nothing ? Client.monotonic() + timeout_seconds : deadline
    check = get(options, :owner_check, () -> nothing)
    previous = Heart.status(options.controller_control; deadline, check)
    return Heart.reset!(options.controller_control, previous; deadline, check)
end

end # module HILHeartControl
