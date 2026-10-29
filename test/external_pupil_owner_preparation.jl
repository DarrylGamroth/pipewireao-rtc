using Test, PipeWireAORTC, AdaptiveOpticsSim, AdaptiveOpticsSimPipeWireHIL, Proper, PipeWireAO
using AdaptiveOpticsSim.AlgorithmGraphs
include(joinpath(@__DIR__,"external_pupil_owner_documents.jl"))
const ExternalOwner = Base.get_extension(PipeWireAORTC,:PipeWireAORTCAOSExt).ExternalPupilOwner
const Owner = PipeWireAORTC.AOSOwner

@testset "external-pupil managed owner uses independent exact exposures" begin
    mktempdir() do directory
        (;config,path) = external_pupil_owner_documents(directory)
        options = Owner.configuration(config)
        science = Owner.prepare_external_pupil_science(options)
        contracts = PipeWireAORTC.InstrumentExport.external_pupil_port_contracts(path)
        @test contracts["pupil"]["shape"] == [2,4,4]
        @test contracts["sensors"]["scc"]["shape"] == [8,8]
        @test contracts["sensors"]["scc"]["schema"] != contracts["sensors"]["llowfs"]["schema"]
        streams = ExternalOwner.stream_options(science,options.pupil_node,options.sensor_nodes)
        @test length(streams) == 3
        @test streams[1].format.rate === nothing
        @test streams[2].format.rate == SPA.Fraction(500,1)
        @test streams[3].format.rate == SPA.Fraction(250,1)
        @test Dict(streams[2].properties)["optics.central-wavelength-m"] == string(1.55e-6)
        @test streams[1].schema == contracts["pupil"]["schema"]
        C = PipeWireAORTC.Common
        E = PipeWireAORTC.InstrumentExport
        IC = PipeWireAORTC.InstrumentConfiguration
        prepared = IC.prepare_simulation_configuration!(directory)
        @test prepared["version"] == 4 && prepared["prescription_identity"] == science.identity
        reference(pointer) = Dict("\$ref"=>pointer)
        session = Dict("sources"=>[Dict("node.name"=>"optical-scc","ports"=>[
            Dict(key=>reference("/simulator/sensors/scc/"*key) for key in ("shape","element-type","schema"))])],
            "sinks"=>[Dict("node.name"=>"optical-pupil","ports"=>[
                Dict(key=>reference("/simulator/pupil/"*key) for key in ("shape","element-type","schema"))])])
        C.write_json(joinpath(directory,"session.conf"),session)
        C.write_json(joinpath(directory,"core.conf"),Dict("context.modules"=>[]))
        E.prepare_session_configuration!(directory,Dict("session"=>"session.conf","core"=>"core.conf"),[],
            "instrument.json",get(ENV,"PIPEWIREAO_PREFIX","/opt/pipewireao"))
        resolved = PipeWireAORTC.DeploymentConfiguration.decode(joinpath(directory,"session.conf"),
            get(ENV,"PIPEWIREAO_PREFIX","/opt/pipewireao"))
        @test only(only(resolved["sources"])["ports"]) == contracts["sensors"]["scc"]
        @test only(only(resolved["sinks"])["ports"]) == contracts["pupil"]
        @test !occursin("\$ref",read(joinpath(directory,"session.conf"),String))
        packet = zeros(Float32,2,4,4); packet[2,:,:] .= 1
        domain = AcquisitionDomain(ntuple(i->UInt8(i),16))
        emit = NamedTuple[]
        for sequence in UInt64(1):UInt64(2)
            receipt = (;identity=AcquisitionIdentity(domain,UInt64(1),sequence),
                pts=Int64((sequence-1)*2_000_000),duration=UInt64(2_000_000),lost_samples=UInt64(0))
            @test ExternalOwner.feed!(science.plant,packet,receipt) do name,image,metadata
                push!(emit,(;name,image=copy(image),metadata))
            end
        end
        @test count(x->x.name===:llowfs,emit) == 2
        @test count(x->x.name===:scc,emit) == 1
        @test all(x->sum(x.image)>0,emit)
        reset_external_pupil!(science.plant)
        @test science.plant.state.domain === nothing
        @test all(e->e.sequence==0 && e.covered_ns==0,values(science.plant.exposures))
    end
    @test all(id->id.name ∉ ("CUDA","AMDGPU"),keys(Base.loaded_modules))
end

@testset "finite-channel optics publish the exposure cadence" begin
    mktempdir() do directory
        (;path,physical,simulation) = external_pupil_owner_documents(directory)
        config = simulation["components"]["optics"]["config"]
        config["channels"] = [Dict("wavelength_um"=>wavelength,"weight"=>1.0,
            "steps"=>deepcopy(config["steps"])) for wavelength in (1.5,1.6)]
        for graph in values(simulation["graphs"])
            graph["nodes"] = [Dict("name"=>"optics","type"=>"proper_optical_train_f64","config"=>deepcopy(config))]
        end
        empty!(simulation["components"])
        write_external_optical_documents(directory,physical,simulation)
        science = ExternalOwner.prepare(path)
        streams = ExternalOwner.stream_options(science,"finite.pupil",(;llowfs="finite.llowfs",scc="finite.scc"))
        @test streams[1].format.rate === nothing
        @test streams[2].format.rate == SPA.Fraction(500,1)
        @test streams[3].format.rate == SPA.Fraction(250,1)
        @test all(exposure->exposure.sequence==0, values(science.plant.exposures))
    end
end

@testset "actual chopped exposures retain missing model windows at transport" begin
    mktempdir() do directory
        (;document,config,path,physical,simulation) = external_pupil_owner_documents(directory)
        physical["wavefront_sensors"]["scc"]["acquisition"]["exposure_duration_s"] = 0.01
        simulation["graphs"]["scc_unfringed"] = deepcopy(simulation["graphs"]["scc"])
        write_external_optical_documents(directory,physical,simulation)
        document["plant"]["chopping"] = Dict("scc"=>Dict("unfringed_graph"=>"scc_unfringed",
            "initial_phase"=>"fringed","trigger_high_is_fringed"=>true))
        PipeWireAORTC.Common.write_json(config,document)
        options = Owner.configuration(config)
        science = Owner.prepare_external_pupil_science(options)
        streams = ExternalOwner.stream_options(science,options.pupil_node,options.sensor_nodes)
        @test streams[2].acquisition_version==2
        @test streams[3].acquisition_version==3
        @test streams[2].format.rate == SPA.Fraction(500,1)
        @test streams[3].format.rate == SPA.Fraction(100,1)
        packet=zeros(Float32,2,4,4);packet[2,:,:].=1
        domain=AcquisitionDomain(ntuple(i->UInt8(i),16))
        emitted=NamedTuple[]
        for index in (1:5...,16:20...)
            receipt=(;identity=AcquisitionIdentity(domain,UInt64(1),UInt64(index)),
                pts=Int64((index-1)*2_000_000),duration=UInt64(2_000_000),lost_samples=UInt64(0))
            @test ExternalOwner.feed!(science.plant,packet,receipt) do name,image,metadata
                push!(emitted,(;name,metadata))
            end
        end
        scc=filter(item->item.name===:scc,emitted)
        @test getproperty.(getproperty.(scc,:metadata),:sequence)==[1,2]
        @test getproperty.(getproperty.(scc,:metadata),:pts)==[0,30_000_000]
        @test getproperty.(getproperty.(scc,:metadata),:duration)==[10_000_000,10_000_000]
        @test getproperty.(getproperty.(scc,:metadata),:chopped_image_kind)==[:fringed,:unfringed]
        @test [ExternalOwner.sensor_sequence(item.metadata,true) for item in scc]==[1,4]
        @test [ExternalOwner.trigger_state(science,:scc,item.metadata) for item in scc]==
            [ACQUISITION_TRIGGER_HIGH,ACQUISITION_TRIGGER_LOW]
        llowfs=filter(item->item.name===:llowfs,emitted)
        @test [ExternalOwner.sensor_sequence(item.metadata,false) for item in llowfs]==collect(1:10)
        reset_external_pupil!(science.plant)
        @test science.plant.state.domain===nothing
        @test all(exposure->exposure.sequence==0,values(science.plant.exposures))
    end
    @test !any(id->id.name in ("CUDA","AMDGPU"),keys(Base.loaded_modules))
end
