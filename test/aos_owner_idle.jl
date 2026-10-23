# Optional regression: run in an environment with RTC, AOS and HIL as direct
# dependencies. No daemon, GPU, FITS artifacts or scientific graph is needed.
using Test
using PipeWireAORTC
using AdaptiveOpticsSim
using AdaptiveOpticsSimPipeWireHIL

const IdleOwnerExtension = Base.get_extension(PipeWireAORTC, :PipeWireAORTCAOSExt)

function idle_owner_polls!(options, mailbox, state, payload, count)
    reset_owner! = () -> begin
        options.owner_check()
        state.sequence = payload[1]
        state.running = false
        return nothing
    end
    period = options.pacing_period_ns
    for _ in 1:count
        # The real transport specialization is large enough to keep this call
        # out of line. Enforce that boundary for the headless Nothing fixture;
        # otherwise inlining erases the unspecialized callback boxing defect.
        @noinline IdleOwnerExtension.consume_control!(options, mailbox, nothing,
            state, period, reset_owner!, nothing)
    end
    return nothing
end

function idle_owner_bytes(options, mailbox, state, payload, count)
    return @allocated idle_owner_polls!(options, mailbox, state, payload, count)
end

println("AOS_IDLE_OWNER julia=$(VERSION) rtc=$(pkgversion(PipeWireAORTC)) source=$(pathof(PipeWireAORTC))")

@testset "idle AOS owner retains its locally captured reset callback" begin
    options = (; pacing_period_ns=UInt64(2_000_000), owner_check=()->nothing)
    mailbox = PipeWireAORTC.NativeSourceControl.Mailbox(Int64(1))
    state = IdleOwnerExtension.OwnerState()
    payload = ntuple(index -> UInt64(index), 512)
    @test !mailbox.ready[]
    @test sizeof(payload) == 4096
    for count in (1, 100, 1000)
        idle_owner_polls!(options, mailbox, state, payload, count)
        idle_owner_bytes(options, mailbox, state, payload, count)
        bytes = idle_owner_bytes(options, mailbox, state, payload, count)
        println("AOS_IDLE_OWNER polls=$count bytes=$bytes")
        @test bytes == 0
    end
    @test state.sequence == 0
    @test !state.running
    @test !mailbox.ready[]
end
