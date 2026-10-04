using Test
using PipeWireAODeployment
const HC=PipeWireAODeployment.HeartConfiguration

@testset "HEART configuration preparation without Python" begin
    @test "TELOFF" in HC.required_sections(Val(:classic))
    @test !("TELOFF" in HC.required_sections(Val(:copper)))
    @test HC.scalar(1e-5)=="0.000010"
    @test parse(Float64,HC.scalar(1e-30))==1e-30
    @test HC.scalar(-0.3)=="-0.3"
    @test_throws ArgumentError HC.scalar(NaN)
    @test_throws ArgumentError HC.scalar(true)
    @test_throws ArgumentError HC.scalar("bad\\escape")
    @test_throws ArgumentError HC.scalar("bad\"quote")
    @test_throws ArgumentError HC.scalar("x"^128)
    @test_throws Exception HC.load_document("- A: { x: 1, x: 2 }\n")
    @test_throws Exception HC.load_document("- A: { 1: 2 }\n")
    @test_throws ArgumentError HC.load_document("- A: { x: 1 }\n- A: { y: 2 }\n")
    @test HC.normalize_aliases("- ALIASES:\n    FOO: &foo 1\n    FOO: &foo 1\n- HO:\n    N: 1\n") ==
        "- ALIASES:\n    FOO: &foo 1\n- HO:\n    N: 1\n"
    @test_throws ArgumentError HC.normalize_aliases("- ALIASES:\n    FOO: &foo 1\n    FOO: &foo 2\n")
    mktempdir() do directory
        source=joinpath(directory,"config.yaml")
        write(source,"---\n- ALIASES:\n    PORT: &port 6000\n- HO:\n    VALUE: 0.00001\n    ROWS: [ { WFS_NUM: 0, ROWS: 64 } ]\n...\n")
        document,sections=HC.load_config(source)
        @test collect(keys(sections))==["ALIASES","HO"]
        emitted=HC.serialize_config(document,source)
        @test occursin("PORT: &port 6000",emitted)
        @test occursin("ROWS: [\n",emitted)
        @test first(HC.load_document(emitted))==document
        @test !occursin(r"[0-9][eE][+-]?[0-9]",emitted)
        payload=joinpath(directory,"background.f32le")
        write(payload,reinterpret(UInt8,Float32[1,2,3,4]))
        fits=joinpath(directory,"background.fits")
        HC.write_offset_fits(payload,fits,[2,2])
        @test filesize(fits)==5760
        @test reinterpret(Float32,ntoh.(reinterpret(UInt32,read(fits)[2881:2896])))==Float32[1,2,3,4]
        @test_throws ArgumentError HC.write_offset_fits(payload,fits,[3,3])
        @test_throws ArgumentError HC.inside_root(joinpath(dirname(directory),"other"),directory)
        @test HC.inside_root(payload,directory)==payload
        @test_throws ArgumentError HC.matrix_dimensions(fits)
        sections["ALIASES"]["PORT"]=-1
        @test_throws ArgumentError HC.serialize_config(document,source)
    end
    @test HC.runtime_requirements("classic")[1]["flags"]["enableClippingFeedback"]==1
    @test HC.runtime_requirements("copper")[2]["flags"]["enableInHoVect"]==1
end

function operational_classic_fixture(root)
    C=PipeWireAODeployment.Common;S=PipeWireAODeployment.ScienceExport;H=PipeWireAODeployment.HILExport
    mkpath(joinpath(root,"calibration"));mkpath(joinpath(root,"graphs"));mkpath(joinpath(root,"hil"))
    origins=fill([0,0],188);active=fill(true,188);active[86]=false
    parameters=[S.parameter_dict(p) for p in S.classic_parameters()]
    payloads=Dict("background"=>collect(reinterpret(UInt8,fill(2f0,352*352))),
        "reference-slopes"=>collect(reinterpret(UInt8,Float32.(1:376))),
        "coordinates"=>collect(reinterpret(UInt8,Float32.(1:968))),
        "thresholds"=>collect(reinterpret(UInt8,repeat(Float32[20,1000],188))),
        "active"=>UInt8.(active),"subaperture-origins"=>H._packed_origins(origins))
    for p in parameters
        if haskey(payloads,p["name"])
            file=joinpath(root,"calibration",p["file"]);write(file,payloads[p["name"]]);p["sha256"]=C.sha256_file(file)
        end
    end
    node(name,label,config)=Dict("name"=>name,"label"=>label,"config"=>config)
    graph=Dict{String,Any}("filter.graph"=>Dict("nodes"=>[
        node("pixel-calibration","pixel-calibration-u16-f32",Dict()),
        node("shack-hartmann","shack-hartmann-image-f32",Dict("initial_subaperture_origins"=>origins,"active"=>active,
            "image_rows"=>352,"image_columns"=>352,"subaperture_count"=>188,"subaperture_rows"=>22,"subaperture_columns"=>22,"coordinate_scale"=>1.0)),
        node("pdm-command","pdm-command-f32",Dict())]))
    for p in parameters
        p["name"] in ("background","reference-slopes","coordinates","thresholds") || continue
        graph["pipewireao.startup-parameter."*p["endpoint"]]="@PACKAGE@/calibration/"*p["file"]
    end
    C.write_json(joinpath(root,"graphs/graph.conf.in"),graph);write(joinpath(root,"hil/plant.toml"),"fixture=true\n")
    provenance=Dict{String,Any}("profile"=>"classic","engine"=>"fgn","parameters"=>parameters,
        "prepared_profile"=>Dict("subaperture_origins"=>origins),"hil"=>Dict{String,Any}())
    snapshot,_,bindings=H.classic_snapshot(root,provenance,"/unused")
    artifacts=Dict{String,Any}();targets=Dict{String,Any}()
    for (name,file,units) in (("background","measured-background.f32le","ADC"),("reference-slopes","measured-reference-slopes.f32le","detector coordinate"),("active","measured-active.u8","eligible ROI"))
        p=bindings[name];artifacts[file]=Dict("sha256"=>p["sha256"],"shape"=>p["shape"],"element_type"=>p["element_type"],"layout"=>"ROW_MAJOR","units"=>units)
        targets[name]=merge(p,Dict("path"=>"calibration/"*p["file"]))
    end
    provenance["hil"]["operational_calibration"]=Dict("mode"=>"operational-measured-offsets","source"=>"declared fixture source",
        "reference_units"=>"micrometre OPD","reference_command"=>zeros(277),"target_estimator"=>snapshot,
        "target_graph_sha256"=>C.sha256_file(joinpath(root,"graphs/graph.conf.in")),"target_model_sha256"=>C.sha256_file(joinpath(root,"hil/plant.toml")),"artifacts"=>artifacts,"target_bindings"=>targets)
    seals=Dict(relpath(joinpath(d,f),root)=>C.sha256_file(joinpath(d,f)) for (d,_,files) in walkdir(root) for f in files)
    C.write_json(joinpath(root,"deployment.conf"),Dict("artifacts"=>seals))
    return provenance
end

@testset "Explicit operational Classic native offsets and fixed eligibility" begin
    C=PipeWireAODeployment.Common
    mktempdir() do root
        provenance=operational_classic_fixture(root)
        selected=HC.calibration_inputs(root,provenance;pipewire_prefix="/unused")
        @test selected.mode=="operational"
        @test selected.background==joinpath(root,"calibration/background.f32le")
        @test selected.reference==joinpath(root,"calibration/reference-slopes.f32le")
        @test selected.active==joinpath(root,"calibration/active-subapertures.u8")
        destination=joinpath(root,"native-mask.csv");HC.write_disabled_mask(selected.active,destination)
        lines=readlines(destination)
        @test first(lines)=="188 1 1 int"
        @test count(==("-1"),lines)==1
        @test lines[87]=="-1" # accepted zero-based ROI85 remains permanently disabled
        @test count(==("1"),lines)==187
        @test !("0" in lines)
        mutations=[p->delete!(p["hil"],"operational_calibration"),
            p->(p["profile"]="copper"),
            p->(p["hil"]["simulated_calibration"]=Dict()),
            p->(p["hil"]["operational_calibration"]["mode"]="guess"),
            p->(p["hil"]["operational_calibration"]["reference_command"][1]=1),
            p->(p["hil"]["operational_calibration"]["artifacts"]["measured-background.f32le"]["sha256"]="0"^64),
            p->(p["hil"]["operational_calibration"]["artifacts"]["measured-reference-slopes.f32le"]["shape"]=[2,188]),
            p->(p["hil"]["operational_calibration"]["artifacts"]["measured-active.u8"]["element_type"]="U8"),
            p->(p["hil"]["operational_calibration"]["target_bindings"]["active"]["path"]="../mask"),
            p->(p["hil"]["operational_calibration"]["target_estimator"]["coordinates_sha256"]="0"^64),
            p->(p["hil"]["operational_calibration"]["target_model_sha256"]="0"^64)]
        for mutate in mutations
            bad=deepcopy(provenance);mutate(bad);output=joinpath(root,"rejected-output")
            @test_throws ArgumentError begin HC.calibration_inputs(root,bad;pipewire_prefix="/unused");mkpath(output);end
            @test !ispath(output)
        end
        # Existing simulated branches retain their source paths and source mask.
        for instrument in ("classic","copper")
            simulated=Dict("profile"=>instrument,"hil"=>Dict("simulated_calibration"=>Dict("artifacts"=>Dict(
                "background"=>Dict("path"=>"background.f32le"),"reference_slopes"=>Dict("path"=>"references.f32le")))))
            result=HC.calibration_inputs(root,simulated)
            @test result.mode=="simulated"
            @test result.active===nothing
            @test result.reference==(instrument=="classic" ? joinpath(root,"hil/references.f32le") : nothing)
        end
        native=joinpath(root,"native");mkdir(native)
        coords=reinterpret(Float32,read(joinpath(root,"calibration/shack-hartmann-coordinates.f32le")))
        coefficient_values=vcat(repeat(coords[1:2:end],188),repeat(coords[2:2:end],188))
        coefficients=joinpath(native,"coefficients.f32le");write(coefficients,reinterpret(UInt8,coefficient_values))
        HC.write_offset_fits(coefficients,joinpath(native,"coefficients.fits"),[2,188*484])
        sections=Dict("HO"=>Dict(key=>[Dict("WFS_NUM"=>0,"FILE"=>file)] for (key,file) in (
            ("GRAD_COEFF_INITIAL_FILE","coefficients.fits"),("SUBAP_THRES_PIXEL","pixels.fits"),
            ("SUBAP_THRES_FLUX","flux.fits"),("SHWFS_SUBAP_LOCATION_FILE","origins.csv"))))
        for (name,value,shape) in (("pixels",20f0,[188]),("flux",1000f0,[188,1]))
            payload=joinpath(native,name*".f32le");write(payload,reinterpret(UInt8,fill(value,188)))
            HC.write_offset_fits(payload,joinpath(native,name*".fits"),shape)
        end
        write(joinpath(native,"origins.csv"),"188 2 1 uint\n"*repeat("0,0\n",188))
        @test HC.validate_native_measurements(root,provenance,sections,native,"/unused")===nothing
        @test HC.native_float_values(joinpath(native,"pixels.fits"),[188])==fill(20f0,188)
        @test_throws ArgumentError HC.native_float_values(joinpath(native,"pixels.fits"),[2,94])
        coefficient_values[1]+=1;write(coefficients,reinterpret(UInt8,coefficient_values))
        HC.write_offset_fits(coefficients,joinpath(native,"coefficients.fits"),[2,188*484])
        @test_throws ArgumentError HC.validate_native_measurements(root,provenance,sections,native,"/unused")
        coefficient_values[1]-=1;write(coefficients,reinterpret(UInt8,coefficient_values))
        HC.write_offset_fits(coefficients,joinpath(native,"coefficients.fits"),[2,188*484])
        write(joinpath(native,"origins.csv"),"188 2 1 uint\n0,1\n"*repeat("0,0\n",187))
        @test_throws ArgumentError HC.validate_native_measurements(root,provenance,sections,native,"/unused")
        references=joinpath(native,"reference.fits");HC.write_offset_fits(selected.reference,references,[188,2])
        @test HC.native_float_values(references,[2,188])==reinterpret(Float32,read(selected.reference))
        original=read(selected.reference);write(selected.reference,reinterpret(UInt8,fill(0f0,376)))
        @test_throws ArgumentError HC.calibration_inputs(root,provenance;pipewire_prefix="/unused")
        write(selected.reference,original)
        original=read(selected.active);write(selected.active,fill(UInt8(1),188))
        @test_throws ArgumentError HC.calibration_inputs(root,provenance;pipewire_prefix="/unused")
        write(selected.active,original)
        invalid=joinpath(root,"invalid-mask");write(invalid,fill(UInt8(2),188))
        @test_throws ArgumentError HC.write_disabled_mask(invalid,joinpath(root,"invalid-native-mask.csv"))
        @test !ispath(joinpath(root,"invalid-native-mask.csv"))
    end
end
