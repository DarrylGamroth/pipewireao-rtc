"""Cold coordinate extraction for the unchanged native floating FITS projections."""
module HeartCalibrationCoordinates
using SHA, LinearAlgebra
include("calibration_inverse_analysis.jl")
const Inverse=CalibrationInverseAnalysis

digest(path)=bytes2hex(open(sha256,path))

"""Read an unscaled primary rank-two Float32/Float64 FITS matrix as native Float32.

FITS stores its first axis consecutively. Native matrix readers consume rows
of that extent and convert floating FITS values to their Float32 MVM buffers.
Only this bounded projection-file contract is supported.
"""
function floating_matrix(path; shape, maximum_bytes=4*1024*1024)
    !islink(path) && 0 < filesize(path) <= maximum_bytes || throw(ArgumentError("linked or oversized native FITS matrix"))
    cards=Dict{String,String}()
    open(path) do io
        ended=false
        for _ in 1:cld(min(maximum_bytes,1024*1024),2880)
            block=read(io,2880)
            length(block)==2880 || throw(ArgumentError("truncated native FITS header"))
            for offset in 1:80:2880
                card=String(block[offset:offset+79]);key=strip(card[1:8])
                if key=="END"
                    ended=true;break
                elseif card[9:10]=="= " && key in ("SIMPLE","BITPIX","NAXIS","NAXIS1","NAXIS2","BSCALE","BZERO")
                    haskey(cards,key) && throw(ArgumentError("duplicate native FITS card"))
                    cards[key]=strip(first(split(card[11:end],'/')))
                end
            end
            ended && break
        end
        ended && get(cards,"SIMPLE",nothing)=="T" && get(cards,"NAXIS",nothing)=="2" || throw(ArgumentError("unsupported native FITS primary matrix"))
        get(cards,"BSCALE","1") in ("1","1.0") && get(cards,"BZERO","0") in ("0","0.0") || throw(ArgumentError("scaled native FITS matrix is unsupported"))
        columns,rows=parse(Int,cards["NAXIS1"]),parse(Int,cards["NAXIS2"])
        (rows,columns)==shape || throw(DimensionMismatch("native FITS matrix shape differs"))
        bits=parse(Int,cards["BITPIX"])
        bits in (-32,-64) || throw(ArgumentError("native FITS matrix must be floating"))
        count=Base.checked_mul(rows,columns);bytes=read(io,Base.checked_mul(count,abs(bits)÷8))
        length(bytes)==count*(abs(bits)÷8) || throw(ArgumentError("truncated native FITS payload"))
        values=bits == -32 ? reinterpret(Float32,ntoh.(reinterpret(UInt32,bytes))) :
            Float32.(reinterpret(Float64,ntoh.(reinterpret(UInt64,bytes))))
        all(isfinite,values) || throw(ArgumentError("nonfinite native FITS projection"))
        return permutedims(reshape(values,columns,rows))
    end
end

"""Compose already selected public AOC inverse policy with the actual physical map.

This returns an unaccepted negative native matrix candidate. Selection, locked
test and active native correction must be completed by their separate owners.
"""
function controller_candidate(interaction,physical_map,reference,method)
    size(physical_map)==(277,253) || throw(DimensionMismatch("native Copper command map must be 277×253"))
    fitted=Inverse.candidate(interaction,physical_map,reference,method)
    controller=-fitted.matrix
    for row in fitted.coordinates.null_coordinates
        fill!(view(controller,row,:),0.0f0)
    end
    return (;fitted,controller,controller_sign=-1,units="micrometre OPD",
        qualification="unaccepted coordinate-compatible candidate; locked test and native correction pending")
end
end
