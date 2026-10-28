using Test, LinearAlgebra, PipeWireAORTC
const O=PipeWireAORTC.PhysicalOffsets
const C=PipeWireAORTC.Common
const A=PipeWireAORTC.InstrumentCalibration

Base.include(@__MODULE__,joinpath(@__DIR__,"physical_offset_inputs_documents.jl"))

@testset "P/Q-only receiver admits exact physical bindings without reference compensation" begin
    mktempdir() do root
        directory=joinpath(root,"receiver");mkpath(directory)
        document=physical_inputs_document(directory)
        cp(joinpath(directory,"projection.fits"),joinpath(root,"outside.fits"))
        path=joinpath(directory,"offsets.yaml")
        prepare()=O.prepare(path;command_count=4,command_order="actual-physical-order",calibration_identity="accepted-calibration")
        C.write_yaml(path,document)
        prepared=prepare()
        @test prepared.inputs.names==(:llowfs,:scc)
        @test all(iszero,prepared.inputs.total)
        @test all(!c.armed for c in values(prepared.inputs.receiver.branches))
        @test !haskey(prepared.inputs.declaration,"reference")
        for change in (d->(d["version"]=1),d->(d["reference"]=deepcopy(d["inverse"])),
                d->(d["command_order"]="other"),d->(d["calibration_identity"]="other"),
                d->(d["projection"]["sha256"]=repeat("0",64)),
                d->(d["branches"]["scc"]["modes"]=[1]),
                d->(d["branches"]["scc"]["node_name"]="receive-llowfs"),
                d->(d["branches"]["scc"]["acquisition_version"]=true))
            invalid=deepcopy(document);change(invalid);C.write_yaml(path,invalid)
            @test_throws ArgumentError prepare()
        end
        escaped=deepcopy(document);escaped["projection"]["path"]="../outside.fits"
        C.write_yaml(path,escaped)
        @test_throws PipeWireAORTC.DeploymentConfiguration.DeploymentError prepare()
        C.write_yaml(path,document)
        @test_throws DimensionMismatch O.prepare(path;command_count=5,command_order="actual-physical-order",calibration_identity="accepted-calibration")
    end
    @test all(id->id.name ∉ ("AdaptiveOpticsSim","AdaptiveOpticsSimPipeWireHIL","FilterGraphAlgorithms","JuliaFilterGraph","CUDA","AMDGPU"),keys(Base.loaded_modules))
end
