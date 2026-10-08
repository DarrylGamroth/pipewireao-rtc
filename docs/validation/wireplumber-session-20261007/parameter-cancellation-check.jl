# No-service check of cancellation before parameter stream buffer access.
# Run from the repository root with:
#   julia --startup-file=no --project=deployment/julia \
#     docs/validation/wireplumber-session-20261007/parameter-cancellation-check.jl
# The stream argument is deliberately `nothing`. Reaching dequeue would fail
# the assertions rather than appearing to prove a real stream publication.
using PipeWireAODeployment, PipeWireAO

const Parameter = PipeWireAODeployment.NativeParameterSource
const Bootstrap = PipeWireAODeployment.NativeOwnerBootstrapRuntime

runtime = Bootstrap.Runtime((endpoint=nothing,), ReentrantLock(), false, nothing,
    false, false, nothing, false, nothing, nothing,
    Base.Threads.Atomic{Bool}(true), Base.Threads.Atomic{Bool}(false), nothing)
format = NdArrayFormat(NdArray.F32_LE, UInt32[1]; layout=NdArray.ROW_MAJOR)

function pending(initial, runtime, format)
    Parameter.Source("parameter", "graph", "inlet", UInt32[1], "", format,
        zeros(UInt8, 4), initial, StreamBuffer(), Int32(4), Parameter.PENDING,
        initial, nothing, runtime, nothing, Int64(1), nothing, nothing,
        (Pod(Int32(0)), Pod(Int32(0))), Base.Event(true))
end

requested = pending(false, runtime, format)
Parameter.Process(requested)(nothing)
@assert requested.phase == Parameter.IDLE
@assert requested.revoked isa InterruptException
@assert requested.publication === nothing && requested.failure === nothing
println("cancelled requested publication revoked before buffer access")

initial = pending(true, runtime, format)
Parameter.Process(initial)(nothing)
@assert initial.phase == Parameter.IDLE
@assert initial.failure isa InterruptException
@assert initial.publication === nothing && initial.revoked === nothing
println("cancelled initial publication revoked before buffer access")
