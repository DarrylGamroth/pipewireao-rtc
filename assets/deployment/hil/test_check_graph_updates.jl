using Test
include("check_graph_updates.jl")
const U = GraphUpdateReplayCheck

@testset "bounded asynchronous adoption candidates" begin
    @test U.candidate_indices(64,66,256) == 63:67
    @test U.candidate_indices(0,1,256) == 1:2
    @test U.candidate_indices(256,256,256) == 255:257
    @test_throws ArgumentError U.candidate_indices(65,64,256)
    @test_throws ArgumentError U.candidate_indices(64,257,256)
    @test_throws ArgumentError U.candidate_indices(true,66,256)
end

@testset "exact error characterization rejects nonfinite inputs" begin
    a = Float32[0,1,2]
    @test U.finite_difference(a,a).nonidentical_components == 0
    b = copy(a); b[2] = nextfloat(b[2])
    @test U.finite_difference(a,b).nonidentical_components == 1
    @test U.finite_difference(a,b).rms_difference_m > 0
    @test_throws ArgumentError U.finite_difference(Float32[NaN],Float32[0])
    @test_throws ArgumentError U.finite_difference(Float32[0],Float32[Inf])
end

@testset "native source and active-generation brackets" begin
    source(sequence) = Dict("sequence"=>sequence,"generation"=>1,"completed"=>false)
    submitted = Dict("native_token"=>1)
    adopted = Dict("native_token"=>2,"result"=>Dict{String,Any}("requested"=>2,"active"=>2))
    receipt = Dict("gain_submission"=>submitted,"gain_adoption"=>adopted,
        "requests"=>[Dict("reply"=>submitted,"source_before"=>source(64)),
            Dict("reply"=>adopted,"source_after"=>source(66))])
    candidates,bracket = U.adoption_bracket(receipt,"gain_submission","gain_adoption",256)
    @test candidates == 63:67
    @test bracket["active"] == 2
    broken = deepcopy(receipt); broken["gain_adoption"]["result"]["active"] = nothing
    @test_throws ArgumentError U.adoption_bracket(broken,"gain_submission","gain_adoption",256)
    broken = deepcopy(receipt); broken["requests"][2]["source_after"]["completed"] = true
    @test_throws ArgumentError U.adoption_bracket(broken,"gain_submission","gain_adoption",256)
    broken = deepcopy(receipt); broken["requests"][2]["source_after"]["generation"] = 2
    @test_throws ArgumentError U.adoption_bracket(broken,"gain_submission","gain_adoption",256)
end

@testset "exact global branch bounds use full errors" begin
    stats(sse) = (;squared_error_m2=Float64(sse),max_abs_difference_m=sqrt(Float64(sse)),nonidentical_components=sse == 0 ? 0 : 1)
    calls = Tuple{Int,Int}[]
    prefix(g) = Float64(g-1)
    full(g,m) = (push!(calls,(g,m));stats(g == 1 ? 5 : g == 2 ? 1.5 : 4))
    candidates,proof = U.exact_candidate_search(1:3,4:5,prefix,full;total_components=10)
    @test first(candidates).gain_frame == 2
    @test (2,4) in calls # Better prefix gain1 has worse full error.
    @test all(pair -> first(pair) != 3,calls)
    @test proof["nominal_pair_count"] == 6
    @test proof["evaluated_full_pair_count"] == 4
    @test proof["pruned_pair_count"] == 2
    @test proof["global_minimum_search_complete"]

    calls = Tuple{Int,Int}[]
    candidates,proof = U.exact_candidate_search(1:3,4:5,
        g -> g <= 2 ? 0.0 : 1.0,
        (g,m) -> (push!(calls,(g,m));stats(0));total_components=10)
    @test length(candidates) == 4
    @test proof["pruned_pair_count"] == 2
    @test all(c -> c.squared_error_m2 == 0,candidates) # Zero-error ties retained.

    candidates,proof = U.exact_candidate_search(1:2,3:3,
        g -> g == 1 ? 1.0 : nextfloat(1.0),
        (g,m) -> stats(1);total_components=10)
    @test length(candidates) == 2 # Summation guard prevents roundoff pruning.
    @test proof["pruned_pair_count"] == 0

    candidates,proof = U.exact_candidate_search(2:4,1:3,g -> 0.0,(g,m) -> stats(0);total_components=10)
    @test proof["nominal_pair_count"] == 3
    @test [(c.gain_frame,c.matrix_frame) for c in candidates] == [(2,2),(2,3),(3,3)]
    @test_throws ArgumentError U.exact_candidate_search(1:3,4:5,g -> 0.0,(g,m) -> stats(0);total_components=10,full_limit=3)
    @test_throws ArgumentError U.exact_candidate_search(1:257,1:257,g -> 0.0,(g,m) -> stats(0);total_components=10)
    @test_throws ArgumentError U.exact_candidate_search(1:1,1:1,g -> NaN,(g,m) -> stats(0);total_components=10)
end
