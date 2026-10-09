using Test
using JSON3
using SHA
using TOML

include("analyze_correction.jl")
using .CorrectionAnalysis
const CA = CorrectionAnalysis

@testset "Pupil variance and units" begin
    mask = Bool[true true; false false]
    values = [1.0 3.0; 999.0 -999.0]
    @test CA.pupil_variance(values, mask) == 1.0
    @test CA.pupil_variance(values .+ 1000, mask) == 1.0
    @test CA.pupil_variance(values .* 1e-6, mask) ≈ 1e-12
    @test CA.pupil_variance(fill(floatmax(Float64), 2, 2), mask) == 0
    @test CA.pupil_variance([1e16 + 2 1e16; 1e16 1e16], trues(2, 2)) == 0.75
    @test CA.pupil_variance(@view(values[:, :]), @view(mask[:, :])) == 1.0
    @test_throws ArgumentError CA.pupil_variance(values, trues(1, 2))
    @test_throws ArgumentError CA.pupil_variance(values, falses(2, 2))
    @test_throws ArgumentError CA.pupil_variance([NaN 0.0; 0.0 0.0], mask)
    @test_throws ArgumentError CA.pupil_variance([floatmax(Float64) -floatmax(Float64); 0.0 0.0], mask)
end

@testset "ADC boundary and row order" begin
    frame = zeros(Float32, 352, 352)
    frame[1, 2] = 1.5
    frame[2, 1] = 2.5
    frame[352, 352] = 65535
    bytes = CA.adc_bytes(frame)
    @test bytes[3:4] == UInt8[2, 0]
    @test bytes[705:706] == UInt8[2, 0]
    @test bytes[end-1:end] == UInt8[255, 255]
    @test CA.adc_comparison(bytes, bytes).exact
    @test CA.adc_comparison(bytes, bytes).differing_pixels == 0
    other = copy(bytes)
    other[3] = 3
    d = CA.adc_comparison(bytes, other)
    @test !d.exact && d.differing_pixels == 1 && d.maximum_abs_adc_difference == 1
    @test d.first_difference == (; row=1, column=2, replay=2, recorded=3)
    @test d.replay_sha256 != d.recorded_sha256
    @test_throws ArgumentError CA.adc_comparison(bytes, bytes[1:end-1])
    @test_throws ArgumentError CA.adc_bytes(zeros(2, 2))
    for invalid in (-1.0f0, 65536.0f0, Inf32, NaN32)
        frame[1, 1] = invalid
        @test_throws ArgumentError CA.adc_bytes(frame)
    end
    @test CA.opd_hash(Float32[1 2; 3 4]) == bytes2hex(sha256(reinterpret(UInt8, htol.(reinterpret(UInt32, Float32[1, 2, 3, 4])))))
end

@testset "Declared windows and score promotion" begin
    for n in (1, 16, 17, 127, 128, 129, 255, 256)
        windows = CA.window_ranges(n)
        @test first(windows).first == (n <= 16 ? 1 : 17)
        @test last(windows).last == n
        @test all(w -> 1 <= w.first <= w.last <= n, windows)
    end
    @test CA.window_ranges(256) == [(; name="frames_17_to_128", first=17, last=128, complete=true), (; name="frames_129_to_256", first=129, last=256, complete=true)]
    @test !only(CA.window_ranges(17)).complete
    @test_throws ArgumentError CA.window_ranges(0)
    @test_throws ArgumentError CA.window_ranges(257)
    @test only(CA.correction_windows(fill(2.0, 17), fill(4.0, 17), true)).residual_to_atmosphere_variance_ratio == 0.5
    @test only(CA.correction_windows(fill(2.0, 17), fill(4.0, 17), false)).residual_to_atmosphere_variance_ratio === nothing
    @test only(CA.correction_windows(zeros(2), zeros(2), true)).residual_to_atmosphere_variance_ratio === nothing
    @test_throws ArgumentError CA.correction_windows(zeros(2), zeros(3), true)
end

function fixture(root)
    package = joinpath(root, "package")
    mkpath(joinpath(package, "hil"))
    for name in ("simulator.jl", "owner_protocol.jl", "Project.toml", "Manifest.toml")
        write(joinpath(package, "hil", name), "# synthetic hash fixture\n")
    end
    config = Dict("resolution" => 4, "telescope_diameter_m" => 1.22,
        "central_obstruction_ratio" => 0.2, "pupil_reflectivity" => 1.0, "aperture_revision" => 1)
    nodes = [Dict("name" => name, "config" => copy(config)) for name in ("atmosphere", "pdm", "shwfs")]
    push!(nodes, Dict("name" => "detector", "config" => Dict("exposure_duration_s" => 0.001)))
    graph = joinpath(package, "hil/plant.toml")
    open(graph, "w") do io
        TOML.print(io, Dict("nodes" => nodes))
    end
    artifacts = Dict("hil/" * name => CA.file_hash(joinpath(package, "hil", name)) for name in ("simulator.jl", "owner_protocol.jl", "plant.toml", "Project.toml", "Manifest.toml"))
    write(joinpath(package, "deployment.conf"), JSON3.write((; version=1, artifacts)))
    frames = joinpath(root, "frames.u16le")
    commands = joinpath(root, "commands.f32le")
    write(frames, zeros(UInt8, 2 * 352 * 352 * 2))
    words = zeros(UInt32, 277 * 2)
    words[1] = htol(reinterpret(UInt32, 1.0f-8))
    write(commands, reinterpret(UInt8, words))
    report = Dict("version"=>1, "profile"=>"classic", "backend"=>"cpu", "completed"=>true,
        "failure"=>nothing, "completed_frames"=>2, "completed_commands"=>2, "requested_frames"=>2,
        "sequence"=>2, "sequences"=>[1,2], "model_period_ns"=>2_000_000,
        "model_timestamps_ns"=>[0,2_000_000], "exposure_ns"=>1_000_000,
        "source_published_ns"=>[100,200], "command_received_ns"=>[110,220],
        "source_to_command_latency_ns"=>[10,20], "graph_sha256"=>CA.file_hash(graph),
        "command_limit_um"=>0.8, "command_limit_tolerance_um"=>1e-7,
        "frame"=>Dict("element_type"=>"U16_LE", "layout"=>"ROW_MAJOR", "shape"=>[352,352],
            "units"=>"raw detector ADC code", "encoding"=>"nearest ties to even", "file"=>"frames.u16le",
            "sha256"=>CA.file_hash(frames), "schema"=>"org.calculon.ao.raw-detector-pixels/1"),
        "command"=>Dict("recorded_element_type"=>"F32_LE", "shape"=>[277], "recorded_units"=>"metre OPD",
            "plant_units"=>"metre OPD", "layout"=>"frame followed by 277 actuator values", "file"=>"commands.f32le",
            "sha256"=>CA.file_hash(commands), "schema"=>"org.calculon.ao.demanded-pdm-command/1",
            "transport_element_type"=>"F32_LE", "transport_units"=>"micrometre OPD", "transport_to_plant_scale"=>1e-6))
    report_path = joinpath(root, "simulator-result.json")
    write(report_path, JSON3.write(report))
    return (; package, graph, frames, commands, report, report_path)
end

@testset "Installed artifact and recording validation" begin
    mktempdir() do root
        f = fixture(root)
        @test CA.validate_package(f.package).artifact_count == 5
        r = CA.validate_recording(f.package, f.report_path)
        @test size(r.commands) == (277, 2)
        @test r.commands[1, 1] == 1.0f-8
        @test iszero(r.commands[1, 2])
        @test CA.telescope_config(f.graph).resolution == 4
        @test_throws ArgumentError CA.checked_artifact(f.package, "../frames.u16le", CA.file_hash(f.frames))
        original = read(joinpath(f.package, "hil/simulator.jl"))
        write(joinpath(f.package, "hil/simulator.jl"), "tampered")
        @test_throws ArgumentError CA.validate_package(f.package)
        write(joinpath(f.package, "hil/simulator.jl"), original)
        write(joinpath(f.package, "hil/unlisted.jl"), "# unbound installed source\n")
        @test_throws ArgumentError CA.validate_package(f.package)
        rm(joinpath(f.package, "hil/unlisted.jl"))
        for (key, bad) in (("completed_frames",0), ("completed_commands",1), ("requested_frames",3),
                ("sequence",1), ("sequences",[2,1]), ("model_period_ns",0),
                ("model_timestamps_ns",[0,1]), ("exposure_ns",3_000_000), ("backend","cuda"),
                ("source_to_command_latency_ns",[10,21]), ("graph_sha256","0"^64), ("completed",false))
            changed = deepcopy(f.report)
            changed[key] = bad
            write(f.report_path, JSON3.write(changed))
            @test_throws ArgumentError CA.validate_recording(f.package, f.report_path)
        end
        changed = deepcopy(f.report)
        changed["sequences"] = Union{Bool,Int}[true, 2]
        write(f.report_path, JSON3.write(changed))
        @test_throws ArgumentError CA.validate_recording(f.package, f.report_path)
        for (part, key, bad) in (("frame","shape",[352,351]), ("frame","layout","COLUMN_MAJOR"),
                ("frame","sha256","0"^64), ("command","recorded_units","micrometre OPD"),
                ("command","recorded_element_type","F32_BE"), ("command","shape",[276]),
                ("command","transport_to_plant_scale",1.0))
            changed = deepcopy(f.report)
            changed[part][key] = bad
            write(f.report_path, JSON3.write(changed))
            @test_throws ArgumentError CA.validate_recording(f.package, f.report_path)
        end
        # Matching hash does not make a non-finite command valid.
        words = zeros(UInt32, 277 * 2)
        words[1] = htol(reinterpret(UInt32, NaN32))
        write(f.commands, reinterpret(UInt8, words))
        changed = deepcopy(f.report)
        changed["command"]["sha256"] = CA.file_hash(f.commands)
        write(f.report_path, JSON3.write(changed))
        @test_throws ArgumentError CA.validate_recording(f.package, f.report_path)
        write(f.frames, UInt8[0])
        @test_throws ArgumentError CA.checked_payload(f.report_path, JSON3.read(JSON3.write(f.report["frame"])), 2 * 352 * 352 * 2)
        definition = TOML.parsefile(f.graph)
        definition["nodes"][2]["config"]["central_obstruction_ratio"] = 0.3
        open(f.graph, "w") do io
            TOML.print(io, definition)
        end
        @test_throws ArgumentError CA.telescope_config(f.graph)
    end
end

@testset "CLI failure evidence and output ownership" begin
    mktempdir() do root
        f = fixture(root)
        output = joinpath(root, "diagnostic.json")
        # The synthetic project differs from the active project. This fails
        # before plant inclusion and preserves a durable failure report.
        @test CA.main(["--package",f.package,"--report",f.report_path,"--output",output]) == 1
        result = JSON3.read(read(output, String))
        @test result.verified === false
        @test !haskey(result, :windows)
        @test_throws ArgumentError CA.main(["--package",f.package,"--report",f.report_path,"--output",output])
        @test_throws ArgumentError CA.main(["--package",f.package,"--report",f.report_path,"--output",joinpath(f.package,"diagnostic.json")])
    end
end

@testset "CORR-R1 canonical output ownership" begin
    mktempdir() do root
        f = fixture(root)
        alias = joinpath(root, "package-alias")
        symlink(f.package, alias)
        for output in (joinpath(alias, "diagnostic.json"), joinpath(alias, "new", "diagnostic.json"))
            @test_throws ArgumentError CA.main(["--package",f.package,"--report",f.report_path,"--output",output])
        end
        @test !ispath(joinpath(f.package, "diagnostic.json"))
        @test !ispath(joinpath(f.package, "new"))
        outside = joinpath(root, "outside")
        mkdir(outside)
        outside_alias = joinpath(root, "outside-alias")
        symlink(outside, outside_alias)
        output = joinpath(outside_alias, "new", "diagnostic.json")
        @test CA.diagnostic_output(f.package, output) == joinpath(outside, "new", "diagnostic.json")
        @test CA.main(["--package",f.package,"--report",f.report_path,"--output",output]) == 1
        @test isfile(joinpath(outside, "new", "diagnostic.json"))
        @test JSON3.read(read(output, String)).verified === false
        for suffix in ("", ".replayed.frames.u16le")
            candidate = joinpath(outside, "dangling" * (isempty(suffix) ? "-report" : "-raw") * ".json")
            symlink(joinpath(root, "absent-target"), candidate * suffix)
            @test_throws ArgumentError CA.main(["--package",f.package,"--report",f.report_path,"--output",candidate])
            @test islink(candidate * suffix)
            @test !ispath(joinpath(root, "absent-target"))
        end
        dangling_parent = joinpath(root, "dangling-parent")
        symlink(joinpath(root, "absent-directory"), dangling_parent)
        @test_throws ArgumentError CA.diagnostic_output(f.package, joinpath(dangling_parent, "report.json"))
        @test !ispath(joinpath(root, "absent-directory"))
    end
end

@testset "Installed script nested includes without main" begin
    mktempdir() do root
        nested = joinpath(root, "nested")
        mkdir(nested)
        write(joinpath(nested, "value.jl"), "const nested_value = 17\n")
        write(joinpath(root, "owner_protocol.jl"), "include(\"nested/value.jl\")\n")
        simulator = joinpath(root, "simulator.jl")
        write(simulator, """
            include("owner_protocol.jl")
            const main_called = Ref(false)
            main() = (main_called[] = true)
            abspath(PROGRAM_FILE) == (@__FILE__) && main()
            """)
        # The cwd deliberately differs from the fixture. Both include levels
        # must resolve relative to their source files, without starting main.
        installed = CA.load_installed_simulator(simulator)
        @test Base.invokelatest(getproperty, installed, :nested_value) == 17
        @test Base.invokelatest(getproperty, installed, :main_called)[] === false
        @test Base.invokelatest(isdefined, installed, :include)
        @test !isdefined(CA, :nested_value)
    end
end

function cold_lazy_prepare(installed)
    # Plant import occurs after this call's world has been established, as in
    # the installed simulator. Preparation must see the newly defined method.
    Base.invokelatest(installed.prepare_science, nothing, installed.load_plant(:classic), nothing)
end

@testset "Cold lazy plant preparation world" begin
    mktempdir() do root
        file = joinpath(root, "simulator.jl")
        write(file, """
            function load_plant(profile)
                return @eval module LazyPlant
                    graph_path(::Symbol) = "fixture"
                end
            end
            prepare_science(options, plant, target) = plant.graph_path(:grid_gaussian)
            """)
        installed = CA.load_installed_simulator(file)
        @test Base.invokelatest(cold_lazy_prepare, installed) == "fixture"
    end
end

@testset "Direct live truth admission and promotion" begin
    mktempdir() do root
        f = fixture(root)
        cp(joinpath(@__DIR__, "correction_truth.jl"), joinpath(f.package, "hil/correction_truth.jl"))
        mask = trues(4, 4)
        cfg = CA.telescope_config(f.graph)
        witness = CA.CorrectionTruth.Witness(cfg, mask, 2)
        atmosphere = reshape(Float32.(1:16) .* 1f-7, 4, 4)
        pupil = atmosphere .* 0.5f0
        surface = atmosphere .- pupil
        for i in 1:2
            CA.CorrectionTruth.record!(witness, atmosphere, pupil, surface, UInt64(i), Int64((i - 1) * 2_000_000))
        end
        metadata = CA.CorrectionTruth.report(witness; graph_sha256=f.report["graph_sha256"],
            frame_sha256=f.report["frame"]["sha256"], command_sha256=f.report["command"]["sha256"],
            simulator_sha256=CA.file_hash(joinpath(f.package, "hil/simulator.jl")), completed_frames=2)
        original = deepcopy(f.report)
        original["correction_truth"] = JSON3.read(JSON3.write(metadata), Dict{String,Any})
        write(f.report_path, JSON3.write(original))
        recording = CA.validate_recording(f.package, f.report_path)
        @test recording.truth.complete_prefix
        samples = [NamedTuple{Tuple(Symbol.(keys(s)))}(Tuple(values(s))) for s in recording.truth.per_frame]
        @test CA.live_truth_matches(recording.truth, samples, mask)
        @test !CA.live_truth_matches(recording.truth, samples, falses(4, 4))
        @test !CA.live_truth_matches(nothing, samples, mask)
        @test !CA.live_truth_matches(recording.truth, samples[1:1], mask)
        @test !CA.live_truth_matches(recording.truth,
            [merge(samples[1], (; pupil_sha256="0"^64)), samples[2]], mask)
        @test !CA.live_truth_matches(recording.truth,
            [merge(samples[1], (; residual_variance_m2=0.0)), samples[2]], mask)
        for (adc, live, baseline) in Iterators.product((false,true), (false,true), (false,true))
            @test CA.verification_gate(adc, nothing, live, baseline) == (adc && baseline)
            @test CA.verification_gate(adc, recording.truth, live, baseline) == (live && baseline)
        end
        for (key, value) in (("version",2), ("complete_prefix",false), ("observed_frames",1),
                ("recorded_frames",1), ("graph_sha256","0"^64), ("frame_sha256","0"^64),
                ("command_sha256","0"^64), ("simulator_sha256","0"^64), ("helper_sha256","0"^64))
            changed = deepcopy(original)
            changed["correction_truth"][key] = value
            write(f.report_path, JSON3.write(changed))
            @test_throws ArgumentError CA.validate_recording(f.package, f.report_path)
        end
        for (part, key, value) in (("opd","units","micrometre OPD"), ("opd","shape",[4,3]),
                ("outputs","pupil","unbound"), ("pupil","mask_sha256","not a hash"),
                ("pupil","support_pixels",0), ("pupil","diameter",2.0),
                ("pupil","variance","sample variance"))
            changed = deepcopy(original)
            changed["correction_truth"][part][key] = value
            write(f.report_path, JSON3.write(changed))
            @test_throws ArgumentError CA.validate_recording(f.package, f.report_path)
        end
        for (key, value) in (("sequence",true), ("model_timestamp_ns",1),
                ("pupil_sha256","bad"), ("residual_variance_m2",-1.0), ("atmosphere_variance_m2",true))
            changed = deepcopy(original)
            changed["correction_truth"]["per_frame"][1][key] = value
            write(f.report_path, JSON3.write(changed))
            @test_throws ArgumentError CA.validate_recording(f.package, f.report_path)
        end
        write(f.report_path, JSON3.write(f.report))
        @test CA.validate_recording(f.package, f.report_path).truth === nothing
    end
end

function selected_fixture(root,profile,backend)
    f=fixture(root)
    definition=TOML.parsefile(f.graph)
    profile=="copper" && (only(filter(n->n["name"]=="shwfs",definition["nodes"]))["name"]="pwfs")
    only(filter(n->n["name"]=="detector",definition["nodes"]))["config"]["bits"]=profile=="copper" ? 14 : 12
    open(io->TOML.print(io,definition),f.graph,"w")
    report=deepcopy(f.report)
    report["profile"]=profile;report["backend"]=backend
    report["graph_sha256"]=CA.file_hash(f.graph)
    shape=CA.detector_shape(Val(Symbol(profile)))
    report["frame"]["shape"]=collect(shape)
    write(f.frames,zeros(UInt8,2*prod(shape)*2));report["frame"]["sha256"]=CA.file_hash(f.frames)
    cp(joinpath(@__DIR__,"correction_truth.jl"),joinpath(f.package,"hil/correction_truth.jl"))
    deps=backend=="cpu" ? Dict() : Dict((backend=="cuda" ? "CUDA" : "AMDGPU") =>
        (backend=="cuda" ? "052768ef-5323-5732-b1bb-66c8b64840ba" : "21141c5a-9bdb-4563-92ae-f87d6854732e"))
    open(io->TOML.print(io,Dict("deps"=>deps)),joinpath(f.package,"hil/Project.toml"),"w")
    provenance=Dict("profile"=>profile,"engine"=>"fgn","mode"=>"frame","hil"=>Dict("backend"=>backend))
    write(joinpath(f.package,"provenance.json"),JSON3.write(provenance))
    descriptor=Dict("version"=>1,"source-owner"=>"simulator","owners"=>[
        Dict("role"=>"simulator","argv"=>["julia","--profile",profile,"--backend",backend])],
        "artifacts"=>Dict(relpath(p,f.package)=>CA.file_hash(p) for p in
            vcat(readdir(joinpath(f.package,"hil");join=true),[joinpath(f.package,"provenance.json")])) )
    write(joinpath(f.package,"deployment.conf"),JSON3.write(descriptor))
    cfg=CA.telescope_config(f.graph);witness=CA.CorrectionTruth.Witness(cfg,trues(4,4),2)
    for i in 1:2
        atmosphere=reshape(Float32.(1:16).*1f-7,4,4)
        surface=fill(i==1 ? 0.0f0 : 1.0f-8,4,4)
        CA.CorrectionTruth.record!(witness,atmosphere,atmosphere.+surface,surface,UInt64(i),Int64((i-1)*2_000_000))
    end
    report["correction_truth"]=JSON3.read(JSON3.write(CA.CorrectionTruth.report(witness;
        graph_sha256=report["graph_sha256"],frame_sha256=report["frame"]["sha256"],
        command_sha256=report["command"]["sha256"],simulator_sha256=CA.file_hash(joinpath(f.package,"hil/simulator.jl")),completed_frames=2)),Dict{String,Any})
    write(f.report_path,JSON3.write(report))
    return (;f...,report,descriptor)
end

copper_fixture(root,backend="cpu")=selected_fixture(root,"copper",backend)
classic_gpu_fixture(root,backend)=selected_fixture(root,"classic",backend)

@testset "Copper selected backend and detector admission" begin
    for backend in ("cpu","cuda","amdgpu")
        mktempdir() do root
            f=copper_fixture(root,backend)
            recording=CA.validate_recording(f.package,f.report_path)
            @test recording.profile===:copper && recording.backend===Symbol(backend)
            @test recording.truth.complete_prefix
            @test length(recording.frames)==2*64*64*2
            @test CA.validate_package(f.package).artifact_count==7
            for (key,value) in (("profile","unknown"),("backend","unknown"),("backend",backend=="cpu" ? "cuda" : "cpu"))
                changed=deepcopy(f.report);changed[key]=value;write(f.report_path,JSON3.write(changed))
                @test_throws ArgumentError CA.validate_recording(f.package,f.report_path)
            end
            changed=deepcopy(f.report);delete!(changed,"correction_truth");write(f.report_path,JSON3.write(changed))
            @test_throws ArgumentError CA.validate_recording(f.package,f.report_path)
        end
    end
    frame=zeros(Float32,64,64);frame[1,2]=1.5;frame[2,1]=2.5;frame[end,end]=16383
    bytes=CA.adc_bytes(Val(:copper),frame)
    @test bytes[3:4]==UInt8[2,0] && bytes[129:130]==UInt8[2,0]
    @test CA.adc_comparison(Val(:copper),bytes,bytes).exact
    other=copy(bytes);other[129]=3
    @test CA.adc_comparison(Val(:copper),bytes,other).first_difference==
        (;row=2,column=1,replay=2,recorded=3)
    @test_throws ArgumentError CA.adc_bytes(Val(:copper),zeros(352,352))
    frame[1,1]=16384
    @test_throws ArgumentError CA.adc_bytes(Val(:copper),frame)
end

struct TransferOnlyMatrix <: AbstractMatrix{Float32}
    values::Matrix{Float32}
end
Base.size(matrix::TransferOnlyMatrix)=size(matrix.values)
Base.getindex(::TransferOnlyMatrix,args...)=error("device diagnostic must use declared host transfer")
Base.copyto!(destination::Matrix{Float32},source::TransferOnlyMatrix)=copyto!(destination,source.values)

mutable struct ReplayFixtureState
    sequence::Int
    command::Vector{Float32}
    atmosphere::TransferOnlyMatrix
    pupil::TransferOnlyMatrix
    surface::TransferOnlyMatrix
end

function fake_replay_simulator(;baseline_mismatch=false,unavailable=false,frame_shape=(64,64))
    state=ReplayFixtureState(0,zeros(Float32,277),TransferOnlyMatrix(zeros(Float32,4,4)),
        TransferOnlyMatrix(zeros(Float32,4,4)),TransferOnlyMatrix(zeros(Float32,4,4)))
    selected=Tuple{Symbol,Symbol}[]
    prepare=(options,plant,target)->begin
        push!(selected,(options.profile,target))
        (;graph=state,boundary=state,driver=state,target)
    end
    step=(boundary,driver)->begin
        state.sequence+=1
        copyto!(state.atmosphere.values,reshape(Float32.(1:16).*1f-7,4,4))
        fill!(state.surface.values,state.command[1])
        state.pupil.values .= state.atmosphere.values .+ state.surface.values
        if baseline_mismatch && length(selected)>1
            state.pupil.values[1]+=1f-7
        end
        (;sequence=UInt64(state.sequence),timestamp=Int64((state.sequence-1)*2_000_000))
    end
    reset=(boundary,driver)->begin
        state.sequence=0;fill!(state.command,0.0f0)
        # Record that the paired baseline follows command replay.
        push!(selected,last(selected))
        nothing
    end
    optics=(;TelescopeDefinition=(;kwargs...)->(;kwargs...),
        prepare_telescope=(definition,target)->nothing,pupil_mask=telescope->trues(4,4))
    simulator=(;prepare_science=prepare,load_plant=identity,
        load_target=backend->(unavailable ? error("selected backend unavailable") : backend),
        AdaptiveOpticsSim=(;Optics=optics),step_hil_frame_at! = step,
        model_nanoseconds=identity,hil_frame_buffer=boundary->zeros(Float32,frame_shape),
        graph_output=(graph,name)->getproperty(graph,name===:atmosphere_opd ? :atmosphere : name===:pupil_opd ? :pupil : :surface),
        hil_command_buffer=boundary->state.command,adopt_hil_command! = (boundary,sequence)->nothing,
        reset_hil_boundary! = reset)
    return (;simulator,selected,state)
end

@testset "Copper replay preserves backend and stages device products" begin
    for backend in ("cpu","cuda","amdgpu")
        mktempdir() do root
            f=copper_fixture(root,backend)
            recording=CA.validate_recording(f.package,f.report_path)
            fake=fake_replay_simulator()
            result=CA.replay(fake.simulator,recording,joinpath(root,"analysis"))
            @test result.verified && result.live_truth_verified && result.baseline_verified && result.adc_exact
            @test first(fake.selected)==(:copper,Symbol(backend))
            @test result.replayed_adc.shape==[64,64]
            @test filesize(result.replayed_adc.path)==2*64*64*2
            @test result.zero_comparison.rtol==CA.ZERO_RTOL && result.zero_comparison.atol_m==0.0
            @test result.command.final_command_effect_is_recorded===false
            @test all(sample->sample.surface_is_zero,result.baseline)
            @test only(result.windows).residual_to_atmosphere_variance_ratio≈1.0
            changed=deepcopy(f.report);changed["correction_truth"]["per_frame"][2]["pupil_sha256"]="0"^64
            write(f.report_path,JSON3.write(changed));tampered=CA.validate_recording(f.package,f.report_path)
            bad=fake_replay_simulator();rejected=CA.replay(bad.simulator,tampered,joinpath(root,"bad-witness"))
            @test !rejected.verified && rejected.adc_exact && !rejected.live_truth_verified
            @test only(rejected.windows).residual_to_atmosphere_variance_ratio===nothing
            bad=fake_replay_simulator(;baseline_mismatch=true)
            rejected=CA.replay(bad.simulator,recording,joinpath(root,"bad-baseline"))
            @test !rejected.verified && rejected.live_truth_verified && !rejected.baseline_verified
            @test only(rejected.windows).residual_to_atmosphere_variance_ratio===nothing
            unavailable=fake_replay_simulator(;unavailable=true)
            @test_throws ErrorException CA.replay(unavailable.simulator,recording,joinpath(root,"unavailable"))
            @test isempty(unavailable.selected)
        end
    end
end

@testset "Copper selection identities fail closed" begin
    for backend in ("cpu","cuda","amdgpu")
        mktempdir() do root
            f=copper_fixture(root,backend)
            for argv in (["julia","--profile","classic","--backend",backend],
                ["julia","--profile","copper","--backend",backend,"--backend",backend],
                ["julia","--profile","copper","--backend="*backend],
                ["julia","--profile","copper","--backend",backend,"--backend="*backend])
                descriptor=deepcopy(f.descriptor);descriptor["owners"][1]["argv"]=argv
                write(joinpath(f.package,"deployment.conf"),JSON3.write(descriptor))
                @test_throws ArgumentError CA.validate_recording(f.package,f.report_path)
            end
            descriptor=deepcopy(f.descriptor);delete!(descriptor["artifacts"],"provenance.json")
            write(joinpath(f.package,"deployment.conf"),JSON3.write(descriptor))
            @test_throws ArgumentError CA.validate_recording(f.package,f.report_path)
            write(joinpath(f.package,"deployment.conf"),JSON3.write(f.descriptor))
            write(joinpath(f.package,"provenance.json"),"{}")
            @test_throws ArgumentError CA.validate_recording(f.package,f.report_path)
        end
    end
    frame=zeros(Float32,64,64)
    @test CA.adc_bytes(Val(:copper),@view(frame[:,:]))==CA.adc_bytes(Val(:copper),frame)
end

@testset "Classic replay retains legacy finite gate" begin
    mktempdir() do root
        f=fixture(root);recording=CA.validate_recording(f.package,f.report_path)
        fake=fake_replay_simulator(;frame_shape=(352,352))
        result=CA.replay(fake.simulator,recording,joinpath(root,"classic"))
        @test result.verified && result.adc_exact && result.baseline_verified
        @test !result.live_truth_present && !result.live_truth_verified
        @test first(fake.selected)==(:classic,:cpu)
        @test result.replayed_adc.shape==[352,352]
        @test result.verification_basis=="exact source ADC replay and zero-command baseline"
        @test result.zero_comparison==(;rtol=8*Float64(eps(Float32)),atol_m=0.0,comparison="elementwise")
        @test only(result.windows).residual_to_atmosphere_variance_ratio≈1.0
        bad=fake_replay_simulator(;baseline_mismatch=true,frame_shape=(352,352))
        rejected=CA.replay(bad.simulator,recording,joinpath(root,"classic-baseline"))
        @test !rejected.verified && rejected.adc_exact && !rejected.baseline_verified
        @test only(rejected.windows).residual_to_atmosphere_variance_ratio===nothing
    end
end

@testset "Copper source dependency and detector failures" begin
    for backend in ("cuda","amdgpu")
        mktempdir() do root
            f=copper_fixture(root,backend)
            write(joinpath(f.package,"hil/Project.toml"),"[deps]\n")
            @test_throws ArgumentError CA.validate_recording(f.package,f.report_path)
        end
    end
    for bits in (13,16,14.0)
        mktempdir() do root
            f=copper_fixture(root)
            plant=TOML.parsefile(f.graph)
            only(filter(n->n["name"]=="detector",plant["nodes"]))["config"]["bits"]=bits
            open(io->TOML.print(io,plant),f.graph,"w")
            @test_throws ArgumentError CA.validate_recording(f.package,f.report_path)
        end
    end
    mktempdir() do root
        f=copper_fixture(root)
        bytes=read(f.frames);bytes[1:2]=reinterpret(UInt8,[htol(UInt16(16384))]);write(f.frames,bytes)
        report=deepcopy(f.report);report["frame"]["sha256"]=CA.file_hash(f.frames)
        report["correction_truth"]["frame_sha256"]=report["frame"]["sha256"]
        write(f.report_path,JSON3.write(report))
        @test_throws ArgumentError CA.validate_recording(f.package,f.report_path)
    end
end

@testset "Classic GPU selected package, twelve-bit ADC and direct witness" begin
    for backend in ("cuda","amdgpu")
        mktempdir() do root
            f=classic_gpu_fixture(root,backend)
            recording=CA.validate_recording(f.package,f.report_path)
            @test recording.profile===:classic && recording.backend===Symbol(backend)
            @test recording.truth.complete_prefix
            @test length(recording.frames)==2*352*352*2
            @test recording.adc_upper_rail==4095
            for (key,value) in (("profile","copper"),("profile","unknown"),("backend","unknown"),("backend",backend=="cuda" ? "amdgpu" : "cuda"))
                changed=deepcopy(f.report);changed[key]=value;write(f.report_path,JSON3.write(changed))
                @test_throws ArgumentError CA.validate_recording(f.package,f.report_path)
            end
            changed=deepcopy(f.report);delete!(changed,"correction_truth");write(f.report_path,JSON3.write(changed))
            @test_throws ArgumentError CA.validate_recording(f.package,f.report_path)
            write(f.report_path,JSON3.write(f.report))
            for argv in (["julia","--profile","copper","--backend",backend],
                ["julia","--profile","classic","--backend",backend,"--backend",backend],
                ["julia","--profile","classic","--backend="*backend])
                descriptor=deepcopy(f.descriptor);descriptor["owners"][1]["argv"]=argv
                write(joinpath(f.package,"deployment.conf"),JSON3.write(descriptor))
                @test_throws ArgumentError CA.validate_recording(f.package,f.report_path)
            end
            write(joinpath(f.package,"deployment.conf"),JSON3.write(f.descriptor))
            project=joinpath(f.package,"hil/Project.toml");original=read(project)
            for content in ("[deps]\n",backend=="cuda" ? "[deps]\nCUDA = \"wrong\"\n" : "[deps]\nAMDGPU = \"wrong\"\n")
                write(project,content)
                @test_throws ArgumentError CA.validate_recording(f.package,f.report_path)
            end
            write(project,original)
            bytes=read(f.frames);bytes[1:2]=reinterpret(UInt8,[htol(UInt16(4096))]);write(f.frames,bytes)
            changed=deepcopy(f.report);changed["frame"]["sha256"]=CA.file_hash(f.frames)
            changed["correction_truth"]["frame_sha256"]=changed["frame"]["sha256"];write(f.report_path,JSON3.write(changed))
            @test_throws ArgumentError CA.validate_recording(f.package,f.report_path)
        end
        for bits in (14,16,12.0)
            mktempdir() do root
                f=classic_gpu_fixture(root,backend);plant=TOML.parsefile(f.graph)
                only(filter(n->n["name"]=="detector",plant["nodes"]))["config"]["bits"]=bits
                open(io->TOML.print(io,plant),f.graph,"w")
                @test_throws ArgumentError CA.validate_recording(f.package,f.report_path)
            end
        end
    end
end
@testset "Classic GPU replay stages declared products and fails closed" begin
    for backend in ("cuda","amdgpu")
        mktempdir() do root
            f=classic_gpu_fixture(root,backend);recording=CA.validate_recording(f.package,f.report_path)
            fake=fake_replay_simulator(;frame_shape=(352,352))
            result=CA.replay(fake.simulator,recording,joinpath(root,"classic-gpu"))
            @test result.verified && result.live_truth_verified && result.baseline_verified
            @test first(fake.selected)==(:classic,Symbol(backend))
            @test result.replayed_adc.shape==[352,352]
            @test result.verification_basis=="exact direct live public OPD witness and zero-command baseline"
            @test result.zero_comparison==(;rtol=8*Float64(eps(Float32)),atol_m=0.0,comparison="elementwise")
            @test CA.adc_bytes(Val(:classic),fill(4095f0,352,352);upper_rail=recording.adc_upper_rail)==repeat(UInt8[0xff,0x0f],352*352)
            @test_throws ArgumentError CA.adc_bytes(Val(:classic),fill(4096f0,352,352);upper_rail=recording.adc_upper_rail)
            changed=deepcopy(f.report);changed["correction_truth"]["per_frame"][2]["pupil_sha256"]="0"^64
            write(f.report_path,JSON3.write(changed));tampered=CA.validate_recording(f.package,f.report_path)
            bad=fake_replay_simulator(;frame_shape=(352,352));rejected=CA.replay(bad.simulator,tampered,joinpath(root,"bad-truth"))
            @test !rejected.verified && rejected.adc_exact && !rejected.live_truth_verified
            @test only(rejected.windows).residual_to_atmosphere_variance_ratio===nothing
            bad=fake_replay_simulator(;baseline_mismatch=true,frame_shape=(352,352))
            rejected=CA.replay(bad.simulator,recording,joinpath(root,"bad-baseline"))
            @test !rejected.verified && rejected.live_truth_verified && !rejected.baseline_verified
            unavailable=fake_replay_simulator(;unavailable=true,frame_shape=(352,352))
            @test_throws ErrorException CA.replay(unavailable.simulator,recording,joinpath(root,"unavailable"))
            @test isempty(unavailable.selected)
        end
    end
end
