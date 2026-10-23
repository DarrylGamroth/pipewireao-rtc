using Test
using TOML
using JSON
using PipeWireAORTC

@testset "Default plant loader enforces active application dependency identity" begin
    mktempdir() do directory
        active = joinpath(directory, "application")
        fallback = joinpath(directory, "global")
        package = joinpath(fallback, "DeclaredOwnerPlant")
        marker = joinpath(directory, "initialized")
        mkpath(active)
        mkpath(joinpath(package, "src"))
        plant_uuid = "4a9c2871-2a36-4b7c-bfb6-ff32510ae59c"
        wrong_uuid = "6dbb376d-6069-4de6-aa0f-d9c731f57411"
        write(joinpath(package, "Project.toml"), """
            name = "DeclaredOwnerPlant"
            uuid = "$plant_uuid"
            version = "0.1.0"
            """)
        write(joinpath(package, "src", "DeclaredOwnerPlant.jl"), """
            module DeclaredOwnerPlant
            __init__() = write($(repr(marker)), "initialized")
            end
            """)
        project_path = joinpath(active, "Project.toml")
        write(project_path, "[deps]\nPipeWireAORTC = \"a3e2c7da-f73f-4284-8482-36ac422b34e6\"\n")
        config = joinpath(directory, "owner.conf")
        document = Dict(
            "version" => 2,
            "plant" => Dict("package" => "DeclaredOwnerPlant", "settings" => Dict()),
            "command_input" => "command", "frame_output" => "frame",
            "command_count" => 3, "frame_shape" => [2, 3],
            "rate" => 500, "exposure_ns" => 1_896_000, "pacing_rate_hz" => 10,
            "backend" => "cpu", "device" => 0, "frame_encoding" => "uint16",
            "frame_schema" => "test.detector/1", "command_schema" => "test.command/1",
            "command_scale" => 1.0)
        write(config, JSON.json(document))
        args = ["--config", config, "--remote", "/tmp/aos-loader-identity",
            "--control-node", "simulator-wfs", "--bootstrap-node", "rtc.bootstrap.aos",
            "--bootstrap-instance", "7"]
        events = Symbol[]
        with_owner = function (f, options)
            push!(events, :preparing)
            f(merge(options, (; owner_check=() -> push!(events, :check))))
        end
        run = options -> begin
            @test Base.PkgId(options.plant_module) == Base.PkgId(Base.UUID(plant_uuid), "DeclaredOwnerPlant")
            push!(events, :run)
        end
        invoke = () -> PipeWireAORTC.AOSOwner._main(args; with_owner,
            load_science=() -> push!(events, :science), run)
        prior_project = Base.ACTIVE_PROJECT[]
        prior_path = copy(LOAD_PATH)
        try
            Base.ACTIVE_PROJECT[] = project_path
            empty!(LOAD_PATH)
            append!(LOAD_PATH, [active, fallback, "@stdlib"])
            @test_throws ArgumentError invoke()
            @test events == [:preparing, :check, :science, :check, :check]
            @test !isfile(marker)
            @test !any(id -> id.name == "DeclaredOwnerPlant", keys(Base.loaded_modules))
            # A name in the project cannot authorize a different UUID found
            # under the same package name in a later LOAD_PATH environment.
            empty!(events)
            write(project_path, "[deps]\nDeclaredOwnerPlant = \"$wrong_uuid\"\n")
            @test_throws ArgumentError invoke()
            @test !isfile(marker)
            @test !any(id -> id.name == "DeclaredOwnerPlant", keys(Base.loaded_modules))
            # Resolve the declared package from the application Manifest.
            empty!(events)
            write(project_path, "[deps]\nDeclaredOwnerPlant = \"$plant_uuid\"\n")
            open(joinpath(active, "Manifest.toml"), "w") do io
                TOML.print(io, Dict("manifest_format" => "2.0", "julia_version" => string(VERSION),
                    "deps" => Dict("DeclaredOwnerPlant" => [Dict("uuid" => plant_uuid,
                        "version" => "0.1.0", "path" => package)])))
            end
            @test invoke() == 0
            @test isfile(marker)
            @test events == [:preparing, :check, :science, :check, :check, :check, :run]
        finally
            Base.ACTIVE_PROJECT[] = prior_project
            empty!(LOAD_PATH)
            append!(LOAD_PATH, prior_path)
        end
    end
end
