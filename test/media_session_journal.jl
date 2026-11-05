module MediaSessionJournalTests
using Test, PipeWireAORTC, PipeWireAO, SQLite, DBInterface
const S = PipeWireAORTC.MediaSession
isdefined(S,:Journal) || Base.include(S,joinpath(pkgdir(PipeWireAORTC),"src/media_session/journal.jl"))
record() = copy(Pod(SPA.Struct()).data)
request(token;event=:requested,key="operation/$token",bytes=record()) =
    S.JournalRequest(UInt64(token),"session/1",event,bytes,"controller",UInt32(getpid()),key)

function result(journal)
    receipt = Ref{Union{Nothing,S.JournalResult}}(nothing)
    @test timedwait(5;pollint=0.001) do
        receipt[] = S.take_result!(journal)
        receipt[] !== nothing
    end === :ok
    return something(receipt[])
end

@testset "Journal owns one writer and bounded copied messages" begin
    mktempdir() do directory
        path = joinpath(directory,"journal.sqlite")
        journal = S.Journal(path)
        @test journal.worker_thread != journal.owner_thread
        @test journal.capacity == 8
        bytes = record()
        original = copy(bytes)
        for token in 1:8
            @test S.submit!(journal,request(token;bytes))
        end
        fill!(bytes,0xff)
        @test !S.submit!(journal,request(9))
        @test timedwait(() -> lock(() -> length(journal.results)==8,journal.lock),5;pollint=0.001) === :ok
        # Even after completion, retained receipts reserve capacity. No worker
        # or filesystem access is necessary to reject a full/closed submission.
        @test !S.submit!(journal,request(9))
        close(journal)
        @test !S.submit!(journal,request(10))
        receipts = [something(S.take_result!(journal)) for _ in 1:8]
        @test getfield.(receipts,:token) == UInt64.(1:8)
        @test all(r -> r.success && !r.unknown && isempty(r.message),receipts)
        @test S.take_result!(journal) === nothing
        close(journal)
        db = SQLite.DB(path)
        try
            rows = [(;sequence=row.sequence,event=String(row.event),bytes=Vector{UInt8}(row.record),
                key=String(row.operation_key)) for row in DBInterface.execute(db,"SELECT * FROM operation_events ORDER BY sequence")]
            @test length(rows) == 8
            @test all(row -> row.bytes == original && row.event == "requested",rows)
            @test getfield.(rows,:key) == ["operation/$index" for index in 1:8]
            @test only(String(row.journal_mode) for row in DBInterface.execute(db,"PRAGMA journal_mode")) == "wal"
        finally
            close(db)
        end
    end
end

@testset "Closing fences new work and retains every admitted receipt" begin
    mktempdir() do directory
        journal = S.Journal(joinpath(directory,"journal.sqlite"))
        for token in 1:8
            @test S.submit!(journal,request(token))
        end
        close(journal)
        @test !S.submit!(journal,request(9))
        receipts = [something(S.take_result!(journal)) for _ in 1:8]
        @test getfield.(receipts,:token) == UInt64.(1:8)
        @test all(receipt -> receipt.success,receipts)
        @test S.take_result!(journal) === nothing
    end
end

@testset "Journal preserves legacy history and shared schema" begin
    mktempdir() do directory
        path = joinpath(directory,"journal.sqlite")
        db = SQLite.DB(path)
        DBInterface.execute(db,"PRAGMA user_version=37")
        DBInterface.execute(db,"CREATE TABLE configuration_schema(version INTEGER NOT NULL)")
        DBInterface.execute(db,"INSERT INTO configuration_schema VALUES (17)")
        DBInterface.execute(db,"""
            CREATE TABLE operation_events(sequence INTEGER PRIMARY KEY AUTOINCREMENT,
            session_id TEXT NOT NULL,event TEXT NOT NULL,record BLOB NOT NULL,
            recorded_at TEXT NOT NULL DEFAULT(strftime('%Y-%m-%dT%H:%M:%fZ','now')))
            """)
        DBInterface.execute(db,"INSERT INTO operation_events(session_id,event,record) VALUES (?,?,?)",
            ("legacy", "requested",record()))
        close(db)
        chmod(path,0o600)
        journal = S.Journal(path)
        @test S.submit!(journal,request(1;key="new-operation"))
        @test result(journal).success
        @test S.submit!(journal,request(2;event=:completed,key="new-operation"))
        @test result(journal).success
        @test S.submit!(journal,request(3;event=:unknown,key="new-operation"))
        @test result(journal).success
        @test S.submit!(journal,request(4;event=:completed,key="new-operation"))
        duplicate = result(journal)
        @test !duplicate.success && duplicate.unknown
        @test occursin("UNIQUE",duplicate.message)
        close(journal)
        db = SQLite.DB(path)
        try
            @test only(row.user_version for row in DBInterface.execute(db,"PRAGMA user_version")) == 37
            @test only(row.version for row in DBInterface.execute(db,"SELECT version FROM configuration_schema")) == 17
            rows = [(String(row.operation_key),String(row.event)) for row in DBInterface.execute(db,"SELECT * FROM operation_events ORDER BY sequence")]
            @test first(rows) == ("legacy:1","requested")
            @test rows[2:end] == [("new-operation","requested"),("new-operation","completed"),("new-operation","unknown")]
        finally
            close(db)
        end
    end
end

@testset "Journal setup, validation and busy failure are explicit" begin
    @test_throws ArgumentError S.Journal("relative.sqlite")
    @test_throws ArgumentError S.Journal("/unused/journal.sqlite";capacity=9)
    @test_throws ArgumentError request(0)
    @test_throws ArgumentError request(1;event=:invalid)
    @test_throws ArgumentError request(1;bytes=zeros(UInt8,7))
    mktempdir() do directory
        insecure = joinpath(directory,"insecure")
        mkdir(insecure;mode=0o755)
        @test_throws ErrorException S.Journal(joinpath(insecure,"journal.sqlite"))
        target = joinpath(directory,"target.sqlite")
        write(target,"preserve me")
        link = joinpath(directory,"link.sqlite")
        symlink(target,link)
        @test_throws ErrorException S.Journal(link)
        @test read(target,String) == "preserve me"
        path = joinpath(directory,"busy.sqlite")
        journal = S.Journal(path)
        db = SQLite.DB(path)
        try
            DBInterface.execute(db,"BEGIN IMMEDIATE")
            @test S.submit!(journal,request(1))
            # SQLite itself supplies the deterministic 1000ms busy timeout;
            # the test does not release its transaction on a timing race.
            busy = result(journal)
            @test !busy.success && busy.unknown
            @test occursin("locked",busy.message) || occursin("busy",busy.message)
            DBInterface.execute(db,"ROLLBACK")
            @test S.submit!(journal,request(2))
            @test result(journal).success
        finally
            close(db)
            close(journal)
        end
        journal = S.Journal(path)
        chmod(path,0o644)
        try
            @test S.submit!(journal,request(3))
            rejected = result(journal)
            @test !rejected.success && !rejected.unknown
        finally
            chmod(path,0o600)
            close(journal)
        end
    end
end

@testset "One-thread configuration refuses journal I/O" begin
    project = dirname(Base.active_project())
    source = joinpath(pkgdir(PipeWireAORTC),"src/media_session/journal.jl")
    code = """
        using PipeWireAORTC
        const S = PipeWireAORTC.MediaSession
        isdefined(S,:Journal) || Base.include(S,$(repr(source)))
        try
            S.Journal("/invalid/journal.sqlite")
            exit(2)
        catch error
            occursin("interactive policy thread",sprint(showerror,error)) || rethrow()
        end
        """
    process = run(pipeline(`$(Base.julia_cmd()) --startup-file=no --threads=1,0 --project=$project -e $code`;
        stdout=devnull,stderr=stderr);wait=false)
    finished = timedwait(() -> process_exited(process),30;pollint=0.05)
    finished === :ok || kill(process)
    wait(process)
    @test finished === :ok
    @test success(process)
end
end
