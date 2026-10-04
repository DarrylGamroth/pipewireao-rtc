module HeartConfiguration

using YAML
using OrderedCollections: OrderedDict
import ..Common

export load_config, serialize_config, prepare_heart_configuration

# YAML's public dicttype hook preserves order and rejects duplicate/non-string
# keys during construction, before any value can be silently overwritten.
struct UniqueDict <: AbstractDict{String,Any}
    values::OrderedDict{String,Any}
end
UniqueDict() = UniqueDict(OrderedDict{String,Any}())
Base.length(value::UniqueDict) = length(value.values)
Base.iterate(value::UniqueDict, state...) = iterate(value.values, state...)
Base.getindex(value::UniqueDict, key) = value.values[key]
Base.haskey(value::UniqueDict, key) = haskey(value.values, key)
function Base.setindex!(value::UniqueDict, item, key::AbstractString)
    haskey(value, key) && throw(ArgumentError("duplicate YAML key: $key"))
    value.values[key] = item
    return value
end
Base.setindex!(::UniqueDict, _, key) = throw(ArgumentError("non-string YAML key: $key"))
materialize(value) = value
materialize(value::AbstractDict) = OrderedDict{String,Any}(key => materialize(item) for (key,item) in value)
materialize(value::AbstractVector) = materialize.(value)

function yaml_text(source)
    filesize(source) <= 16 * 1024 * 1024 || throw(ArgumentError("HEART YAML exceeds 16 MiB"))
    return replace(read(source, String), r"(?m)^[ \t]+" => indentation -> begin
        column = 0
        for character in indentation
            column += character == '\t' ? 8 - column % 8 : 1
        end
        " " ^ column
    end)
end

function normalize_aliases(text)
    aliases = Dict{String,String}()
    result = String[]
    in_aliases = false
    for line in split(text, '\n'; keepempty=true)
        occursin(r"^- ALIASES:", line) && (in_aliases = true)
        occursin(r"^- [A-Z_]+:", line) && !startswith(line, "- ALIASES:") && (in_aliases = false)
        item = in_aliases ? match(r"^\s*([A-Z_]+):\s*&", line) : nothing
        if item !== nothing
            key = item.captures[1]
            if haskey(aliases, key)
                aliases[key] == strip(line) || throw(ArgumentError("conflicting duplicate HEART alias: $key"))
                continue
            end
            aliases[key] = strip(line)
        end
        push!(result, line)
    end
    return join(result, "\n")
end

function load_document(text)
    document = materialize(YAML.load(text; dicttype=UniqueDict))
    document isa AbstractVector || throw(ArgumentError("HEART configuration must be a section list"))
    sections = OrderedDict{String,Any}()
    for entry in document
        entry isa AbstractDict && length(entry) == 1 || throw(ArgumentError("HEART section must be one mapping"))
        name, values = first(entry)
        haskey(sections, name) && throw(ArgumentError("duplicate HEART section $name"))
        values isa AbstractDict || throw(ArgumentError("HEART section $name must be a mapping"))
        sections[name] = values
    end
    return document, sections
end
load_config(source) = load_document(yaml_text(source))

function scalar(value::AbstractString)
    any(c -> Int(c) < 32 || c in ('\\','"'), value) && throw(ArgumentError("unsupported HEART string escape/control"))
    ncodeunits(value) < 128 || throw(ArgumentError("HEART scalar exceeds 128-byte buffer"))
    return "\"" * value * "\""
end
scalar(::Bool) = throw(ArgumentError("HEART scalar must not be Boolean"))
function scalar(value::Integer)
    result = string(value)
    ncodeunits(result) < 128 || throw(ArgumentError("HEART scalar exceeds 128-byte buffer"))
    return result
end
function scalar(value::AbstractFloat)
    isfinite(value) || throw(ArgumentError("HEART scalar must be finite"))
    result = string(value)
    parts = split(lowercase(result), 'e')
    if length(parts) == 2
        exponent = parse(Int, parts[2])
        negative = startswith(parts[1], "-")
        mantissa = negative ? parts[1][2:end] : parts[1]
        components = split(mantissa, '.')
        digits = join(components)
        point = length(components[1]) + exponent
        result = if point <= 0
            "0." * "0" ^ (-point) * digits
        elseif point >= length(digits)
            digits * "0" ^ (point - length(digits)) * ".0"
        else
            digits[1:point] * "." * digits[point+1:end]
        end
        negative && (result = "-" * result)
    end
    ncodeunits(result) < 128 || throw(ArgumentError("HEART scalar exceeds 128-byte buffer"))
    return result
end
scalar(value) = throw(ArgumentError("unsupported HEART scalar $(typeof(value))"))

function serialize_config(document, source)
    anchors = Dict{String,String}()
    in_aliases = false
    for line in split(yaml_text(source), '\n')
        occursin(r"^- ALIASES:", line) && (in_aliases = true)
        occursin(r"^- [A-Z_]+:", line) && !startswith(line,"- ALIASES:") && (in_aliases = false)
        item = in_aliases ? match(r"^\s*([A-Z_]+):\s*&([A-Za-z_][A-Za-z0-9_]*)\s",line) : nothing
        item === nothing || (anchors[item.captures[1]] = item.captures[2])
    end
    lines, used = ["---"], Set{String}()
    for entry in document
        name, values = first(entry)
        push!(lines, "- $name:")
        for (key,value) in values
            if name == "ALIASES"
                anchor = get(anchors,key,"classic_$key")
                occursin(r"^[A-Za-z_][A-Za-z0-9_]*$",anchor) && ncodeunits(anchor)<63 && !(anchor in used) ||
                    throw(ArgumentError("unsupported or duplicate HEART anchor $anchor"))
                value isa Real && value < 0 && throw(ArgumentError("negative HEART alias cannot be represented"))
                push!(used,anchor); push!(lines,"    $key: &$anchor $(scalar(value))")
            elseif value isa AbstractVector
                isempty(value) && throw(ArgumentError("empty HEART record array $name.$key"))
                push!(lines,"    $key: [")
                for (index,record) in enumerate(value)
                    record isa AbstractDict || throw(ArgumentError("HEART record must be a mapping"))
                    fields = join(("$field: $(scalar(item))" for (field,item) in record),", ")
                    push!(lines,"        { $fields }" * (index < length(value) ? "," : ""))
                end
                push!(lines,"    ]")
            else
                push!(lines,"    $key: $(scalar(value))")
            end
        end
    end
    push!(lines,"...")
    all(line -> ncodeunits(line)+1<1152,lines) || throw(ArgumentError("HEART configuration line exceeds native buffer"))
    output = join(lines,"\n") * "\n"
    first(load_document(output)) == document || throw(ArgumentError("HEART serialization changed values"))
    return output
end

function require_value(section, key, expected)
    get(section,key,nothing) == expected || throw(ArgumentError("unsupported HEART $key"))
    return section[key]
end
function one(section,key,index)
    values = section[key]
    length(values)==1 && get(values[1],index,nothing)==0 || throw(ArgumentError("HEART requires one $key for $index=0"))
    return values[1]
end

const CLASSIC_FILES = OrderedDict(
    "SHWFS_SUBAP_LOCATION_FILE"=>"cblueROIoffsets.csv", "BIAS_FILE"=>"wfs_dark_unscaled.fits",
    "SUBAP_THRES_FLUX"=>"threshold_1000_188.fits", "SUBAP_THRES_PIXEL"=>"calPixThresh_20.fits",
    "NCPA_GRADS_FILE"=>"slopeOffsets.fits", "SUBAP_MASK_INITIAL_FILE"=>"validSubapMask.csv",
    "GRAD_COEFF_INITIAL_FILE"=>"cBluePixelCoefs.fits", "PDM_ACTUATOR_MAP_FILE"=>"dmActuatorMap_277.csv",
    "PDM_CLIPPINGS_FILE"=>"dm_clipping_277_0.8.csv", "VDM_EXTRAPOLATION_FILE"=>"dmExtrapolationMatrixTT.sparse")

const SECTION_KEYS=Dict(
    "ADDRS"=>"BLOCK_ADDRS PERFORMANCE_MONITOR LOOP_MONITOR SRT SRT_RPG_HO SRT_OPT_HO HRT_HO_PIPE TEL_SOCKET_STREAM_BASE_ADDR TEL_SOCKET_STREAM_SRT_TO_HRT_BASE_ADDR TEL_SOCKET_STREAM_HRT_TO_SRT_BASE_ADDR",
    "CB"=>"CAPACITY TELEMETRY_SOCKET_STREAMS TELEMETRY_FILE_STREAMS",
    "GEN"=>"MODAL_CTRL GRAD_NOISE_COVARIANCE_ENABLED GRAD_NOISE_COVARIANCE_PERIOD_SEC HO_POLC LO_POLC UNCTRL_MODE_SIZE UNCTRL_MODE_GAIN WC_SHAPE_TO_UNCTRL_MODE_FILE UNCTRL_MODE_TO_WC_SHAPE_FILE UNCTRL_MODE_REMOVAL OPTICAL_GAIN_OPT_ENABLED PIXEL_THRESHOLD_OPT_ENABLED OPTICAL_GAIN_APPLICATION OPTICAL_GAIN_DITHER_INJECTION",
    "HO"=>"RECONSTRUCTED_VECT_SIZE WFS_COUNT WFS_SIZE SUBAP_TOTAL WFS_TYPE SHWFS_SUBAP_SIZE SHWFS_SUBAP_LOCATION_FILE OPTICAL_GAIN_INITIAL WFS_HARDWARE GLOBAL_NORM_FLAG BIAS_FILE SUBAP_THRES_FLUX SUBAP_THRES_PIXEL NCPA_GRADS_FILE SUBAP_MASK_INITIAL_FILE GRAD_COEFF_INITIAL_FILE SHWFS_GRAD_TYPE RECON_TYPE HO_CONTROL_MATRIX_FILE",
    "LO"=>"WFS_COUNT RECONSTRUCTED_VECT_SIZE",
    "DM"=>"PDM_COUNT PDM_SIZES VDM_COUNT VDM_SIZES PDM_DIAMETER PDM_ACTUATOR_MAP_FILE TT_COUNT PDM_HARDWARE PDM_CLIPPINGS_FILE VDM_EXTRAPOLATION_FILE PDM_TO_LO_PROJECTION_FILE PDM_SYS_FLAT_FILE PDM_OFFSETS_FILE PDM_SLEW_RATE_LIMIT",
    "TELOFF"=>"TELOFF_COUNT",
    "TFC"=>"TFC_INIT_GAIN_FILTER TFC_HO_PSD TFC_HO_TEMPORAL_FILTER TFC_LO_TEMPORAL_FILTER TFC_HO_NCPA_REF_VEC_FILEPATH",
    "SUM"=>"SUM_SYNC_TIMEOUT", "CLWC"=>"CLWC_DM_SCALAR CLWC_DM_LEAK_PARAM")
const RECORD_KEYS=Dict(
    "BLOCK_ADDRS"=>"name ipStr cmdPort port", "PERFORMANCE_MONITOR"=>"ipStr port", "LOOP_MONITOR"=>"IPSTR PORT",
    "SRT"=>"SERVER_IP SERVER_PORT RPG_IP OPT_IP", "SRT_RPG_HO"=>"WFS_NUM RECON_PORT",
    "SRT_OPT_HO"=>"WFS_NUM PIXEL_THRESHOLD_PORT OPTICAL_GAIN_PORT",
    "HRT_HO_PIPE"=>"WFS_NUM IP GRAD_COV_PORT MAX_PIXEL_PORT DITHER_AMPLITUDE_PORT",
    "TEL_SOCKET_STREAM_BASE_ADDR"=>"IPSTR PORT", "TEL_SOCKET_STREAM_SRT_TO_HRT_BASE_ADDR"=>"IPSTR PORT",
    "TEL_SOCKET_STREAM_HRT_TO_SRT_BASE_ADDR"=>"IPSTR PORT", "CAPACITY"=>"tagName capacity",
    "TELEMETRY_SOCKET_STREAMS"=>"tagName decimate pollPeriod", "TELEMETRY_FILE_STREAMS"=>"tagName decimate pollPeriod",
    "WFS_SIZE"=>"WFS_NUM ROWS COLS FIRSTROW FIRSTCOL", "SUBAP_TOTAL"=>"WFS_NUM NUM",
    "SHWFS_SUBAP_SIZE"=>"WFS_NUM ROWS COLS", "OPTICAL_GAIN_INITIAL"=>"WFS_NUM X Y",
    "WFS_HARDWARE"=>"WFS_NUM DETECTOR_TYPE CONNECTION_STR FPS EXPOSURE_TIME GAIN TRIG_TYPE",
    "PDM_SIZES"=>"PDM_NUM SIZE", "VDM_SIZES"=>"VDM_NUM SIZE SIZE_FULL NUM_OF_PDM",
    "PDM_DIAMETER"=>"PDM_NUM SIZE", "PDM_HARDWARE"=>"PDM_NUM WC_TYPE CONNECTION_STR SCALE_FACTOR BYTE_ORDER",
    "PDM_SLEW_RATE_LIMIT"=>"PDM_NUM EXISTS LIMIT_FILE INITIAL_SHAPE_FILE", "TFC_INIT_GAIN_FILTER"=>"HO LO",
    "TFC_HO_PSD"=>"EXISTS SELECTION_MATRIX_FILE NUM_PTS SEG_TO_AVG SHAPE_AVG",
    "TFC_HO_TEMPORAL_FILTER"=>"EXISTS ORDER COEFF_FILE MODAL_GAIN_FILE ZONAL_GAIN",
    "TFC_LO_TEMPORAL_FILTER"=>"EXISTS ORDER COEFF_FILE GAIN_FILE")

function validate_classic_sections(sections)
    Set(keys(sections))==union(Set(keys(SECTION_KEYS)),Set(["ALIASES"])) || throw(ArgumentError("unsupported Classic HEART section set"))
    for (name,values) in sections
        if name=="ALIASES"
            all(value->!(value isa AbstractDict || value isa AbstractVector),Base.values(values)) ||
                throw(ArgumentError("HEART aliases must be scalar"))
            continue
        end
        admitted=Set(split(SECTION_KEYS[name]))
        issubset(Set(keys(values)),admitted) || throw(ArgumentError("unknown Classic HEART key in $name"))
        for (key,value) in values
            if value isa AbstractVector
                fields=get(RECORD_KEYS,key,nothing)
                if fields===nothing && (endswith(key,"FILE") || haskey(CLASSIC_FILES,key))
                    fields=name=="HO" ? "WFS_NUM FILE" : key=="VDM_EXTRAPOLATION_FILE" ? "VDM_NUM FILE" : "PDM_NUM FILE"
                end
                fields!==nothing && !isempty(value) || throw(ArgumentError("unsupported or empty Classic record $name.$key"))
                all(record->record isa AbstractDict && !isempty(record) &&
                    issubset(Set(keys(record)),Set(split(fields))) &&
                    all(item->!(item isa AbstractDict || item isa AbstractVector),Base.values(record)),value) ||
                    throw(ArgumentError("unsupported Classic record fields $name.$key"))
            elseif value isa AbstractDict
                throw(ArgumentError("unexpected Classic mapping $name.$key"))
            end
        end
    end
end

function classic_overlay!(sections, rate)
    ho,dm,gen,tfc = (sections[key] for key in ("HO","DM","GEN","TFC"))
    for (key,value) in ("RECONSTRUCTED_VECT_SIZE"=>277,"WFS_COUNT"=>1,"WFS_TYPE"=>0,
                        "GLOBAL_NORM_FLAG"=>0,"SHWFS_GRAD_TYPE"=>0,"RECON_TYPE"=>0)
        require_value(ho,key,value)
    end
    require_value(ho,"WFS_SIZE",[Dict("WFS_NUM"=>0,"ROWS"=>352,"COLS"=>352,"FIRSTROW"=>0,"FIRSTCOL"=>0)])
    require_value(ho,"SUBAP_TOTAL",[Dict("WFS_NUM"=>0,"NUM"=>188)])
    require_value(ho,"SHWFS_SUBAP_SIZE",[Dict("WFS_NUM"=>0,"ROWS"=>22,"COLS"=>22)])
    for (key,value) in ("PDM_COUNT"=>1,"VDM_COUNT"=>1,"TT_COUNT"=>0,
        "PDM_SIZES"=>[Dict("PDM_NUM"=>0,"SIZE"=>277)],
        "VDM_SIZES"=>[Dict("VDM_NUM"=>0,"SIZE"=>277,"SIZE_FULL"=>277,"NUM_OF_PDM"=>1)])
        require_value(dm,key,value)
    end
    require_value(gen,"MODAL_CTRL",0); require_value(sections["LO"],"WFS_COUNT",0)
    require_value(sections["TELOFF"],"TELOFF_COUNT",0)
    for (key,filename) in CLASSIC_FILES
        section = haskey(ho,key) ? ho : dm
        record = one(section,key,section===ho ? "WFS_NUM" : key=="VDM_EXTRAPOLATION_FILE" ? "VDM_NUM" : "PDM_NUM")
        basename(record["FILE"])==filename || throw(ArgumentError("Classic must retain $filename"))
    end
    for key in ("HO_POLC","LO_POLC","UNCTRL_MODE_REMOVAL","GRAD_NOISE_COVARIANCE_ENABLED",
                "OPTICAL_GAIN_OPT_ENABLED","PIXEL_THRESHOLD_OPT_ENABLED","OPTICAL_GAIN_APPLICATION","OPTICAL_GAIN_DITHER_INJECTION")
        gen[key]=0
    end
    ho["HO_CONTROL_MATRIX_FILE"]=[OrderedDict("WFS_NUM"=>0,"FILE"=>"config/REVOLT2_CM_lab_20240917.fits")]
    ho["OPTICAL_GAIN_INITIAL"]=[OrderedDict("WFS_NUM"=>0,"X"=>1.0,"Y"=>1.0)]
    for (key,value) in ("WFS_STDWFS"=>1,"WFS_TRIG_SELF"=>0,"WC_STDDM"=>1)
        require_value(sections["ALIASES"],key,value)
    end
    for (name,port) in (("wfs",6000),("dmOut",6100))
        rows = filter(row -> get(row,"name",nothing)==name,sections["ADDRS"]["BLOCK_ADDRS"])
        length(rows)==1 || throw(ArgumentError("missing/duplicate HEART address $name"))
        merge!(only(rows),Dict("ipStr"=>"localhost","cmdPort"=>port,"port"=>port))
    end
    dm["PDM_SLEW_RATE_LIMIT"]=[OrderedDict("PDM_NUM"=>0,"EXISTS"=>0)]
    tfc["TFC_INIT_GAIN_FILTER"]=[OrderedDict("HO"=>-0.3,"LO"=>0.0)]
    tfc["TFC_HO_PSD"]=[OrderedDict("EXISTS"=>0)]
    tfc["TFC_HO_TEMPORAL_FILTER"]=[OrderedDict("EXISTS"=>0,"ORDER"=>2)]
    tfc["TFC_LO_TEMPORAL_FILTER"]=[OrderedDict("EXISTS"=>0,"ORDER"=>2)]
    merge!(sections["CLWC"],Dict("CLWC_DM_SCALAR"=>1.0,"CLWC_DM_LEAK_PARAM"=>0.99))
    sections["ADDRS"]["TEL_SOCKET_STREAM_SRT_TO_HRT_BASE_ADDR"]=[OrderedDict("IPSTR"=>"localhost","PORT"=>6200)]
    sections["ADDRS"]["TEL_SOCKET_STREAM_HRT_TO_SRT_BASE_ADDR"]=[OrderedDict("IPSTR"=>"localhost","PORT"=>6300)]
end

function write_offset_fits(source,destination,shape)
    bytes=read(source)
    length(bytes)==4prod(shape) || throw(ArgumentError("simulated offset payload extent mismatch"))
    values=reinterpret(Float32,bytes)
    all(isfinite,values) || throw(ArgumentError("nonfinite simulated offset"))
    cards=[("SIMPLE","T"),("BITPIX","-32"),("NAXIS",string(length(shape)))]
    append!(cards,[("NAXIS$index",string(size)) for (index,size) in enumerate(reverse(shape))])
    header=join(rpad(rpad(name,8)*"= "*lpad(value,20),80) for (name,value) in cards)*rpad("END",80)
    open(destination,"w") do io
        write(io,header); write(io,fill(UInt8(' '),mod(-ncodeunits(header),2880)))
        for value in values
            write(io,hton(reinterpret(UInt32,value)))
        end
        write(io,zeros(UInt8,mod(-length(bytes),2880)))
    end
end

function inside_root(path,root)
    relative=relpath(path,root)
    relative!=".." && !startswith(relative,"../") ||
        throw(ArgumentError("native calibration escapes its root: $path"))
    return path
end

function matrix_dimensions(path)
    cards=Dict{String,Int}()
    return open(path) do io
        for _ in 1:364
            block=read(io,2880)
            length(block)==2880 || throw(ArgumentError("incomplete HEART control-matrix FITS header"))
            for start in 1:80:2880
                card=String(block[start:start+79]); key=strip(card[1:8])
                if key=="END"
                    get(cards,"NAXIS",nothing)==2 && get(cards,"BITPIX",nothing) in (-32,-64) ||
                        throw(ArgumentError("HEART control matrix must be rank-two floating FITS"))
                    (get(cards,"NAXIS2",nothing),get(cards,"NAXIS1",nothing))==(277,376) ||
                        throw(ArgumentError("Classic HEART control matrix must be 277 by 376"))
                    filesize(path)>=position(io)+277*376*(abs(cards["BITPIX"])÷8) ||
                        throw(ArgumentError("HEART control-matrix FITS payload is truncated"))
                    return (277,376)
                end
                if card[9:10]=="= " && key in ("NAXIS","NAXIS1","NAXIS2","BITPIX")
                    haskey(cards,key) && throw(ArgumentError("duplicate control-matrix FITS card $key"))
                    cards[key]=parse(Int,strip(first(split(card[11:end],'/'))))
                end
            end
        end
        throw(ArgumentError("HEART control-matrix FITS header exceeds 1 MiB"))
    end
end

function validate_classic_calibrations(sections,root)
    ho,dm=sections["HO"],sections["DM"]
    resolve(path)=inside_root(realpath(isabspath(path) ? path : joinpath(root,path)),root)
    matrix_dimensions(resolve(one(ho,"HO_CONTROL_MATRIX_FILE","WFS_NUM")["FILE"]))
    extrapolation=resolve(one(dm,"VDM_EXTRAPOLATION_FILE","VDM_NUM")["FILE"])
    filesize(extrapolation)<=16*1024*1024 || throw(ArgumentError("Classic extrapolator exceeds bound"))
    occursin(r"(?m)^Sparse: rows=277 cols=277 nnz=12597(?:\s|$)",read(extrapolation,String)) ||
        throw(ArgumentError("Classic requires original 277 by 277 sparse extrapolator"))
    clipping=resolve(one(dm,"PDM_CLIPPINGS_FILE","PDM_NUM")["FILE"])
    filesize(clipping)<=65536 || throw(ArgumentError("Classic clipping file exceeds bound"))
    lines=split(chomp(read(clipping,String)),'\n')
    length(lines)==3 && split(lines[1])==["2","277","1","float"] || throw(ArgumentError("invalid Classic clipping dimensions"))
    for (line,expected) in zip(lines[2:end],(0.8,-0.8))
        limits=parse.(Float64,split(line,','))
        limits==fill(expected,277) || throw(ArgumentError("Classic clipping must retain 277 limits of ±0.8"))
    end
end

required_sections(::Val{:classic}) =
    ("ALIASES","ADDRS","CB","GEN","HO","LO","DM","TELOFF","TFC","SUM","CLWC")
required_sections(::Val{:copper}) =
    ("ALIASES","ADDRS","CB","GEN","HO","LO","DM","TFC","SUM","CLWC")

function prepare_heart_configuration(package,base,source,calibration_root,rate)
    rate isa Integer && !(rate isa Bool) && rate>0 || throw(ArgumentError("HEART rate must be positive integer"))
    root=realpath(calibration_root)
    provenance=Common.read_json(joinpath(base,"provenance.json"))
    instrument=provenance["profile"]
    instrument in ("classic","copper") || throw(ArgumentError("unsupported HEART instrument"))
    text=instrument=="copper" ? normalize_aliases(yaml_text(source)) : yaml_text(source)
    document,sections=load_document(text)
    for name in required_sections(Val(Symbol(instrument)))
        haskey(sections,name) || throw(ArgumentError("missing HEART section $name"))
    end
    instrument=="classic" && validate_classic_sections(sections)
    instrument=="classic" && classic_overlay!(sections,rate)
    instrument=="classic" && validate_classic_calibrations(sections,root)
    ho,dm=sections["HO"],sections["DM"]
    shape=instrument=="classic" ? [352,352] : [64,64]
    detector=one(ho,"WFS_SIZE","WFS_NUM")
    [detector["ROWS"],detector["COLS"]]==shape && ho["WFS_TYPE"]==(instrument=="classic" ? 0 : 1) ||
        throw(ArgumentError("HEART detector differs from simulated profile"))
    require_value(dm,"PDM_COUNT",1); require_value(dm,"PDM_SIZES",[Dict("PDM_NUM"=>0,"SIZE"=>277)])
    calibration=joinpath(package,"heart","calibration"); mkpath(calibration)
    generated=provenance["hil"]["simulated_calibration"]["artifacts"]
    write_offset_fits(joinpath(base,"hil",generated["background"]["path"]),joinpath(calibration,"simulated-background.fits"),shape)
    ho["BIAS_FILE"]=[OrderedDict("WFS_NUM"=>0,"FILE"=>"./config/simulated-background.fits")]
    for key in ("DARK_FILE","SKY_FILE","FLAT_FILE")
        pop!(ho,key,nothing)
    end
    if instrument=="classic"
        write_offset_fits(joinpath(base,"hil",generated["reference_slopes"]["path"]),joinpath(calibration,"simulated-references.fits"),[188,2])
    end
    ho["NCPA_GRADS_FILE"]=[OrderedDict("WFS_NUM"=>0,"FILE"=>(instrument=="classic" ? "./config/simulated-references.fits" : ""))]
    dm["PDM_SYS_FLAT_FILE"]=[OrderedDict("PDM_NUM"=>0,"FILE"=>"")]
    dm["PDM_OFFSETS_FILE"]=[OrderedDict("PDM_NUM"=>0,"FILE"=>"")]
    sections["TFC"]["TFC_HO_NCPA_REF_VEC_FILEPATH"]=""
    merge!(one(ho,"WFS_HARDWARE","WFS_NUM"),Dict("DETECTOR_TYPE"=>1,"CONNECTION_STR"=>":6000",
        "FPS"=>Float64(rate),"EXPOSURE_TIME"=>provenance["hil"]["exposure_ns"]/1e6,"GAIN"=>1.0,"TRIG_TYPE"=>0))
    merge!(one(dm,"PDM_HARDWARE","PDM_NUM"),Dict("WC_TYPE"=>1,"CONNECTION_STR"=>":6100","SCALE_FACTOR"=>1.0,"BYTE_ORDER"=>0))
    for key in ("TELEMETRY_FILE_STREAMS","TELEMETRY_SOCKET_STREAMS")
        pop!(sections["CB"],key,nothing)
    end
    retained=Dict{String,String}()
    retain_files!(sections,calibration,root,retained)
    normalized=joinpath(package,"heart","source-normalized.yaml")
    write(normalized,text)
    try
        write(joinpath(package,"heart","config.yaml.in"),serialize_config(document,normalized))
    finally
        rm(normalized)
    end
    requirements=Dict("runtime_requirements"=>runtime_requirements(instrument),"calibrations"=>retained)
    Common.write_json(joinpath(package,"heart","requirements.json"),requirements)
    return Dict("source_configuration"=>abspath(source),"source_sha256"=>Common.sha256_file(source),
        "retained_calibration"=>retained,"generated_offsets"=>generated,
        "command_convention"=>"matched numerical command interpreted as OPD; physical calibration unqualified",
        "static_offset"=>"zero simulated figure; empty native flat/offset files",
        "detector_roi"=>Dict("row"=>detector["FIRSTROW"],"column"=>detector["FIRSTCOL"]))
end

retain_files!(value,calibration,root,retained)=nothing
function retain_files!(value::AbstractVector,calibration,root,retained)
    foreach(child->retain_files!(child,calibration,root,retained),value)
end
function retain_files!(value::AbstractDict,calibration,root,retained)
    for (key,child) in value
        if (key=="FILE" || endswith(key,"_FILE") || endswith(key,"FILEPATH")) && child isa AbstractString && !isempty(child)
            target=joinpath(calibration,basename(child))
            if basename(target) in ("simulated-background.fits","simulated-references.fits")
                isfile(target) || throw(ArgumentError("missing generated HEART offset"))
            else
                original=inside_root(realpath(isabspath(child) ? child : joinpath(root,child)),root)
                isfile(original) || throw(ArgumentError("HEART calibration must be regular file"))
                if ispath(target)
                    Common.sha256_file(original)==Common.sha256_file(target) || throw(ArgumentError("native calibration basename collision"))
                else
                    cp(original,target)
                    retained[original]=Common.sha256_file(original)
                end
            end
            value[key]="./config/"*basename(target)
        else
            key=="ALIASES" || retain_files!(child,calibration,root,retained)
        end
    end
end

function runtime_requirements(instrument)
    clwc=Dict("enableClippingFeedback"=>1,"enableNotClearingIntg"=>0,"enableFigureDmVector"=>0,
        "enableDmOffset"=>0,"enableDmDisturbance"=>0,"enableDmDither"=>0,"enableLoCmdAggre"=>0,
        "enableWCOptimize"=>0,"enableUnctrlModeFeedback"=>0,"enablePOLFeedback"=>0)
    tfc=Dict("enableInHoVect"=>1,"enableOutDmErrs"=>1,"enablePOLFeedback"=>0)
    if instrument=="classic"
        merge!(clwc,Dict("enableTtOffset"=>0,"enableTtDisturbance"=>0))
        for key in ("enableLoCmdAggre","enableInLoVect","enableInLotVect","enableInHotVect","enableFieldRotation",
                    "enableLGSDefocus","enableLoOptimization","enableHoOptimization","enableKalman")
            tfc[key]=0
        end
    end
    return [Dict("block"=>"clwcBlock","control"=>"ENABLE_HRT_FLAGS","flags"=>clwc),
            Dict("block"=>"tfcBlock","control"=>"ENABLE_HRT_FLAGS","flags"=>tfc)]
end

end
