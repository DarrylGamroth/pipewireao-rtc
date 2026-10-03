using Test
include("calibration_owner.jl")

function capture_owner_arguments(root)
    return ["--profile", "classic", "--graph", joinpath(root, "plant.toml"),
        "--rate", "500", "--exposure-ns", "2000000", "--remote", "isolated-core",
        "--prepared-event", joinpath(root, "prepared"), "--connect-request", joinpath(root, "connect-request"),
        "--connect-reply", joinpath(root, "connect-reply"), "--quit-request", joinpath(root, "quit"),
        "--control-request", joinpath(root, "request.json"), "--control-reply", joinpath(root, "reply.json"),
        "--output", joinpath(root, "result.json"), "--calibration-socket", joinpath(root, "calibration.sock")]
end

@testset "calibration owner startup campaign options" begin
    mktempdir() do root
        arguments = capture_owner_arguments(root)
        defaults = calibration_options(arguments)
        @test defaults.illumination === :lamp && defaults.calibration_stage == "calibration"
        @test defaults.capture_directory === nothing && defaults.capture_max_bytes === nothing
        directory = joinpath(root, "capture")
        capture = ["--capture-directory", directory, "--capture-max-bytes", "4004032"]
        selected = calibration_options([arguments; capture; "--illumination"; "dark"; "--calibration-stage"; "dark-training"])
        @test selected.illumination === :dark && selected.calibration_stage == "dark-training"
        @test selected.capture_directory == directory && selected.capture_max_bytes == 16CalibrationServer.CLASSIC_CAPTURE_BYTES
        @test !ispath(directory) # parsing has no filesystem or model effects
        for invalid in ("0", "-1", "true", "1.5", "1e6", string(big(2)^64), string(typemax(UInt64)))
            @test_throws ArgumentError calibration_options([arguments; "--capture-directory"; directory; "--capture-max-bytes"; invalid])
        end
        @test_throws ArgumentError calibration_options([arguments; "--capture-directory"; directory])
        @test_throws ArgumentError calibration_options([arguments; "--capture-max-bytes"; "1"])
        @test_throws ArgumentError calibration_options([arguments; capture; "--capture-directory"; directory])
        @test_throws ArgumentError calibration_options([arguments; "--illumination"; "laser"])
        @test_throws ArgumentError calibration_options([arguments; "--illumination"; "dark"; "--illumination"; "lamp"])
        for stage in ("", "../other", "with space", repeat("a", 65))
            @test_throws ArgumentError calibration_options([arguments; "--calibration-stage"; stage])
        end
        @test_throws ArgumentError calibration_options([arguments; "--capture-directory"; joinpath(root, "missing", "capture"); "--capture-max-bytes"; "1"])
        copper = copy(arguments)
        copper[findfirst(==("--profile"), copper) + 1] = "copper"
        copper_selected = calibration_options([copper; capture])
        @test copper_selected.profile === :copper && copper_selected.capture_directory == directory
        @test copper_selected.capture_max_bytes == 4_004_032 && !ispath(directory)
        active = joinpath(root, "active.u8")
        write(active, ones(UInt8, 188))
        @test_throws ArgumentError calibration_options([copper; capture; "--wfs-active"; active])
        mkdir(directory)
        @test_throws ArgumentError calibration_options([arguments; capture])
        rm(directory)
        symlink(joinpath(root, "absent"), directory)
        @test_throws ArgumentError calibration_options([arguments; capture])
    end
end
