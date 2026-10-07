using Test, PipeWireAODeployment
const D = PipeWireAODeployment.Deployment

struct UnconfirmedIngress
    runtime::Nothing
    source_owner::Dict{String,String}
    processes::Vector{Tuple{String,Base.Process}}
    source_failed::Bool
    native_shutdown::Bool
    source_state::Nothing
    runner_client::Union{Nothing,Symbol}
    attempts::Vector{String}
    native_attempts::Vector{String}
end

function D.native_control(deployment::UnconfirmedIngress, argv; kwargs...)
    push!(deployment.native_attempts, only(argv))
    error("injected unknown native runner outcome")
end

function D._owned_wait(deployment::UnconfirmedIngress, process::Base.Process, ::Real)
    role = only(role for (role, child) in deployment.processes if child === process)
    push!(deployment.attempts, role)
    error("injected uncertain $role revocation")
end

@testset "Unconfirmed ingress preserves consumers" begin
    children = Tuple{String,Base.Process}[]
    try
        for role in ("core", "simulator", "rtc")
            push!(children, (role, run(`sleep 30`; wait=false)))
        end
        for (source, runner_client) in ((true,nothing), (false,nothing), (false,:unknown))
            deployment = UnconfirmedIngress(nothing, Dict("role"=>"simulator"),
                children, true, false, nothing, runner_client, String[], String[])
            errors = Any[]
            D._stop_processes(deployment, errors; source)
            @test !("rtc" in deployment.attempts)
            @test deployment.attempts == (source ? ["core", "simulator"] : ["core"])
            @test any(error->occursin("preserving consumers", sprint(showerror,error)), errors)
            @test !("quit" in deployment.native_attempts)
        end
    finally
        for (_, process) in children
            process_running(process) && kill(process)
            wait(process)
        end
    end
end
