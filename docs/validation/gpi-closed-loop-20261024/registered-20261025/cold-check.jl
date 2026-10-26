using PipeWireAORTC, FilterGraphAlgorithms, JuliaFilterGraph, FilterGraphPipeWire, FilterGraphIsland, TOML, Test
const app="/home/dgamroth/.local/state/pipewireao/gpi2-registered-live-20261025/application"
const previous="/home/dgamroth/.local/state/pipewireao/gpi2-shape-live-20261025/application"
old=TOML.parsefile(joinpath(previous,"Manifest.toml"))["deps"]
new=TOML.parsefile(joinpath(app,"Manifest.toml"))["deps"]
versions=Dict("FilterGraphAlgorithms"=>"0.8.0","JuliaFilterGraph"=>"0.4.2","FilterGraphPipeWire"=>"0.1.7","FilterGraphIsland"=>"0.1.3")
@testset "Exact registered package upgrade and retained science" begin
 @test Set(keys(old))==Set(keys(new))
 for name in keys(old)
  x=only(old[name]); y=only(new[name])
  if haskey(versions,name)
   @test y["version"]==versions[name]
   @test !haskey(y,"path")
  else
   @test all(get(x,k,nothing)==get(y,k,nothing) for k in ("version","git-tree-sha1","path","repo-url","repo-rev"))
  end
 end
 for (root,dirs,files) in walkdir(joinpath(previous,"calibration"))
  for file in files
   relative=relpath(joinpath(root,file),previous)
   @test read(joinpath(previous,relative))==read(joinpath(app,relative))
  end
 end
end
ENV["GPI2_OFFLINE_APPLICATION"]=app
include("/home/dgamroth/.local/state/pipewireao/gpi2-registered-live-20261025/verification-tools/offline_preflight.jl")
@testset "Actual graph FITS preparation with registered providers" begin
 values=PipeWireAORTC.GraphOwner.read_bindings(joinpath(app,"rtc/graph.conf"),joinpath(app,"rtc/parameters.conf"))
 @test !isempty(values)
 @test size(values[Symbol("woofer-system-flat")])==(97,)
 @test size(values[Symbol("tweeter-system-flat")])==(2304,)
 println("Validated ",length(values)," startup FITS bindings before execution")
end
