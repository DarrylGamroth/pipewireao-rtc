include("/home/dgamroth/.local/state/pipewireao/gpi2-registered-live-20261025/verification-tools/native_observation_helpers.jl")
const OUT = "/home/dgamroth/.cache/pipewireao/gpi2-tiptilt-20261025"
function main()
    receipt = Dict{String,Any}("completed"=>false,"scope"=>"Read-only command observation; no reset or parameter changes", "driver_sha256"=>C.sha256_file(@__FILE__))
    try
        identity = C.read_json(joinpath(ROOT,"live-identity.json"))
        before = unit_snapshot(identity["unit"])
        before["ActiveState"]=="active" && parse(Int,before["MainPID"])==identity["pid"] && before["InvocationID"]==identity["invocation"] || error("live identity changed")
        app = joinpath(identity["stage"],"installed")
        session = D.decode(joinpath(app,"rtc/session.conf.in"),PREFIX)
        specs = Tuple(s for s in M.observation_specs(app,PREFIX) if s.name!="detector")
        for mirror in ("woofer","tweeter")
            name=mirror*"-constraint-feedback"
            specs=(specs...,M.observation_spec(app,session,"rtc-"*name*"-queue-input",name,PREFIX))
        end
        samples=Any[]
        receipt["identity"]=identity
        receipt["observations"]=M.Observation.observe_classic(identity["remote"]; timeout=180,stream_specs=specs,
            drive_interval=0.01,minimum_duration=55,
            process_capture=c -> begin s=Samples(c);push!(samples,s);s end,
            finished=captures -> all(s -> s.count>=256,samples))
        receipt["streams"]=Dict(spec.name=>begin
            s=samples[i]; slots=sort(findall(!iszero,s.sequences);by=j->s.sequences[j])
            Dict("sequences"=>s.sequences[slots],"samples"=>[collect(view(s.values,:,j)) for j in slots],
                "total_captured"=>s.count,"schema"=>spec.schema,"shape"=>collect(spec.shape))
        end for (i,spec) in enumerate(specs))
        sequences=reduce(intersect,[available(s) for s in samples])
        length(sequences)>=64 || error("insufficient same-sequence commands and feedback")
        receipt["common_sequences"]=sort!(collect(sequences))
        unit_snapshot(identity["unit"])==before || error("live unit changed during capture")
        receipt["observers_closed"]=true
        receipt["completed"]=true
    catch err
        receipt["failure"]=sprint(showerror,err,catch_backtrace());rethrow()
    finally
        C.write_json(joinpath(OUT,"native-samples.json"),receipt)
    end
end
main()
