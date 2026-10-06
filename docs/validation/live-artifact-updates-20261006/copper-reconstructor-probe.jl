using FilterGraphAlgorithms, FilterGraphPipeWire, JuliaFilterGraph, PipeWireAO, SHA, LinearAlgebra
const FGA=FilterGraphAlgorithms
const FGPW=FilterGraphPipeWire
const JFG=JuliaFilterGraph
const INSTALLED="/tmp/copper-jfg-main-noobs-v2-installed"
const GRAPH_TEXT="""
filter.graph = {
    nodes = [{
        type = ndarray
        name = reconstruct
        label = pwfs-pupil-reconstructor-f32
        config = {
            reconstructed_schema = org.calculon.ao.controller-residual-error/1
            initial_reconstructor = null
            reconstructed_count = 253
            selected_pixel_count = 900
        }
    }]
    links = []
    inputs = [ "reconstruct:reconstruction-pixels" "reconstruct:reconstructor" ]
    outputs = [ "reconstruct:reconstructed" ]
}
"""
stage!(o,m)=FGPW._stage_parameter_transaction!(o,:reconstructor=>m)
adopt!(o)=FGPW._adopt_pending_parameters!(o)
process!(o,i,u)=JFG._process_admitted!(u,o.graph,i,o.graph.default_input_metadata)
function adopt_process!(o,i,u)
    adopt!(o) || error("no pending reconstructor")
    return process!(o,i,u)
end
measure_stage!(o,m)=@allocated stage!(o,m)
measure_adopt!(o)=@allocated adopt!(o)
measure_process!(o,i,u)=@allocated process!(o,i,u)
measure_adopt_process!(o,i,u)=@allocated adopt_process!(o,i,u)
measure_public_process!(o,i,u)=@allocated JFG.process!(u,o.graph,i)
function scalar_oracle(matrix,pixels)
    y=zeros(Float64,size(matrix,1))
    # Explicit pupil-major semantic input order, independent of BLAS and Workspace.
    for row in eachindex(y)
        s=0.0
        for pupil in 1:4, pixel in 1:900
            column=(pupil-1)*900+pixel
            s+=Float64(matrix[row,column])*Float64(pixels[pupil,pixel])
        end
        y[row]=s
    end
    return y
end
function check_output(output,oracle)
    delta=maximum(abs(Float64(output[k])-oracle[k]) for k in eachindex(output))
    bound=2e-6*maximum(abs,oracle)+1e-7
    @assert delta<=bound (delta,bound)
    @assert all(isfinite,output)
    @assert maximum(abs,output)>1e-5
    return delta
end
function main()
    GC.enable(true)
    println("julia_version=",VERSION," julia_threads=",Threads.nthreads()," blas_threads=",BLAS.get_num_threads()," gc_enabled=true")
    for mod in (FGA,FGPW,JFG,PipeWireAO)
        println("package=",nameof(mod)," version=",pkgversion(mod)," source=",pathof(mod))
    end
    for (mod,rel) in ((FGPW,"graph_node.jl"),(JFG,"parameters.jl"),(JFG,"graph.jl"),(FGA,"algorithms/wavefront_sensor/pyramid_pupil_reconstruction.jl"),(FGA,"algorithms/wavefront_sensor/dense_reconstruction.jl"))
        file=joinpath(dirname(pathof(mod)),rel)
        println("source_sha256 ",rel,"=",bytes2hex(sha256(read(file))))
    end
    calibration=joinpath(INSTALLED,"calibration/parameter-reconstructor.f32")
    raw=read(calibration)
    @assert length(raw)==253*3600*sizeof(Float32)
    println("calibration=",calibration," bytes=",length(raw)," sha256=",bytes2hex(sha256(raw))," layout=row-major element_type=F32_LE")
    @assert ENDIAN_BOM==0x04030201
    values=reinterpret(Float32,raw)
    matrix_a=Matrix{Float32}(undef,253,3600)
    for row in 1:253, column in 1:3600
        matrix_a[row,column]=values[(row-1)*3600+column]
    end
    matrix_b=0.99f0 .* matrix_a
    @assert all(isfinite,matrix_a)
    graph=mktemp() do path,io
        write(io,GRAPH_TEXT);flush(io)
        prepare_graph(path;algorithms=(PyramidPupilReconstructorF32,))
    end
    o=FGPW.PreparedGraphOwner(graph)
    pixels=Matrix{Float32}(undef,4,900)
    for pupil in 1:4, pixel in 1:900
        pixels[pupil,pixel]=(Float32(pupil)-2.5f0)*0.01f0+Float32(pixel)*0.0001f0
    end
    i=NamedTuple{keys(graph.input_formats)}((pixels,))
    u=NamedTuple{keys(graph.output_formats)}((zeros(Float32,253),))
    reference_a=scalar_oracle(matrix_a,pixels)
    reference_b=scalar_oracle(matrix_b,pixels)
    println("plan_type=",typeof(only(graph.nodes).prepared.plan)," workspace_type=",typeof(only(graph.nodes).prepared.workspace)," parameter_transaction_type=",typeof(o.parameter_transaction))
    println("graph_nodes=",length(graph.nodes)," algorithm=",PyramidPupilReconstructorF32," input_type=",typeof(i)," output_type=",typeof(u))
    stage!(o,matrix_a);adopt_process!(o,i,u)
    maxerror=check_output(u.reconstructed,reference_a)
    before=copy(u.reconstructed)
    # Warm exactly the measured barriers: 32 sequences of isolated adoption/process,
    # checked public processing, then combined adoption/process.
    for k in 1:32
        matrix=isodd(k) ? matrix_a : matrix_b
        oracle=isodd(k) ? reference_a : reference_b
        measure_stage!(o,matrix);measure_adopt!(o)
        measure_process!(o,i,u);maxerror=max(maxerror,check_output(u.reconstructed,oracle))
        measure_public_process!(o,i,u);maxerror=max(maxerror,check_output(u.reconstructed,oracle))
        stage!(o,isodd(k) ? matrix_b : matrix_a)
        measure_adopt_process!(o,i,u)
        maxerror=max(maxerror,check_output(u.reconstructed,isodd(k) ? reference_b : reference_a))
    end
    bstage=Int[];badopt=Int[];bprocess=Int[];bpublic=Int[];bcombined=Int[]
    for k in 1:64
        matrix=isodd(k) ? matrix_a : matrix_b
        oracle=isodd(k) ? reference_a : reference_b
        push!(bstage,measure_stage!(o,matrix))
        push!(badopt,measure_adopt!(o))
        @assert only(graph.nodes).prepared.plan.matrix==matrix
        push!(bprocess,measure_process!(o,i,u));maxerror=max(maxerror,check_output(u.reconstructed,oracle))
        push!(bpublic,measure_public_process!(o,i,u));maxerror=max(maxerror,check_output(u.reconstructed,oracle))
        stage!(o,isodd(k) ? matrix_b : matrix_a)
        push!(bcombined,measure_adopt_process!(o,i,u))
        maxerror=max(maxerror,check_output(u.reconstructed,isodd(k) ? reference_b : reference_a))
    end
    for (name,bytes) in (("control_reconstructor_staging",bstage),("reconstructor_adoption",badopt),("full_admitted_graph_process",bprocess),("full_public_graph_process",bpublic),("reconstructor_adoption_and_full_graph_process",bcombined))
        println(name," samples=",length(bytes)," min_bytes=",minimum(bytes)," max_bytes=",maximum(bytes)," sum_bytes=",sum(bytes))
    end
    println("matrix_shape=",size(matrix_a)," input_shape=",size(pixels)," scales=(1.0,0.99) warm_sequences=32 measured_sequences=64 numerical_checks_before_final_cycle=289 max_abs_error=",maxerror)
    println("before_scale1 first5=",before[1:5]," l2_norm=",norm(before))
    stage!(o,matrix_b);adopt_process!(o,i,u);check_output(u.reconstructed,reference_b)
    println("after_scale0.99 first5=",u.reconstructed[1:5]," l2_norm=",norm(u.reconstructed)," difference_l2_norm=",norm(u.reconstructed-before))
    println("SUCCESS")
end
main()
