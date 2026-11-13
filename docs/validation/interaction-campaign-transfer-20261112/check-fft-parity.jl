using PipeWireAORTC, LinearAlgebra, YAML
const Calibration = PipeWireAORTC.InstrumentCalibration
const FITS = PipeWireAORTC.Artifacts.FITSIO.FITS
root = only(ARGS)
function compare(root, first, second; exact=false)
    paths = (joinpath(root, first*"-gpi2-bundle"), joinpath(root, second*"-gpi2-bundle"))
    a, b = map(Calibration.read_bundle, paths)
    @assert keys(a.artifacts) == keys(b.artifacts)
    @assert a.report["retained_rank"] == b.report["retained_rank"] == 1445
    @assert a.report["mode_count"] == b.report["mode_count"] == 1509
    for file in ("graph.conf","context.yaml")
        @assert read(joinpath(paths[1],file)) == read(joinpath(paths[2],file))
    end
    println(first, " versus ",second)
    changed = sort!([k for k in keys(a.artifacts) if
        a.report["artifact_sha256"][k] != b.report["artifact_sha256"][k]])
    @assert !exact || isempty(changed) changed
    for file in changed
        x,y = map(bundle -> FITS(f -> Float64.(read(f[1])), bundle.artifacts[file], "r"), (a,b))
        println(file, " relative L2 ", norm(x-y)/norm(x), " maximum absolute ", maximum(abs,x-y))
    end
    @show length(a.artifacts) length(changed)
    if exact
        @assert a.report == b.report
    end
    reports = map(s -> YAML.load_file(joinpath(root,s*"-gpi2-report.yaml")), (first,second))
    for r in reports
        @assert r["passed"] && r["steps"] == 48
        @show Dict(k => c["residual_ratio"] for (k,c) in r["cases"])
        delete!(r,"calibration_sha256")
        foreach(c -> delete!(c,"step_ms"), values(r["cases"]))
    end
    @assert !exact || reports[1] == reports[2]
end
compare(root,"baseline","baseline-repeat")
compare(root,"baseline-estimate","candidate-estimate"; exact=true)
