using FilterGraphAlgorithms
using FilterGraphPipeWire
using JuliaFilterGraph
using PipeWireAO
using SHA
const REPO = "/home/dgamroth/workspaces/codex/pipewire/JuliaFilterGraph.jl"
const FGPW = FilterGraphPipeWire
const JFG = JuliaFilterGraph
const FGA = FilterGraphAlgorithms
const SPA = PipeWireAO.SPA
# Exact heterogeneous fixture definitions; no test suite execution.
source = read(joinpath(REPO, "julia/FilterGraphPipeWire/test/runtests.jl"), String)
a = findfirst("@enum AdapterFailure::UInt8", source).start
b = findfirst("@algorithm AdapterLatestHoldAddF32", source).start
include_string(Main, source[a:prevind(source,b)], "heterogeneous_fixture_excerpt")

adopt_parameter!(owner) = FGPW._adopt_pending_parameters!(owner)
adopt_property!(owner) = FGPW._adopt_pending_properties!(owner)
cycle!(owner, inputs, outputs) = JFG._process_admitted!(outputs, owner.graph, inputs, owner.graph.default_input_metadata)
function adopt_parameter_cycle!(owner, inputs, outputs)
    adopt_parameter!(owner) || error("parameter absent")
    return cycle!(owner, inputs, outputs)
end
function adopt_property_cycle!(owner, inputs, outputs)
    adopt_property!(owner) || error("property absent")
    return cycle!(owner, inputs, outputs)
end
stage_parameter!(owner, matrix) = FGPW._stage_parameter_transaction!(owner, Symbol("shape-to-hidden") => matrix)
stage_property!(owner, props) = FGPW._stage_property_transaction!(owner, props)
measure_parameter!(owner) = @allocated adopt_parameter!(owner)
measure_property!(owner) = @allocated adopt_property!(owner)
measure_parameter_cycle!(owner, inputs, outputs) = @allocated adopt_parameter_cycle!(owner, inputs, outputs)
measure_property_cycle!(owner, inputs, outputs) = @allocated adopt_property_cycle!(owner, inputs, outputs)
measure_cycle!(owner, inputs, outputs) = @allocated cycle!(owner, inputs, outputs)
measure_public_cycle!(owner, inputs, outputs) = @allocated JFG.process!(outputs, owner.graph, inputs)
measure_parameter_stage!(owner, matrix) = @allocated stage_parameter!(owner, matrix)
measure_property_stage!(owner, props) = @allocated stage_property!(owner, props)
function oracle!(expected, state, prior, plan, residual, feedback, firstcycle)
    if firstcycle
        fill!(state, 0f0)
    else
        hidden = 0f0
        for j in eachindex(prior)
            hidden += plan.shape_to_hidden[1,j] * (prior[j]-feedback[j])
        end
        for j in eachindex(prior)
            state[j] = prior[j] - plan.anti_windup_gain * feedback[j] - plan.hidden_mode_gain * plan.hidden_to_shape[j,1] * hidden
        end
    end
    for j in eachindex(prior)
        expected[j] = plan.pole * state[j] + plan.gain * residual[j]
    end
    copyto!(prior, expected)
end
function check_cycle!(owner, inputs, outputs, expected, state, prior, firstcycle)
    plan = only(owner.graph.nodes).prepared.plan
    oracle!(expected, state, prior, plan, getproperty(inputs, Symbol("residual-error")), getproperty(inputs, Symbol("constraint-feedback")), firstcycle)
    @assert isapprox(outputs.correction, expected; rtol=2f-6, atol=2f-6)
    @assert isapprox(getproperty(outputs, Symbol("controller-state")), state; rtol=2f-6, atol=2f-6)
end
function main()
    previous_gc = GC.enable(true)
    println("julia_version=", VERSION, " threads=", Threads.nthreads(), " gc_enabled_before=",previous_gc," gc_enabled_during=true")
    for mod in (FGA,FGPW,JFG,PipeWireAO)
        println("package=",nameof(mod)," version=",pkgversion(mod)," path=",pathof(mod))
    end
    for rel in ("graph_node.jl",)
        path=joinpath(dirname(pathof(FGPW)),rel)
        println("source_hash=",path," sha256=",bytes2hex(sha256(read(path))))
    end
    for rel in ("parameters.jl","graph.jl")
        path=joinpath(dirname(pathof(JFG)),rel)
        println("source_hash=",path," sha256=",bytes2hex(sha256(read(path))))
    end
    graph = prepare_graph(joinpath(REPO,"julia/FilterGraphPipeWire/test/fixtures/closed-loop-correction.conf"); algorithms=FGA.algorithms())
    owner = FGPW.PreparedGraphOwner(graph)
    inputs = NamedTuple{keys(graph.input_formats)}((Float32[1,2], Float32[0.1,0.2]))
    outputs = NamedTuple{keys(graph.output_formats)}((zeros(Float32,2), zeros(Float32,2)))
    matrix_a=fill(2f0,1,2); matrix_b=fill(3f0,1,2)
    JFG.replace_parameters!(graph, Symbol("hidden-to-shape")=>reshape(Float32[0.1,0.2],2,1))
    props_a=SPA.Props("closed-loop-correction:gain"=>1f0)
    props_b=SPA.Props("closed-loop-correction:gain"=>2f0)
    expected=zeros(Float32,2); state=zeros(Float32,2); prior=zeros(Float32,2)
    cycle!(owner,inputs,outputs)
    check_cycle!(owner,inputs,outputs,expected,state,prior,true)
    println("control_before plan_gain=",only(graph.nodes).prepared.plan.gain," projection=",only(graph.nodes).prepared.plan.shape_to_hidden," correction=",outputs.correction," state=",getproperty(outputs, Symbol("controller-state")))
    println("control_owner_type=",typeof(owner))
    println("parameter_transaction_type=",typeof(owner.parameter_transaction))
    println("input_type=",typeof(inputs)," output_type=",typeof(outputs))
    # Warm every measured concrete wrapper, 32 complete parameter+property sequences.
    for k in 1:32
        stage_parameter!(owner,isodd(k) ? matrix_a : matrix_b)
        measure_parameter!(owner)
        measure_cycle!(owner,inputs,outputs); check_cycle!(owner,inputs,outputs,expected,state,prior,false)
        stage_parameter!(owner,isodd(k) ? matrix_b : matrix_a)
        measure_parameter_cycle!(owner,inputs,outputs); check_cycle!(owner,inputs,outputs,expected,state,prior,false)
        stage_property!(owner,isodd(k) ? props_a : props_b)
        measure_property!(owner)
        measure_public_cycle!(owner,inputs,outputs); check_cycle!(owner,inputs,outputs,expected,state,prior,false)
        stage_property!(owner,isodd(k) ? props_b : props_a)
        measure_property_cycle!(owner,inputs,outputs); check_cycle!(owner,inputs,outputs,expected,state,prior,false)
        measure_parameter_stage!(owner,matrix_a); adopt_parameter!(owner)
        measure_property_stage!(owner,props_a); adopt_property!(owner)
    end
    parameter=Int[]; property=Int[]; parameter_cycle=Int[]; property_cycle=Int[]; process_admitted=Int[]; process_public=Int[]; parameter_stage=Int[]; property_stage=Int[]
    for k in 1:64
        matrix=isodd(k) ? matrix_a : matrix_b
        props=isodd(k) ? props_a : props_b
        stage_parameter!(owner,matrix)
        push!(parameter,measure_parameter!(owner))
        @assert only(graph.nodes).prepared.plan.shape_to_hidden == matrix
        push!(process_admitted,measure_cycle!(owner,inputs,outputs)); check_cycle!(owner,inputs,outputs,expected,state,prior,false)
        stage_parameter!(owner,isodd(k) ? matrix_b : matrix_a)
        push!(parameter_cycle,measure_parameter_cycle!(owner,inputs,outputs)); check_cycle!(owner,inputs,outputs,expected,state,prior,false)
        stage_property!(owner,props)
        push!(property,measure_property!(owner))
        @assert only(graph.nodes).prepared.plan.gain == (isodd(k) ? 1f0 : 2f0)
        push!(process_public,measure_public_cycle!(owner,inputs,outputs)); check_cycle!(owner,inputs,outputs,expected,state,prior,false)
        stage_property!(owner,isodd(k) ? props_b : props_a)
        push!(property_cycle,measure_property_cycle!(owner,inputs,outputs)); check_cycle!(owner,inputs,outputs,expected,state,prior,false)
        push!(parameter_stage,measure_parameter_stage!(owner,matrix)); adopt_parameter!(owner)
        push!(property_stage,measure_property_stage!(owner,props)); adopt_property!(owner)
    end
    for (label,bytes) in (("parameter_adopt",parameter),("property_adopt",property),("parameter_adopt_and_full_admitted_process",parameter_cycle),("property_adopt_and_full_admitted_process",property_cycle),("full_admitted_process",process_admitted),("full_public_process",process_public),("control_parameter_staging",parameter_stage),("control_property_staging",property_stage))
        println(label," samples=",length(bytes)," bytes_min=",minimum(bytes)," bytes_max=",maximum(bytes)," bytes_sum=",sum(bytes))
    end
    println("control_after plan_gain=",only(graph.nodes).prepared.plan.gain," projection=",only(graph.nodes).prepared.plan.shape_to_hidden," correction=",outputs.correction," state=",getproperty(outputs, Symbol("controller-state"))," numerical_checks=385 passed=true")
    # Exact heterogeneous property Graph: LeakyIntegratorF32 -> AdapterFailureF32.
    hetero_graph=mktemp() do path,io
        write(io,ADAPTER_HETEROGENEOUS_PROPERTY_GRAPH); flush(io)
        prepare_graph(path;algorithms=(LeakyIntegratorF32,AdapterFailureF32))
    end
    hetero=FGPW.PreparedGraphOwner(hetero_graph)
    hin=(input=Float32[1,2],); hout=(output=zeros(Float32,2),)
    hp_a=SPA.Props("integrate:gain"=>3f0); hp_b=SPA.Props("integrate:gain"=>4f0)
    println("heterogeneous_owner_type=",typeof(hetero))
    for k in 1:32
        stage_property!(hetero,isodd(k) ? hp_a : hp_b); measure_property!(hetero)
        measure_cycle!(hetero,hin,hout)
        stage_property!(hetero,isodd(k) ? hp_b : hp_a); measure_property_cycle!(hetero,hin,hout)
    end
    hbytes=Int[]; hcbytes=Int[]; prev=copy(hout.output); h_expected=zeros(Float32,2)
    for k in 1:64
        gain=isodd(k) ? 3f0 : 4f0
        stage_property!(hetero,isodd(k) ? hp_a : hp_b)
        push!(hbytes,measure_property!(hetero))
        @assert first(hetero.graph.nodes).prepared.plan.gain == gain
        cycle!(hetero,hin,hout)
        @. h_expected=0.5f0*prev + gain*hin.input
        @assert hout.output == h_expected
        copyto!(prev,hout.output)
        gain=isodd(k) ? 4f0 : 3f0
        stage_property!(hetero,isodd(k) ? hp_b : hp_a)
        push!(hcbytes,measure_property_cycle!(hetero,hin,hout))
        @. h_expected=0.5f0*prev + gain*hin.input
        @assert hout.output == h_expected
        copyto!(prev,hout.output)
    end
    println("heterogeneous_property_adopt samples=64 bytes_min=",minimum(hbytes)," bytes_max=",maximum(hbytes)," bytes_sum=",sum(hbytes))
    println("heterogeneous_property_adopt_and_full_admitted_process samples=64 bytes_min=",minimum(hcbytes)," bytes_max=",maximum(hcbytes)," bytes_sum=",sum(hcbytes))
    println("heterogeneous_after gain=",first(hetero.graph.nodes).prepared.plan.gain," output=",hout.output," numerical_checks=128 passed=true")
    println("SUCCESS")
end
main()
