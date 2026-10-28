# Optional CPU transfer/build selector; no native core or accelerator imports.
using Test, LinearAlgebra, PipeWireAORTC, PipeWireAO, AdaptiveOpticsSim,
    AdaptiveOpticsSimPipeWireHIL,AdaptiveOpticsCalibration,FilterGraphAlgorithms,
    FilterGraphIsland,FilterGraphPipeWire,JuliaFilterGraph
const E=PipeWireAORTC.InstrumentExport
const C=PipeWireAORTC.Common
const D=PipeWireAORTC.DeploymentConfiguration
const IC=PipeWireAORTC.InstrumentConfiguration
const Cal=PipeWireAORTC.InstrumentCalibration
const PREFIX=ENV["PIPEWIREAO_PREFIX"]
Base.include(@__MODULE__,joinpath(@__DIR__,"pupil_source_documents.jl"))
Base.include(@__MODULE__,joinpath(@__DIR__,"composition_documents.jl"))

@testset "standalone preparation selects actual P/Q and proves physical response transfer" begin
    mktempdir() do temporary
        base=joinpath(temporary,"base");mkpath(base)
        (;document,simulation)=pupil_source_documents(base)
        composition_fixture(base,"standalone","plant","pupil")
        spec=C.read_json(joinpath(base,"deployment.conf"))
        append!(only(spec["owners"])["argv"],["--config","@PACKAGE@/simulation.conf"])
        C.write_json(joinpath(base,"deployment.conf"),spec)
        original=deepcopy(simulation)
        original["id"]="calibrated-pupil-source"
        C.write_yaml(joinpath(base,"simulation/calibrated.yaml"),original)
        calibrated=IC.load_simulation(joinpath(base,"simulation/calibrated.yaml"))
        settings=IC.settings(calibrated)
        original_identity=IC.prescription_identity(calibrated,settings)
        E.seal!(base)
        component=composition_fixture(joinpath(temporary,"component"),"cal2","optics","camera")
        directory=joinpath(component,"generated/calibration");mkpath(directory)
        identity="sha256:"*repeat("b",64)
        C.write_json(joinpath(component,"simulation.conf"),Dict("backend"=>"cpu","device"=>0,
            "rtc_configuration"=>"generated/calibration/rtc.yaml","calibration_identity"=>identity))
        C.write_yaml(joinpath(directory,"rtc.yaml"),Dict("calibration_identity"=>identity,"calibration"=>"generated/calibration/context.yaml"))
        recipe=Dict("branch_modes"=>Dict("llowfs"=>[1],"scc"=>[2]),"mirror"=>"primary","upstream_simulation"=>"simulation/calibrated.yaml")
        for name in ("llowfs","scc")
            report=Dict("recipe"=>recipe,"source_graph_sha256"=>repeat("c",64),"source_prescription_identity"=>"sha256:"*repeat("d",64),
                "status"=>"accepted","calibration_identity"=>identity,"built_application_calibration"=>true,"deployable"=>true,"diagnostic"=>false,
                "branch"=>name,"branches"=>Dict(name=>Dict("accepted"=>true)),"held_out"=>Dict("accepted"=>true),
                "upstream_prescription_identity"=>original_identity,"provenance"=>Dict("mirror_component"=>"primary"),
                "upstream_reference"=>Dict("effective_settings"=>settings,"effective_settings_identity"=>
                    PipeWireAORTC.InstrumentDefinition.scientific_identity(IC.canonical(settings))))
            Cal.write_bundle(joinpath(directory,name),report,Dict(),Dict("filter.graph"=>Dict("nodes"=>[])),
                Dict("command-projection"=>Matrix{Float32}(I,2,2));diagnostics=Dict("physical-to-modes"=>Matrix{Float32}(I,2,2)))
        end
        shared=Dict(key=>Dict("path"=>"llowfs/artifacts/"*key*".fits","sha256"=>C.sha256_file(joinpath(directory,"llowfs/artifacts/"*key*".fits")))
            for key in ("command-projection","physical-to-modes"))
        index=Dict("version"=>1,"kind"=>"optical-calibration-index","calibration_identity"=>identity,"physical_projection"=>shared,
            "branches"=>Dict(name=>Dict("path"=>name,"result_sha256"=>C.sha256_file(joinpath(directory,name,"result.yaml"))) for name in ("llowfs","scc")))
        C.write_yaml(joinpath(directory,"calibration.yaml"),index)
        C.write_yaml(joinpath(directory,"selection.yaml"),Dict("calibration_identity"=>identity,
            "calibration_index_sha256"=>C.sha256_file(joinpath(directory,"calibration.yaml")),
            "rtc_configuration"=>Dict("path"=>"rtc.yaml","sha256"=>C.sha256_file(joinpath(directory,"rtc.yaml")))))
        E.seal!(component)
        author=joinpath(temporary,"author");mkpath(author)
        contract=Dict("version"=>2,"command_limit_m"=>1e-6,"calibration_identity"=>Dict("\$ref"=>"/calibration/cal2/calibration_identity"),
            "command_order"=>Dict("\$ref"=>"/calibration/cal2/command_order"),
            "branches"=>Dict(name=>Dict("node_name"=>name*"-offset","schema"=>"test.physical/1","modes"=>recipe["branch_modes"][name],
                "command_limit_m"=>1e-6,"coefficient_limit_m"=>1e-7,"max_age_ns"=>10000000,"silence_ns"=>1000000000) for name in ("llowfs","scc")))
        for (field,key,hashkey) in (("projection","command-projection","projection"),("inverse","physical-to-modes","inverse"))
            contract[field]=Dict("path"=>"components/cal2/generated/calibration/"*shared[key]["path"],"shape"=>[2,2],"axes"=>[2,1],
                "sha256"=>Dict("\$ref"=>"/calibration/cal2/"*hashkey*"_sha256"))
        end
        C.write_yaml(joinpath(author,"receiver.yaml"),contract)
        C.write_yaml(joinpath(author,"profile.yaml"),Dict("version"=>1,"backend"=>"cpu","device"=>0,"pacing_rate_hz"=>1,
            "silence_ns"=>Dict("llowfs"=>1000000000,"scc"=>2000000000)))
        recipepath=joinpath(author,"composition.yaml")
        recipe=Dict("version"=>1,"namespace"=>"cal2","roles"=>Dict("optics"=>"cal2-optics"),"links"=>[],"profile"=>"profile.yaml",
            "calibration"=>"generated/calibration","receiver"=>Dict("kind"=>"pupil-source","owner"=>"plant","mirror"=>"primary",
                "rtc_configuration"=>"rtc/configuration.yaml","simulation_configuration"=>"simulation.conf","template"=>"receiver.yaml","configuration"=>"offsets.yaml"),
            "owner_arguments"=>Dict("role"=>"plant","threads"=>"3,0","append"=>["--physical-offsets","@PACKAGE@/offsets.yaml"]))
        C.write_yaml(recipepath,recipe)
        source_before=Dict(file=>read(joinpath(base,file)) for file in ("instrument.json","rtc/configuration.yaml","simulation.conf"))
        bundle_before=C.sha256_file(joinpath(directory,"llowfs/result.yaml"))
        output=E.prepare_feedback(base,component,joinpath(temporary,"composed"),recipepath;prefix=PREFIX)
        selected=C.read_yaml(joinpath(output,"generated/physical-offset-calibration/selection.yaml"))
        @test selected["physical_equivalence"]["accepted"]
        @test selected["physical_equivalence"]["responses"]==3
        @test selected["physical_equivalence"]["maximum_opd_error_m"]==0
        @test selected["physical_equivalence"]["calibrated_prescription_identity"]==original_identity
        @test selected["source_prescription_identity"]==document["prescription_identity"]!=original_identity
        @test selected["original_calibration_identity"]==document["calibration_identity"]!=identity
        options=PipeWireAORTC.AOSOwner.configuration(joinpath(output,"simulation.conf"))
        @test options.calibration_identity==identity
        @test options.prescription_identity==document["prescription_identity"]
        @test options.rtc_configuration==joinpath(output,"generated/physical-offset-calibration/rtc.yaml")
        @test all(read(joinpath(base,file))==bytes for (file,bytes) in source_before)
        @test C.sha256_file(joinpath(directory,"llowfs/result.yaml"))==bundle_before
        @test D.profile(joinpath(output,"deployment.conf"),PREFIX)!==nothing
        # A real changed physical response rejects before publishing an output.
        changed=joinpath(temporary,"changed");cp(base,changed)
        model=C.read_yaml(joinpath(changed,"simulation/definition.yaml"))
        model["components"]["primary"]["coupling"]=0.2
        C.write_yaml(joinpath(changed,"simulation/definition.yaml"),model)
        sim=C.read_json(joinpath(changed,"simulation.conf"))
        declaration=IC.load_simulation(joinpath(changed,"simulation/definition.yaml"))
        sim["prescription_identity"]=IC.prescription_identity(declaration,IC.settings(declaration))
        C.write_json(joinpath(changed,"simulation.conf"),sim);E.seal!(changed)
        rejected=joinpath(temporary,"rejected")
        @test_throws ArgumentError E.prepare_feedback(changed,component,rejected,recipepath;prefix=PREFIX)
        @test !ispath(rejected)
    end
    @test !any(id->id.name in ("CUDA","AMDGPU"),keys(Base.loaded_modules))
end
