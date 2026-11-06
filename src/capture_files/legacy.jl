# Explicit schema-4 compatibility. New captures never use these instrument policies.
const CLASSIC_CAPTURE_CONTRACTS = (
    raw = (type = UInt16, encoding = "U16_LE", shape = (352, 352), bytes = 247808),
    slopes = (type = Float32, encoding = "F32_LE", shape = (188, 2), bytes = 1504),
    flux = (type = Float32, encoding = "F32_LE", shape = (188,), bytes = 752),
    validity = (type = Bool, encoding = "BOOL8", shape = (188,), bytes = 188),
)
const CLASSIC_CAPTURE_BYTES = sum(contract.bytes for contract in CLASSIC_CAPTURE_CONTRACTS)


_legacy_capture_quality(arrays) = Dict(
    "finite_slopes" => all(isfinite, arrays.slopes),
    "finite_flux" => all(isfinite, arrays.flux),
    "valid_rois" => count(arrays.validity),
)

"""
    read_capture(Val(4), directory, descriptor; expected_contract, expected_stage,
        expected_illumination, expected_settings)

Read historical schema-4 Classic evidence explicitly. This format records no port
schemas or rates: these facts CANNOT be verified by this compatibility reader.
Only historical element types, shapes and recorded metadata are verified against
`expected_contract`; callers must not claim schema/rate qualification from it.
Returns `(manifest, samples)`, where each sample has fresh owned `arrays` and
JSON `metadata` receipts, native `exposure`, and intrinsic `quality`. Descriptor
and payload hashes, exact fields/lengths, full acquisition identities, sequence
continuity, nonoverlapping model-time intervals and canonical paths are verified
before returning any sample. The
manifest cannot choose a profile or relax the expected startup snapshot.
"""
read_capture(
    version::Val{4}, directory, descriptor::CalibrationActionCodec.Captured; kwargs...
) = _read_capture(version, directory, descriptor; kwargs...)

function _capture_read_contract(::Val{4}, expected_contract::Contract)
    _capture_require(
        keys(expected_contract.channels) == keys(CLASSIC_CAPTURE_CONTRACTS) &&
            all(pairs(CLASSIC_CAPTURE_CONTRACTS)) do (role, contract)
                payload = _channel_payload(getproperty(expected_contract.channels, role))
                payload.type === contract.type && payload.shape == contract.shape
            end,
        "legacy capture requires the historical Classic payload contract",
    )
    return (;
        field = "profile",
        value = "classic",
        mismatch = "capture profile/stage/illumination/settings differ",
    )
end
_capture_record_fields(::Val{4}) =
    ("exposure", "metadata", "payloads", "quality", "recording")
function _capture_read_sample(::Val{4}, arrays, metadata, exposure, record)
    _capture_require(
        _capture_same_json(record["quality"], _legacy_capture_quality(arrays)),
        "capture intrinsic quality differs",
    )
    return (; arrays, metadata, exposure, quality = record["quality"])
end
