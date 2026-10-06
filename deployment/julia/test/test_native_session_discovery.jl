module NativeSessionDiscoveryTests

using Test
using PipeWireAO
using PipeWireAODeployment

# Until the supervisor integration adopts this module, qualify its standalone
# listing contract without mutating the loaded package's module graph.
include(joinpath(dirname(@__DIR__), "src", "native_session_discovery.jl"))
const Discovery = NativeSessionDiscovery
const SPA = PipeWireAO.SPA
const Pod = PipeWireAO.Pod
const SESSION_A = "01234567-89ab-cdef-0123-456789abcdef"
const SESSION_B = "11234567-89ab-cdef-0123-456789abcdef"
struct StatusVerifier
    status::Discovery.FreshSupervisorStatus
end
(verifier::StatusVerifier)(record::Discovery.SessionRecord) = verifier.status
current_pid() = UInt32(getpid())
record(id=SESSION_A; label="Copper") = Discovery.SessionRecord(label, id,
    current_pid(), Int64(100), "/run/user/$(Discovery._uid())/pw-copper", "rtc.supervisor.copper")
directory(root) = Discovery.registry_directory(root)

@testset "native local session discovery contract" begin
    @testset "strict bounded SPA Struct" begin
        item = record()
        pod = Discovery.encode_record(item)
        @test sizeof(pod) <= 4096
        @test Discovery.decode_record(pod) == item
        @test Discovery.decode_record(pod.data) == item
        padded = vcat(UInt8[0], pod.data, UInt8[0])
        @test Discovery.decode_record(@view padded[2:(end - 1)]) == item
        @test length(Discovery._fields(pod)) == 7
        @test_throws ArgumentError Discovery.SessionRecord("", SESSION_A,
            current_pid(), Int64(1), "/run/user/1000/pipewire", "rtc.supervisor")
        @test_throws ArgumentError Discovery.SessionRecord("name", uppercase(SESSION_A),
            current_pid(), Int64(1), "/run/user/1000/pipewire", "rtc.supervisor")
        @test_throws ArgumentError Discovery.SessionRecord("name", SESSION_A,
            UInt32(0), Int64(1), "/run/user/1000/pipewire", "rtc.supervisor")
        @test_throws ArgumentError Discovery.SessionRecord("name", SESSION_A,
            current_pid(), Int64(0), "/run/user/1000/pipewire", "rtc.supervisor")
        @test_throws ArgumentError Discovery.SessionRecord("name", SESSION_A,
            current_pid(), Int64(1), "pipewire-0", "rtc.supervisor")
        @test_throws ArgumentError Discovery.SessionRecord("x"^257, SESSION_A,
            current_pid(), Int64(1), "/run/user/1000/pipewire", "rtc.supervisor")
        @test_throws ArgumentError Discovery.SessionRecord("label", SESSION_A,
            current_pid(), Int64(1), "/run/user/1000/pipewire", "rtc.supervisor/0")
        @test_throws ArgumentError Discovery.SessionRecord("label", SESSION_A,
            current_pid(), Int64(1), "/run/user/1000/pipewire", "café")
        @test_throws ArgumentError Discovery.SessionRecord("label", SESSION_A,
            current_pid(), Int64(1), "/run/user/1000/pipewire", "n"^129)

        values = copy(Discovery._fields(pod))
        values[1] = Pod(SPA.Id(UInt32(1)))
        @test_throws ArgumentError Discovery.decode_record(Pod(SPA.Struct(values)))
        values = copy(Discovery._fields(pod))
        values[4] = Pod(Int32(current_pid()))
        @test_throws ArgumentError Discovery.decode_record(Pod(SPA.Struct(values)))
        @test_throws ArgumentError Discovery.decode_record(vcat(pod.data, UInt8[0]))
        @test_throws ArgumentError Discovery.decode_record(UInt8[1, 2, 3])
        @test ncodeunits(Discovery.DiscoveryEntry(item, Discovery.Unverified,
            "d"^1024).detail) <= 512
    end

    @testset "owned private XDG registry and atomic publication" begin
        mktempdir() do root
            chmod(root, 0o700)
            registry = directory(root)
            @test (lstat(registry).mode & 0o777) == 0o700
            first = record(SESSION_A; label="Copper")
            second = record(SESSION_B; label="Copper")
            first_path = Discovery.publish!(registry, first)
            second_path = Discovery.publish!(registry, second)
            @test isfile(first_path) && isfile(second_path)
            @test (lstat(first_path).mode & 0o777) == 0o600
            open(joinpath(registry, ".lock"), "r+") do io
                @test ccall(:flock, Cint, (Cint, Cint), Base.fd(io), 2) == 0
                @test_throws ArgumentError Discovery.publish!(registry, record(SESSION_B))
                @test ccall(:flock, Cint, (Cint, Cint), Base.fd(io), 8) == 0
            end
            listed = Discovery.list_sessions(registry)
            @test length(listed) == 2
            @test all(item -> item.verification === Discovery.Unverified, listed)
            @test all(item -> item.record.label == "Copper", listed)
            @test all(item -> occursin("has not been queried", item.detail), listed)

            fresh = Discovery.FreshSupervisorStatus(SESSION_A, current_pid(), Int64(100),
                record(SESSION_A).remote, "rtc.supervisor.copper", UInt32(9), UInt64(200), Int64(1), :stopped,
                :deployment_supervisor)
            selected = Discovery.select_session(only(filter(
                item -> item.record.session_id == SESSION_A, listed)), StatusVerifier(fresh))
            @test selected isa Discovery.SelectedSession
            @test selected.status.lifecycle === :stopped
            @test Discovery.select_session(only(filter(
                item -> item.record.session_id == SESSION_A, listed)), _ -> :stopped).verification ===
                Discovery.Inaccessible

            inaccessible = Discovery.select_session(only(filter(
                item -> item.record.session_id == SESSION_B, listed)), _ -> error("endpoint inaccessible"))
            @test inaccessible.verification === Discovery.Inaccessible
            @test inaccessible.record.session_id == SESSION_B
            replaced_status = Discovery.FreshSupervisorStatus(SESSION_B, current_pid(), Int64(101),
                record(SESSION_B).remote, "rtc.supervisor.copper", UInt32(10), UInt64(201), Int64(2), :ready,
                :deployment_supervisor)
            replaced = Discovery.select_session(only(filter(
                item -> item.record.session_id == SESSION_B, listed)), _ -> replaced_status)
            @test replaced.verification === Discovery.Replaced
            wrong_remote = Discovery.FreshSupervisorStatus(SESSION_B, current_pid(), Int64(100),
                "/run/user/$(Discovery._uid())/other-remote", "rtc.supervisor.copper",
                UInt32(11), UInt64(202), Int64(3), :ready, :deployment_supervisor)
            remote_mismatch = Discovery.select_session(only(filter(
                item -> item.record.session_id == SESSION_B, listed)), _ -> wrong_remote)
            @test remote_mismatch.verification === Discovery.Replaced
            runner_status = Discovery.FreshSupervisorStatus(SESSION_B, current_pid(), Int64(100),
                record(SESSION_B).remote, "rtc.supervisor.copper", UInt32(12), UInt64(203),
                Int64(4), :ready, :standalone_runner)
            wrong_authority = Discovery.select_session(only(filter(
                item -> item.record.session_id == SESSION_B, listed)), _ -> runner_status)
            @test wrong_authority.verification === Discovery.Replaced
            @test occursin("standalone runner", wrong_authority.detail)

            new_incarnation = Discovery.SessionRecord("Copper", SESSION_A,
                current_pid(), Int64(101), first.remote, first.node_name)
            @test Discovery.publish!(registry, new_incarnation) == first_path
            @test !Discovery.remove!(registry, first)
            @test Discovery.decode_record(read(first_path)).incarnation == 101
            @test Discovery.remove!(registry, new_incarnation)
            @test !ispath(first_path)
            @test Discovery.remove!(registry, second)
            @test isempty(Discovery.list_sessions(registry))
        end
    end

    @testset "untrusted, malformed, stale and inaccessible records" begin
        mktempdir() do root
            chmod(root, 0o700)
            registry = directory(root)
            item = record()
            Discovery.publish!(registry, item)
            path = joinpath(registry, "session-$(item.session_id).pod")
            rm(path)
            symlink("/etc/passwd", path)
            write(joinpath(registry, "unexpected.pod"), UInt8[])
            listing = Discovery.list_sessions(registry)
            @test length(listing) == 2
            @test all(item -> item.record === nothing, listing)
            @test all(item -> item.verification === Discovery.Malformed, listing)
            @test_throws ArgumentError Discovery.remove!(registry, item)
        end

        mktempdir() do root
            chmod(root, 0o700)
            linked = joinpath(root, "runtime-link")
            symlink(root, linked)
            @test_throws ArgumentError directory(linked)
            @test_throws ArgumentError Discovery.FreshSupervisorStatus(SESSION_A,
                current_pid(), Int64(1), "/run/user/$(Discovery._uid())/pw", "rtc.supervisor", UInt32(2), UInt64(1), Int64(1),
                :running, :deployment_supervisor)
            @test_throws ArgumentError Discovery.FreshSupervisorStatus(SESSION_A,
                current_pid(), Int64(1), "/run/user/$(Discovery._uid())/pw", "rtc.supervisor", UInt32(2), UInt64(1), Int64(0),
                :ready, :deployment_supervisor)
        end

        mktempdir() do root
            chmod(root, 0o700)
            registry = directory(root)
            stale_pid = current_pid() + UInt32(100_000)
            stale = Discovery.SessionRecord("Stopped", SESSION_A, stale_pid, Int64(33),
                "/run/user/$(Discovery._uid())/pw-stale", "rtc.supervisor.stale")
            stale_path = joinpath(registry, "session-$(stale.session_id).pod")
            write(stale_path, Discovery.encode_record(stale).data)
            chmod(stale_path, 0o600)
            entry = only(Discovery.list_sessions(registry))
            @test entry.verification === Discovery.Unverified
            @test entry.record.owner_pid == stale_pid
            selected = Discovery.select_session(entry, _ -> error("supervisor no longer exists"))
            @test selected.verification === Discovery.Inaccessible
            @test isfile(stale_path)
        end

        mktempdir() do root
            chmod(root, 0o700)
            registry = directory(root)
            for value in 1:(Discovery.MAX_ENTRIES + 1)
                hex = lpad(string(value, base=16), 32, '0')
                id = string(hex[1:8], '-', hex[9:12], '-', hex[13:16], '-',
                    hex[17:20], '-', hex[21:32])
                write(joinpath(registry, "session-$id.pod"), UInt8[])
            end
            @test_throws ArgumentError Discovery.list_sessions(registry)
        end
    end
end

end # module NativeSessionDiscoveryTests
