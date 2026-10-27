using FilterGraphAlgorithms, JuliaFilterGraph, FilterGraphPipeWire
cases = (
    ("Classic", "/home/dgamroth/workspaces/codex/adaptive-optics-simulations/revolt-classic/rtc/graph.conf",
        (Symbol("pdm-command"),)),
    ("GPI2", "/home/dgamroth/.local/state/pipewireao/gpi2-loop-controls-live-20261026/session/installed/rtc/graph.conf",
        (Symbol("modal-filter"), Symbol("tiptilt-filter"), Symbol("tiptilt-command"), Symbol("woofer-command"), Symbol("tweeter-command"))),
)
for (name,path,participants) in cases
    try
        start=time_ns()
        graph=prepare_graph(path; algorithms=algorithms())
        owner=FilterGraphPipeWire.PreparedGraphOwner(graph,nothing;
            feedback=Symbol("constraint-feedback")=>Symbol("controller-constraint-feedback"))
        scope=prepare_recovery(owner; controller=Symbol("closed-loop-correction"),
            participants,reference_timeout_ms=60000)
        required=Tuple(node.name for (node,yes) in zip(graph.nodes,scope.feedback_required) if yes)
        println(name," accepted nodes=",length(graph.nodes)," participants=",participants,
            " feedback_zero_required=",required," reference_supported=",scope.reference_supported,
            " elapsed_s=",(time_ns()-start)/1e9)
    catch error
        println(name," BLOCKED: ",sprint(showerror,error))
    end
end
