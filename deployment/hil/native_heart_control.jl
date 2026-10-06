"""Load the shared native wrapper protocol in the installed HIL environment."""
module HILHeartControl

# The HIL environment and deployment environment have different scientific
# dependencies. Both execute the same deployed native protocol implementation.
const SOURCE = normpath(joinpath(@__DIR__, "..", "julia", "src"))
include(joinpath(SOURCE, "native_control_codec.jl"))
include(joinpath(SOURCE, "native_control_client.jl"))
include(joinpath(SOURCE, "native_heart_codec.jl"))
include(joinpath(SOURCE, "native_heart_client.jl"))

const Client = NativeControlClient
const Heart = NativeHeartClient
const Codec = NativeHeartCodec

function with_controller(f, options)
    get(options, :transport, :scientific) === :heart || return f(options)
    check = () -> (options.quit_request !== nothing && isfile(options.quit_request) &&
        error("HEART controller admission cancelled"))
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
    check = () -> (options.quit_request !== nothing && isfile(options.quit_request) &&
        error("shutdown requested while resetting HEART"))
    previous = Heart.status(options.controller_control; deadline, check)
    return Heart.reset!(options.controller_control, previous; deadline, check)
end

end # module HILHeartControl
