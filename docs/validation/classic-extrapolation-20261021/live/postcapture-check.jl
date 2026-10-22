using Test, PipeWireAORTC, FilterGraphIsland, JuliaFilterGraph, Statistics
include("/home/dgamroth/workspaces/codex/pipewire/revolt-classic-rtc/calibration.jl")
include("/home/dgamroth/workspaces/codex/pipewire/pipewireao-rtc-classic-extrapolation/test/integration/classic_replay.jl")
K=ClassicCalibration;C=PipeWireAORTC.Common
application,stage=ARGS
frames=reshape(reinterpret(UInt16,read(joinpath(stage,"frames-u16-row-major.bin"))),352*352,256)
demanded=reshape(reinterpret(Float32,read(joinpath(stage,"demanded-f32-micrometre.bin"))),277,256)
central=[119,120,121,138,139,140,157,158,159]
graph=K.controller_graph(application);storage=K.controller_storage(graph)
clips=0;central_clips=0;roles=zeros(UInt8,277)
@testset "Recorded completed-basis commands" begin
    try
        ClassicReplay.load_frame!(storage.raw,frames,1)
        JuliaFilterGraph.process!(storage.outputs,graph,storage.inputs)
        JuliaFilterGraph.reset!(graph);fill!(storage.feedback,0)
        for index in axes(frames,2)
            ClassicReplay.load_frame!(storage.raw,frames,index)
            @test all(values(JuliaFilterGraph.process!(storage.outputs,graph,storage.inputs)))
            @test storage.outputs.demanded==demanded[:,index]
            residual=getproperty(storage.outputs,Symbol("constraint-feedback"))
            global clips+=count(!iszero,residual)
            global central_clips+=count(!iszero,residual[central])
            copyto!(roles,getproperty(storage.outputs,Symbol("correction-role")))
            copyto!(storage.feedback,getproperty(storage.outputs,Symbol("controller-constraint-feedback")))
        end
        @test clips==0
        @test central_clips==0
        @test all(==(2),roles[central])
        @test any(!iszero,demanded[central,:])
    finally
        FilterGraphIsland.close_execution(graph)
    end
end
C.write_json(joinpath(stage,"command-check.json"),Dict("frames"=>256,"physical_constraint_nonzero_samples"=>clips,"central_constraint_nonzero_samples"=>central_clips,"max_command_um"=>maximum(abs,demanded),"max_central_command_um"=>maximum(abs,demanded[central,:]),"central_actuator_ids"=>central,"central_roles"=>roles[central],"central_commands_nonzero"=>any(!iszero,demanded[central,:]),"calibration_identity"=>C.read_json(joinpath(application,"simulation.conf"))["calibration_identity"],"scope"=>"Direct replay of captured frames, exact physical command equality and preclipping constraint residual check"))
