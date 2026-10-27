using Test

# Standalone deterministic selector: no optional science, core or owner process.
include(joinpath(@__DIR__, "..", "src", "owners", "correction_supervision.jl"))
const CS = CorrectionSupervision
const INSTANCE = Int64(701)

configuration(; kwargs...) = CS.Configuration(; trip_fraction=0.6,
    clear_fraction=0.2, persistence_ns=100, max_gap_ns=60, kwargs...)
supervisor(; kwargs...) = CS.Supervisor(configuration(; kwargs...), INSTANCE)
sample!(sm, sequence, time, fraction; instance=INSTANCE, now=time) =
    CS.observe!(sm, instance, sequence, time, fraction; now_ns=now)

function trip!(sm)
    @test sample!(sm, 1, 1000, 0.8).action === :none
    @test sample!(sm, 2, 1050, 0.8).action === :none
    result = sample!(sm, 3, 1100, 0.8)
    @test result.tripped
    return result
end

@testset "Clipping supervision requires explicit valid numeric configuration" begin
    for value in (NaN, Inf, -0.1, 1.1, true, "0.6")
        @test_throws ArgumentError CS.Configuration(; trip_fraction=value,
            clear_fraction=0.2, persistence_ns=100, max_gap_ns=60)
        @test_throws ArgumentError CS.Configuration(; trip_fraction=0.6,
            clear_fraction=value, persistence_ns=100, max_gap_ns=60)
    end
    for clear in (0.6, 0.8)
        @test_throws ArgumentError CS.Configuration(; trip_fraction=0.6,
            clear_fraction=clear, persistence_ns=100, max_gap_ns=60)
    end
    for value in (false, 0, -1, 1.5, UInt128(typemax(Int64)) + 1)
        @test_throws ArgumentError CS.Configuration(; trip_fraction=0.6,
            clear_fraction=0.2, persistence_ns=value, max_gap_ns=60)
        @test_throws ArgumentError CS.Configuration(; trip_fraction=0.6,
            clear_fraction=0.2, persistence_ns=100, max_gap_ns=value)
    end
    for action in (:resume, :close, :reset, :unknown)
        @test_throws ArgumentError configuration(; action)
    end
    for instance in (false, 0, -1, "701", UInt128(typemax(Int64)) + 1)
        @test_throws ArgumentError CS.Supervisor(configuration(), instance)
    end
    boundary = CS.Configuration(; trip_fraction=1, clear_fraction=0,
        persistence_ns=typemax(Int64), max_gap_ns=typemax(Int64))
    @test boundary.enabled && boundary.action === :monitor_only
    @test boundary.persistence_ns == UInt64(typemax(Int64))
end

@testset "Persistence, exact thresholds and hysteresis" begin
    sm = supervisor()
    @test CS.state(sm) === :Unknown
    @test CS.reason(sm) === nothing
    @test sample!(sm, 0, 0, 0.59).action === :none
    @test CS.state(sm) === :Clear
    @test sample!(sm, 1, 10, 0.6).action === :none
    @test CS.state(sm) === :Pending
    @test sample!(sm, 2, 60, 0.3).action === :none
    @test sm.pending_since_ns == 10 # Hysteresis band retains the high onset.
    @test sample!(sm, 3, 109, 0.4).action === :none
    @test !sm.tripped
    result = sample!(sm, 4, 110, 0.4)
    @test result isa CS.Recommendation
    @test result.action === :monitor_only
    @test result.reason === :persistent_clipping && result.tripped
    @test CS.state(sm) === :Tripped
    @test CS.reason(sm) === :persistent_clipping

    sm = supervisor()
    sample!(sm, 1, 1000, 1.0)
    @test sample!(sm, 2, 1050, 0.2).action === :none
    @test CS.state(sm) === :Clear
    @test sample!(sm, 3, 1100, 0.4).action === :none
    @test CS.state(sm) === :Clear # Band alone cannot start persistence.
    @test sample!(sm, 4, 1150, 0.7).action === :none
    @test sm.pending_since_ns == 1150
end

@testset "Gaps and sequence loss restart persistence" begin
    for (sequence, time, now) in ((4, 1050, 1050), (2, 1061, 1061), (2, 1050, 1061))
        sm = supervisor()
        sample!(sm, 1, 1000, 1.0)
        @test sample!(sm, sequence, time, 1.0; now).action === :none
        @test sm.pending_since_ns == time
        @test sample!(sm, sequence + 1, time + 50, 1.0; now=now + 50).action === :none
        @test sample!(sm, sequence + 2, time + 100, 1.0; now=now + 100).tripped
    end
    # The permitted maximum gap is inclusive and still requires multiple samples.
    sm = supervisor()
    sample!(sm, 1, 1000, 1.0)
    @test sample!(sm, 2, 1060, 1.0).action === :none
    @test sample!(sm, 3, 1100, 1.0).tripped
end

@testset "Invalid feedback is unknown, never zero or evidence of persistence" begin
    observations = (
        (INSTANCE + 1, 2, 1040, 0.0, 1040, :wrong_owner),
        (INSTANCE, 2, 1040, nothing, 1040, :missing_feedback),
        (INSTANCE, 2, 1040, NaN, 1040, :malformed_feedback),
        (INSTANCE, 2, 1040, Inf, 1040, :malformed_feedback),
        (INSTANCE, 2, 1040, -0.1, 1040, :malformed_feedback),
        (INSTANCE, 2, 1040, true, 1040, :malformed_feedback),
        (INSTANCE, 1, 1000, 0.0, 1040, :stale_sample),
        (INSTANCE, 2, 1000, 0.0, 1040, :stale_sample),
        (INSTANCE, 2, 1040, 0.0, 1039, :future_sample),
        (INSTANCE, 2, 1040, 0.0, 1101, :stale_sample),
        (INSTANCE, -1, 1040, 0.0, 1040, :malformed_sample),
        (INSTANCE, 2, "1040", 0.0, 1040, :malformed_sample),
        (INSTANCE, 2, 1040, 0.0, false, :malformed_sample),
    )
    for (instance, sequence, time, fraction, now, reason) in observations
        sm = supervisor()
        sample!(sm, 1, 1000, 1.0)
        result = sample!(sm, sequence, time, fraction; instance, now)
        @test result.action === :none && !result.tripped && result.reason === reason
        @test CS.state(sm) === :Unknown
        @test CS.reason(sm) === nothing
        @test sample!(sm, 5, 1200, 1.0).action === :none
        @test sm.pending_since_ns == 1200
        @test sample!(sm, 6, 1250, 1.0).action === :none
        @test sample!(sm, 7, 1300, 1.0).tripped
    end
    sm = supervisor()
    sample!(sm, 1, 1000, 1.0)
    sample!(sm, 2, 1040, nothing)
    @test sm.last_sequence == 2
    @test sample!(sm, 2, 1040, 1.0).reason === :stale_sample
    @test CS.state(sm) === :Unknown
    sample!(sm, 3, 1080, 1.0; instance=INSTANCE + 1)
    @test sm.last_sequence == 2 && sm.last_sample_ns == 1040
end

@testset "Recommendations latch once and never request closure" begin
    for action in (:monitor_only, :hold, :restore_reference)
        sm = supervisor(; action)
        @test trip!(sm).action === action
        for (sequence, time, fraction, instance, now) in (
                (3, 1100, 1.0, INSTANCE, 1100),
                (4, 1150, 0.0, INSTANCE, 1150),
                (5, 1200, nothing, INSTANCE, 1200),
                (6, 1250, NaN, INSTANCE, 1250),
                (7, 1300, 0.0, INSTANCE + 1, 1300),
                (7, 1300, 0.0, INSTANCE, 1400))
            result = sample!(sm, sequence, time, fraction; instance, now)
            @test result.action === :none && result.tripped
            @test CS.state(sm) === :Tripped
            @test CS.reason(sm) === :persistent_clipping
        end
    end
    disabled = supervisor(; enabled=false, action=:restore_reference)
    for i in 1:10
        @test sample!(disabled, i, i * 100, 1.0).action === :none
    end
    @test CS.state(disabled) === :Disabled && !disabled.has_sample
end

@testset "Explicit rearm requires exact recent clear evidence and preserves fencing" begin
    sm = supervisor(; action=:restore_reference)
    trip!(sm)
    @test !CS.rearm!(sm, INSTANCE, 3; now_ns=1100)
    @test sample!(sm, 4, 1150, 0.0).action === :none
    @test CS.state(sm) === :Tripped # Clear data never automatically rearms.
    @test !CS.rearm!(sm, INSTANCE + 1, 4; now_ns=1150)
    @test !CS.rearm!(sm, INSTANCE, 3; now_ns=1150)
    @test !CS.rearm!(sm, INSTANCE, 4; now_ns=1149)
    @test !CS.rearm!(sm, INSTANCE, 4; now_ns=1211)
    @test !CS.rearm!(sm, INSTANCE, true; now_ns=1150)
    @test sample!(sm, 5, 1200, nothing).action === :none
    @test !CS.rearm!(sm, INSTANCE, 5; now_ns=1200)
    @test sample!(sm, 6, 1250, 0.2).action === :none
    @test CS.rearm!(sm, INSTANCE, 6; now_ns=1250)
    @test CS.state(sm) === :Clear && CS.reason(sm) === nothing
    @test sm.last_sequence == 6 && sm.last_sample_ns == sm.last_observed_ns == 1250
    @test !CS.rearm!(sm, INSTANCE, 6; now_ns=1250)
    @test sample!(sm, 6, 1250, 1.0).reason === :stale_sample
    @test !sm.pending && !sm.tripped
    @test sample!(sm, 7, 1300, 1.0).action === :none
    @test sample!(sm, 8, 1350, 1.0).action === :none
    @test sample!(sm, 9, 1400, 1.0).action === :restore_reference

    replacement = CS.Supervisor(configuration(), INSTANCE + 1)
    @test CS.state(replacement) === :Unknown && !replacement.tripped
    @test sample!(replacement, 1, 0, 1.0).reason === :wrong_owner
    @test sample!(replacement, 1, 0, 1.0; instance=INSTANCE + 1).action === :none
end
