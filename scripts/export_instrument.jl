# Cold export in the site environment selected by the operator CLI.
using PipeWireAORTC: InstrumentExport

source, destination, profile, host = ARGS
if !isfile(joinpath(source, "Project.toml")) && !isdefined(InstrumentExport, :source_project)
    throw(ArgumentError("the selected site RTC requires an instrument Project.toml; " *
        "update the site runtime to export definitions without one"))
end
manifest = joinpath(dirname(Base.active_project()), "Manifest.toml")
println(InstrumentExport.prepare(source, destination;
    profile = InstrumentExport.load_profile(profile; host), manifest))
