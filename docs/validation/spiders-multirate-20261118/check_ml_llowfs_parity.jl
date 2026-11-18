using FilterGraphAlgorithms
using Printf: @printf
using SHA: sha256
using Statistics: mean, std

# FITSIO and SimpleChains are transitive dependencies of the sealed application.
const FITSIO = Base.require(Base.PkgId(Base.UUID("525bcba6-941b-5504-bd06-fd0dc1a4d2eb"), "FITSIO"))
const SimpleChains = Base.require(Base.PkgId(Base.UUID("de6bee2f-e2f4-4ec7-b6ed-219cc6f6e9e5"), "SimpleChains"))
const FGA = FilterGraphAlgorithms

function read_network(source)
    # Load only the lab's actual network declaration. The rest of the service
    # defines Aeron handlers that are unnecessary for an offline inference check.
    declaration = match(r"(?ms)^const my_chain = SimpleChain\(.*?^    TurboDense\(identity, 14\)\)", source)
    isnothing(declaration) && error("Could not locate the legacy network definition")
    return declaration.match
end

function evaluate_legacy(chain, crop, weights)
    # Match the legacy service's Float32 array and its in-place operation order.
    legacy = copy(crop)
    flux = sum(legacy)
    legacy ./= flux
    center = mean(legacy)
    legacy .-= center
    deviation = std(legacy)
    legacy ./= deviation
    input = reshape(legacy, 20, 20, 1)
    prediction = Base.invokelatest(chain, input, weights)
    return copy(vec(prediction)), (; flux, center, deviation)
end

module Legacy end

function main(lab_source, weights_path, image_path)
    source = read(lab_source, String)
    network = read_network(source)
    for name in (:SimpleChain, :static, :Conv, :MaxPool, :Flatten, :TurboDense, :relu)
        Base.eval(Legacy, :(const $name = $(getproperty(SimpleChains, name))))
    end
    chain = Base.include_string(Legacy, network * "\nmy_chain", lab_source)

    weights = FITSIO.FITS(f -> read(f[1]), weights_path)
    cube_size, cube_type, original_crop = FITSIO.FITS(image_path) do f
        cube = f[1]
        return size(cube), eltype(cube), read(cube, :, :, 1)
    end
    crop = Float32.(original_crop)
    size(crop) == (20, 20) || error("Wrong crop dimensions")
    weights isa Vector{Float32} && length(weights) == 240584 && all(isfinite, weights) ||
        error("Weights must be 240,584 finite Float32 values")

    expected, normalization = evaluate_legacy(chain, crop, weights)
    prepared = FGA.prepare_algorithm(
        FGA.MlLlowfsF32, FGA.MlLlowfsF32Configuration(model="legacy-simplechains-llowfs-v1")
    )
    FGA.replace_parameter!(prepared, Symbol("model-parameters"), weights)
    input = reshape(crop, 1, 20, 20)
    actual = fill(Float32(NaN), 14)
    status = FGA.process!(actual, prepared, input)

    # The sample digests cover decoded column-major values on this host.
    println("Julia ", VERSION, " | FilterGraphAlgorithms ", Base.pkgversion(FGA),
            " | SimpleChains ", Base.pkgversion(SimpleChains))
    println("Lab source: ", abspath(lab_source))
    println("Lab source SHA-256: ", bytes2hex(sha256(source)))
    println("Input: ", abspath(image_path), " | HDU 1, image 1")
    println("Input cube: ", cube_size, " ", cube_type)
    println("Input FITS SHA-256: ", open(io -> bytes2hex(sha256(io)), image_path))
    println("Input crop SHA-256 (decoded Float64): ", bytes2hex(sha256(reinterpret(UInt8, vec(original_crop)))))
    println("Model input SHA-256 (decoded Float32): ", bytes2hex(sha256(reinterpret(UInt8, vec(crop)))))
    println("Weights: ", abspath(weights_path), " | HDU 1, ", size(weights), " ", eltype(weights))
    println("Weights FITS SHA-256: ", open(io -> bytes2hex(sha256(io)), weights_path))
    println("Legacy input shape: ", (20, 20, 1), " | Registered input shape: ", size(input))
    println("Normalization: divide by summed flux, subtract mean, divide by sample standard deviation")
    println("Normalization values: ", normalization)
    println("Process status: ", status)
    println("Mode          Legacy      Registered")
    for i in eachindex(actual)
        @printf("%4d  % .10f  % .10f\n", i, expected[i], actual[i])
    end
    println("Exact Float32 equality: ", actual == expected)
    println("Maximum absolute difference: ", maximum(abs, actual - expected))
    status === nothing && all(isfinite, actual) && actual == expected ||
        error("MLLOWFS inference parity failed")
end

length(ARGS) == 3 || error("Usage: check_ml_llowfs_parity.jl LAB_SOURCE WEIGHTS_FITS IMAGE_CUBE_FITS")
main(ARGS...)
