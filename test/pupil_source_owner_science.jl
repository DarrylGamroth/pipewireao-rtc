# Optional CPU graph/clock selector. No core, service, optical camera or GPU.
using Test, LinearAlgebra, PipeWireAORTC, AdaptiveOpticsSim, AdaptiveOpticsSimPipeWireHIL, PipeWireAO
using AdaptiveOpticsSim.AlgorithmGraphs
using AdaptiveOpticsSim.AlgorithmGraphs: poll_graph_output_snapshot!, snapshot_metadata,
    snapshot_values,release_graph_output_snapshot!
Base.include(@__MODULE__,joinpath(@__DIR__,"pupil_source_documents.jl"))
const Owner=PipeWireAORTC.AOSOwner
const Ext=Base.get_extension(PipeWireAORTC,:PipeWireAORTCAOSExt)
const Source=Ext.PupilSourceOwner
const Pupil=Ext.PupilOutput
const O=PipeWireAORTC.PhysicalOffsets

function completed(publisher)
    deadline=time_ns()+UInt64(10_000_000_000)
    while !poll_graph_output_snapshot!(publisher.snapshot)
        time_ns()<deadline || error("source snapshot timed out")
        yield()
    end
    return snapshot_metadata(publisher.snapshot)
end

@testset "clocked source warms without publication and owns model command chronology" begin
    mktempdir() do directory
        (;config)=pupil_source_documents(directory)
        options=Owner.configuration(config)
        science=Owner.prepare_pupil_source_science(options)
        p=science.publisher
        try
            @test science.boundary===nothing
            @test science.driver!==nothing && model_time_sequence(science.driver)==0
            @test graph_step_sequence(science.graph)==0
            @test all(iszero,science.command)
            @test p.task===nothing && !Pupil.registered(p)
            @test p.completed[]==0 && p.sequence==0
            @test !poll_graph_output_snapshot!(p.snapshot)
            properties=Ext.simulation_properties(options,science)
            @test properties["aos.simulation.graph"]=="plant"
            @test !haskey(properties,"aos.simulation.exposure-ns")
            @test Source.applied_command_option(options)===nothing
            observed=merge(options,(;applied_command_observation=true))
            applied=Source.applied_command_option(observed)
            @test applied.node_name=="simulator-primary-applied"
            @test applied.schema==PipeWireAORTC.Schemas.identifier("applied_dm_command_opd_um")
            @test applied.buffers==3 && applied.format.shape==(2,)
            @test haskey(Dict(applied.properties),PipeWireAORTC.InstrumentDefinition.MIRROR_PROPERTY)
            c=O.Calibration(;identity=options.calibration_identity,schema="physical/1",command_order=options.command_order,
                projection=Matrix{Float32}(I,2,2),inverse=Matrix{Float32}(I,2,2),modes=[1,2],
                command_limit_m=1e-6,coefficient_limit_m=1e-7,max_age_ns=20_000_000,silence_ns=1000)
            r=O.Receiver((scc=c,);command_limit_m=1e-6)
            command=zeros(Float32,2)
            # No controller/priming output: source begins at t=0 and progresses.
            @test Source.step!(science,p,r,command;generation=UInt64(1))==1
            m=completed(p)
            @test m.sequence==1 && m.model_time_ns==0 && m.generation==1
            @test all(iszero,snapshot_values(p.snapshot))
            release_graph_output_snapshot!(p.snapshot)
            @test r.clock_end_ns==2_000_000
            identity=AcquisitionIdentity(AcquisitionDomain(ntuple(i->UInt8(i),16)),UInt64(1),UInt64(0))
            O.arm!(r,:scc,identity)
            values=Float32[1e-9,0]
            @test O.accept!(r,:scc,values,AcquisitionIdentity(identity.domain,UInt64(1),UInt64(1)),Int64(0),UInt64(2_000_000);
                now_ns=UInt64(1),schema=c.schema,calibration_identity=c.identity,command_order=c.command_order)
            O.total!(command,r)
            @test Source.step!(science,p,r,command;generation=UInt64(1))==2
            m=completed(p)
            @test m.model_time_ns==2_000_000 && m.sequence==2
            @test any(!iszero,snapshot_values(p.snapshot))
            release_graph_output_snapshot!(p.snapshot)
            # A slow/unavailable serializer does not stop the model. Only its
            # acquisition snapshots are dropped, and the subsequent gap is real.
            @test Source.step!(science,p,r,command;generation=UInt64(1))==3
            @test Source.step!(science,p,r,command;generation=UInt64(1))==4
            m=completed(p)
            @test m.sequence==3 && m.model_time_ns==4_000_000
            release_graph_output_snapshot!(p.snapshot)
            @test p.dropped[]==1
            @test Source.step!(science,p,r,command;generation=UInt64(1))==5
            m=completed(p)
            @test m.sequence==5 && m.model_time_ns==8_000_000
            release_graph_output_snapshot!(p.snapshot)
            # A branch failure withdraws the held absolute command, while source
            # coverage continues independently.
            O.disarm!(r,:scc;reason=:transport)
            O.total!(command,r)
            @test all(iszero,command)
            @test Source.step!(science,p,r,command;generation=UInt64(1))==6
            completed(p)
            @test all(iszero,snapshot_values(p.snapshot))
            release_graph_output_snapshot!(p.snapshot)
            Source.reset_science!(science)
            @test model_time_sequence(science.driver)==graph_step_sequence(science.graph)==0
            @test all(iszero,science.command)
            O.disarm!(r;reason=:reset)
            r.clock_identity=nothing;r.clock_end_ns=0
            @test Source.step!(science,p,r,command;generation=UInt64(2))==1
            m=completed(p)
            @test m.sequence==1 && m.model_time_ns==0 && m.generation==2
            release_graph_output_snapshot!(p.snapshot)
            p.failed[]=true
            @test_throws ErrorException Source.step!(science,p,r,command;generation=UInt64(2))
            @test model_time_sequence(science.driver)==1
        finally
            Pupil.close!(p)
        end
    end
    @test !any(id->id.name in ("FilterGraphAlgorithms","FilterGraphPipeWire","JuliaFilterGraph","CUDA","AMDGPU"),keys(Base.loaded_modules))
end

@testset "native pupil and adopted command exports follow the selected physical source" begin
    mktempdir() do directory
        (;config,document)=pupil_source_documents(directory)
        document["applied_command_observation"]=true
        PipeWireAORTC.Common.write_json(config,document)
        PipeWireAORTC.Common.write_json(joinpath(directory,"session.conf"),Dict("sources"=>[],"links"=>[]))
        PipeWireAORTC.Common.write_json(joinpath(directory,"core.conf"),Dict("context.modules"=>[]))
        spec=Dict("session"=>"session.conf","core"=>"core.conf","source-owner"=>"plant","node-owners"=>Dict{String,String}(),
            "owners"=>[Dict("role"=>"plant","argv"=>["julia","--threads=3,0","--pupil-output-cpu","4"])])
        PipeWireAORTC.InstrumentExport.prepare_session_configuration!(directory,spec,[],"instrument.json",ENV["PIPEWIREAO_PREFIX"])
        session=PipeWireAORTC.DeploymentConfiguration.decode(joinpath(directory,"session.conf"),ENV["PIPEWIREAO_PREFIX"])
        @test Set(row["node.name"] for row in session["sources"])==Set(("simulator-pupil-output","simulator-primary-applied"))
        @test spec["node-owners"]==Dict("simulator-pupil-output"=>"plant","simulator-primary-applied"=>"plant")
        row=only(filter(row->row["node.name"]=="simulator-primary-applied",session["sources"]))
        port=only(row["ports"])
        @test port["shape"]==[2] && port["element-type"]=="F32_LE" && port["layout"]=="ROW_MAJOR"
        @test port["schema"]==PipeWireAORTC.Schemas.identifier("applied_dm_command_opd_um") && port["rate"]=="500/1"
    end
    # Exercise the exact v4 stream-options constructor without preparing optics:
    # pool selection changes transport storage, not spectral/scientific identity.
    sensor=(;image=zeros(Float32,2,3),schema="example.intensity/1",properties=Dict{String,String}())
    optical=(;pupil=(;shape=(2,4,4),schema="example.pupil/1",properties=Dict{String,String}()),
        sensors=(;llowfs=sensor,scc=sensor),chopping=(;scc=nothing))
    names=(;llowfs="llowfs",scc="scc")
    for count in (2,3,64)
        streams=Ext.ExternalPupilOwner.stream_options(optical,"pupil",names;sensor_buffers=count)
        @test first(streams).buffers==2
        @test streams[2].buffers==streams[3].buffers==count
        @test streams[2].acquisition_version==2 && streams[3].acquisition_version==3
    end
    @test !any(id->id.name in ("FilterGraphAlgorithms","FilterGraphPipeWire","JuliaFilterGraph","CUDA","AMDGPU"),keys(Base.loaded_modules))
end
