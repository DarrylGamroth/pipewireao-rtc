using Test, LinearAlgebra, PipeWireAO, PipeWireAORTC
const Offsets = PipeWireAORTC.PhysicalOffsets
const domain = AcquisitionDomain(ntuple(i->UInt8(i),16))
const other_domain = AcquisitionDomain(ntuple(i->UInt8(i+1),16))
id(sequence; generation=1, domain=domain) = AcquisitionIdentity(domain,UInt64(generation),UInt64(sequence))
const P = Float32[1 0;0 1;1 1;1 -1]
const Q = Float32.(pinv(Float64.(P)))
calibration(modes;kwargs...) = Offsets.Calibration(;identity="calibration-sha256",schema="physical-opd",
    command_order="explicit-order-sha256",projection=P,inverse=Q,modes,
    command_limit_m=1e-6,coefficient_limit_m=5e-9,max_age_ns=100,silence_ns=1000,kwargs...)
function receiver()
    r = Offsets.Receiver((llowfs=calibration([1]),scc=calibration([2]));command_limit_m=1e-6)
    Offsets.observe_clock!(r,id(1),Int64(0),UInt64(10))
    Offsets.arm!(r,:llowfs,id(0))
    Offsets.arm!(r,:scc,id(0))
    return r
end
accept(r,branch,value,identity=id(1);pts=0,duration=10,now=100,
    schema="physical-opd",calibration_identity="calibration-sha256",command_order="explicit-order-sha256") =
    Offsets.accept!(r,branch,value,identity,Int64(pts),UInt64(duration);
        now_ns=UInt64(now),schema,calibration_identity,command_order)
total(r) = Offsets.total!(zeros(Float32,4),r)

@testset "physical offset authority and held absolute contributions" begin
    r = receiver()
    a,b = P*Float32[1e-9,0],P*Float32[0,2e-9]
    @test iszero(norm(total(r)))
    @test accept(r,:llowfs,a)
    @test accept(r,:scc,b)
    @test total(r) ≈ a+b
    Offsets.observe_clock!(r,id(2),Int64(10),UInt64(10))
    @test accept(r,:llowfs,2a,id(3);pts=10) # sequence gaps allowed for absolute latest values
    @test total(r) ≈ 2a+b
    @test !accept(r,:llowfs,2a,id(3);pts=10) # duplicate clears, never integrates twice
    @test total(r) == b
    @test !r.branches[:llowfs].armed
    @test !accept(r,:llowfs,a,id(4);pts=10)
    @test r.branches[:scc].armed
    Offsets.arm!(r,:llowfs,id(0))
    @test accept(r,:llowfs,a,id(5);pts=10)
    Offsets.disarm!(r;reason=:protective_recovery)
    @test total(r) == zeros(Float32,4)
    @test all(!c.armed for c in values(r.branches))
end

@testset "physical offset contract rejects uncalibrated or nonfinite values" begin
    a = P*Float32[1e-9,0]
    for bad in (Float32[1e-9,0,0,0],P*Float32[0,1e-9],P*Float32[6e-9,0],
            Float32[NaN,0,0,0],Float32[Inf,0,0,0],Float32[1e-9])
        r = receiver()
        @test !accept(r,:llowfs,bad)
        @test !r.branches[:llowfs].armed
        @test all(iszero,total(r))
    end
    for fields in ((schema="wrong",),(calibration_identity="wrong",),(command_order="wrong",))
        r=receiver()
        @test !accept(r,:llowfs,a;fields...)
        @test r.branches[:llowfs].reason == :contract
    end
    @test_throws ArgumentError calibration([1];inverse=zeros(Float32,2,4))
    @test_throws ArgumentError Offsets.Receiver((a=calibration([1]),b=calibration([1]));command_limit_m=1e-6)
    @test_throws ArgumentError Offsets.arm!(receiver(),:scc,id(1))
end

@testset "physical offset model time and monotonic silence are independent" begin
    a = P*Float32[1e-9,0]
    r=receiver()
    @test accept(r,:llowfs,a)
    Offsets.expire!(r,UInt64(1100))
    @test r.branches[:llowfs].present
    Offsets.expire!(r,UInt64(1101))
    @test !r.branches[:llowfs].armed
    @test r.branches[:llowfs].reason == :silence
    r=receiver()
    @test accept(r,:llowfs,a)
    Offsets.observe_clock!(r,id(2),Int64(110),UInt64(10))
    Offsets.expire!(r,UInt64(101))
    @test r.branches[:llowfs].reason == :model_age
    for identity in (id(2;generation=2),id(2;domain=other_domain))
        r=receiver()
        @test accept(r,:llowfs,a)
        @test !accept(r,:llowfs,a,identity)
        @test r.branches[:llowfs].reason == :source_cohort
    end
    r=receiver()
    @test accept(r,:llowfs,a)
    @test Offsets.observe_clock!(r,id(1;generation=2),Int64(0),UInt64(10))
    @test all(!c.armed for c in values(r.branches))
    @test !accept(r,:llowfs,a,id(1;generation=2))
    Offsets.arm!(r,:llowfs,id(0;generation=2))
    @test accept(r,:llowfs,a,id(1;generation=2))
    @test !Offsets.observe_clock!(r,id(1;generation=2),Int64(0),UInt64(10))
    @test all(iszero,total(r))
    for fields in ((pts=10,),(duration=0,))
        r=receiver()
        @test !accept(r,:llowfs,a;fields...)
    end
    @test_throws OverflowError Offsets.observe_clock!(receiver(),id(2),typemax(Int64),UInt64(1))
end

@testset "combined physical offset retains every branch coefficient limit" begin
    projection = Matrix{Float32}(I,2,2)
    branch(modes) = Offsets.Calibration(;identity="calibration-sha256",schema="physical-opd",
        command_order="explicit-order-sha256",projection,inverse=projection,modes,
        command_limit_m=1e-6,coefficient_limit_m=1e-9,max_age_ns=100,silence_ns=1000)
    r = Offsets.Receiver((llowfs=branch([1]),scc=branch([2]));command_limit_m=1e-6)
    Offsets.observe_clock!(r,id(1),Int64(0),UInt64(10))
    Offsets.arm!(r,:llowfs,id(0))
    Offsets.arm!(r,:scc,id(0))
    @test accept(r,:llowfs,Float32[1e-9,0])
    # The SCC leakage is inside its calibrated span/authority tolerance, but
    # adding it to LLOWFS already at its limit must not enlarge that limit.
    @test !accept(r,:scc,Float32[5e-15,1e-9])
    @test r.branches[:scc].reason == :total_coefficient_limit
    @test Offsets.total!(zeros(Float32,2),r) == Float32[1e-9,0]
end

@testset "withdrawing cancelling leakage preserves combined limits" begin
    projection = Matrix{Float32}(I,3,3)
    branch(i) = Offsets.Calibration(;identity="calibration-sha256",schema="physical-opd",
        command_order="explicit-order-sha256",projection,inverse=projection,modes=[i],
        command_limit_m=1e-6,coefficient_limit_m=1e-9,max_age_ns=100,silence_ns=1000)
    r = Offsets.Receiver((a=branch(1),b=branch(2),c=branch(3));command_limit_m=1e-6)
    Offsets.observe_clock!(r,id(1),Int64(0),UInt64(10))
    for name in (:a,:b,:c)
        Offsets.arm!(r,name,id(0))
    end
    @test accept(r,:c,Float32[-5e-15,0,1e-9])
    @test accept(r,:a,Float32[1e-9,0,0])
    @test accept(r,:b,Float32[5e-15,1e-9,0])
    @test maximum(abs,Offsets.total!(zeros(Float32,3),r))<=1f-9
    Offsets.disarm!(r,:c;reason=:silence)
    @test all(iszero,Offsets.total!(zeros(Float32,3),r))
    @test all(!c.armed for c in values(r.branches))
    @test r.branches[:a].reason == :total_coefficient_limit
end

@testset "withdrawing a cancelling branch preserves total command limit" begin
    projection = Float32[1 1 1;0 1 0;0 0 1]
    inverse = Float32[1 -1 -1;0 1 0;0 0 1]
    branch(i) = Offsets.Calibration(;identity="calibration-sha256",schema="physical-opd",
        command_order="explicit-order-sha256",projection,inverse,modes=[i],
        command_limit_m=1e-6,coefficient_limit_m=1e-6,max_age_ns=100,silence_ns=1000)
    r = Offsets.Receiver((a=branch(1),b=branch(2),c=branch(3));command_limit_m=1e-6)
    Offsets.observe_clock!(r,id(1),Int64(0),UInt64(10))
    for name in (:a,:b,:c)
        Offsets.arm!(r,name,id(0))
    end
    @test accept(r,:c,projection*Float32[0,0,-6e-7])
    @test accept(r,:a,projection*Float32[6e-7,0,0])
    @test accept(r,:b,projection*Float32[0,6e-7,0])
    Offsets.disarm!(r,:c;reason=:transport)
    @test all(iszero,Offsets.total!(zeros(Float32,3),r))
    @test r.branches[:a].reason == :total_limit
end
