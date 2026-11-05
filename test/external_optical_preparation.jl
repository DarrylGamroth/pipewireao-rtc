# Optional CPU selector: shared RTC configuration plus AOS/Proper/HIL packages.
using Test, PipeWireAORTC, AdaptiveOpticsSim, AdaptiveOpticsSimPipeWireHIL, Proper
using AdaptiveOpticsSim.AlgorithmGraphs
using AdaptiveOpticsSim.Backends: HostComputeDevice
const IC = PipeWireAORTC.InstrumentConfiguration
Base.include(@__MODULE__, joinpath(@__DIR__, "external_optical_documents.jl"))

@testset "external optical graph uses the standard typed AOS preparation path" begin
    mktempdir() do directory
        physical, simulation = external_optical_documents()
        path = write_external_optical_documents(directory, physical, simulation)
        @test_throws ArgumentError IC.prepare_system(path) # Production must be explicitly declared.
        system = IC.prepare_system(path; simulation_graph = "llowfs")
        @test system.boundary === nothing
        @test system.driver === nothing
        @test isempty(system.mirror_descriptions)
        @test system.declaration.path == path
        @test system.configured == IC.settings(system.declaration)
        @test system.settings.profile == "reference"
        @test size(graph_input(system.graph, :pupil_opd)) == (4, 4)
        @test size(graph_output(system.graph, :intensity)) == (8, 8)
        fill!(graph_input(system.graph, :pupil_amplitude), 1)
        step_graph!(system.graph)
        image = copy(graph_output(system.graph, :intensity))
        @test all(isfinite, image)
        @test sum(image) ≈ 4
        fill!(graph_input(system.graph, :pupil_amplitude), 2)
        step_graph!(system.graph)
        @test graph_output(system.graph, :intensity) ≈ 4 .* image
        reset_graph!(system.graph)
        fill!(graph_input(system.graph, :pupil_amplitude), 1)
        step_graph!(system.graph)
        @test graph_output(system.graph, :intensity) == image
    end
end

@testset "shared external-pupil preparation selects post-exposure response graphs" begin
    mktempdir() do directory
        physical, simulation = external_optical_documents()
        physical["optical_paths"] = Dict(
            "scc"=>Dict("sensor"=>"scc", "lyot_stop_port"=>"transmitted"),
            "llowfs"=>Dict("sensor"=>"llowfs", "lyot_stop_port"=>"reflected"),
        )
        for sensor in values(physical["wavefront_sensors"])
            sensor["acquisition"] = Dict("exposure_duration_s"=>0.002)
        end
        path = write_external_optical_documents(directory, physical, simulation)
        authored_response!(directory, physical, simulation; mtf = true)
        simulation["observations"]["llowfs"] = pop!(simulation["observations"], "low_order")
        simulation["observations"]["llowfs"]["graph"] = "llowfs_response"
        simulation["graphs"] = Dict{String,Any}(simulation["graphs"])
        simulation["graphs"]["llowfs_response"] = "simulation/low_order_response.yaml"
        config=simulation["components"]["low_order_detector"]["config"]
        config["pixel_sampling_m"] = [0.003, 0.003] # diameter / declared pupil resolution
        config["photon_noise"] = false
        config["readout_noise"] = false
        for detector in ("ingaas", "hgcdte_linear_avalanche_array")
            simulation["components"]["low_order_detector"]["template"] = detector
            write_external_optical_documents(directory, physical, simulation)
            target = HostComputeDevice()
            prepared=IC.prepare_external_pupil(
                path;
                target,
                execution = StreamGraphExecution(),
            )
            @test keys(prepared.graphs) == (:llowfs, :scc)
            @test all(graph -> graph.target === target, prepared.graphs)
            @test prepared.observations.llowfs.response.graph.target === target
            @test hasproperty(prepared.observations.llowfs, :response)
            @test !hasproperty(prepared.observations.scc, :response)
            @test prepared.observations.llowfs.response.frame_schema ==
                  config["frame_schema"]
            emissions=Any[]
            emit(name, image, metadata) = push!(emissions, (copy(image), metadata))
            step_external_pupil!(
                emit,
                prepared,
                zeros(4, 4),
                ones(4, 4),
                ModelTimestamp(0),
                ModelDuration(2_000_000);
                domain = ntuple(_->UInt8(1), 16),
                generation = UInt64(1),
                sequence = UInt64(1),
            )
            @test length(emissions)==2
            response=only(
                filter(
                    item->get(item[2], :quantity, :intensity)==:detector_frame,
                    emissions,
                ),
            )
            @test response[1] ≈
                  Float32.(prepared.exposures.llowfs.image .* 100 .* 0.002 .* 0.8)
            @test_throws AlgorithmGraphs.AlgorithmGraphError IC.prepare_external_pupil(
                path;
                target,
                execution = GroupedStreamGraphExecution((:unknown_node,)),
            )
            config["pixel_sampling_m"]=[0.001, 0.001]
            write_external_optical_documents(directory, physical, simulation)
            @test_throws AlgorithmGraphs.AlgorithmGraphError IC.prepare_external_pupil(path)
            config["pixel_sampling_m"]=[0.003, 0.003]
        end
        physical["wavefront_sensors"]["llowfs"]["expected_schema"] = "example.incompatible/1"
        write_external_optical_documents(directory, physical, simulation)
        @test_throws ArgumentError IC.prepare_external_pupil(path)
        physical["wavefront_sensors"]["llowfs"]["expected_schema"] = config["frame_schema"]
        config["exposure_duration_s"]=0.001
        write_external_optical_documents(directory, physical, simulation)
        @test_throws ArgumentError IC.prepare_external_pupil(path)
    end
end

@testset "physical camera permits an explicit ROI with an unknown sensor origin" begin
    mktempdir() do directory
        physical, simulation = external_optical_documents()
        physical["optical_paths"] =
            Dict("llowfs"=>Dict("sensor"=>"llowfs", "lyot_stop_port"=>"reflected"))
        path = write_external_optical_documents(directory, physical, simulation)
        authored_response!(directory, physical, simulation)
        simulation["observations"]["llowfs"] = pop!(simulation["observations"], "low_order")
        simulation["observations"]["llowfs"]["graph"] = "llowfs_response"
        simulation["graphs"] = Dict{String,Any}(simulation["graphs"])
        simulation["graphs"]["llowfs_response"] = "simulation/low_order_response.yaml"
        config = simulation["components"]["low_order_detector"]["config"]
        config["pixel_sampling_m"] = [0.003, 0.003]
        camera = physical["wavefront_sensors"]["llowfs"]
        camera["detector"] = Dict(
            "name"=>"CRED2",
            "rows"=>12,
            "columns"=>14,
            "pixel_sampling_m"=>[0.003, 0.003],
        )
        write_external_optical_documents(directory, physical, simulation)
        plant = IC.prepare_external_pupil(path)
        @test size(graph_output(plant.observations.llowfs.response.graph, :frame)) == (8, 8)
        declaration = IC.load_simulation(path)
        owner = Base.get_extension(PipeWireAORTC, :PipeWireAORTCAOSExt).ExternalPupilOwner
        contract = owner.sensor_contract(
            declaration,
            IC.settings(declaration),
            plant,
            :llowfs,
            "sha256:"*repeat("a", 64),
        )
        @test contract.properties["detector.roi-origin-known"] == "false"
        @test contract.properties["detector.roi-shape"] == "8,8"
        @test !haskey(contract.properties, "detector.roi-origin")
        @test !haskey(
            IC.load_simulation(path).instrument.document["wavefront_sensors"]["llowfs"]["acquisition"],
            "roi_origin",
        )
        camera["acquisition"] = Dict{String,Any}(camera["acquisition"])
        camera["acquisition"]["roi_origin"] = [4, 6]
        write_external_optical_documents(directory, physical, simulation)
        known = IC.prepare_external_pupil(path)
        declaration = IC.load_simulation(path)
        contract = owner.sensor_contract(
            declaration,
            IC.settings(declaration),
            known,
            :llowfs,
            "sha256:"*repeat("a", 64),
        )
        @test contract.properties["detector.roi-origin-known"] == "true"
        @test contract.properties["detector.roi-origin"] == "4,6"
        camera["acquisition"]["roi_origin"] = [5, 6]
        write_external_optical_documents(directory, physical, simulation)
        @test_throws ArgumentError IC.prepare_external_pupil(path)
        delete!(camera["acquisition"], "roi_origin")
        camera["detector"]["rows"] = 7
        write_external_optical_documents(directory, physical, simulation)
        @test_throws ArgumentError IC.prepare_external_pupil(path)
        camera["detector"]["rows"] = 12
        camera["detector"]["pixel_sampling_m"] = [0.004, 0.003]
        write_external_optical_documents(directory, physical, simulation)
        @test_throws ArgumentError IC.prepare_external_pupil(path)
    end
end
