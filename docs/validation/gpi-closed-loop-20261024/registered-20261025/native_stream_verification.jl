include(joinpath(@__DIR__,"native_observation_helpers.jl"))
function main()
    receipt=Dict{String,Any}("completed"=>false,"driver_sha256"=>C.sha256_file(@__FILE__),
        "scope"=>"Read-only finite native stream observation; no timing, optical performance or hardware claim",
        "owned_observers_closed"=>false)
    try
        deadline=time()+900
        marker=joinpath(ROOT,"live-identity.json")
        while !isfile(marker)
            time()<deadline || error("new Running identity did not appear within 900 seconds")
            sleep(0.25)
        end
        identity=C.read_json(marker)
        identity["stage"]==joinpath(ROOT,"session") || error("unexpected stage identity")
        application=joinpath(identity["stage"],"installed")
        remote=identity["remote"]
        startswith(remote,identity["runtime_root"]*"/") || error("remote outside recorded runtime")
        receipt["live_identity"]=identity
        receipt["unit_before"]=unit_snapshot(identity["unit"])
        receipt["unit_before"]["ActiveState"]=="active" || error("new session is not active")
        parse(Int,receipt["unit_before"]["MainPID"])==identity["pid"] || error("new session main PID changed")
        profile=D.profile(joinpath(application,"deployment.conf"),PREFIX)
        ledger=C.read_json(joinpath(dirname(remote),"launch.json"))
        ledger["unit"]==identity["unit"] && ledger["remote"]==remote || error("launch ledger differs from Running identity")
        session=D.decode(D.relative_asset(application,profile["session"]),PREFIX)
        specs=M.observation_specs(application,PREFIX)
        for mirror in ("woofer","tweeter"), product in ("applied","correction-role","constraint-feedback","offset","shape-offset")
            name=mirror*"-"*product
            specs=(specs...,M.observation_spec(application,session,"rtc-"*name*"-queue-input",name,PREFIX))
        end
        length(specs)==14 || error("expected fourteen native streams")
        receipt["application_hashes"]=Dict(file=>C.sha256_file(joinpath(application,file)) for file in
            ("deployment.conf","Manifest.toml","instrument.json","rtc/graph.conf","rtc/parameters.conf","rtc/session.conf.in"))
        role_expected=Dict{String,Vector{UInt8}}()
        receipt["role_calibration"]=Dict{String,Any}()
        offset_expected=Dict{String,Vector{Float32}}()
        for mirror in ("woofer","tweeter")
            role_expected[mirror],receipt["role_calibration"][mirror]=expected_roles(application,mirror)
            for product in ("offset","shape-offset")
                offset_expected[mirror*"-"*product]=(product=="shape-offset" ? shape_baseline(application,mirror) : read_parameter(application,mirror*"-"*product)).data
            end
        end
        receipt["offset_baseline_artifacts"]=Dict(m*"-"*p=>(p=="shape-offset" ? shape_baseline(application,m) : read_parameter(application,m*"-"*p)).provenance for m in ("woofer","tweeter") for p in ("offset","shape-offset"))
        all(v -> all(iszero,v),values(offset_expected)) || error("expected declared zero engineering and shape baselines")
        receipt["role_calibration"]["tweeter"]["counts"]==Dict("0"=>588,"1"=>1412,"2"=>304,"3"=>0) || error("unexpected actual-calibration tweeter role partition")
        before=graph_dump(remote)
        receipt["source_before"]=source_snapshot(before,profile,ledger)
        receipt["source_before"]["snapshot"]["running"] || error("recorded source is not Running")
        generation=receipt["source_before"]["snapshot"]["generation"]
        first_sequence=receipt["source_before"]["snapshot"]["sequence"]
        samples=Any[]
        paired=Dict{String,Vector{UInt64}}()
        common=Ref{Union{Nothing,AcquisitionIdentity}}(nothing)
        receipt["observations"]=M.Observation.observe_classic(remote;timeout=180,stream_specs=specs,
            drive_interval=0.01,process_capture=c -> begin
                s=Samples(c);push!(samples,s);s
            end,
            finished=captures -> begin
                all(s -> s.count>=32,samples) || return false
                for mirror in ("woofer","tweeter")
                    role=samples[findfirst(s -> s.name==mirror*"-correction-role",specs)]
                    for slot in findall(!iszero,role.sequences)
                        view(role.values,:,slot)==role_expected[mirror] || error("native role assignment differs from actual calibration C")
                    end
                    for product in ("offset","shape-offset")
                        name=mirror*"-"*product
                        offset=samples[findfirst(s -> s.name==name,specs)]
                        for slot in findall(!iszero,offset.sequences)
                            reinterpret(UInt32,collect(view(offset.values,:,slot)))==reinterpret(UInt32,offset_expected[name]) || error("$name readback differs from exact declared/restored baseline")
                        end
                    end
                    demanded=samples[findfirst(s -> s.name==mirror,specs)]
                    applied=samples[findfirst(s -> s.name==mirror*"-applied",specs)]
                    paired[mirror]=sort!(collect(intersect(available(demanded),available(applied))))
                    length(paired[mirror])>=16 || return false
                end
                coherent=filter(c -> c.identity!==nothing,captures)
                length(coherent)==12 || error("expected acquisition identities on camera, commands and role/constraint/engineering-offset/shape-offset outputs only")
                common[]=M.common_identity(coherent)
                common[]!==nothing || return false
                common[].generation==generation || error("observation generation differs from current source")
                common[].sequence>first_sequence
            end)
        receipt["owned_observers_closed"]=true # helper returns only after deterministic retirement/finally
        receipt["offset_baseline_bits_match"]=Dict(name=>true for name in keys(offset_expected))
        receipt["coherent_identity"]=M.Observation._classic_identity_record(common[])
        receipt["applied_comparisons"]=Dict{String,Any}()
        for mirror in ("woofer","tweeter")
            demanded=samples[findfirst(s -> s.name==mirror,specs)]
            applied=samples[findfirst(s -> s.name==mirror*"-applied",specs)]
            maxerror=0f0
            for sequence in paired[mirror]
                d=view(demanded.values,:,findfirst(==(sequence),demanded.sequences))
                a=view(applied.values,:,findfirst(==(sequence),applied.sequences))
                expected=d ./ 1f-6
                maxerror=max(maxerror,maximum(abs.(a.-expected)))
                a==expected || error("same-sequence adopted Applied µm differs from demanded m / 1e-6")
            end
            receipt["applied_comparisons"][mirror]=Dict("paired_sequences"=>paired[mirror],
                "maximum_absolute_error_um"=>maxerror,"exact_float32_scaling_match"=>true,
                "demanded_units"=>"m OPD","applied_units"=>"µm OPD","header_sequence_lag"=>0,
                "semantics"=>"Applied publishes command adopted after frame n for next optical frame n+1; no AcquisitionMetadata is published on Applied")
        end
        receipt["clipping"]=Dict{String,Any}()
        graph=D.decode(joinpath(application,"rtc/graph.conf"),PREFIX)["filter.graph"]
        for mirror in ("woofer","tweeter")
            d=samples[findfirst(s -> s.name==mirror,specs)]
            f=samples[findfirst(s -> s.name==mirror*"-constraint-feedback",specs)]
            sequences=sort!(collect(intersect(available(d),available(f))))
            length(sequences)>=16 || error("insufficient same-sequence clipping samples")
            limits=only(filter(n -> n["name"]==mirror*"-command",graph["nodes"]))["config"]["command_limits"]
            lo,hi=Float32.(limits)
            counts=Int[]; peaks=Float64[]; spans=Float64[]
            for sequence in sequences
                values=view(d.values,:,findfirst(==(sequence),d.sequences))
                feedback=view(f.values,:,findfirst(==(sequence),f.sequences))
                all(isfinite,values) && all(isfinite,feedback) || error("nonfinite command/feedback")
                all(i -> feedback[i]==0 || values[i]==(feedback[i]>0 ? hi : lo),eachindex(values)) || error("feedback is not an exact signed-limit clip")
                request=values.+feedback
                push!(counts,count(!iszero,feedback));push!(peaks,Float64(maximum(abs,request))*1e6)
                push!(spans,Float64(maximum(request)-minimum(request))*1e6)
            end
            receipt["clipping"][mirror]=Dict("sequences"=>sequences,"limit_um_opd"=>Float64.([lo,hi]).*1e6,
                "mean_clipped_actuators"=>sum(counts)/length(counts),"actuator_count"=>length(d.capture.values),
                "maximum_requested_abs_um_opd"=>maximum(peaks),"requested_span_um_opd"=>[minimum(spans),maximum(spans)],
                "exact_signed_limit_feedback"=>true)
        end

        after=graph_dump(remote)
        receipt["source_after"]=source_snapshot(after,profile,ledger)
        receipt["source_after"]["instance"]==receipt["source_before"]["instance"] &&
            receipt["source_after"]["snapshot"]["generation"]==generation &&
            receipt["source_after"]["snapshot"]["running"] &&
            receipt["source_after"]["snapshot"]["sequence"]>=first_sequence || error("source incarnation/run cursor changed")
        receipt["source_control_cursor_semantics"]="Snapshot is published on control/query completion; current frame progression is established by stream acquisition identities."
        receipt["unit_after"]=unit_snapshot(identity["unit"])
        receipt["unit_after"]==receipt["unit_before"] || error("session process identity/state changed")
        C.read_json(marker)==identity || error("live identity changed during observation")
        observer_prefix="classic-integration-observer-$(getpid())-"
        residual=filter(o -> startswith(get(props(o),"node.name",""),observer_prefix),after)
        isempty(residual) || error("owned observer nodes remain")
        receipt["owned_observer_nodes_remaining"]=length(residual)
        receipt["completed"]=true
    catch error
        receipt["failure"]=sprint(showerror,error,catch_backtrace())
        rethrow()
    finally
        C.write_json(joinpath(ROOT,"native-stream-verification.json"),receipt)
        println("native stream verification completed=",receipt["completed"]);flush(stdout)
    end
end
if abspath(PROGRAM_FILE) == (@__FILE__)
    main()
end
