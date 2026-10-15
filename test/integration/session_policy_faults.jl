#!/usr/bin/env julia
# Opt-in control-flow checks against the selected production Lua policy.
# Native transport, registry admission and systemd behavior need live tests.
using Test
using Libdl
using SHA

const POLICY = abspath(isempty(ARGS) ?
    "/opt/pipewireao/share/wireplumber/scripts/ao/session.lua" : only(ARGS))
isfile(POLICY) || error("production WirePlumber session policy was not found: $POLICY")
const LUA = Libdl.find_library(["lua5.4", "liblua5.4.so.0"])
isempty(LUA) && error("the optional policy test requires the Lua 5.4 shared library")
const SCRIPT = joinpath(@__DIR__, "..", "data", "session_faults", "policy_faults.lua")
println("RTC_SESSION_POLICY source=$POLICY sha256=$(bytes2hex(sha256(read(POLICY)))) lua=$LUA")

function policy_case(name)
    state = ccall((:luaL_newstate, LUA), Ptr{Cvoid}, ())
    state == C_NULL && error("Lua state allocation failed")
    try
        ccall((:luaL_openlibs, LUA), Cvoid, (Ptr{Cvoid},), state)
        for (key, value) in (("POLICY_PATH", POLICY), ("CASE", name))
            ccall((:lua_pushstring, LUA), Cstring, (Ptr{Cvoid}, Cstring), state, value)
            ccall((:lua_setglobal, LUA), Cvoid, (Ptr{Cvoid}, Cstring), state, key)
        end
        loaded = ccall((:luaL_loadfilex, LUA), Cint,
            (Ptr{Cvoid}, Cstring, Ptr{Cvoid}), state, SCRIPT, C_NULL)
        status = loaded == 0 ? ccall((:lua_pcallk, LUA), Cint,
            (Ptr{Cvoid}, Cint, Cint, Cint, Int, Ptr{Cvoid}), state, 0, 0, 0, 0, C_NULL) : loaded
        if status != 0
            message = ccall((:lua_tolstring, LUA), Cstring,
                (Ptr{Cvoid}, Cint, Ptr{Csize_t}), state, -1, C_NULL)
            error(message == C_NULL ? "Lua policy test failed" : unsafe_string(message))
        end
        return nothing
    finally
        ccall((:lua_close, LUA), Cvoid, (Ptr{Cvoid},), state)
    end
end

@testset "Production RTC fault ordering" begin
    for name in ("source_first", "first_fault", "hold_unknown", "graph_hold_failed",
                 "withdraw_failed", "before_source_capture", "no_automatic_readmission")
        @testset "$name" begin
            @test isnothing(policy_case(name))
        end
    end
end
