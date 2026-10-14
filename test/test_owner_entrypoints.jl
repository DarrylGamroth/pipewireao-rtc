module OwnerEntrypointTests
using Test, PipeWireAORTC
const Bootstrap = PipeWireAORTC.NativeOwnerBootstrapRuntime
const Parameters = PipeWireAORTC.NativeParameterSource

const OPTIONS = (; config="/tmp/parameters.conf", remote="/tmp/rtc-core",
    bootstrap_node="parameters.bootstrap", bootstrap_instance="7",
    control_node="parameters.control", control_instance="9")
arguments(options=OPTIONS) = reduce(vcat,
    (["--" * replace(string(key), "_" => "-"), value] for (key, value) in pairs(options)))

@testset "parameter owner arguments preserve endpoint contract" begin
    admitted = Parameters._owner_options(arguments())
    @test Dict(pairs(admitted)) == Dict(pairs(merge(OPTIONS,
        (; bootstrap_instance=Int64(7), control_instance=Int64(9)))))
    @test Parameters._owner_options(["--" * replace(string(key), "_" => "-") * "=" * value
        for (key, value) in pairs(OPTIONS)]) == admitted
    for key in keys(OPTIONS)
        missing = (; (name => value for (name, value) in pairs(OPTIONS) if name != key)...)
        @test_throws ArgumentError Parameters._owner_options(arguments(missing))
    end
    for extra in (["--unknown", "value"], ["--config", "/tmp/other.conf"], ["positional"], ["--control-node"])
        @test_throws ArgumentError Parameters._owner_options(vcat(arguments(), extra))
    end
    for changed in ((; config="relative.conf"), (; remote="relative-core"),
                    (; bootstrap_node="invalid/name"), (; control_node=""),
                    (; control_node=repeat("n",129)), (; control_node=OPTIONS.bootstrap_node),
                    (; bootstrap_instance="0"), (; bootstrap_instance="-1"),
                    (; bootstrap_instance="9223372036854775808"), (; control_instance="1.0"))
        @test_throws ArgumentError Parameters._owner_options(arguments(merge(OPTIONS, changed)))
    end
    maximal = Parameters._owner_options(arguments(merge(OPTIONS,
        (; bootstrap_instance=string(typemax(Int64)), control_instance=string(typemax(Int64))))))
    @test maximal.bootstrap_instance == maximal.control_instance == typemax(Int64)
    @test_throws ArgumentError Parameters.main(["--unknown", "value"])
end

mutable struct OwnerRuntime
    events::Vector{Symbol}
    cancelled::Bool
    preparation_failure::Union{Nothing,Exception}
    finish_failure::Union{Nothing,Exception}
    close_failure::Union{Nothing,Exception}
    fault::Union{Nothing,Exception}
end
OwnerRuntime(; cancelled=false, preparation_failure=nothing, finish_failure=nothing,
    close_failure=nothing) = OwnerRuntime(Symbol[], cancelled, preparation_failure,
        finish_failure, close_failure, nothing)
Bootstrap.cancelled(runtime::OwnerRuntime) = runtime.cancelled
function Bootstrap.preparation_check!(runtime::OwnerRuntime)
    push!(runtime.events, :check)
    runtime.preparation_failure === nothing || throw(runtime.preparation_failure)
    runtime.cancelled && throw(InterruptException())
    return nothing
end
function Bootstrap.fault!(runtime::OwnerRuntime, error::Exception)
    push!(runtime.events, :fault)
    runtime.fault = error
    return nothing
end
function Bootstrap.finish!(runtime::OwnerRuntime)
    push!(runtime.events, :finish)
    runtime.finish_failure === nothing || throw(runtime.finish_failure)
    return nothing
end
function Base.close(runtime::OwnerRuntime)
    push!(runtime.events, :close)
    runtime.close_failure === nothing || throw(runtime.close_failure)
    return nothing
end
caught(f) = try f(); nothing catch error; error end

@testset "cold owner options and deterministic cleanup" begin
    runtime = OwnerRuntime()
    options = merge(OPTIONS, (; bootstrap_instance=Int64(7)))
    result = Bootstrap._with_owner(options, runtime) do admitted
        push!(runtime.events, :cold)
        @test admitted.bootstrap_runtime === runtime
        @test all(getproperty(admitted, name) == value for (name, value) in pairs(options))
        admitted.owner_check()
        return :ignored_owner_result
    end
    @test result === nothing
    @test runtime.events == [:cold, :check, :finish, :close]
    @test runtime.fault === nothing

    primary, finishing, closing = ErrorException.(["preparation failed", "finish failed", "close failed"])
    runtime = OwnerRuntime(; finish_failure=finishing, close_failure=closing)
    failure = caught() do
        Bootstrap._with_owner(options, runtime) do admitted
            push!(runtime.events, :cold)
            throw(primary)
        end
    end
    @test failure isa CompositeException
    @test failure.exceptions == [primary, finishing, closing]
    @test runtime.fault === primary
    @test runtime.events == [:cold, :fault, :finish, :close]

    runtime = OwnerRuntime(; preparation_failure=primary)
    failure = caught(() -> Bootstrap._with_owner(admitted -> admitted.owner_check(), options, runtime))
    @test failure === primary
    @test runtime.fault === primary
    @test runtime.events == [:check, :fault, :finish, :close]

    runtime = OwnerRuntime(; finish_failure=finishing, close_failure=closing)
    failure = caught(() -> Bootstrap._with_owner(_ -> nothing, options, runtime))
    @test failure isa CompositeException
    @test failure.exceptions == [finishing, closing]
    @test runtime.events == [:finish, :close]
    @test runtime.fault === nothing
end

@testset "cooperative cancellation preserves cleanup failures" begin
    options = merge(OPTIONS, (; bootstrap_instance=Int64(7)))
    runtime = OwnerRuntime(; cancelled=true)
    @test Bootstrap._with_owner(admitted -> admitted.owner_check(), options, runtime) === nothing
    @test runtime.fault === nothing
    @test runtime.events == [:check, :finish, :close]

    interrupt = InterruptException()
    runtime = OwnerRuntime()
    failure = caught(() -> Bootstrap._with_owner(_ -> throw(interrupt), options, runtime))
    @test failure === interrupt
    @test runtime.fault === interrupt
    @test runtime.events == [:fault, :finish, :close]

    closing = ErrorException("close failed after cancellation")
    runtime = OwnerRuntime(; cancelled=true, close_failure=closing)
    failure = caught(() -> Bootstrap._with_owner(admitted -> admitted.owner_check(), options, runtime))
    @test failure === closing
    @test runtime.fault === nothing
    @test runtime.events == [:check, :finish, :close]
end
end
