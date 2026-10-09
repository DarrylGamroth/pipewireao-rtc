"""Cold comparisons for the predeclared finite-corpus Copper selection policy.

Inputs are already associated, validated batch means from the deployed owner.
This module does not acquire data, choose instrument tolerances or authorize
correction. Scientific inverse construction uses public AOC through the
composition helper; selected Float32 bytes still require a locked test.
"""
module CalibrationSelection

using LinearAlgebra
include("calibration_inverse_analysis.jl")
const Inverse = CalibrationInverseAnalysis

function family_candidates(name::AbstractString, first::AbstractMatrix,
                           second::AbstractMatrix, forward::AbstractMatrix,
                           reference::AbstractVector)
    a=Inverse.finite_matrix(first,"first interaction matrix")
    b=Inverse.finite_matrix(second,"second interaction matrix")
    size(a)==size(b) || throw(DimensionMismatch("repeated interaction matrix extents"))
    coordinates=Inverse.physical_coordinates(forward)
    size(a,2)==size(forward,1) || throw(DimensionMismatch("interaction/physical map extents"))
    scale=opnorm(Inverse.reject_reference((a-b)*coordinates.basis,reference))/2
    isfinite(scale) && scale>0 || throw(ArgumentError("repeat scale must be finite and positive"))
    mean=(a+b)/2
    return [let fitted=Inverse.candidate(mean,forward,reference,
                    Inverse.Reconstructors.TSVDInverse(rtol=0,atol=multiplier*scale))
        (;name=String(name)*"-"*string(multiplier),family=String(name),multiplier,
            repeat_scale=scale,cutoff=multiplier*scale,interaction=mean,
            matrix=fitted.matrix,effective_rank=fitted.effective_rank,
            eligible_rank=fitted.effective_rank>0,
            rejected_response_frobenius=fitted.rejected_response_frobenius,
            total_response_frobenius=fitted.total_response_frobenius,
            packed_reference_command_norm=fitted.packed_reference_command_norm)
    end for multiplier in (1,2,4)]
end

function paired_inputs(figures,responses)
    q=Inverse.finite_matrix(figures,"represented physical probe figures")
    y=Inverse.finite_matrix(responses,"absolute batch means")
    size(q,1)==size(y,1) && iseven(size(q,1)) ||
        throw(DimensionMismatch("one absolute batch mean per signed probe"))
    q[1:2:end,:]==-q[2:2:end,:] ||
        throw(ArgumentError("selection requires paired absolute probes around zero physical reference"))
    return q,y
end

function score_inverse(matrix,forward,figures,responses;groups)
    q,y=paired_inputs(figures,responses)
    r=Inverse.finite_matrix(matrix,"packed inverse")
    b=Inverse.finite_matrix(forward,"physical command map")
    size(r)==(size(b,2),size(y,2)) && size(b,1)==size(q,2) ||
        throw(DimensionMismatch("inverse/physical/measurement extents"))
    prediction=permutedims(b*r*permutedims(y))
    all(isfinite,prediction) || throw(ArgumentError("nonfinite physical prediction"))
    length(unique(vcat(values(groups)...)))==sum(length,values(groups)) &&
        sort(vcat(values(groups)...))==collect(1:size(q,1)÷2) ||
        throw(ArgumentError("groups must partition signed probe pairs"))
    scores=Dict{String,NamedTuple}()
    for (name,pairs) in groups
        rows=reduce(vcat,([2*i-1,2*i] for i in pairs))
        baseline=sum(abs2,q[rows,:])
        absolute=sum(abs2,prediction[rows,:]-q[rows,:])
        signed=sum(sum(abs2,(prediction[2*i-1,:]-prediction[2*i,:])/2-q[2*i-1,:]) for i in pairs)
        scores[String(name)]=(;absolute_physical_sse=absolute,zero_command_sse=baseline,
            signed_difference_physical_sse=signed,improves_zero=baseline>0 && absolute<baseline)
    end
    return (;groups=scores,absolute_physical_sse=sum(x.absolute_physical_sse for x in values(scores)),
        zero_command_sse=sum(x.zero_command_sse for x in values(scores)),
        eligible=all(x.improves_zero for x in values(scores)))
end

function score_forward(interaction,reference,figures,responses)
    q,y=paired_inputs(figures,responses)
    d=Inverse.finite_matrix(interaction,"interaction matrix")
    size(d)==(size(y,2),size(q,2)) || throw(DimensionMismatch("forward model extents"))
    observed=permutedims((y[1:2:end,:]-y[2:2:end,:])/2)
    predicted=d*permutedims(q[1:2:end,:])
    projected_observed=Inverse.reject_reference(observed,reference)
    projected_predicted=Inverse.reject_reference(predicted,reference)
    return (;raw_signed_forward_sse=sum(abs2,predicted-observed),
        raw_zero_response_sse=sum(abs2,observed),
        projected_signed_forward_sse=sum(abs2,projected_predicted-projected_observed),
        projected_zero_response_sse=sum(abs2,projected_observed),
        removed_observed_sse=sum(abs2,observed-projected_observed))
end

"""Select by worst repeated absolute physical SSE; no failed candidate is retuned."""
function select_candidate(candidates,scores)
    length(candidates)==length(scores) || throw(DimensionMismatch("one score set per candidate"))
    eligible=findall(eachindex(candidates)) do index
        candidates[index].eligible_rank && length(scores[index])==2 &&
            all(score->score.eligible && isfinite(score.absolute_physical_sse),scores[index])
    end
    isempty(eligible) && throw(ArgumentError("no candidate passed absolute held-out utility"))
    sort!(eligible;by=index->(maximum(score.absolute_physical_sse for score in scores[index]),
        -candidates[index].cutoff,candidates[index].family))
    return first(eligible)
end

end
