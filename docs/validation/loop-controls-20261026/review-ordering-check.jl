using Test
module AOG
    struct AlgorithmGraphError <: Exception
        message::String
    end
    _node_name(reference::Pair) = first(reference)
    link(source, destination) = (; source, destination)
    # Evaluate the exact source helper without waiting for unrelated package precompilation.
    source = read("/home/dgamroth/workspaces/codex/worktrees/aos-graph-ordering-20261026/src/algorithm_graphs/preparation.jl", String)
    start = findfirst("function _node_ordinal(", source).start
    stop = findnext("@inline _validate_direct_links!", source, start).start
    include_string(@__MODULE__, source[start:prevind(source, stop)])
end

names = (:a, :b, :c)
nodes = (a=1, b=2, c=3)
permutations = ((1, 2, 3), (1, 3, 2), (2, 1, 3), (2, 3, 1), (3, 1, 2), (3, 2, 1))
@testset "independent exhaustive three-node ordering review" begin
    for mask in 0:511
        edges = [(source, destination) for source in 1:3 for destination in 1:3
            if !iszero(mask & (1 << ((source - 1) * 3 + destination - 1)))]
        # A duplicate edge exercises separate direct ports between the same nodes.
        for duplicate in (false, true)
            selected = duplicate && !isempty(edges) ? [edges; edges[1]] : edges
            links = Tuple(AOG.link(names[source] => :out, names[destination] => :in)
                for (source, destination) in selected)
            valid = filter(permutations) do order
                all(findfirst(==(source), order) < findfirst(==(destination), order)
                    for (source, destination) in edges)
            end
            if isempty(valid)
                @test_throws AOG.AlgorithmGraphError AOG._ordered_graph_nodes(nodes, links)
            else
                ordered = AOG._ordered_graph_nodes(nodes, links)
                @test values(ordered) == first(valid)
                @test keys(ordered) == map(index -> names[index], first(valid))
            end
        end
    end
end
