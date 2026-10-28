using Test, PipeWireAORTC, PipeWireAO
Base.include(@__MODULE__,joinpath(@__DIR__,"external_pupil_owner_documents.jl"))
const E=PipeWireAORTC.InstrumentExport
const C=PipeWireAORTC.Common
const D=PipeWireAORTC.DeploymentConfiguration
const Calibration=PipeWireAORTC.InstrumentCalibration
const PREFIX=PipeWireAO.LibPipeWire.PipeWireAO_jll.artifact_dir

@testset "accepted branch calibration materialization preserves authored recipe" begin
    mktempdir() do temporary
        source=joinpath(temporary,"source");mkpath(source)
        fixture=external_pupil_owner_documents(source)
        recipe=Dict("kind"=>"relative-intensity-optical","optical_simulation"=>"simulation/definition.yaml")
        mkpath(joinpath(source,"calibration"))
        C.write_yaml(joinpath(source,"calibration/optical.yaml"),recipe)
        graphs=Dict(name=>"rtc/"*name*".conf" for name in ("llowfs","scc"))
        graph=Dict("filter.graph"=>Dict("nodes"=>[]))
        for path in values(graphs);C.write_json(joinpath(source,path),graph);end
        entry(path)=Dict("path"=>path,"sha256"=>C.sha256_file(joinpath(source,path)))
        C.write_yaml(joinpath(source,"provenance.yaml"),Dict("sources"=>[entry("instrument.yaml")],
            "graphs"=>[],"execution"=>entry("simulation/definition.yaml")))
        built=joinpath(temporary,"built");cp(source,built)
        for path in ("session.conf","core.conf","client.conf");C.write_json(joinpath(built,path),Dict());end
        placement=Dict(role=>Dict("cpus"=>[2],"leader-cpu"=>2,"rt-priority"=>0,
            "threads"=>[],"locked-bytes"=>0) for role in ("core","rtc"))
        C.write_json(joinpath(built,"deployment.conf"),Dict("version"=>1,"name"=>"calibration-fixture",
            "session"=>"session.conf","core"=>"core.conf","client"=>Dict(role=>"client.conf" for role in keys(placement)),
            "placement"=>placement,"owners"=>[],"environment"=>Dict(),"artifacts"=>Dict(),"cpu-latency-us"=>nothing))
        E.seal!(built)
        results=joinpath(temporary,"results");mkpath(results)
        identity="sha256:"*repeat("c",64)
        reports=Dict{String,Any}()
        for name in keys(graphs)
            diagnostics=Dict("selection-mask"=>trues(2,2),"physical-to-modes"=>ones(Float32,2,2))
            maskpath=joinpath(temporary,name*"-mask.fits");Calibration.write_fits(maskpath,trues(2,2))
            context=Dict("pixel_selection_mask"=>Dict("kind"=>"fits","path"=>"artifacts/selection-mask.fits",
                "sha256"=>C.sha256_file(maskpath),"hdu"=>1,"axes"=>[2,1],"shape"=>[2,2],"type"=>"Bool","storage_order"=>"row-major"))
            report=Dict("recipe"=>recipe,"recipe_sha256"=>C.sha256_file(joinpath(built,"calibration/optical.yaml")),
                "source_prescription_identity"=>fixture.document["prescription_identity"],
                "source_graph_sha256"=>C.sha256_file(joinpath(built,"simulation/definition.yaml")),
                "status"=>"accepted","built_application_calibration"=>true,"application_accepted"=>false,
                "deployable"=>true,"diagnostic"=>false,
                "command_count"=>2,
                "held_out"=>Dict("accepted"=>true),"calibration_identity"=>identity,"branch"=>name,
                "branches"=>Dict(name=>Dict("accepted"=>true)))
            reports[name]=Calibration.write_bundle(joinpath(results,name),report,context,graph,
                Dict("command-projection"=>ones(Float32,2,2));diagnostics)
        end
        shared=Dict(name=>Dict("path"=>"llowfs/artifacts/"*name*".fits",
            "sha256"=>reports["llowfs"]["artifact_sha256"][name*".fits"])
            for name in ("command-projection","physical-to-modes"))
        C.write_yaml(joinpath(results,"calibration.yaml"),Dict("version"=>1,"kind"=>"optical-calibration-index",
            "calibration_identity"=>identity,"physical_projection"=>shared,"branches"=>Dict(name=>Dict("path"=>name,
                "result_sha256"=>C.sha256_file(joinpath(results,name,"result.yaml"))) for name in keys(graphs))))
        recipehash=C.sha256_file(joinpath(source,"calibration/optical.yaml"))
        options=(;graphs,prefix=PREFIX,provenance="provenance.yaml")
        # Rejected numerical evidence must not create a generated selection.
        invalid=joinpath(temporary,"invalid");cp(results,invalid)
        write(joinpath(invalid,"llowfs/result.yaml"),"status: rejected\n")
        @test_throws ArgumentError E.materialize_calibration(source,built,invalid;options...)
        @test !ispath(joinpath(source,"generated/calibration"))
        rejected=joinpath(temporary,"rejected");cp(results,rejected)
        rejected_report=C.read_yaml(joinpath(rejected,"llowfs/result.yaml"))
        rejected_report["status"]="rejected"
        C.write_yaml(joinpath(rejected,"llowfs/result.yaml"),rejected_report)
        rejected_index=C.read_yaml(joinpath(rejected,"calibration.yaml"))
        rejected_index["branches"]["llowfs"]["result_sha256"]=C.sha256_file(joinpath(rejected,"llowfs/result.yaml"))
        C.write_yaml(joinpath(rejected,"calibration.yaml"),rejected_index)
        @test_throws ArgumentError E.materialize_calibration(source,built,rejected;options...)
        @test !ispath(joinpath(source,"generated/calibration"))
        authored_bytes=read(joinpath(source,"rtc/configuration.yaml"))
        output=E.materialize_calibration(source,built,results;options...)
        @test C.sha256_file(joinpath(source,"calibration/optical.yaml"))==recipehash
        @test read(joinpath(source,"rtc/configuration.yaml"))==authored_bytes
        selected_rtc=joinpath(output,"rtc.yaml")
        @test C.read_yaml(selected_rtc)["calibration_identity"]==identity
        @test C.read_yaml(selected_rtc)["calibration"]=="generated/calibration/context.yaml"
        @test C.read_yaml(selected_rtc)["instrument"]=="../../instrument.yaml"
        @test C.read_yaml(joinpath(output,"context.yaml"))["pixel_selection_mask"]["path"]=="llowfs/artifacts/selection-mask.fits"
        @test C.sha256_file(joinpath(output,"scc/result.yaml"))==C.sha256_file(joinpath(results,"scc/result.yaml"))
        @test C.read_yaml(joinpath(output,"selection.yaml"))["application_accepted"]===false
        zero=C.read_yaml(joinpath(output,"selection.yaml"))["zero_command"]
        @test zero["shape"]==[2] && zero["sha256"]==C.sha256_file(joinpath(output,zero["path"]))
        @test PipeWireAORTC.Artifacts.prepare(PipeWireAORTC.Artifacts.FITSArtifact(joinpath(output,zero["path"])),Float32,(2,)).data==zeros(Float32,2)
        @test PipeWireAORTC.InstrumentConfiguration.load_rtc(selected_rtc).calibration["pixel_selection_mask"]==trues(4)
        selected_configuration=C.read_yaml(joinpath(output,"selection.yaml"))["rtc_configuration"]
        @test selected_configuration==Dict("path"=>"rtc.yaml","sha256"=>C.sha256_file(selected_rtc))
        # The existing exporter selects this generated configuration without
        # changing the authored optical-calibration configuration.
        rebuilt=joinpath(temporary,"rebuilt");cp(source,rebuilt)
        selected_path="generated/calibration/rtc.yaml"
        IC=PipeWireAORTC.InstrumentConfiguration
        @test C.read_json(IC.prepare_publication(rebuilt;configuration=selected_path))["calibration_identity"]==identity
        IC.prepare_simulation_configuration!(rebuilt;configuration=selected_path)
        execution=D.decode(joinpath(rebuilt,"simulation.conf"),PREFIX)
        @test execution["rtc_configuration"]==selected_path && execution["calibration_identity"]==identity
        @test read(joinpath(rebuilt,"rtc/configuration.yaml"))==authored_bytes
        @test_throws ArgumentError E.materialize_calibration(source,built,results;options...)
    end
end
