module PipeWireAORTCOffsetsExt

using PipeWireAO
import PipeWireAORTC
import AdaptiveOpticsSimPipeWireHIL as HIL
import FilterGraphAlgorithms as FGA
import FilterGraphPipeWire as FGP
import JuliaFilterGraph as JFG
using SHA
import ThreadPinning
const Offsets = PipeWireAORTC.PhysicalOffsets
const Common = PipeWireAORTC.Common
const Artifacts = PipeWireAORTC.Artifacts

# Single frame writer, bounded seqlock readers, all payload fields atomic.
# No image/command data is copied by this observer.
mutable struct ModelClock
    @atomic version::UInt64
    @atomic domain_low::UInt64
    @atomic domain_high::UInt64
    @atomic generation::UInt64
    @atomic sequence::UInt64
    @atomic pts::Int64
    @atomic duration::UInt64
    @atomic valid::Bool
    @atomic reset_generation::UInt64
    ModelClock() = new(0,0,0,0,0,0,0,false,0)
end
struct ClockObserver{O,N}
    clock::ModelClock
    next::N
end
function (observer::ClockObserver{O})(::Val{:frame},outputs,metadata) where O
    observer.next === nothing || observer.next(Val(:frame),outputs,metadata)
    clock=observer.clock
    @atomic clock.version += UInt64(1)
    admitted=getproperty(metadata,O)
    valid=admitted.present
    if valid
        m=admitted.value
        valid=m.has_timestamp && m.has_exposure_duration && m.has_acquisition_identity &&
            !m.corrupted && !m.discontinuity && m.timestamp_nanoseconds>=0 &&
            m.exposure_duration_nanoseconds>0
        if valid
            identity=m.acquisition_identity
            domain=identity.domain
            low=UInt64(0);high=UInt64(0)
            for i in 1:8
                low |= UInt64(domain[i]) << (8(i-1))
                high |= UInt64(domain[i+8]) << (8(i-1))
            end
            @atomic clock.domain_low=low
            @atomic clock.domain_high=high
            @atomic clock.generation=identity.generation
            @atomic clock.sequence=identity.sequence
            @atomic clock.pts=m.timestamp_nanoseconds
            @atomic clock.duration=m.exposure_duration_nanoseconds
        end
    end
    @atomic clock.valid=valid
    @atomic clock.version += UInt64(1)
    return nothing
end
function (observer::ClockObserver)(event::Union{Val{:reset},Val{:invalidated}})
    observer.next === nothing || observer.next(event)
    @atomic observer.clock.version += UInt64(1)
    @atomic observer.clock.valid=false
    event isa Val{:reset} && (@atomic observer.clock.reset_generation += UInt64(1))
    @atomic observer.clock.version += UInt64(1)
    return nothing
end
function clock_sample(clock)
    for _ in 1:3
        before=@atomic clock.version
        isodd(before) && continue
        low=@atomic clock.domain_low
        high=@atomic clock.domain_high
        generation=@atomic clock.generation
        sequence=@atomic clock.sequence
        pts=@atomic clock.pts
        duration=@atomic clock.duration
        valid=@atomic clock.valid
        reset_generation=@atomic clock.reset_generation
        after=@atomic clock.version
        before==after && !isodd(after) || continue
        valid || return (;version=after,valid=false,reset_generation)
        domain=AcquisitionDomain(ntuple(i->UInt8((i<=8 ? low>>(8(i-1)) : high>>(8(i-9))) & 0xff),16))
        return (;version=after,valid=true,reset_generation,identity=AcquisitionIdentity(domain,generation,sequence),pts,duration)
    end
    return nothing
end

function configuration(path)
    filesize(path)<=65536 || throw(ArgumentError("physical offsets configuration exceeds64KiB"))
    d=Common.read_yaml(path)
    required=Set(("version","parameter","algorithm","clock_output","command_limit_m","projection","inverse",
        "calibration_identity","command_order","branches","reference","reference_sign"))
    d isa AbstractDict && Set(keys(d))==required && d["version"]===1 ||
        throw(ArgumentError("invalid physical offsets configuration"))
    for key in ("parameter","algorithm","clock_output")
        d[key] isa String && occursin(r"^[a-zA-Z0-9_.-]{1,128}$",d[key]) ||
            throw(ArgumentError("invalid physical offsets $key"))
    end
    rows=d["branches"]
    rows isa AbstractDict && 1<=length(rows)<=8 && all(name -> name isa String && occursin(r"^[a-zA-Z0-9_.-]{1,128}$",name),keys(rows)) || throw(ArgumentError("physical offsets require1:8branches"))
    return d
end
function Offsets.frame_observer(path::AbstractString,prior,formats::NamedTuple)
    d=configuration(path)
    hasproperty(formats,Symbol(d["clock_output"])) || throw(ArgumentError("physical offset clock output is absent"))
    return ClockObserver{Symbol(d["clock_output"]),typeof(prior)}(ModelClock(),prior)
end
function matrix(path,selection)
    selection isa AbstractDict && Set(keys(selection))==Set(("path","sha256","axes","shape")) ||
        throw(ArgumentError("physical projection requires path,sha256,axes,shape"))
    file=PipeWireAORTC.DeploymentConfiguration.relative_asset(dirname(abspath(path)),selection["path"])
    hash=selection["sha256"]
    hash isa String && occursin(r"^[a-f0-9]{64}$",hash) ||
        throw(ArgumentError("invalid physical projection content hash"))
    artifact=Artifacts.FITSArtifact(file;axes=selection["axes"])
    prepared=Artifacts.prepare(artifact,Float32,selection["shape"])
    prepared.provenance["original_sha256"]==hash || throw(ArgumentError("physical projection content hash mismatch"))
    prepared.data isa AbstractMatrix || throw(ArgumentError("physical projection must be a matrix"))
    return prepared.data
end

function Offsets.prepare(path::AbstractString,graph)
    d=configuration(path)
    P,Q,C=matrix(path,d["projection"]),matrix(path,d["inverse"]),matrix(path,d["reference"])
    index=findfirst(n->n.name===Symbol(d["algorithm"]),graph.nodes)
    index===nothing && throw(ArgumentError("physical offset algorithm is absent"))
    plan=graph.nodes[index].prepared.plan
    plan isa FGA.PhysicalOffsetReferencePlan && plan.physical_to_modes==Q && plan.modes_to_reference==C &&
        d["reference_sign"] in (-1,1) && !(d["reference_sign"] isa Bool) && plan.reference_sign==d["reference_sign"] ||
        throw(ArgumentError("physical offset graph calibration or sign differs from bound artifacts"))
    bindings=graph.parameter_routes
    port=Symbol(d["parameter"])
    hasproperty(bindings,port) && getproperty(bindings,port) isa JFG.ParameterInput{index,:offset} ||
        throw(ArgumentError("physical offset parameter must bind exactly the declared algorithm offset"))
    all(iszero,plan.offset) || throw(ArgumentError("physical offsets must start at zero"))
    names=Tuple(Symbol.(sort!(collect(keys(d["branches"])))))
    calibrations=map(names) do name
        row=d["branches"][string(name)]
        required=Set(("node_name","schema","modes","command_limit_m","coefficient_limit_m","max_age_ns","silence_ns"))
        row isa AbstractDict && required ⊆ Set(keys(row)) ⊆ union(required,Set(("acquisition_version",))) ||
            throw(ArgumentError("invalid physical offset branch fields"))
        version=get(row,"acquisition_version",2)
        version isa Integer && !(version isa Bool) && version in (2,3) ||
            throw(ArgumentError("physical offset acquisition_version must be 2 or 3"))
        Offsets.Calibration(;identity=d["calibration_identity"],schema=row["schema"],command_order=d["command_order"],
            projection=P,inverse=Q,modes=row["modes"],command_limit_m=row["command_limit_m"],
            coefficient_limit_m=row["coefficient_limit_m"],max_age_ns=row["max_age_ns"],silence_ns=row["silence_ns"])
    end
    receiver=Offsets.Receiver(NamedTuple{names}(calibrations);command_limit_m=d["command_limit_m"])
    options=map(names) do name
        row=d["branches"][string(name)]
        HIL.PipeWireArrayStreamOptions(;node_name=row["node_name"],media_name=string(name)*" physical offset",
            acquisition_version=get(row,"acquisition_version",2),
            schema=row["schema"],format=NdArrayFormat(NdArray.F32_LE,(size(P,1),);layout=NdArray.ROW_MAJOR))
    end
    buffers=map(_->zeros(Float32,size(P,1)),names)
    total=zeros(Float32,size(P,1))
    return (;declaration=d,receiver,names,calibrations,options=Tuple(options),buffers,total)
end

function Offsets.with_receiver(f,prepared::NamedTuple;node,remote,frame_clock::ClockObserver,clock=time_ns)
    Threads.nthreads(:default)>=3 || throw(ArgumentError("physical offset receiver requires three default threads; thread3 owns admission"))
    (;receiver,names,calibrations,options,buffers,total)=prepared
    d=prepared.declaration
    stop=Threads.Atomic{Bool}(false)
    HIL.with_array_streams(Tuple(options);remote,input=ntuple(_->true,length(names))) do transport
        initial=trues(length(names));rejected=zeros(UInt64,length(names))
        submitted_revision=typemax(UInt64);clock_version=UInt64(0);reset_generation=UInt64(0)
        pump=ThreadPinning.@spawnat 3 try
            while !stop[]
                sample=clock_sample(frame_clock.clock)
                if sample!==nothing && sample.version!=clock_version
                    clock_version=sample.version
                    reset = sample.reset_generation!=reset_generation
                    if reset
                        reset_generation=sample.reset_generation
                        Offsets.disarm!(receiver;reason=:reset)
                        receiver.clock_identity=nothing
                        receiver.clock_end_ns=0
                        fill!(initial,true)
                        for i in eachindex(names)
                            HIL.reset_pipewire_array!(transport,i)
                            rejected[i]=0
                        end
                    end
                    if sample.valid
                        previous=receiver.clock_identity
                        Offsets.observe_clock!(receiver,sample.identity,sample.pts,sample.duration)
                        if previous!==nothing && !Offsets.same_cohort(previous,sample.identity)
                            fill!(initial,false)
                        end
                    elseif !reset
                        Offsets.disarm!(receiver;reason=:upstream_clock)
                        fill!(initial,false)
                    end
                end
                status=FGP.parameter_status(node,Symbol(d["algorithm"]))
                if status.closure_inhibited
                    Offsets.disarm!(receiver;reason=:protective_recovery)
                    fill!(initial,false)
                end
                for i in eachindex(names)
                    name=names[i]
                    wire_status=HIL.array_stream_status(transport,i)
                    state = if wire_status.failed
                        nothing
                    else
                        try
                            HIL.with_array_stream(transport,i) do stream
                                stream_state(stream)
                            end
                        catch error
                            error isa PipeWireAO.PipeWireError || rethrow()
                            nothing
                        end
                    end
                    if state===nothing || wire_status.failed || wire_status.rejected!=rejected[i] ||
                            (receiver.branches[name].present && state!=PipeWireAO.LibPipeWire.PW_STREAM_STATE_STREAMING)
                        Offsets.disarm!(receiver,name;reason=:transport)
                        initial[i]=false
                    end
                    rejected[i]=wire_status.rejected
                    receipt=HIL.drain_pipewire_array!(buffers[i],transport,i)
                    receipt===nothing && continue
                    if initial[i] && receiver.clock_identity!==nothing && !status.closure_inhibited
                        identity=receipt.identity
                        previous=receiver.branches[name].identity
                        # Reset flushes retained pools, and a new acquisition
                        # cohort fences any older in-flight publication.
                        if previous!==nothing && identity.domain==previous.domain && identity.generation<=previous.generation
                            continue
                        end
                        Offsets.arm!(receiver,name,AcquisitionIdentity(identity.domain,identity.generation,0))
                        initial[i]=false
                    end
                    Offsets.accept!(receiver,name,buffers[i],receipt.identity,receipt.pts,receipt.duration;
                        now_ns=clock(),schema=calibrations[i].schema,
                        calibration_identity=d["calibration_identity"],command_order=d["command_order"])
                end
                Offsets.expire!(receiver,clock())
                if receiver.revision!=submitted_revision
                    Offsets.total!(total,receiver)
                    try
                        FGP.replace_parameters!(node,Symbol(d["parameter"])=>total;supersede=true)
                        submitted_revision=receiver.revision
                    catch error
                        error isa InvalidStateException && error.state in (:busy,:inhibited) || rethrow()
                        # Keep only the current desired value; pending adoption is
                        # not acknowledgement and cannot renew branch freshness.
                    end
                end
                @ccall gc_safe=true usleep(Cuint(1000)::Cuint)::Cint
                yield()
            end
        catch
            # Receiver failure must stop the native graph owner, not silently
            # leave its last contribution adopted indefinitely.
            quit!(node)
            rethrow()
        end
        try
            return f()
        finally
            stop[]=true
            wait(pump)
        end
    end
end

end
