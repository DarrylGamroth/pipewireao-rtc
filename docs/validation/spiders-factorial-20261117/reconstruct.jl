using AdaptiveOpticsCalibration
using LinearAlgebra
using PipeWireAORTC
using SHA

const R = AdaptiveOpticsCalibration.Reconstructors
const C = PipeWireAORTC.Common
const I = PipeWireAORTC.InstrumentCalibration
const FITS = PipeWireAORTC.InstrumentConfiguration.FITSIO.FITS

function legacy_inverse(source)
    assets = joinpath(source, "generated/dual-calibration/scc/artifacts")
    interaction_path = joinpath(assets, "scc-interaction-matrix.fits")
    interaction = FITS(interaction_path) do file
        permutedims(read(file[1]))
    end
    spec = R.ReconstructorSpecification(size(interaction)..., Float32)
    inputs = R.SVDReconstructorInputs(interaction)
    tsvd = R.process(R.prepare(R.TSVDInverse(rtol=1f-4), spec), inputs)
    spectrum = R.singular_values(tsvd)
    cutoff = min(length(spectrum), 100)
    damping = spectrum[cutoff]
    damped = R.process(R.prepare(R.TikhonovInverse(damping; rtol=0f0), spec), inputs)
    matrix = Matrix(R.reconstructor(damped))
    matrix[1:2, :] .= 0
    standard_path = joinpath(assets, "scc-reconstructor.fits")
    standard = FITS(standard_path) do file
        permutedims(read(file[1]))
    end
    tsvd_matrix = Matrix(R.reconstructor(tsvd))
    tsvd_matrix[1:2, :] .= 0
    @assert size(standard) == size(matrix)
    @assert norm(tsvd_matrix - standard) / norm(standard) < 1e-5
    path = I.write_fits(joinpath(source, "calibration/scc-legacy-damped.fits"), matrix)
    digest(path) = bytes2hex(open(sha256, path))
    return (; mode_count=size(matrix, 1)-2, singular_index=cutoff, damping,
        interaction_sha256=digest(interaction_path), tsvd_sha256=digest(standard_path),
        legacy_sha256=digest(path))
end

source, out = ARGS
C.write_json(out, legacy_inverse(source); atomic=true)
