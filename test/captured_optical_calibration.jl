# Optional native-free selector: PIPEWIREAORTC_TEST_BACKEND=cpu|cuda|amdgpu.
using Test, LinearAlgebra, PipeWireAORTC, AdaptiveOpticsSim, AdaptiveOpticsSimPipeWireHIL, Proper
using AdaptiveOpticsCalibration, FilterGraphAlgorithms, FilterGraphIsland, FilterGraphPipeWire, JuliaFilterGraph
using AdaptiveOpticsSim.AlgorithmGraphs
import AdaptiveOpticsSim.Backends as B
BLAS.set_num_threads(1)
B.set_fft_provider_threads!(1)
backend=get(ENV,"PIPEWIREAORTC_TEST_BACKEND","cpu")
target=if backend=="cuda"
    @eval using CUDA
    CUDA.allowscalar(false)
    B.AcceleratorComputeDevice(B.CUDABackend(),0)
elseif backend=="amdgpu"
    @eval using AMDGPU
    AMDGPU.allowscalar(false)
    B.AcceleratorComputeDevice(B.AMDGPUBackend(),1)
elseif backend=="cpu"
    B.HostComputeDevice()
else
    error("unsupported test backend")
end
const IC=PipeWireAORTC.InstrumentConfiguration
const Calibration=PipeWireAORTC.InstrumentCalibration
const Implementation=Base.get_extension(PipeWireAORTC,:PipeWireAORTCCalibrationExt)
Base.include(@__MODULE__,joinpath(@__DIR__,"pupil_source_documents.jl"))
Base.include(@__MODULE__,joinpath(@__DIR__,"chopped_calibration_documents.jl"))

@testset "captured physical mirror and matched chopped optical calibration" begin
    @test_throws ArgumentError Implementation.optical_callbacks("unused","unused";
        mirror="primary",branches=(scc="scc",),target=nothing)
    for precision in (Float64,Float32)
        mktempdir() do directory
            upstream=pupil_source_documents(joinpath(directory,"upstream"))
            physical,simulation=external_optical_documents()
            for binding in values(simulation["bindings"])
                binding["type"]=string(precision)
            end
            node_type=precision===Float32 ? "proper_optical_train_f32" : "proper_optical_train_f64"
            simulation["components"]["optics"]["template"]=node_type
            physical["optical_paths"]=Dict("scc"=>Dict("sensor"=>"scc","lyot_stop_port"=>"transmitted"))
            physical["wavefront_sensors"]["scc"]["acquisition"]=Dict("exposure_duration_s"=>0.002)
            config=simulation["components"]["optics"]["config"]
            # Nonzero defocus yields a signed linear intensity response to the real mirror.
            config["steps"]=[Dict("op"=>"multiply","amplitude"=>0.5),Dict("op"=>"propagate","distance_m"=>0.01)]
            unfringed=deepcopy(simulation["graphs"]["scc"])
            unfringed["nodes"]=[Dict("name"=>"optics","type"=>node_type,"config"=>deepcopy(config))]
            unfringed["nodes"][1]["config"]["steps"][1]["amplitude"]=0.25
            simulation["graphs"]=Dict("scc"=>simulation["graphs"]["scc"],"unfringed"=>unfringed)
            path=write_external_optical_documents(joinpath(directory,"optical"),physical,simulation)
            chopping=(scc=(unfringed_graph="unfringed",initial_phase="fringed",trigger_high_is_fringed=true),)
            plan=(;rtc=(;document=Dict("dimensions"=>Dict("image_rows"=>8,"image_columns"=>8)),
                    controls=Dict("deformable_mirrors"=>Dict())),frames=Dict(),
                instrument=Dict("deformable_mirrors"=>Dict(),"wavefront_sensors"=>Dict()),
                templates=(scc=chopped_calibration_document((8,8)),),chopping)
            options=(;mirror="primary",branches=(scc="scc",),chopping,publication_plan=plan)
            reference=Implementation.optical_callbacks(upstream.path,path;options...)
            actual=Implementation.optical_callbacks(upstream.path,path;options...,target)
            graphs=(actual.mirror_graph,map(system->system.graph,values(actual.systems))...,
                map(system->system.graph,values(actual.unfringed_systems))...)
            @test length(graphs)==3
            for graph in graphs
                @test graph_execution_policy(graph) isa (backend=="cpu" ? StreamGraphExecution : CapturedGraphExecution)
                @test captured_graph_node_count(graph)==(backend=="cpu" ? 0 : length(graph.nodes))
            end
            @test_throws DimensionMismatch actual.observe(zeros(Float32,3,4))
            @test_throws ArgumentError actual.observe(fill(Float32(NaN),4,4))
            # F32 residuals subtract a bright F/U reference. This case-specific
            # rounding allowance applies once to the image norm (array isapprox),
            # alongside the derivative and held-out gates for the small signal.
            image_atol=precision===Float32 ? 4eps(Float32)*norm(reference.chopped_references.scc.difference) : 2e-8
            for command in (Float32[0,0],Float32[1e-8,-2e-8],Float32[-2e-8,1e-8],Float32[0,0])
                expected_opd=reference.surface(command)
                observed_opd=actual.surface(command)
                @test observed_opd≈expected_opd rtol=2e-5 atol=1e-14
                observed_image=actual.observe(observed_opd).scc
                @test observed_image≈reference.observe(expected_opd).scc rtol=1e-3 atol=image_atol
                all(iszero,command) && @test all(iszero,observed_image)
            end
            calibration_options=(;pupil_support=actual.pupil_support,branch_modes=(scc=1:2,),
                pixel_masks=(scc=trues(8,8),),poke_m=1e-8,tsvd_rtol=1e-5,
                derivative_tolerance=0.05,reconstruction_tolerance=0.05,signed_measurements=(:scc,))
            P=Matrix{Float32}(I,2,2)
            expected=Calibration.calibrate_optical(reference.surface,reference.observe,P;calibration_options...)
            observed=Calibration.calibrate_optical(actual.surface,actual.observe,P;calibration_options...)
            @test expected.report["status"]==observed.report["status"]=="accepted"
            @test observed.branches.scc.interaction≈expected.branches.scc.interaction rtol=2e-3
            @test observed.normalization≈expected.normalization rtol=2e-5
            @test observed.validation.accepted
            captured_nodes=map(captured_graph_node_count,graphs)
            interaction_relative_error=norm(observed.branches.scc.interaction-expected.branches.scc.interaction)/
                norm(expected.branches.scc.interaction)
            derivative_error=observed.branches.scc.derivative_error
            reconstruction_error=maximum(observed.validation.reconstruction_errors)
            @info "Small optical calibration" backend precision captured_nodes interaction_relative_error derivative_error reconstruction_error
            # CUDA optical calibration does not broaden the separate qualified upstream reference law.
            if backend=="cuda"
                @test_throws ArgumentError Calibration.calibrate_optical_reference("unused",observed;target,method="host-expectation")
            end
        end
    end
end
@test backend=="cuda" || !any(p.name=="CUDA" for p in keys(Base.loaded_modules))
@test backend=="amdgpu" || !any(p.name=="AMDGPU" for p in keys(Base.loaded_modules))
