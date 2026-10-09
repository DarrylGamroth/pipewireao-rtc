"""Exact native flag contracts for the qualified normal correction profiles."""
module HeartCorrectionFlags

const COPPER=Set(vcat(
    [("CLWFC",name,value) for (name,value) in (("enableClippingFeedback",1),("enableNotClearingIntg",0),
        ("enableFigureDmVector",0),("enableDmOffset",0),("enableDmDisturbance",0),("enableDmDither",0),
        ("enableLoCmdAggre",0),("enableWCOptimize",0),("enableUnctrlModeFeedback",0),("enablePOLFeedback",0))],
    [("TFC",name,value) for (name,value) in (("enableInHoVect",1),("enableOutDmErrs",1),("enablePOLFeedback",0))]))
const CLASSIC=union(COPPER,Set(vcat(
    [("CLWFC",name,0) for name in ("enableTtOffset","enableTtDisturbance")],
    [("TFC",name,0) for name in ("enableKalman","enableHoOptimization","enableLoCmdAggre",
        "enableFieldRotation","enableLGSDefocus","enableInHotVect","enableInLotVect","enableInLoVect","enableLoOptimization")])))

function required_flags(profile::Symbol)
    profile===:copper && return copy(COPPER)
    profile===:classic && return copy(CLASSIC)
    throw(ArgumentError("unsupported native correction flag profile"))
end

field(row::AbstractDict,key)=row[String(key)]
field(row,key)=getproperty(row,key)
function validate_flags(rows,profile::Symbol)
    flags=Tuple{String,String,Int}[]
    for row in rows
        section,name,value=field(row,:section),field(row,:field),field(row,:value)
        section isa AbstractString && name isa AbstractString && value isa Integer && !(value isa Bool) ||
            error("native correction flag representation differs")
        push!(flags,(String(section),String(name),Int(value)))
    end
    expected=required_flags(profile)
    length(flags)==length(expected) && Set(flags)==expected || error("native correction flags omit or alter a required profile condition")
    return nothing
end

end
