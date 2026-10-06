"""Typed client to the public deployment supervisor on its exact private core."""
module NativeSupervisorClient
import ..NativeControlClient
import ..NativeSupervisorCodec
const PROFILE = NativeSupervisorCodec.PROFILE
const Client = NativeControlClient.Client
const UnknownOutcome = NativeControlClient.UnknownOutcome
connect(args...; kwargs...) = NativeControlClient.connect(PROFILE, args...; kwargs...)
request!(args...; kwargs...) = NativeControlClient.request!(args...; kwargs...)
export Client, UnknownOutcome, connect, request!
end
