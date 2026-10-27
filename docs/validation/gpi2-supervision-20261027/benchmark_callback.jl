# Generated validation harness: calibrated GPI2 native callback, disconnected CPU owners.
using FilterGraphAlgorithms, FilterGraphPipeWire, FilterGraphIsland, JuliaFilterGraph, PipeWireAO
using PipeWireAORTC, LinearAlgebra, JSON, SHA
const CS = PipeWireAORTC.CorrectionSupervision
const R = PipeWireAORTC
const ROOT = @__DIR__
const APP = "/home/dgamroth/.local/state/pipewireao/gpi2-operator-live-20261027/session-shape/installed"
const TESTS = "/home/dgamroth/workspaces/codex/worktrees/jfg-frame-observer-20261027/julia/FilterGraphPipeWire/test"
source = read(joinpath(TESTS,"runtests.jl"),String)
@assert occursin("@testset \"FGN Header metadata mapping is transport-neutral\"", source)
@assert pkgversion(FilterGraphAlgorithms) == v"0.8.4"
println("FGA ",pkgversion(FilterGraphAlgorithms)," from ",pathof(FilterGraphAlgorithms));flush(stdout)
include_string(Main,replace(first(split(source,"@testset \"FGN Header metadata mapping is transport-neutral\"")),r"^include\([^\n]*\)\n"m=>"", "using ForwardDiff\n"=>""),joinpath(TESTS,"runtests.jl"))
BLAS.set_num_threads(1)
function prepare_case(monitored)
    path=joinpath(APP,"rtc/graph.conf")
    entries=R.GraphOwner.bindings(joinpath(APP,"rtc/parameters.conf"))
    options=FilterGraphIsland.parse_arguments(["--graph",path,"--execution","complete-frame","--check"])
    graph=FilterGraphIsland.prepare_service_graph(options;initial_parameters=formats->R.GraphOwner.prepare_bindings(entries,formats))
    formats=JuliaFilterGraph.output_formats(graph)
    names=(Symbol("woofer-constraint-feedback"),Symbol("tweeter-constraint-feedback"))
    policies=NamedTuple{names}(map(names) do name
        f=getproperty(formats,name)
        (;configuration=CS.Configuration(trip_fraction=0.05,clear_fraction=0.01,persistence_ns=100_000_000,max_gap_ns=1_000_000_000),
          tolerance=0.0,schema=f.schema,shape=f.shape,layout=f.layout)
    end)
    observer=monitored ? CS.Observer(formats,policies;owner_instance=451) : nothing
    node=PipeWireNode(graph;connect=false,rate=2000//1,boundary_layout=RowMajorLayout(),
        feedback=Symbol("constraint-feedback")=>Symbol("controller-constraint-feedback"),frame_observer=observer)
    input=fill(UInt16(1400),prod(only(values(node.owner.feedback.public_input_bindings)).shape))
    outputs=FilterGraphPipeWire._warm_buffers(node.owner.feedback.public_output_bindings)
    arrays=map(vec,outputs)
    ni=native_callback_buffer(input;header=BufferHeader(SPA.META_HEADER_FLAG_MARKER,UInt32(0),Int64(0),Int64(0),UInt64(0)))
    no=vcat(map(array->native_callback_buffer(array;header_available=true),values(arrays))...)
    FilterGraphPipeWire._prepare_owner(node.owner)
    return (;node,input,outputs,arrays,ni,no,observer)
end
function frame!(run,sequence::UInt64)
    GC.@preserve run begin
        header=PipeWireAO.LibPipeWire.spa_meta_header(SPA.META_HEADER_FLAG_MARKER,UInt32(0),Int64(sequence*500_000),Int64(0),sequence)
        unsafe_store!(pointer(run.ni).header,header)
        inputs=NdArrayFilterBuffers{false}(Ptr{Cvoid}(pointer(run.ni)),UInt32(length(run.ni)))
        outputs=NdArrayFilterBuffers{true}(Ptr{Cvoid}(pointer(run.no)),UInt32(length(run.no)))
        run.node.filter.callbacks.on_process(run.node.filter,inputs,outputs)
    end
    return nothing
end
function same_outputs(a,b)
    all(map(values(a.outputs),values(b.outputs)) do x,y
        reinterpret(UInt8,vec(x)) == reinterpret(UInt8,vec(y))
    end)
end
function stats(times)
    sorted=sort(times); n=length(sorted)
    Dict("samples"=>n,"p50_ns"=>sorted[clamp(ceil(Int,.50n),1,n)],"p95_ns"=>sorted[clamp(ceil(Int,.95n),1,n)],
         "p99_ns"=>sorted[clamp(ceil(Int,.99n),1,n)],"max_ns"=>maximum(times),"mean_ns"=>sum(Float64,times)/n)
end
allocation!(run, sequence::UInt64) = @allocated frame!(run,sequence)
function measure!(times, run, round::Int, sequence::UInt64)
    for i in 1:64
        index=(round-1)*64+i
        cursor=sequence+UInt64(index)
        start=time_ns();frame!(run,cursor);times[index]=time_ns()-start
    end
    return nothing
end
function main()
    println("Preparing baseline");flush(stdout)
    baseline=prepare_case(false)
    println("Preparing monitored");flush(stdout)
    monitored=prepare_case(true)
    println("Warming callbacks");flush(stdout)
    times=(zeros(UInt64,2048),zeros(UInt64,2048)); sequence=UInt64(0)
    try
        for _ in 1:128
            sequence+=1;frame!(baseline,sequence);frame!(monitored,sequence)
        end
        @assert same_outputs(baseline,monitored)
        sequence+=1;frame!(baseline,sequence);frame!(monitored,sequence)
        ba=allocation!(baseline,sequence+UInt64(1))
        ma=allocation!(monitored,sequence+UInt64(1))
        sequence+=1
        # Alternate order every64frames; no sleep/open-loop/deadline claim.
        for round in 1:32
            for case in (isodd(round) ? (1,2) : (2,1))
                run=case==1 ? baseline : monitored
                measure!(times[case],run,round,sequence)
            end
            @assert same_outputs(baseline,monitored)
        end
        @assert !monitored.node.owner.frame_observer.failed[]
        @assert all(x->x.state in (:Clear,:Pending,:Tripped),CS.snapshot(monitored.observer))
        @assert all(i->native_callback_flags(monitored.no,i)==0,1:length(monitored.no))
        report=Dict("scope"=>"disconnected calibrated GPI2 CPU native callbacks; paired closed-loop workload; not fixed-rate or deadline qualification",
            "fga_version"=>string(pkgversion(FilterGraphAlgorithms)),"fga_source"=>pathof(FilterGraphAlgorithms),"julia"=>string(VERSION),"cpu"=>Sys.CPU_NAME,"threads"=>Threads.nthreads(),"blas_threads"=>BLAS.get_num_threads(),
            "graph_sha256"=>bytes2hex(sha256(read(joinpath(APP,"rtc/graph.conf")))),
            "bindings_sha256"=>bytes2hex(sha256(read(joinpath(APP,"rtc/parameters.conf")))),
            "public_outputs"=>string.(keys(monitored.outputs)),"identical_output_bytes"=>same_outputs(baseline,monitored),
            "baseline_allocated_bytes"=>ba,"monitored_allocated_bytes"=>ma,"baseline"=>stats(times[1]),"monitored"=>stats(times[2]),
            "observer_states"=>string.([x.state for x in CS.snapshot(monitored.observer)]))
        open(joinpath(ROOT,"calibrated-callback-timing.json"),"w") do io;JSON.print(io,report,2);end
        open(joinpath(ROOT,"calibrated-callback-timing.csv"),"w") do io
            println(io,"sample,baseline_ns,monitored_ns")
            for i in eachindex(times[1]);println(io,i,",",times[1][i],",",times[2][i]);end
        end
        @assert ba==ma==0
        println(JSON.json(report))
    finally
        close(baseline.node);close(monitored.node)
    end
end
main()
