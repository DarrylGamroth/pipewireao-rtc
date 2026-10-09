# Synthetic public-format fixtures; no native code or native processing is used.
function phase_field!(bytes,offset,value)
    bytes[offset+1:offset+sizeof(value)]=reinterpret(UInt8,[value])
end
function phase_fixture_path(root,phase,tag)
    ordinal=findfirst(==(phase),(:startup_run,:correcting,:restore_run))
    state=phase===:correcting ? "CORRECTING" : "RUNNING"
    return joinpath(root,"2026-10-04_00-00-00_$(tag)_$(state)_20261004T00000$(ordinal).000000.tel")
end
function phase_fixture_file(root,phase,tag,datatype,shape,frames;empty=false,science=false,active=nothing)
    rows,columns=shape;element=datatype==7 ? 2 : datatype==13 ? 16 : 4
    payload=cld(rows*columns*element,64)*64
    count=empty ? 0 : phase===:correcting ? frames : tag=="cbDmCmd0" ? 1 : 0
    start=phase===:startup_run ? 0 : phase===:correcting ? (tag=="cbDmCmd0" ? 1 : 0) : tag=="cbDmCmd0" ? frames+1 : frames
    header=zeros(UInt8,1024);header[1:ncodeunits(tag)]=codeunits(tag)
    for (offset,value) in ((32,Float64(element)),(40,Int32(datatype)),(48,UInt32(rows)),(52,UInt32(columns)),
        (56,UInt32(payload)),(128,UInt64(start)),(136,UInt64(start+count)),(144,UInt64(count)))
        phase_field!(header,offset,value)
    end
    path=phase_fixture_path(root,phase,tag)
    open(path,"w") do io
        write(io,header)
        for index in 1:count
            record=zeros(UInt8,64+payload)
            sync=tag=="cbClUnclipped0" ? 0 : phase===:startup_run ? 0 : phase===:restore_run ? frames : index
            for (offset,value) in ((0,Int64(tag=="cbHoPixelsCalib0" ? 0 : 1)),(16,UInt64(start+index-1)),
                (32,Int16(2)),(34,UInt16(2)),(44,UInt32(sync)))
                phase_field!(record,offset,value)
            end
            if datatype==13
                active!==nothing && length(active)==rows || error("Classic fixture requires explicit eligibility")
                for subap in 1:rows
                    phase_field!(record,64+16(subap-1),Int32(active[subap] ? 1 : -1))
                    phase_field!(record,64+16(subap-1)+12,1001f0)
                end
            end
            science && tag=="cbHoPixelsRaw0" && phase_field!(record,64,UInt16(1))
            science && tag=="cbHoGrad0" && index>1 && phase_field!(record,datatype==13 ? 68 : 64,Float32(1))
            write(io,record)
        end
    end
    return path
end
function phase_fixture_set(root,streams,phase,frames;kwargs...)
    return Dict(tag=>phase_fixture_file(root,phase,tag,datatype,shape,frames;kwargs...) for (tag,datatype,shape) in streams)
end
