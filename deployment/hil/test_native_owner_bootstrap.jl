module NativeOwnerBootstrapSDKTests
using Test
include("owner_protocol.jl")
include("native_owner_bootstrap.jl")
const P = HILOwnerProtocol
const SDK = HILNativeOwnerBootstrap
@testset "native ordinary bootstrap flags" begin
    mktempdir() do root
        arguments = ["--profile","classic","--graph",joinpath(root,"graph.toml"),
            "--rate","10","--exposure-ns","100000000","--remote",joinpath(root,"core"),
            "--control-node","source.science","--bootstrap-node","source.bootstrap",
            "--bootstrap-instance",string(typemax(Int64)),"--output",joinpath(root,"report.json")]
        options = P.parse_options(arguments; native_bootstrap=true)
        @test options.bootstrap_node == "source.bootstrap"
        @test options.control_node == "source.science"
        @test options.bootstrap_instance == typemax(Int64)
        @test options.prepared_event === nothing && options.connect_request === nothing &&
            options.connect_reply === nothing && options.quit_request === nothing
        @test options.control_request === nothing && options.control_reply === nothing
        @test_throws ArgumentError P.parse_options(arguments)
        @test_throws ArgumentError P.parse_options(arguments; native_lifecycle=true,native_bootstrap=true)
        for option in P.LEGACY_CONTROL_OPTIONS
            @test_throws ArgumentError P.parse_options([arguments;"--"*option;"legacy"];native_bootstrap=true)
        end
        for (option, bad) in (("--remote","relative"),("--bootstrap-node","source.science"),("--bootstrap-instance","0"))
            values = copy(arguments); values[findfirst(==(option),values)+1] = bad
            @test_throws ArgumentError P.parse_options(values; native_bootstrap=true)
        end
        graph = ["--graph","graph.conf","--session-run-control","--parameter","M","Float32","2,2","matrix.bin",
            "--remote",joinpath(root,"core"),"--bootstrap-node","jfg.bootstrap","--bootstrap-instance","9"]
        binding, retained = SDK.graph_arguments(graph)
        @test binding.bootstrap_node == "jfg.bootstrap" && binding.bootstrap_instance == 9
        @test retained == graph[1:end-4]
        for flag in ("--prepared-event","--connect-request","--connect-reply","--quit-request","--control-request","--control-reply","--check")
            @test_throws ArgumentError SDK.graph_arguments([graph;flag;"x"])
            @test_throws ArgumentError SDK.graph_arguments([graph;flag*"=x"])
        end
        @test_throws ArgumentError SDK.graph_arguments([graph;"--bootstrap-instance";"10"])
    end
end
end
