module CorrectionTruth

using SHA
using TOML

require(condition, message) = condition || throw(ArgumentError(message))
positive_integer(x) = x isa Integer && !(x isa Bool) && 0 < x <= typemax(Int)

# Shared with the cold correction analyzer. These three functions retain its
# public pupil geometry, variance arithmetic and OPD byte-order conventions.
function telescope_config(graph)
    definition = TOML.parsefile(graph)
    nodes = definition["nodes"]
    sensors = filter(node -> node["name"] in ("shwfs", "pwfs"), nodes)
    require(length(sensors) == 1, "requires exactly one supported WFS node")
    names = ("atmosphere", "pdm", only(sensors)["name"])
    configs = map(names) do name
        selected = filter(node -> node["name"] == name, nodes)
        require(length(selected) == 1, "requires exactly one $name node")
        only(selected)["config"]
    end
    keys = ("resolution", "telescope_diameter_m", "central_obstruction_ratio", "pupil_reflectivity", "aperture_revision")
    for key in keys
        require(all(c -> c[key] == configs[1][key], configs), "inconsistent telescope parameter: $key")
    end
    c = configs[1]
    require(positive_integer(c["resolution"]) && positive_integer(c["aperture_revision"]), "invalid pupil dimensions/revision")
    require(isfinite(c["telescope_diameter_m"]) && c["telescope_diameter_m"] > 0 && isfinite(c["central_obstruction_ratio"]) && 0 <= c["central_obstruction_ratio"] < 1 && isfinite(c["pupil_reflectivity"]) && 0 < c["pupil_reflectivity"] <= 1, "invalid annular pupil")
    detector = only(filter(node -> node["name"] == "detector", nodes))["config"]
    return (; resolution=Int(c["resolution"]), diameter=c["telescope_diameter_m"],
        central_obstruction=c["central_obstruction_ratio"], pupil_reflectivity=c["pupil_reflectivity"],
        revision=Int(c["aperture_revision"]), exposure_seconds=detector["exposure_duration_s"])
end

"""Population spatial variance on the public pupil support, after piston removal.
Accumulate in Float64 around a fixed origin; no square-array dilution, sample
variance correction, wavelength conversion, or additional reflection factor.
"""
function pupil_variance(values::AbstractMatrix{<:Real}, mask::AbstractMatrix{Bool})
    Base.require_one_based_indexing(values, mask)
    require(size(values) == size(mask), "OPD/pupil shape mismatch")
    require(all(isfinite, values), "non-finite OPD product")
    selected = findfirst(mask)
    require(selected !== nothing, "empty pupil support")
    origin = Float64(values[selected])
    count = 0
    total = 0.0
    for i in eachindex(values, mask)
        if mask[i]
            total += Float64(values[i]) - origin
            count += 1
        end
    end
    center = total / count
    energy = 0.0
    for i in eachindex(values, mask)
        mask[i] && (energy += abs2((Float64(values[i]) - origin) - center))
    end
    variance = energy / count
    require(isfinite(variance), "OPD variance overflow")
    return variance
end

"""Canonical row-major little-endian Float32 hash of a public OPD output."""
function opd_hash(values::AbstractMatrix{Float32})
    words = UInt32[htol(reinterpret(UInt32, values[r, c])) for r in axes(values, 1) for c in axes(values, 2)]
    return bytes2hex(sha256(reinterpret(UInt8, words)))
end

mutable struct Witness{C}
    config::C
    mask::Matrix{Bool}
    mask_sha256::String
    count::Int
    sequences::Vector{UInt64}
    model_timestamps_ns::Vector{Int64}
    residual_variance_m2::Vector{Float64}
    atmosphere_variance_m2::Vector{Float64}
    atmosphere_sha256::Vector{String}
    pupil_sha256::Vector{String}
    surface_sha256::Vector{String}
    staging::NTuple{3,Matrix{Float32}}
end

function Witness(config, mask::AbstractMatrix{Bool}, frames::Integer)
    require(!(frames isa Bool) && 1 <= frames <= 256, "truth witness requires 1..256 frames")
    Base.require_one_based_indexing(mask)
    require(size(mask) == (config.resolution, config.resolution) && any(mask), "invalid truth pupil support")
    support = Matrix{Bool}(mask)
    mask_hash = bytes2hex(sha256(UInt8[support[r, c] for r in axes(support, 1) for c in axes(support, 2)]))
    return Witness(config, support, mask_hash, 0, zeros(UInt64, frames), zeros(Int64, frames),
        zeros(Float64, frames), zeros(Float64, frames), fill("", frames), fill("", frames), fill("", frames),
        ntuple(_ -> zeros(Float32, size(support)), 3))
end

"""Prepare the same public annular pupil as the cold correction replay."""
function prepare_witness(graph, optics, target, frames)
    config = telescope_config(graph)
    telescope = optics.prepare_telescope(optics.TelescopeDefinition(;
        resolution=config.resolution, diameter=config.diameter, central_obstruction=config.central_obstruction,
        pupil_reflectivity=config.pupil_reflectivity, revision=config.revision, T=Float32), target)
    # Materialize the public support once. Device masks must not be indexed
    # scalarly by the host diagnostic or silently trigger a backend fallback.
    return Witness(config, Array(optics.pupil_mask(telescope)), frames)
end

"""Copy public OPD products into prepared host diagnostic buffers.

For accelerator arrays, copyto! performs the declared device-to-host transfer.
This opt-in witness adds transfer/synchronization cost and is excluded from
cadence qualification. No staging array is created per frame.
"""
function stage!(witness::Witness, atmosphere, pupil, surface)
    for (destination, source) in zip(witness.staging, (atmosphere, pupil, surface))
        require(size(destination) == size(source), "truth staging extent differs")
        copyto!(destination, source)
    end
    return witness.staging
end

function reset!(witness::Witness)
    witness.count = 0
    fill!(witness.sequences, 0)
    fill!(witness.model_timestamps_ns, 0)
    fill!(witness.residual_variance_m2, 0)
    fill!(witness.atmosphere_variance_m2, 0)
    fill!(witness.atmosphere_sha256, "")
    fill!(witness.pupil_sha256, "")
    fill!(witness.surface_sha256, "")
    return nothing
end

"""Observe current public graph products after exchange, before another step.
Hashes allocate in this opt-in source diagnostic. This is no cadence measurement
or calibration input; it never changes a graph, command, detector or model time.
"""
function record!(witness::Witness, atmosphere::AbstractMatrix{Float32}, pupil::AbstractMatrix{Float32},
                 surface::AbstractMatrix{Float32}, sequence::UInt64, model_timestamp_ns::Int64)
    index = witness.count + 1
    require(index <= length(witness.sequences), "truth witness frame capacity exceeded")
    require(sequence == UInt64(index), "truth sequence does not match completed frame")
    require(model_timestamp_ns >= 0 && (index == 1 || model_timestamp_ns > witness.model_timestamps_ns[index - 1]),
        "truth model timestamp is not increasing")
    require(size(surface) == size(witness.mask) && all(isfinite, surface), "invalid public PDM surface")
    atmosphere_variance = pupil_variance(atmosphere, witness.mask)
    residual_variance = pupil_variance(pupil, witness.mask)
    atmosphere_hash, pupil_hash, surface_hash = opd_hash(atmosphere), opd_hash(pupil), opd_hash(surface)
    witness.sequences[index] = sequence
    witness.model_timestamps_ns[index] = model_timestamp_ns
    witness.atmosphere_variance_m2[index] = atmosphere_variance
    witness.residual_variance_m2[index] = residual_variance
    witness.atmosphere_sha256[index] = atmosphere_hash
    witness.pupil_sha256[index] = pupil_hash
    witness.surface_sha256[index] = surface_hash
    witness.count = index
    return nothing
end

function report(witness::Witness; graph_sha256, frame_sha256, command_sha256, simulator_sha256, completed_frames)
    count = witness.count
    return (; version=1, observed_frames=count, recorded_frames=completed_frames,
        complete_prefix=count == completed_frames, graph_sha256, frame_sha256, command_sha256, simulator_sha256,
        helper_sha256=bytes2hex(open(sha256, @__FILE__)),
        outputs=(; atmosphere=:atmosphere_opd, pupil=:pupil_opd, surface=:pdm_surface_opd),
        opd=(; units="metre OPD", element_type="F32_LE", layout="ROW_MAJOR", shape=collect(size(witness.mask))),
        pupil=(; witness.config..., support_pixels=Base.count(witness.mask), mask_sha256=witness.mask_sha256,
            mask_encoding="row-major UInt8, zero outside support and one inside",
            weighting="uniform public annular pupil support", variance="population spatial variance after piston removal, metre OPD squared"),
        per_frame=[(; sequence=witness.sequences[n], model_timestamp_ns=witness.model_timestamps_ns[n],
            atmosphere_sha256=witness.atmosphere_sha256[n], pupil_sha256=witness.pupil_sha256[n], surface_sha256=witness.surface_sha256[n],
            residual_variance_m2=witness.residual_variance_m2[n], atmosphere_variance_m2=witness.atmosphere_variance_m2[n]) for n in 1:count],
        command_interpretation="command n is adopted after frame n and affects frame n+1; the final command effect is not recorded",
        qualification="direct public simulated OPD diagnostic; independent replay/baseline verification, correction acceptance and cadence remain separate gates")
end

end
