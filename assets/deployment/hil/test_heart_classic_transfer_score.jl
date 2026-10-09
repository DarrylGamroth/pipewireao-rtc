using Test
include("heart_classic_transfer_score.jl")
const Score=HeartClassicTransferScore
@testset "interleaved fixed eligibility preserves inverse and exposes raw excluded residuals" begin
    active=fill(true,188);active[[86,87,102,103]].=false
    mask=repeat(active;inner=2)
    @test findall(!,mask).-1==[170,171,172,173,202,203,204,205]
    r=zeros(1,376);r[1,1]=1.0;b=ones(1,1);m=zeros(376,1);m[1,1]=1.0
    labels=Any[];figures=Vector{Float64}[];rows=Vector{Float64}[]
    for direction in (1,8,9,16)
        for (kind,slot,sign,position) in (("reference",0,0,"before"),("signed",1,1,""),("signed",2,-1,""),
            ("signed",3,-1,""),("signed",4,1,""),("reference",0,0,"after"))
            push!(labels,Dict("kind"=>kind,"direction"=>direction,"slot"=>slot,"position"=>position))
            push!(figures,[Float64(sign)])
            row=zeros(376);row[1]=sign;row[171]=10sign;push!(rows,row)
        end
    end
    y=reduce(vcat,permutedims.(rows));plan=Dict("probes"=>figures)
    result=Score.paired_losses(r,b,m,plan,y,labels,active)
    @test result["passed"]
    @test result["raw_and_projected_physical_predictions_bit_identical"]
    @test all(group->group["projected_forward_sse_detector_coordinate2"]==0 && group["raw_forward_sse_detector_coordinate2"]==200,result["paired_scores"])
    @test !Score.paired_losses(-r,b,m,plan,y,labels,active)["passed"]
    bad=copy(r);bad[1,171]=1.0
    @test_throws ArgumentError Score.paired_losses(bad,b,m,plan,y,labels,active)
    @test_throws ArgumentError Score.paired_losses(r,b,m,plan,y,labels,active[1:187])
    bady=copy(y);bady[1,1]=NaN
    @test_throws ArgumentError Score.paired_losses(r,b,m,plan,bady,labels,active)
    mktempdir() do root
        path=joinpath(root,"labels.json")
        write(path,Score.JSON3.write(labels))
        decoded=Score.document(path,Vector{Dict{String,Any}})
        @test decoded==labels
        @test Score.paired_losses(r,b,m,plan,y,decoded,active)==result
        @test_throws ArgumentError Score.document(path)
        @test_throws ArgumentError Score.paired_losses(r,b,m,plan,y,decoded[1:end-1],active)
        write(path,"{\"version\":1}")
        @test Score.document(path)==Dict("version"=>1)
        @test_throws ArgumentError Score.document(path,Vector{Dict{String,Any}})
        write(path,"[{")
        @test_throws ArgumentError Score.document(path,Vector{Dict{String,Any}})
        write(path,"[1]")
        @test_throws ArgumentError Score.document(path,Vector{Dict{String,Any}})
    end
end
