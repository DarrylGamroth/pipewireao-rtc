# Scratch-only repair for relocated precompile resources. Numerical methods,
# graph declarations and catalog bytes remain unchanged.
function install_resource_paths!()
 root=pkgdir(V.PipeWireAORTC)
 snippets=String[];identities=Dict{String,Any}()
 for (file,name) in (("components.jl","component_template_path"),("catalogs.jl","catalog_document"),("metadata.jl","simulation_catalog_identities"))
  sourcepath=joinpath(root,"src/instruments",file);source=read(sourcepath,String)
  start=findfirst("function "*name*"(",source)
  finish=findnext("\nend\n",source,last(start))
  original=source[first(start):last(finish)]
  @assert count("joinpath(@__DIR__, \"..\", \"..\",",original)==1
  patched=replace(original,"joinpath(@__DIR__, \"..\", \"..\","=>"joinpath(pkgdir(parentmodule(@__MODULE__)),")
  push!(snippets,patched)
  identities[name]=Dict("source_file"=>sourcepath,"source_sha256"=>C.sha256_file(sourcepath),"original_snippet_sha256"=>bytes2hex(sha256(original)),"patched_snippet_sha256"=>bytes2hex(sha256(patched)))
 end
 Base.include_string(V.IC,join(snippets,"\n"),@__FILE__)
 assets=Dict{String,String}()
 for (directory,_,filenames) in walkdir(joinpath(root,"data")),name in filenames
  endswith(name,".yaml") || continue
  path=joinpath(directory,name);assets[relpath(path,root)]=C.sha256_file(path)
 end
 return Dict("reason"=>"Relocated registered package precompile embeds absent ~/.julia source path. Scratch-only method replacement changes only resource-root expression from @__DIR__/../.. to pkgdir(parentmodule(@__MODULE__)).", "package_dir"=>root,"methods"=>identities,"asset_sha256"=>assets,"verification"=>"V.plant requires exact source prescription identity from original calibration receipt, which hashes all used template/catalog bytes and resolved declarations; assertion is unchanged")
end
