# Opt-in finite optical evidence through the existing private diagnostic queues.
module ManagedSessionOptical
using Test, PipeWireAO, PipeWireAORTC, Statistics
include("managed_session_lifecycle.jl")
const M = ManagedSessionLifecycle
const C, W, D = M.C, M.W, M.D

mutable struct RMSSamples
    values::Matrix{Float32}
    identities::Vector{AcquisitionIdentity}
    count::Int
end
RMSSamples(count::Int) = RMSSamples(zeros(Float32,2,count),Vector{AcquisitionIdentity}(undef,count),0)

function record!(samples::RMSSamples, values, identity::AcquisitionIdentity)
    samples.count == size(samples.values,2) && return nothing
    if samples.count > 0
        previous = samples.identities[samples.count]
        identity.domain == previous.domain && identity.generation == previous.generation ||
            error("RMS observation changed acquisition domain or generation")
        identity.sequence == previous.sequence && return nothing
        identity.sequence > previous.sequence || error("RMS observation sequence regressed")
    end
    length(values) == 2 && all(isfinite,values) && all(>=(0),values) ||
        error("RMS observation requires two finite nonnegative nm OPD values")
    index = samples.count + 1
    samples.values[1,index], samples.values[2,index] = values[1], values[2]
    samples.identities[index] = identity
    samples.count = index
    return nothing
end

struct RMSCapture{Capture}
    capture::Capture
    samples::RMSSamples
end
function (owner::RMSCapture)(stream)
    capture = owner.capture
    before = capture.count
    capture(stream)
    if capture.error === nothing && capture.count > before
        try
            record!(owner.samples,capture.values,something(capture.identity))
        catch error
            capture.error = error
        end
    end
    return nothing
end

function summary(samples::RMSSamples; settling_frames=32)
    samples.count == size(samples.values,2) || error("RMS sample collection is incomplete")
    0 <= settling_frames < samples.count || error("invalid RMS settling prefix")
    atmosphere = Float64.(samples.values[1,:])
    residual = Float64.(samples.values[2,:])
    trailing = settling_frames+1:samples.count
    uncorrected, corrected = mean(atmosphere[trailing]), mean(residual[trailing])
    uncorrected > 0 || error("uncorrected atmosphere has zero RMS")
    return Dict("sample_count"=>samples.count,"settling_frames"=>settling_frames,
        "uncorrected_atmosphere_rms_nm"=>atmosphere,"corrected_pupil_rms_nm"=>residual,
        "identities"=>M.Observation._classic_identity_record.(samples.identities),
        "trailing_uncorrected_mean_nm"=>uncorrected,"trailing_corrected_mean_nm"=>corrected,
        "residual_ratio"=>corrected/uncorrected)
end

function main(application,stage,prefix; sample_count=128)
    32 < sample_count <= 256 || error("sample_count must be in 33:256")
    !ispath(stage) && !islink(stage) || error("optical validation stage must be fresh")
    application = realpath(application)
    spec = D.profile(joinpath(application,"deployment.conf"),prefix)
    session = D.decode(D.relative_asset(application,spec["session"]),prefix)
    session["profile"] == "development" && session["authority"] == "none" || error("development authority=none is required")
    products = M.observation_specs(application,prefix)
    rms = M.observation_spec(application,session,"simulator-wavefront-rms-queue-input","wavefront-rms",prefix)
    rms.shape == (1,2) && rms.type === Float32 &&
        rms.schema == PipeWireAORTC.Schemas.identifier("pupil_opd_rms_nm") || error("unexpected pupil RMS contract")
    samples = RMSSamples(sample_count)
    handle = nothing
    result = Dict{String,Any}("completed"=>false,"deployment_sha256"=>C.sha256_file(joinpath(application,"deployment.conf")),
        "manifest_sha256"=>C.sha256_file(joinpath(application,"Manifest.toml")),
        "harness_sha256"=>C.sha256_file(@__FILE__),"scope"=>"Finite native simulated optical correction; no cadence, latency or hardware qualification")
    try
        handle = W.start!(application,stage;prefix,deadline=W.monotonic()+M.Faults.startup_budget(spec))
        initial = M.inspect_source(handle,application,prefix,stage,"ready")
        result["backend"] = initial["report"]["backend"]
        configuration = C.read_json(joinpath(application,"simulation.conf"))
        result["model_rate_hz"], result["test_pacing_rate_hz"] = configuration["rate"], configuration["pacing_rate_hz"]
        observation = M.Observation.observe_classic(W._ledger(handle)["remote"];
            timeout=120,stream_specs=(products...,rms),drive_interval=0.005,
            process_capture=capture -> capture.schema == rms.schema ? RMSCapture(capture,samples) : capture,
            on_ready=() -> M.Faults.checked(M.request(handle,stage,"start",["session-start"])["state"] == "Running","session did not start"),
            finished=captures -> samples.count == sample_count && M.common_identity(captures) !== nothing)
        result["observation"] = observation
        result["optical"] = summary(samples)
        # The two RMS channels share one payload and identity, so the comparison
        # uses the same atmospheric realization after the finite settling prefix.
        M.Faults.checked(result["optical"]["residual_ratio"] < 1,"native correction did not reduce pupil RMS")
        result["shutdown"] = M.shutdown(handle,stage)
        result["completed"] = true
    catch error
        result["failure"] = sprint(showerror,error)
        rethrow()
    finally
        if handle !== nothing && !result["completed"]
            try M.Faults.cleanup!(handle,stage;failed=true)
            catch error; result["cleanup_failure"] = sprint(showerror,error) end
        end
        mkpath(stage)
        C.write_json(joinpath(stage,"optical-result.json"),result)
    end
    return result
end

if abspath(PROGRAM_FILE) == (@__FILE__)
    length(ARGS) == 3 || error("usage: managed_session_optical.jl APPLICATION FRESH_STAGE PREFIX")
    @testset "private native simulated optical correction" begin
        main(ARGS...)
    end
end
end
