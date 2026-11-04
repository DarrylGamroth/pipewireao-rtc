# Standalone local IPC acceptance. Uses only a test-owned native service/worker.
using Test, JSON, Sockets

const ENDPOINT = get(ENV,"PIPEWIREAO_MANAGEMENT_BINARY", "")
isfile(ENDPOINT) || error("set PIPEWIREAO_MANAGEMENT_BINARY to the built native companion")
const MANAGEMENT = "pipewireao.management/1"
const CONFIGURATION = "pipewireao.configuration/1"
const SIMULATOR = "pipewireao.simulator-settings/1"
const sequence = Ref(0)
request_id() = (sequence[] += 1; string(sequence[], base=16, pad=32))
envelope(op; domain=CONFIGURATION, arguments=Dict(), id=request_id()) =
    Dict("protocol"=>MANAGEMENT,"id"=>id,"request"=>Dict("protocol"=>domain,"op"=>op,"arguments"=>arguments))

# Linux sendmsg ABI; attach a retained regular input descriptor to byte one.
struct InputVector
    base::Ptr{Cvoid}
    length::Csize_t
end
struct MessageHeader
    name::Ptr{Cvoid}
    namelen::Cuint
    padding::Cuint
    vector::Ptr{Cvoid}
    vectorlen::Csize_t
    control::Ptr{Cvoid}
    controllen::Csize_t
    flags::Cint
    padding2::Cint
end
function attach_first(socket, byte, file)
    payload=UInt8[byte]
    control=zeros(UInt8,24)
    GC.@preserve control begin
        unsafe_store!(Ptr{Csize_t}(pointer(control)),20)
        unsafe_store!(Ptr{Cint}(pointer(control)+8),1) # SOL_SOCKET
        unsafe_store!(Ptr{Cint}(pointer(control)+12),1) # SCM_RIGHTS
        unsafe_store!(Ptr{Cint}(pointer(control)+16),reinterpret(Cint,Base.fd(file)))
    end
    vector=Ref(InputVector(pointer(payload),1))
    GC.@preserve payload control vector begin
        header=Ref(MessageHeader(C_NULL,0,0,Base.unsafe_convert(Ptr{Cvoid},vector),1,pointer(control),24,0,0))
        @test ccall(:sendmsg, Cssize_t,(Cint,Ref{MessageHeader},Cint),reinterpret(Cint,Base._fd(socket)),header,0)==1
    end
end
function submit(path, request; input=nothing, disconnect=false)
    socket=connect(path)
    text=JSON.json(request)*"\n"
    if input===nothing
        write(socket,text)
    else
        attach_first(socket,codeunit(text,1),input)
        write(socket,SubString(text,2))
    end
    flush(socket)
    if disconnect
        close(socket); return nothing
    end
    reply=JSON.parse(readline(socket)); close(socket)
    @test reply["protocol"]==MANAGEMENT
    @test reply["id"]==request["id"]
    return reply
end
function wait_until(predicate; timeout=10)
    limit=time()+timeout
    while !predicate()
        time()<limit || error("condition did not become true")
        sleep(0.02)
    end
end
function stop_service(process)
    process_running(process) && kill(process,Base.SIGTERM)
    wait_until(()->!process_running(process))
    wait(process)
end
function start_service(directory; idle=2, deadline=3, activation=false)
    socket=joinpath(directory,"management.sock")
    worker=joinpath(directory,"worker.jl")
    arguments=JSON.json([joinpath(Sys.BINDIR,Base.julia_exename()),"--startup-file=no","--project="*dirname(Base.active_project()),worker,directory])
    command=`$ENDPOINT --socket $socket --state-root $(joinpath(directory,"receipts")) --configuration-root $(joinpath(directory,"configuration")) --worker-argv $arguments --idle-timeout $idle --operation-timeout $deadline --describe-timeout $deadline`
    if activation
        launcher=joinpath(dirname(ENDPOINT),"tests","management-activate")
        isfile(launcher) || error("build the management-activate test target")
        command=`$launcher $command`
    end
    process=run(pipeline(command,stdout=devnull,stderr=joinpath(directory,"service.log"));wait=false)
    wait_until(()->ispath(socket)||!process_running(process))
    process_running(process) || error(read(joinpath(directory,"service.log"),String))
    return process,socket
end

const WORKER = raw"""
using JSON
root=ARGS[1]
open(joinpath(root,"workers"),"a") do io
    println(io,getpid())
end
for line in eachline(stdin)
    request=JSON.parse(line)
    args=request["arguments"]
    action=get(args,"test_action","")
    if action=="hold"
        write(joinpath(root,"entered"),string(getpid()))
        sleep(1)
    elseif action=="die"
        open(joinpath(root,"effects"),"a") do io; println(io,"die"); end
        exit(9)
    elseif action=="group"
        child=run(`sh -c 'echo $$ > "$1"; exec sleep 100' sh $(joinpath(root,"child"))`;wait=false)
        write(joinpath(root,"entered"),string(getpid()))
        sleep(100)
    elseif action=="detached"
        child=run(`setsid sh -c 'echo $$ > "$1"; exec sleep 100' sh $(joinpath(root,"detached"))`;wait=false)
        sleep(0.1)
    elseif action=="oversize"
        println(JSON.json(Dict("ok"=>true,"result"=>repeat("x",17*1024*1024))));flush(stdout);continue
    elseif action=="malformed"
        println("not json");flush(stdout);continue
    elseif action=="reject"
        println(JSON.json(Dict("ok"=>false,"error"=>"explicit owner rejection")));flush(stdout);continue
    end
    result=Dict("worker"=>getpid(),"domain"=>request["protocol"],"root"=>get(request,"root",nothing),"request_id"=>get(request,"id",nothing))
    if haskey(args,"path")
        write(joinpath(root,"entered"),"fd")
        sleep(0.3)
        result["bytes"]=read(args["path"],String)
    end
    if request["op"] in ("register","get","start_rebuild")
        open(joinpath(root,"effects"),"a") do io; println(io,request["op"]); end
    end
    println(JSON.json(Dict("ok"=>true,"result"=>result)));flush(stdout)
end
"""

@testset "RTC-owned management native IPC" begin
    mktempdir() do directory
        chmod(directory,0o700)
        write(joinpath(directory,"worker.jl"),WORKER)
        process,path=start_service(directory)
        try
            @test stat(path).mode & 0o777 == 0o600
            first=submit(path,envelope("list"))
            @test first["ok"]
            other=submit(path,envelope("describe";domain=SIMULATOR))
            @test other["result"]["worker"]==first["result"]["worker"]
            @test first["result"]["root"]==joinpath(directory,"configuration")
            rebuild=envelope("start_rebuild";domain=SIMULATOR)
            @test submit(path,rebuild)["result"]["request_id"]==rebuild["id"]
            @test first["result"]["request_id"]===nothing
            @test !submit(path,envelope("Status"))["ok"]
            rooted=envelope("list");rooted["request"]["root"]="/untrusted"
            @test !submit(path,rooted)["ok"]
            @test !submit(path,envelope("list";arguments=Dict("root"=>"/untrusted")))["ok"]
            @test !submit(path,envelope("register"))["ok"]
            open(joinpath(directory,"descriptor"),"w+") do input
                @test !submit(path,envelope("list");input)["ok"]
                @test !submit(path,envelope("register";arguments=Dict("path"=>"/untrusted"));input)["ok"]
            end
            @test !submit(path,envelope("list";id="BAD"))["ok"]
            rejected=submit(path,envelope("list";arguments=Dict("test_action"=>"reject")))
            @test rejected["error"]=="explicit owner rejection"
            @test !rejected["unavailable"]

            # A second client is rejected immediately while admitted owner work runs.
            active=@async submit(path,envelope("list";arguments=Dict("test_action"=>"hold")))
            wait_until(()->isfile(joinpath(directory,"entered")) || (istaskdone(active) && (fetch(active); false)))
            @test submit(path,envelope("list"))["error"]=="Busy"
            @test fetch(active)["ok"]
            rm(joinpath(directory,"entered"))

            # The owner keeps the inode after unlink and client descriptor closure.
            input_path=joinpath(directory,"input.fits");write(input_path,"retained FITS bytes")
            input=open(input_path)
            registration=envelope("register")
            active=@async submit(path,registration;input)
            wait_until(()->isfile(joinpath(directory,"entered")) || (istaskdone(active) && (fetch(active); false)))
            rm(input_path);close(input)
            registered=fetch(active)
            @test registered["result"]["bytes"]=="retained FITS bytes"
            rm(joinpath(directory,"entered"))
            @test !submit(path,registration)["ok"] # missing FD still rejects without dispatch

            # Lost acknowledgement still produces a complete receipt, never replay.
            materialization=envelope("get")
            submit(path,materialization;disconnect=true)
            recovery=()->submit(path,envelope("receipt";domain=MANAGEMENT,arguments=Dict("id"=>materialization["id"])))
            receipt=Ref{Any}(nothing)
            wait_until(()->begin
                receipt[]=recovery()
                get(receipt[],"ok",false) && receipt[]["result"]["state"]=="complete"
            end)
            @test !submit(path,materialization)["ok"]
            @test count(==("get"),readlines(joinpath(directory,"effects")))==1

            # Worker loss retains unknown; restart must not dispatch it again.
            uncertain=envelope("get";arguments=Dict("test_action"=>"die"))
            @test submit(path,uncertain)["unavailable"]
            unknown=submit(path,envelope("receipt";domain=MANAGEMENT,arguments=Dict("id"=>uncertain["id"])))
            @test unknown["result"]["state"]=="unknown"
            stop_service(process)
            process,path=start_service(directory)
            @test !submit(path,materialization)["ok"]
            @test !submit(path,uncertain)["ok"]
            @test count(==("die"),readlines(joinpath(directory,"effects")))==1
            @test submit(path,envelope("list"))["ok"]

            # No response/oversized/malformed worker output retires the worker.
            @test submit(path,envelope("list";arguments=Dict("test_action"=>"malformed")))["unavailable"]
            @test submit(path,envelope("describe";domain=SIMULATOR,arguments=Dict("test_action"=>"oversize")))["unavailable"]
            held=@async submit(path,envelope("list";arguments=Dict("test_action"=>"group")))
            wait_until(()->isfile(joinpath(directory,"child")))
            child=parse(Int,strip(read(joinpath(directory,"child"),String)))
            @test fetch(held)["unavailable"]
            wait_until(()->!isfile("/proc/$child/stat") || occursin(") Z",read("/proc/$child/stat",String)))
            @test submit(path,envelope("list"))["ok"]
            previous=length(readlines(joinpath(directory,"workers")))
            sleep(3.2)
            @test submit(path,envelope("list"))["ok"]
            @test length(readlines(joinpath(directory,"workers")))==previous+1

            # Connection capacity rejects before parsing, without creating a queue.
            clients=Base.PipeEndpoint[]
            for _ in 1:16
                push!(clients,connect(path));sleep(0.02)
            end
            sleep(0.2)
            extra=connect(path)
            saturated=JSON.parse(readline(extra));close(extra)
            @test saturated==Dict("protocol"=>MANAGEMENT,"id"=>"","ok"=>false,"admitted"=>false,"error"=>"Busy")
            foreach(close,clients)
            sleep(0.2)

            # A second owner cannot share the durable state-root lock.
            duplicate=run(pipeline(`$ENDPOINT --socket $(joinpath(directory,"second.sock")) --state-root $(joinpath(directory,"receipts")) --worker-argv '["false"]'`,stdout=devnull,stderr=devnull);wait=false)
            wait_until(()->!process_running(duplicate))
            @test !success(duplicate)
            @test !ispath(joinpath(directory,"second.sock"))

            # Worker retirement does not kill work detached from its process group.
            @test submit(path,envelope("list";arguments=Dict("test_action"=>"detached")))["ok"]
            detached=parse(Int,strip(read(joinpath(directory,"detached"),String)))
            stop_service(process)
            try
                @test ccall(:kill,Cint,(Cint,Cint),detached,0)==0
            finally
                ccall(:kill,Cint,(Cint,Cint),detached,Base.SIGKILL)
            end
            process,path=start_service(directory)

            # Wire framing stays bounded and a slow input times out independently.
            socket=connect(path);write(socket,"{"*repeat(" ",65536));flush(socket)
            @test !JSON.parse(readline(socket))["ok"];close(socket)
            socket=connect(path);write(socket,"{\"protocol\":");flush(socket)
            started=time();@test !JSON.parse(readline(socket))["ok"];close(socket)
            @test 9<time()-started<13
            socket=connect(path);write(socket,"{protocol:1}\n");flush(socket)
            @test !JSON.parse(readline(socket))["ok"];close(socket)
        finally
            stop_service(process)
        end
        @test !ispath(path)
    end
end

@testset "Durable interrupted acceptance and bounded receipt capacity" begin
    mktempdir() do directory
        chmod(directory,0o700)
        write(joinpath(directory,"worker.jl"),WORKER)
        receipts=joinpath(directory,"receipts");mkdir(receipts;mode=0o700)
        interrupted=request_id()
        write(joinpath(receipts,interrupted*".json"),JSON.json(Dict("id"=>interrupted,"domain"=>CONFIGURATION,"state"=>"accepted")))
        # A crash can leave a partial replacement alongside accepted recovery data.
        write(joinpath(receipts,"."*interrupted*".tmp"),"interrupted atomic replacement")
        write(joinpath(receipts,".owner-note.tmp"),"unrelated owner file")
        large_id=request_id()
        large_metadata=repeat("m",2*1024*1024)
        completed=Dict("protocol"=>MANAGEMENT,"id"=>large_id,"ok"=>true,"result"=>Dict("metadata"=>large_metadata))
        write(joinpath(receipts,large_id*".json"),JSON.json(Dict("id"=>large_id,"domain"=>CONFIGURATION,"state"=>"complete","response"=>completed)))
        process,path=start_service(directory)
        try
            large_receipt=submit(path,envelope("receipt";domain=MANAGEMENT,arguments=Dict("id"=>large_id)))
            @test large_receipt["ok"]
            @test large_receipt["result"]["response"]["result"]["metadata"]==large_metadata
            @test !ispath(joinpath(receipts,"."*interrupted*".tmp"))
            @test read(joinpath(receipts,".owner-note.tmp"),String)=="unrelated owner file"
            recovered=submit(path,envelope("receipt";domain=MANAGEMENT,arguments=Dict("id"=>interrupted)))
            @test recovered["result"]["state"]=="unknown"
            @test !haskey(recovered["result"],"response")
            @test !submit(path,envelope("get";id=interrupted))["ok"]
            @test !isfile(joinpath(directory,"workers"))
        finally
            stop_service(process)
        end
        # Seed 255 recovery records, then persist the final admitted slot.
        for _ in 3:255
            id=request_id()
            write(joinpath(receipts,id*".json"),JSON.json(Dict("id"=>id,"domain"=>CONFIGURATION,"state"=>"unknown")))
        end
        process,path=start_service(directory)
        try
            @test !isfile(joinpath(directory,"workers"))
            @test submit(path,envelope("get"))["ok"]
            denied=submit(path,envelope("get"))
            @test !denied["ok"]
            @test occursin("full",denied["error"])
            @test length(filter(name->endswith(name,".json"),readdir(receipts)))==256
            @test readlines(joinpath(directory,"effects"))==["get"]
            @test submit(path,envelope("list"))["ok"]
        finally
            stop_service(process)
        end
    end
end

@testset "Service interruption never replays admitted work" begin
    mktempdir() do directory
        chmod(directory,0o700)
        write(joinpath(directory,"worker.jl"),WORKER)
        process,path=start_service(directory)
        accepted=envelope("get";arguments=Dict("test_action"=>"group"))
        active=@async submit(path,accepted)
        wait_until(()->isfile(joinpath(directory,"child")))
        child=parse(Int,strip(read(joinpath(directory,"child"),String)))
        started=time()
        stop_service(process)
        @test time()-started<2
        wait_until(()->!isfile("/proc/$child/stat") || occursin(") Z",read("/proc/$child/stat",String)))
        # The interrupted connection closes; it cannot supply an acknowledgement.
        try fetch(active) catch end
        process,path=start_service(directory)
        try
            recovered=submit(path,envelope("receipt";domain=MANAGEMENT,arguments=Dict("id"=>accepted["id"])))
            @test recovered["result"]["state"]=="unknown"
            @test !submit(path,accepted)["ok"]
            @test length(readlines(joinpath(directory,"workers")))==1
        finally
            stop_service(process)
        end
    end
end

@testset "Validated systemd socket activation" begin
    mktempdir() do directory
        chmod(directory,0o700)
        write(joinpath(directory,"worker.jl"),WORKER)
        process,path=start_service(directory;activation=true)
        try
            @test stat(path).mode & 0o777 == 0o600
            @test submit(path,envelope("list"))["ok"]
        finally
            stop_service(process)
        end
        # The inherited activation listener's filesystem entry belongs to its owner.
        @test ispath(path)
    end
end

@testset "Companion crash kills direct worker and preserves unknown acceptance" begin
    mktempdir() do directory
        chmod(directory,0o700)
        write(joinpath(directory,"worker.jl"),WORKER)
        process,path=start_service(directory)
        accepted=envelope("get";arguments=Dict("test_action"=>"hold"))
        active=@async submit(path,accepted)
        wait_until(()->isfile(joinpath(directory,"entered")))
        worker=parse(Int,read(joinpath(directory,"entered"),String))
        kill(process,Base.SIGKILL)
        wait_until(()->!process_running(process))
        wait_until(()->!isfile("/proc/$worker/stat") || occursin(") Z",read("/proc/$worker/stat",String)))
        try fetch(active) catch end
        rm(path) # test-owned stale direct-bind socket after uncatchable SIGKILL
        process,path=start_service(directory)
        try
            recovered=submit(path,envelope("receipt";domain=MANAGEMENT,arguments=Dict("id"=>accepted["id"])))
            @test recovered["result"]["state"]=="unknown"
            @test !submit(path,accepted)["ok"]
            @test length(readlines(joinpath(directory,"workers")))==1
            @test !isfile(joinpath(directory,"effects"))
        finally
            stop_service(process)
        end
    end
end
