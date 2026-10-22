using PipeWireAORTC
const C=PipeWireAORTC.Common
const root=@__DIR__
const app=joinpath(root,"cpu-application")
cp("/home/dgamroth/workspaces/codex/worktrees/wavefront-series-20261022/cpu-application",app)
cp("/home/dgamroth/workspaces/codex/pipewire/pipewireao-rtc-detector/test/integration/classic_fft_oracle.jl",joinpath(app,"classic_fft_oracle.jl"))
spec=C.read_json(joinpath(app,"deployment.conf"))
spec["name"]="revolt-classic-cpu-exact-fft-oracle"
owner=only(filter(o->any(s->occursin("AOSOwner.main",s),o["argv"]),spec["owners"]))
index=findfirst(==("-e"),owner["argv"])+1
owner["argv"][index]="using PipeWireAORTC; include(\"@PACKAGE@/classic_fft_oracle.jl\"); Main.ClassicFFTOracle.record_native!(joinpath(ENV[\"PIPEWIREAO_RUNTIME_DIR\"],\"fft-oracle\")); PipeWireAORTC.AOSOwner.main(ARGS)"
spec["artifacts"]["classic_fft_oracle.jl"]=C.sha256_file(joinpath(app,"classic_fft_oracle.jl"))
for path in keys(spec["artifacts"])
    spec["artifacts"][path]=C.sha256_file(joinpath(app,path))
end
C.write_json(joinpath(app,"deployment.conf"),spec)
println("Test-only native FFT witness sealed; unchanged science and 32-frame CPU configuration")
