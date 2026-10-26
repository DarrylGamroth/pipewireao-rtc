using LinearAlgebra, Statistics, Serialization, Libdl
using PipeWireAORTC, AdaptiveOpticsSim, AdaptiveOpticsSimPipeWireHIL
const A = AdaptiveOpticsSim.AlgorithmGraphs
const I = PipeWireAORTC.InstrumentConfiguration
const C = PipeWireAORTC.Common
const APP = "/home/dgamroth/.local/state/pipewireao/gpi2-registered-live-20261025/application"
const OUT = "/home/dgamroth/.cache/pipewireao/gpi2-tiptilt-20261025"
function main()
    BLAS.set_num_threads(1)
    declaration=I.load_simulation(joinpath(APP,"simulation/definition.yaml"))
    settings=I.settings(declaration,Dict())
    system=I.prepare_system(declaration.path;calibration=true,target=AdaptiveOpticsSim.Backends.HostComputeDevice())
    support=I.binding_values(declaration,settings,Dict("kind"=>"pupil_support","resolution"=>"pupil_resolution"))
    valid=findall(vec(support).!=0)
    xy=I.binding_values(declaration,settings,Dict("kind"=>"pupil_coordinates","resolution"=>"pupil_resolution"))
    B=hcat(ones(length(valid)),Float64.(reshape(xy,:,2)[valid,:]))
    Q=pinv(B)
    maps=Dict{String,Matrix{Float64}}()
    optical_checks=Dict()
    for mirror in ("woofer","tweeter")
        owner=A.prepared_graph_node(system.graph,Symbol(mirror))
        dm=owner.deformable_mirror
        @assert dm.state.separable_x !== nothing
        x=Float64.(dm.state.separable_x); y=Float64.(dm.state.separable_y_t)
        support_exact=Float64.(AdaptiveOpticsSim.Optics._separable_surface_support(dm.state.modes))
        projection=zeros(3,length(owner.pdm_command))
        for k in 1:3
            field=zeros(size(support)); field[valid].=Q[k,:]
            full=x'*(field.*support_exact)*y'
            projection[k,:].=vec(full)[owner.actuator_grid_indices]
        end
        maps[mirror]=projection
        owner.pdm_command .= Float32.(1e-8 .* sin.(eachindex(owner.pdm_command)))
        A.step_graph_node!(owner)
        direct=Q*Float64.(vec(owner.output)[valid])
        predicted=projection*Float64.(owner.pdm_command)
        optical_checks[mirror]=Dict("max_abs_projection_error_m"=>maximum(abs,direct-predicted),"direct_coefficients_m"=>direct)
    end
    fits=PipeWireAORTC.Artifacts.FITSIO
    readfit(name)=fits.FITS(joinpath(APP,"calibration/artifacts",name*".fits"),"r") do file
        x=read(file[1]); ndims(x)==1 ? x : permutedims(x,reverse(ntuple(identity,ndims(x))))
    end
    P=Float64.(readfit("woofer-vdm-to-pdm")); F=Float64.(readfit("tiptilt-to-woofer"))
    G=maps["woofer"]
    report=Dict("scope"=>"Offline CPU optical projection; exact deployed package and calibration assets; no live attachment",
        "packages"=>Dict("PipeWireAORTC"=>pathof(PipeWireAORTC),"AdaptiveOpticsSim"=>pathof(AdaptiveOpticsSim)),
        "pupil_pixels"=>length(valid),"pupil_xy_rms"=>sqrt.(mean(abs2,B[:,2:3];dims=1))[:],
        "optical_projection_checks"=>optical_checks,
        "woofer_fit_pupil_tt_response"=>G[2:3,:]*F,
        "woofer_high_order_optical_tt_row_norm"=>sqrt.(sum(abs2,G[2:3,:]*P[:,3:end];dims=2))[:],
        "woofer_high_order_optical_tt_max_coefficient"=>maximum(abs,G[2:3,:]*P[:,3:end]),
        "woofer_high_order_actuator_fit_orthogonality"=>maximum(abs,F'*P[:,3:end]),
        "woofer_fit_equals_projection_first_columns_max_abs"=>maximum(abs,F-P[:,1:2]),
        "filter_coefficients"=>Dict(name=>readfit(name) for name in ("tiptilt-filter-coefficients","modal-filter-coefficients")),
        "offset_max_abs_m"=>Dict(name=>maximum(abs,readfit(name)) for name in ("woofer-offset","tweeter-offset","tiptilt-offset","woofer-system-flat","tweeter-system-flat")))
    @assert !any(id->id.name in ("CUDA","AMDGPU","GPUCompiler"),keys(Base.loaded_modules))
    serialize(joinpath(OUT,"optical-maps.jls"),(maps=maps,P=P,F=F,report=report))
    C.write_json(joinpath(OUT,"optical-maps-report.json"),report)
    println(report)
end
main()
