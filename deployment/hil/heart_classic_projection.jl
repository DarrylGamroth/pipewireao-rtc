"""Independent public Classic geometry and native sparse-file representation."""
module HeartClassicProjection
using SHA
"""Decode the public Classic sparse E file without changing entry values.

The qualified original format has zero-based unique coordinates and exactly
12597 Float32 entries. Duplicate coordinates or unspecified dimensions fail.
"""
function sparse_extrapolation(path)
    isfile(path) && !islink(path) && 0<filesize(path)<=4*1024*1024 || throw(ArgumentError("native sparse map exceeds its bound"))
    header=nothing;entries=0;occupied=Set{Tuple{Int,Int}}();matrix=zeros(Float32,277,277)
    for line in eachline(path)
        text=strip(line)
        (isempty(text) || startswith(text,"#")) && continue
        if startswith(text,"Sparse:")
            header===nothing || throw(ArgumentError("duplicate native sparse header"))
            fields=split(text)
            length(fields) in (4,5) || throw(ArgumentError("native sparse header differs"))
            pairs=split.(fields[2:end],'=';limit=2)
            names=first.(pairs)
            all(pair->length(pair)==2 && !isempty(last(pair)),pairs) && length(unique(names))==length(names) &&
                Set(names) in (Set(("rows","cols","nnz")),Set(("rows","cols","nnz","name"))) ||
                throw(ArgumentError("native sparse header fields differ"))
            dimensions=Dict(first(pair)=>parse(Int,last(pair)) for pair in pairs if first(pair)!="name")
            (dimensions["rows"],dimensions["cols"],dimensions["nnz"])==(277,277,12597) ||
                throw(DimensionMismatch("native sparse extrapolation extent differs"))
            header=dimensions
        else
            header!==nothing || throw(ArgumentError("native sparse entries precede header"))
            fields=split(text);length(fields)==3 || throw(ArgumentError("native sparse entry differs"))
            row,column=parse.(Int,fields[1:2]);value=parse(Float32,fields[3])
            0<=row<277 && 0<=column<277 && isfinite(value) && !((row,column) in occupied) ||
                throw(ArgumentError("invalid or duplicate native sparse coordinate"))
            entries+=1;entries<=12597 || throw(ArgumentError("native sparse entry bound exceeded"))
            push!(occupied,(row,column));matrix[row+1,column+1]=value
        end
    end
    header!==nothing && entries==12597 || throw(ArgumentError("native sparse map is incomplete"))
    return matrix
end


function read_wire(path,shape)
    isfile(path) && !islink(path) && filesize(path)==4prod(shape) || throw(ArgumentError("Classic wire matrix extent differs"))
    values=reinterpret(Float32,ltoh.(reinterpret(UInt32,read(path))))
    all(isfinite,values) || throw(ArgumentError("nonfinite Classic wire matrix"))
    return Matrix(permutedims(reshape(values,reverse(shape))))
end

"""Lift the accepted inverse through the actual one-hot full-to-active selector.

S is Tᵀ. The explicit selected rows preserve the nontrivial physical actuator
indices; this performs no pseudoinverse or fitted map conversion.
"""
function lift(R::Matrix{Float32},T::Matrix{Float32},E::Matrix{Float32},B::Matrix{Float32})
    size(R)==(221,376) && size(T)==(221,277) && size(E)==(277,277) && size(B)==(277,221) ||
        throw(DimensionMismatch("Classic selected/native geometry extents differ"))
    all(matrix->all(isfinite,matrix),(R,T,E,B)) || throw(ArgumentError("nonfinite Classic geometry"))
    indices=Int[]
    for row in 1:221
        selected=findall(==(1f0),view(T,row,:))
        length(selected)==1 || throw(ArgumentError("Classic selector must have one unit entry per controlled row"))
        index=only(selected)
        all(reinterpret(UInt32,T[row,column])==(column==index ? UInt32(0x3f800000) : UInt32(0)) for column in 1:277) ||
            throw(ArgumentError("Classic selector contains a nonunit or nonzero inactive coefficient"))
        push!(indices,index)
    end
    length(unique(indices))==221 || throw(ArgumentError("Classic selector repeats a native coordinate"))
    reinterpret(UInt32,vec(E[:,indices]))==reinterpret(UInt32,vec(B)) ||
        throw(ArgumentError("native E times the explicit selector differs from the accepted physical map"))
    padded=zeros(Float32,277,376)
    padded[indices,:]=R
    return (;padded,indices)
end
end
