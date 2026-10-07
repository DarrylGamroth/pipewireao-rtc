#!/usr/bin/env julia
"""Offline numerical characterization of receipt-bracketed Copper updates.
Run with installed --project=PACKAGE/jfg/deployment and SDK on JULIA_LOAD_PATH:
  check_graph_updates.jl --package PACKAGE --receipt RECEIPT.json \
      --report simulator-result.json --output NEW_DIRECTORY
No tolerance or equivalence claim is imposed. Candidate changes happen before
processing frame indices inside a ±1 expansion of asynchronous source brackets.
"""
module GraphUpdateReplayCheck
include("check_graph_replay.jl")
const R = GraphReplayCheck
const C = R.Common
const MAX_CANDIDATES = 2048
const SCRIPT_HASH = R.digest(@__FILE__)
require(ok,message) = R.require(ok,message)

function candidate_indices(before,after,n)
    require(R.integer(before) && R.integer(after) && before <= after && after <= n,
        "invalid or unretained adoption source bracket")
    # A source cursor can identify the current or just-completed exchange.
    # Expand one frame each way and permit n+1 (outside retained prefix).
    return max(1,Int(before)-1):min(n+1,Int(after)+1)
end
function finite_difference(predicted,actual)
    require(all(isfinite,predicted) && all(isfinite,actual),"nonfinite comparison")
    return R.difference_statistics(predicted,actual)
end
function squared_error(predicted,actual)
    require(size(predicted) == size(actual) && all(isfinite,predicted) && all(isfinite,actual),"finite squared-error extent")
    value = sum(abs2,Float64.(predicted).-Float64.(actual))
    require(isfinite(value) && value >= 0,"invalid squared-error sum")
    return value
end
function candidate_statistics(predicted,actual)
    stats = finite_difference(predicted,actual)
    return (;stats...,squared_error_m2=squared_error(predicted,actual))
end

# Prefix error before the earliest possible matrix change is independent of
# matrix choice. Nonnegative remaining squared error makes it a lower bound.
# The relative guard only protects finite Float64 summation roundoff.
function exact_candidate_search(gain,matrix,prefix_error,full_error;
        total_components,prefix_limit=256,full_limit=MAX_CANDIDATES)
    require(0 < total_components <= 277*256,"invalid comparison component bound")
    require(0 < length(gain) <= prefix_limit && 0 < length(matrix) <= 257,"candidate index ranges exceed prefix bounds")
    require(all(i -> R.integer(i) && 1 <= i <= 257,gain) &&
        all(i -> R.integer(i) && 1 <= i <= 257,matrix),"invalid adoption candidate indices")
    relative_guard = 64eps(Float64)*total_components
    prefix_trials = Any[]
    nominal = 0
    for g in gain
        valid = count(m -> g <= m,matrix)
        valid == 0 && continue
        value = Float64(prefix_error(g))
        require(isfinite(value) && value >= 0,"invalid prefix lower bound")
        push!(prefix_trials,(;gain_frame=g,prefix_squared_error_m2=value,valid_matrix_candidates=valid))
        nominal += valid
    end
    require(nominal > 0,"candidate search empty")
    sort!(prefix_trials;by=p -> (p.prefix_squared_error_m2,p.gain_frame))
    evaluated = Any[]
    branches = Any[]
    upper = Inf
    pruned = 0
    for p in prefix_trials
        margin = isfinite(upper) ? relative_guard*max(p.prefix_squared_error_m2,upper) : 0.0
        skip = isfinite(upper) && p.prefix_squared_error_m2 > upper + margin
        push!(branches,(;p...,full_upper_bound_m2=isfinite(upper) ? upper : nothing,
            summation_margin_m2=margin,pruned=skip))
        if skip
            pruned += p.valid_matrix_candidates
            continue
        end
        for m in matrix
            p.gain_frame <= m || continue
            require(length(evaluated) < full_limit,"exact search requires more than $full_limit full evaluations; ambiguous branches remain")
            stats = full_error(p.gain_frame,m)
            value = stats.squared_error_m2
            require(isfinite(value) && value >= 0,"invalid full squared-error sum")
            push!(evaluated,(;gain_frame=p.gain_frame,matrix_frame=m,stats...))
            upper = min(upper,value)
        end
    end
    sort!(evaluated;by=c -> (c.squared_error_m2,c.max_abs_difference_m,c.nonidentical_components,c.gain_frame,c.matrix_frame))
    proof = Dict("nominal_pair_count"=>nominal,"evaluated_full_pair_count"=>length(evaluated),
        "prefix_trial_count"=>length(prefix_trials),"pruned_pair_count"=>pruned,
        "prefix_limit"=>prefix_limit,"full_evaluation_limit"=>full_limit,
        "relative_summation_guard"=>relative_guard,"gain_branches"=>branches,
        "global_minimum_search_complete"=>length(evaluated)+pruned == nominal,
        "proof"=>"prefix SSE before earliest matrix adoption lower-bounds every full candidate in that gain branch; prune only when prefix exceeds an actually evaluated full SSE upper bound plus Float64 summation guard; ties retained",
        "margin_scope"=>"roundoff protection only; no scientific error tolerance",
        "ranking_scope"=>"global minimum Float64 SSE and its ties certified; runner-up/top remaining entries describe evaluated candidates only",
        "ranking"=>"Float64 squared-error sum, then maximum absolute error, nonidentical components and adoption indices")
    return evaluated,proof
end

function receipt_event(receipt,reply)
    matches = filter(e -> get(get(e,"reply",Dict()),"native_token",nothing) == reply["native_token"],receipt["requests"])
    require(length(matches) == 1,"receipt native token does not identify one request")
    return only(matches)
end
function adoption_bracket(receipt,submission,adoption,n)
    before = receipt_event(receipt,receipt[submission])["source_before"]
    after = receipt_event(receipt,receipt[adoption])["source_after"]
    require(R.integer(before["generation"]) && before["generation"] > 0 &&
        R.integer(after["generation"]) && before["generation"] == after["generation"] &&
        before["completed"] === false && after["completed"] === false,"adoption bracket changed or completed source")
    result = receipt[adoption]["result"]
    require(R.integer(result["requested"]) && R.integer(result["active"]) && result["requested"] == result["active"],"adoption generation unknown or pending")
    return candidate_indices(before["sequence"],after["sequence"],n),Dict(
        "before_sequence"=>before["sequence"],"after_sequence"=>after["sequence"],
        "source_generation"=>before["generation"],"requested"=>result["requested"],"active"=>result["active"])
end

function gain!(graph,fga,node,value)
    nodes = filter(n -> n.name == Symbol(node),graph.nodes)
    require(length(nodes) == 1,"offline controller node differs from receipt")
    prepared = only(nodes).prepared
    infos = filter(info -> String(info.name) == "gain",fga.property_infos(prepared.plan))
    require(length(infos) == 1,"controller gain declaration missing")
    plan = fga.prepare_properties(prepared.plan,(fga.PropertyAssignment(only(infos).id,Float32(value)),))
    require(typeof(plan) === typeof(prepared.plan),"gain changed plan type")
    prepared.plan = plan
    return nothing
end

function replay(metadata,receipt,fga,jfg,raw_values,actual,alternate,gain_frame,matrix_frame;measure=false)
    graph = jfg.prepare_graph(metadata["diagnostic_graph"];algorithms=R.declarations(fga,metadata["algorithms"]))
    can_close = applicable(close,graph)
    try
        bindings = map(p -> Symbol(p["name"])=>R.parameter_array(p),metadata["parameters"])
        jfg.replace_parameters!(graph,bindings...)
        raw = zeros(UInt16,Tuple(metadata["frame_shape"]))
        feedback = zeros(Float32,metadata["controller_count"])
        inputs = NamedTuple{(:raw,R.FEEDBACK_IN)}((raw,feedback))
        outputs = map(format -> zeros(format.element_type,format.shape),graph.output_formats)
        R.load_frame!(raw,raw_values,1)
        require(R.complete(jfg.process!(outputs,graph,inputs)),"incomplete warmup")
        measure && R.allocated_process!(jfg.process!,outputs,graph,inputs)
        jfg.reset!(graph); fill!(feedback,0)
        predicted = similar(actual)
        requested_commands = similar(actual)
        bytes = Int[]
        per_frame = Any[]
        for sequence in axes(actual,2)
            # Preserve workspace/controller/limiter state across both changes.
            sequence == gain_frame && gain!(graph,fga,metadata["replay_controller_node"],0.0125f0)
            sequence == matrix_frame && jfg.replace_parameters!(graph,:reconstructor=>alternate)
            R.load_frame!(raw,raw_values,sequence)
            result = if measure
                count,published = R.allocated_process!(jfg.process!,outputs,graph,inputs)
                push!(bytes,count); published
            else
                jfg.process!(outputs,graph,inputs)
            end
            require(R.complete(result),"incomplete candidate frame $sequence")
            demanded = outputs.demanded
            requested = getproperty(outputs,R.REQUESTED)
            controller = getproperty(outputs,R.FEEDBACK_OUT)
            physical = getproperty(outputs,R.PHYSICAL)
            require(all(array -> all(isfinite,array),(demanded,requested,controller,physical)),"nonfinite candidate outputs")
            for actuator in axes(actual,1)
                predicted[actuator,sequence] = demanded[actuator]*R.SCALE
                requested_commands[actuator,sequence] = requested[actuator]*R.SCALE
            end
            push!(per_frame,(;sequence,finite_difference(@view(predicted[:,sequence]),@view(actual[:,sequence]))...,
                controller_constraint_feedback=R.vector_statistics(controller),
                requested_minus_demanded=R.vector_statistics(Float64.(requested).-Float64.(demanded))))
            copyto!(feedback,controller)
        end
        return (;predicted,requested_commands,per_frame,bytes,can_close)
    finally
        can_close && close(graph)
    end
end

function verify_inputs(metadata,receipt_path,receipt_hash,receipt)
    R.manifest(metadata["package"],"/opt/pipewireao")
    R.manifest(metadata["source_package"],"/opt/pipewireao")
    require(R.digest(receipt_path) == receipt_hash,"receipt changed during replay")
    for (root,key) in ((metadata["package"],""),(metadata["source_package"],"source_"))
        for (name,field) in (("deployment.conf","descriptor"),("provenance.json","provenance"),("graphs/graph.conf.in","graph"))
            require(R.digest(joinpath(root,name)) == metadata["hashes"][key*field],"installed fixture identity changed: $key$field")
        end
    end
    for (name,key) in (("Project.toml","project"),("Manifest.toml","manifest"))
        require(R.digest(joinpath(metadata["package"],"jfg/deployment",name)) == metadata["hashes"][key],"installed JFG environment changed")
    end
    require(R.digest(joinpath(metadata["source_package"],"hil/plant.toml")) == metadata["hashes"]["plant"],"source plant changed")
    for (field,key) in (("raw_path","raw"),("command_path","commands"),("report_path","report"),("diagnostic_graph","diagnostic_graph"))
        require(R.digest(metadata[field]) == metadata["hashes"][key],"replay input changed: $field")
    end
    for p in metadata["parameters"]
        require(R.digest(p["path"]) == p["sha256"],"original parameter changed")
    end
    for role in ("original","alternate")
        p = receipt["reconstructor"]
        require(R.digest(p[role*"_file"]) == p[role*"_sha256"],"receipt matrix hash differs: $role")
    end
    R.verify_script_identity(@__FILE__,SCRIPT_HASH)
    return nothing
end

function characterize(metadata,output,receipt,receipt_path,fga,jfg)
    n = metadata["frame_count"]
    require(metadata["profile"] == "copper" && metadata["source_engine"] in ("jfg","fgn"),"requires actual Copper complete CPU graph")
    source_graph = R.Deployment.decode(joinpath(metadata["source_package"],"graphs/graph.conf.in"),"/opt/pipewireao")
    replay_graph = R.Deployment.decode(metadata["diagnostic_graph"],"/opt/pipewireao")
    source_controller = R.one_node(source_graph,"closed-loop-correction-f32")["name"]
    require(source_controller == receipt["property_node"],"receipt controller differs from canonical source algorithm")
    metadata["replay_controller_node"] = R.one_node(replay_graph,"closed-loop-correction-f32")["name"]
    C.write_json(joinpath(output,"input-metadata.json"),metadata)
    require(receipt["success"] === true && receipt["package"] == metadata["source_package"],"receipt does not bind successful source package")
    require(receipt["descriptor_sha256"] == metadata["hashes"]["source_descriptor"],"source descriptor differs from receipt")
    run = receipt["run-1"]
    prefix_report = C.read_json(metadata["report_path"])
    generation = run["summary"]["acquisition_generation"]
    require(R.integer(generation) && generation > 0 &&
        prefix_report["acquisition_generation"] == generation &&
        run["native_completion"]["source"]["generation"] == generation,
        "prefix, receipt summary and native completion generations differ")
    require(run["prefix_frame_sha256"] == metadata["hashes"]["raw"] &&
        run["prefix_command_sha256"] == metadata["hashes"]["commands"],"prefix payloads differ from qualification receipt")
    reconstructor = only(filter(p -> p["name"] == "reconstructor",metadata["parameters"]))
    require(reconstructor["sha256"] == receipt["reconstructor"]["original_sha256"],"original replay matrix differs from receipt")
    alternate = R.parameter_array(Dict("path"=>receipt["reconstructor"]["alternate_file"],"shape"=>[253,3600],"element_type"=>"F32_LE"))
    require(alternate == R.parameter_array(reconstructor) .* 0.99f0,"alternate matrix is not receipt-scoped Float32 0.99 replacement")
    receipt_hash = R.digest(receipt_path)
    verify_inputs(metadata,receipt_path,receipt_hash,receipt)
    raw = R.read_values(metadata["raw_path"],UInt16,prod(metadata["frame_shape"])*n)
    actual = reshape(R.read_values(metadata["command_path"],Float32,277*n),277,n)
    brackets = Dict{String,Any}()
    gain,matrix = if receipt["qualification_mode"] == "baseline"
        ([n+1],[n+1])
    else
        require(receipt["qualification_mode"] == "updates","unknown receipt mode")
        g,brackets["gain"] = adoption_bracket(receipt,"gain_submission","gain_adoption",n)
        m,brackets["matrix"] = adoption_bracket(receipt,"parameter_submission","parameter_adoption",n)
        (g,m)
    end
    prefix_frames = min(n,minimum(matrix)-1)
    prefix_actual = @view actual[:,1:prefix_frames]
    prefix_error = g -> begin
        prefix_frames == 0 && return 0.0
        trial = replay(metadata,receipt,fga,jfg,raw,prefix_actual,alternate,g,n+1)
        squared_error(trial.predicted,prefix_actual)
    end
    full_error = (g,m) -> begin
        trial = replay(metadata,receipt,fga,jfg,raw,actual,alternate,g,m)
        candidate_statistics(trial.predicted,actual)
    end
    candidates,search = exact_candidate_search(gain,matrix,prefix_error,full_error;
        total_components=length(actual))
    search["prefix_frame_count"] = prefix_frames
    search["additional_full_replays"] = 3 # best, allocation replay, counterfactual
    best = first(candidates)
    normal = replay(metadata,receipt,fga,jfg,raw,actual,alternate,best.gain_frame,best.matrix_frame)
    measured = replay(metadata,receipt,fga,jfg,raw,actual,alternate,best.gain_frame,best.matrix_frame;measure=true)
    require(normal.predicted == measured.predicted,"allocation replay changed best trajectory")
    unchanged = replay(metadata,receipt,fga,jfg,raw,actual,alternate,n+1,n+1)
    counterfactual = Dict("scope"=>"same recorded ADC inputs and feedback carried; original gain/matrix throughout; not a live plant trajectory",
        "demanded_vs_best"=>finite_difference(unchanged.predicted,normal.predicted),
        "requested_vs_best"=>finite_difference(unchanged.requested_commands,normal.requested_commands),
        "demanded_output_distinguishes_updates"=>any(unchanged.predicted .!= normal.predicted))
    path = joinpath(output,"best.commands.f32le")
    write(path,htol.(reinterpret(UInt32,vec(normal.predicted))))
    verify_inputs(metadata,receipt_path,receipt_hash,receipt)
    exact = filter(c -> c.nonidentical_components == 0,candidates)
    tied = count(c -> c.squared_error_m2 == best.squared_error_m2 && c.max_abs_difference_m == best.max_abs_difference_m,candidates)
    result = Dict("version"=>1,"executed"=>true,"qualification_mode"=>receipt["qualification_mode"],
        "scope"=>"offline update-aware numerical characterization; no tolerance, equivalence, deadline or foreign callback allocation claim",
        "candidate_semantics"=>"gain/matrix applied before candidate frame; asynchronous submission-before to active-after source cursors expanded +/-1; n+1 means after retained prefix",
        "feedback"=>"fresh graph for each candidate; warm then reset; zero initial feedback and chronological delayed controller feedback; state retained at updates",
        "receipt_path"=>receipt_path,"receipt_sha256"=>receipt_hash,"script_sha256"=>SCRIPT_HASH,
        "input_metadata"=>metadata,"adoption_brackets"=>brackets,"candidate_count"=>length(candidates),
        "candidate_search"=>search,
        "candidate_limit"=>MAX_CANDIDATES,"top_candidates"=>candidates[1:min(10,length(candidates))],
        "best"=>best,"runner_up"=>length(candidates)>1 ? candidates[2] : nothing,
        "exact_match_count"=>length(exact),"exact_match_candidates"=>exact,
        "minimum_sse_candidate_count"=>count(c -> c.squared_error_m2 == best.squared_error_m2,candidates),
        "best_error_tie_count"=>tied,"adoption_indices_ambiguous"=>tied>1,
        "best_prediction_file"=>path,"best_prediction_sha256"=>R.digest(path),
        "best_per_frame"=>normal.per_frame,"no_update_counterfactual"=>counterfactual,
        "ordinary_process_allocations"=>Dict("per_frame_bytes"=>measured.bytes,"total_bytes"=>sum(measured.bytes),
            "max_bytes"=>maximum(measured.bytes),"allocation_free"=>all(iszero,measured.bytes),"scope"=>"separate warmed/reset best-candidate public process! only; property/matrix preparation, diagnostics and feedback copies excluded"))
    C.write_json(joinpath(output,"graph-update-replay.json"),result)
    return result
end

function main(argv=ARGS)
    options = C.cli_arguments(argv;required=["package","receipt","report","output"],defaults=(prefix="/opt/pipewireao",))
    package = realpath(options.package)
    require(Base.active_project() !== nothing && realpath(Base.active_project()) == joinpath(package,"jfg/deployment/Project.toml"),"use exact installed JFG project")
    receipt_path = realpath(options.receipt)
    receipt = C.read_json(receipt_path;maximum=32*1024*1024)
    metadata,output = R.admit(package,options.report,options.output;prefix=options.prefix)
    fga = @eval begin
        import FilterGraphAlgorithms
        FilterGraphAlgorithms
    end
    jfg = @eval begin
        import JuliaFilterGraph
        JuliaFilterGraph
    end
    return Base.invokelatest(characterize,metadata,output,receipt,receipt_path,fga,jfg)
end
end
abspath(PROGRAM_FILE) == (@__FILE__) && GraphUpdateReplayCheck.main()
