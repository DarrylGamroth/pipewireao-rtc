using Test, PipeWireAODeployment

const SD = PipeWireAODeployment.Deployment
const SE = PipeWireAODeployment.ScienceExport

@testset "deployment process supervisor CLI options" begin
    direct = SD._options(["run", "--deployment", "/tmp/deployment.conf"])
    @test direct.process_supervisor == "direct"
    @test direct.supervisor_unit == ""

    systemd = SD._options(["run", "--deployment", "/tmp/deployment.conf",
        "--process-supervisor", "systemd", "--supervisor-unit", "pipewireao-rtc@test.service"])
    @test systemd.process_supervisor == "systemd"
    @test systemd.supervisor_unit == "pipewireao-rtc@test.service"
    @test_throws SD.DeploymentError SD._options(["run", "--deployment", "/tmp/deployment.conf",
        "--process-supervisor", "unknown"])
    @test_throws SD.DeploymentError SD._options(["run", "--deployment", "/tmp/deployment.conf",
        "--process-supervisor", "systemd"])

    cleanup = SD._options(["cleanup-systemd-owners", "--invocation",
        "0123456789abcdef0123456789abcdef"])
    @test cleanup.command == "cleanup-systemd-owners"
    @test cleanup.invocation == "0123456789abcdef0123456789abcdef"
    @test_throws SD.DeploymentError SD._options(["preflight", "--deployment", "/tmp/deployment.conf",
        "--supervisor-unit", "pipewireao-rtc@test.service"])
    @test_throws SD.DeploymentError SD._options(["control", "--runtime", "/tmp/runtime",
        "--process-supervisor", "systemd"])
end

@testset "Service admission wait skips another supervisor's locator" begin
    mktempdir() do runtime
        C = PipeWireAODeployment.Common
        N = PipeWireAODeployment.NativeControlClient
        profile = PipeWireAODeployment.NativeSupervisorCodec.PROFILE
        C.write_json(joinpath(runtime,"control.json"), Dict("version"=>1,
            "profile"=>N.profile_name(profile), "remote"=>joinpath(runtime,"removed-old-core","remote"),
            "node"=>"old-supervisor", "owner_pid"=>1, "instance"=>1))
        # Connecting this old address would throw ENOENT. The fresh owner wait
        # must instead skip it and reach its finite observation deadline.
        @test_throws N.UnknownOutcome SD.wait_state(runtime, _->true;
            timeout=0.05, expected_owner_pid=getpid())
        @test_throws SD.DeploymentError SD.wait_state(runtime, _->true;
            expected_owner_pid=true)
    end
end

@testset "opt-in systemd coordinator template and SDK copy" begin
    source = joinpath(PipeWireAODeployment.resource_root(), "pipewireao-rtc-systemd@.service.in")
    template = read(source, String)
    for expected in ("Type=notify", "--process-supervisor systemd --supervisor-unit %n",
        "ExecStopPost=@LAUNCHER@ cleanup-systemd-owners --invocation \${INVOCATION_ID}",
        "RuntimeDirectory=pipewireao-rtc-systemd-%i", "KillMode=mixed", "KillSignal=SIGINT",
        "TimeoutStartSec=600", "TimeoutStopSec=300", "CPUAffinity=@CPUS@", "Restart=no")
        @test occursin(expected, template)
    end
    @test !occursin("BindsTo=", template)
    @test !occursin("PartOf=", template)

    mktempdir() do package
        SE.copy_deployment_runtime(package; copy_service=false)
        copied = joinpath(package, "julia", "assets", "deployment", basename(source))
        @test isfile(copied)
        @test read(copied, String) == template
    end
end
