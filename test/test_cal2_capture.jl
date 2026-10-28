using Test
Base.include(@__MODULE__,joinpath(@__DIR__,"integration","managed_session_cal2.jl"))

@testset "CAL2 capture follows the executed generated calibration selection" begin
    M = ManagedSessionCAL2
    C = M.C
    mktempdir() do component
        function selection(name, identity)
            directory=joinpath(component,name)
            mkpath(directory)
            C.write_yaml(joinpath(directory,"rtc.yaml"),Dict("calibration_identity"=>identity,
                "calibration"=>name*"/context.yaml"))
            C.write_yaml(joinpath(directory,"calibration.yaml"),Dict("calibration_identity"=>identity))
            C.write_yaml(joinpath(directory,"selection.yaml"),Dict("calibration_identity"=>identity,
                "calibration_index_sha256"=>C.sha256_file(joinpath(directory,"calibration.yaml")),
                "rtc_configuration"=>Dict("path"=>"rtc.yaml","sha256"=>C.sha256_file(joinpath(directory,"rtc.yaml")))))
            return Dict("rtc_configuration"=>name*"/rtc.yaml","calibration_identity"=>identity)
        end
        old=selection("generated/calibration","historical")
        new=selection("generated/chopped-calibration","selected")
        historical=Dict(name=>read(joinpath(component,"generated/calibration",name))
            for name in ("rtc.yaml","selection.yaml","calibration.yaml"))
        @test M.selected_calibration(component,old).calibration=="generated/calibration"
        @test M.selected_calibration(component,new).index["calibration_identity"]=="selected"
        @test M.selected_calibration(component,new).calibration=="generated/chopped-calibration"
        @test all(read(joinpath(component,"generated/calibration",name))==bytes for (name,bytes) in historical)
        for path in (nothing,2,"rtc/configuration.yaml","/generated/calibration/rtc.yaml",
                "generated/../rtc/rtc.yaml","generated/calibration/../chopped-calibration/rtc.yaml",
                "generated/rtc.yaml","generated/chopped-calibration/configuration.yaml")
            @test_throws ArgumentError M.selected_calibration(component,merge(new,Dict("rtc_configuration"=>path)))
        end
        @test_throws ArgumentError M.selected_calibration(component,Dict("calibration_identity"=>"selected"))
        @test_throws ArgumentError M.selected_calibration(component,merge(new,Dict("calibration_identity"=>"historical")))
        directory=joinpath(component,"generated/chopped-calibration")
        path=joinpath(directory,"selection.yaml")
        receipt=C.read_yaml(path)
        for bad in (merge(receipt,Dict("calibration_index_sha256"=>repeat("0",64))),
                merge(receipt,Dict("calibration_identity"=>"historical")),
                merge(receipt,Dict("rtc_configuration"=>Dict("path"=>"../calibration/rtc.yaml","sha256"=>repeat("0",64)))),
                merge(receipt,Dict("rtc_configuration"=>Dict("path"=>"rtc.yaml","sha256"=>repeat("0",64)))))
            C.write_yaml(path,bad)
            @test_throws ArgumentError M.selected_calibration(component,new)
        end
        C.write_yaml(path,receipt)
        rtcpath=joinpath(directory,"rtc.yaml")
        rtc=C.read_yaml(rtcpath)
        rtc["calibration"]="generated/calibration/context.yaml"
        C.write_yaml(rtcpath,rtc)
        receipt["rtc_configuration"]["sha256"]=C.sha256_file(rtcpath)
        C.write_yaml(path,receipt)
        @test_throws ArgumentError M.selected_calibration(component,new)
        mktempdir() do outside
            C.write_yaml(joinpath(outside,"rtc.yaml"),Dict())
            symlink(outside,joinpath(component,"generated/outside"))
            @test_throws M.D.DeploymentError M.selected_calibration(component,merge(new,Dict("rtc_configuration"=>"generated/outside/rtc.yaml")))
        end
    end
end

@testset "CAL2 capture selects a native Node by type and name" begin
    object(kind, id) = Dict("type"=>"PipeWire:Interface:"*kind,"id"=>id,
        "info"=>Dict("props"=>Dict("node.name"=>"controller")))
    node = object("Node", 12)
    objects = [object("Client", 10), object("Metadata", 11), node]
    @test ManagedSessionCAL2.capture_node(objects,"controller") === node
    @test_throws ArgumentError ManagedSessionCAL2.capture_node(objects,"absent")
    push!(objects,object("Node",13))
    @test_throws ArgumentError ManagedSessionCAL2.capture_node(objects,"controller")
    @test !any(id->id.name in ("CUDA","AMDGPU"),keys(Base.loaded_modules))
end

@testset "CAL2 cleanup observes the nested session receipt" begin
    M = ManagedSessionCAL2
    F = M.M.Faults
    mktempdir() do stage
        session=joinpath(stage,"session")
        mkpath(session)
        unit="pipewireao-session@0123456789ab.service"
        invocation=repeat("a",32)
        M.C.write_json(joinpath(session,"session.json"),Dict("unit"=>unit,"invocation"=>invocation,
            "runtime_root"=>"/run/user/1000/pipewireao-session-0123456789ab"))
        record=Dict("unit"=>unit,"invocation"=>invocation,"cleanup_complete"=>true)
        M.C.write_json(joinpath(session,"final-launch.json"),record)
        # Use the actual default retained-record reader; only live process and
        # cgroup checks are replaced for this service-free test.
        checks=record->Dict("receipt_complete"=>record["cleanup_complete"])
        @test_throws ArgumentError F.observe_cleanup!(nothing,stage;failed=true,seconds=1,read_checks=checks)
        @test F.observe_cleanup!(nothing,session;failed=true,seconds=1,read_checks=checks)==record
        evidence=M.C.read_json(joinpath(session,"observed-cleanup.json"))
        @test evidence["checks"]==Dict("receipt_complete"=>true)
        @test isempty(evidence["observation_errors"])
    end
end

@testset "CAL2 capture retains publication time and derives declared model coverage" begin
    M = ManagedSessionCAL2
    domain = M.PipeWireAO.AcquisitionDomain(ntuple(i->UInt8(i),16))
    period = Int64(500_000)
    receipt(sequence,pts) = (;identity=M.PipeWireAO.AcquisitionIdentity(domain,UInt64(1),UInt64(sequence)),
        pts=Int64(pts),duration=UInt64(period),lost_samples=UInt64(0),trigger_state=M.PipeWireAO.ACQUISITION_TRIGGER_ABSENT)
    values = zeros(Float32,2)
    samples = M.Samples((;shape=(2,)),4)
    M.record!(samples,values,receipt(1,9_000_000),period;model_time=false)
    M.record!(samples,values,receipt(2,19_000_000),period;model_time=false)
    @test getindex.(samples.records,"pts") == [9_000_000,19_000_000]
    @test getindex.(samples.records,"model_pts") == [0,period]
    @test_throws ArgumentError M.record!(samples,values,receipt(4,29_000_000),period;model_time=false)
    @test length(samples.records)==2
    model = M.Samples((;shape=(2,)),4)
    @test_throws ArgumentError M.record!(model,values,receipt(1,9_000_000),period)
    M.record!(model,values,receipt(1,0),period)
    @test_throws ArgumentError M.record!(model,values,receipt(2,2period),period)
    @test length(model.records)==1
end

@testset "CAL2 chopped controller capture accounts for one priming exposure" begin
    M = ManagedSessionCAL2
    domain = M.PipeWireAO.AcquisitionDomain(ntuple(i->UInt8(i),16))
    duration = Int64(10_000_000)
    receipt(sequence,pts) = (;identity=M.PipeWireAO.AcquisitionIdentity(domain,UInt64(1),UInt64(sequence)),
        pts=Int64(pts),duration=UInt64(duration),lost_samples=UInt64(0),trigger_state=M.PipeWireAO.ACQUISITION_TRIGGER_ABSENT)
    values = zeros(Float32,2)
    samples = M.Samples((;shape=(2,)),4)
    M.record!(samples,values,receipt(2,duration),duration;priming_exposures=1)
    M.record!(samples,values,receipt(3,2duration),duration;priming_exposures=1)
    @test getindex.(samples.records,"sequence") == [2,3]
    @test M.covered_count((;duration,priming_exposures=1),4duration)==3
    @test M.covered_count((;duration,priming_exposures=0),4duration)==4
    @test_throws ArgumentError M.record!(samples,values,receipt(5,4duration),duration;priming_exposures=1)
    @test length(samples.records)==2
    for (sequence,pts) in ((1,0),(2,0),(3,2duration))
        empty = M.Samples((;shape=(2,)),4)
        @test_throws ArgumentError M.record!(empty,values,receipt(sequence,pts),duration;priming_exposures=1)
        @test isempty(empty.records)
    end
end

@testset "CAL2 capture identifies a rejected receipt without appending it" begin
    M = ManagedSessionCAL2
    P = M.PipeWireAO
    domain = P.AcquisitionDomain(ntuple(i->UInt8(i),16))
    other = P.AcquisitionDomain(ntuple(_->UInt8(0xaa),16))
    duration = Int64(10_000_000)
    receipt(domain,generation,sequence,pts) = (;identity=P.AcquisitionIdentity(domain,UInt64(generation),UInt64(sequence)),
        pts=Int64(pts),duration=UInt64(duration),lost_samples=UInt64(0),trigger_state=P.ACQUISITION_TRIGGER_HIGH)
    samples = M.Samples((;shape=(2,)),4)
    M.record!(samples,Float32[1,2],receipt(domain,1,1,100_000_000),duration;model_time=false)
    before = deepcopy(samples)
    error = try
        M.record!(samples,Float32[3,4],receipt(other,9,4,987_654_321),duration;model_time=false,name="scc-offset")
        nothing
    catch caught
        caught
    end
    @test error isa ArgumentError
    message = sprint(showerror,error)
    @test occursin("acquisition gap or changed cohort for scc-offset",message)
    @test occursin("previous=(domain=0102030405060708090a0b0c0d0e0f10, generation=1, sequence=1, model_pts=0, duration=10000000)",message)
    @test occursin("rejected=(domain=aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa, generation=9, sequence=4, pts=987654321, duration=10000000, lost_samples=0, trigger_state=$(P.ACQUISITION_TRIGGER_HIGH), model_pts=30000000)",message)
    @test samples.records==before.records
    @test samples.first==before.first
    @test samples.last==before.last
    @test samples.history==before.history
end

@testset "CAL2 observer preserves explicit metadata negotiation" begin
    M = ManagedSessionCAL2
    contract = Dict("schema"=>"test/image/1","element-type"=>"F32_LE","shape"=>[2,2])
    mapping = Dict("sensor"=>"cal2-optics")
    raw = M.product("scc","sensor:image",contract,10_000_000,mapping;acquisition_version=3)
    @test raw.acquisition_version == 3
    @test raw.priming_exposures == 0
    ordinary = M.product("llowfs","sensor:image",contract,2_000_000,mapping)
    @test ordinary.acquisition_version == 2
    @test_throws ArgumentError M.product("invalid","sensor:image",contract,10_000_000,mapping;
        model_time=false,priming_exposures=1)
end

@testset "CAL2 post-Reset proof retains controller priming and cohort checks" begin
    M = ManagedSessionCAL2
    previous = Dict("domain"=>"a","generation"=>1,"sequence"=>8)
    current(sequence;domain="a",generation=2) = Dict("domain"=>domain,"generation"=>generation,"sequence"=>sequence)
    ordinary = (;priming_exposures=0)
    chopped = (;priming_exposures=1)
    @test M.require_reset_product(ordinary,previous,current(1)) === nothing
    @test M.require_reset_product(chopped,previous,current(2)) === nothing
    @test M.require_reset_product(chopped,previous,current(2;domain="b",generation=1)) === nothing
    @test_throws ArgumentError M.require_reset_product(chopped,previous,current(1))
    @test_throws ArgumentError M.require_reset_product(chopped,previous,current(3))
    @test_throws ArgumentError M.require_reset_product(chopped,previous,current(2;generation=1))
    @test_throws ArgumentError M.require_reset_product(ordinary,previous,current(2))
end

@testset "CAL2 observer retains and verifies actual chopped exposure classification" begin
    M = ManagedSessionCAL2
    P = M.PipeWireAO
    duration = Int64(10_000_000)
    domain = P.AcquisitionDomain(ntuple(i->UInt8(i),16))
    receipt(sequence,pts,state) = (;identity=P.AcquisitionIdentity(domain,UInt64(1),UInt64(sequence)),
        pts=Int64(pts),duration=UInt64(duration),lost_samples=UInt64(0),trigger_state=state)
    high = receipt(1,0,P.ACQUISITION_TRIGGER_HIGH)
    low = receipt(1,0,P.ACQUISITION_TRIGGER_LOW)
    samples = [M.Samples((;shape=(2,)),4) for _ in 1:2]
    for (sample,observed) in zip(samples,(high,low))
        M.record!(sample,zeros(Float32,2),observed,duration)
    end
    @test samples[1].records != samples[2].records
    @test samples[1].records[1]["trigger_state"]==string(P.ACQUISITION_TRIGGER_HIGH)
    for initial in ("fringed","unfringed"), polarity in (false,true)
        product = (;duration,chopping=Dict("initial_phase"=>initial,"trigger_high_is_fringed"=>polarity))
        firsthigh = (initial=="fringed")==polarity
        states = firsthigh ? (P.ACQUISITION_TRIGGER_HIGH,P.ACQUISITION_TRIGGER_LOW) :
            (P.ACQUISITION_TRIGGER_LOW,P.ACQUISITION_TRIGGER_HIGH)
        @test M.require_chopped_exposure(product,receipt(1,0,states[1])) === nothing
        @test M.require_chopped_exposure(product,receipt(2,duration,states[2])) === nothing
        @test_throws ArgumentError M.require_chopped_exposure(product,receipt(1,0,states[2]))
        @test_throws ArgumentError M.require_chopped_exposure(product,receipt(1,0,P.ACQUISITION_TRIGGER_MIXED))
        @test_throws ArgumentError M.require_chopped_exposure(product,receipt(1,0,P.ACQUISITION_TRIGGER_ABSENT))
    end
end
