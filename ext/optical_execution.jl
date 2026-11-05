# Scientific execution admission methods require the optional AOS dependency.
# Keep them outside the transport-neutral optical numerical implementation.

validate_optical_target(
    target::Union{
        AdaptiveOpticsSim.Backends.HostComputeDevice,
        AdaptiveOpticsSim.Backends.AcceleratorComputeDevice{
            AdaptiveOpticsSim.Backends.AMDGPUBackend,
        },
        AdaptiveOpticsSim.Backends.AcceleratorComputeDevice{
            AdaptiveOpticsSim.Backends.CUDABackend,
        },
    },
) = nothing
validate_optical_target(target) = throw(
    ArgumentError("optical calibration supports explicit host, AMDGPU or CUDA targets"),
)

validate_optical_reference_target(
    target::Union{
        AdaptiveOpticsSim.Backends.HostComputeDevice,
        AdaptiveOpticsSim.Backends.AcceleratorComputeDevice{
            AdaptiveOpticsSim.Backends.AMDGPUBackend,
        },
    },
) = nothing
validate_optical_reference_target(target) = throw(
    ArgumentError("upstream optical reference supports explicit host or AMDGPU targets"),
)

validate_optical_expectation_target(target::AdaptiveOpticsSim.Backends.HostComputeDevice) =
    nothing
validate_optical_expectation_target(target) = throw(
    ArgumentError("host expectation reference acquisition requires explicit Host target"),
)

function validate_expectation_sensor(
    sensor::AdaptiveOpticsSim.Detectors.EMCCDSensor,
    params,
)
    validate_expectation_emccd_law(
        sensor.operating_mode,
        sensor.output_path,
        sensor.multiplication_model,
    )
    params.full_well === nothing &&
    sensor.register_full_well === nothing &&
    params.bits === nothing &&
    params.binning == 1 &&
    params.dark_current == 0 || throw(
        ArgumentError(
            "host expectation requires the qualified unsaturated linear EMCCD law",
        ),
    )
    return nothing
end
validate_expectation_sensor(sensor, params) = throw(
    ArgumentError("host expectation requires the qualified unsaturated linear EMCCD law"),
)
validate_expectation_emccd_law(
    ::AdaptiveOpticsSim.Detectors.LinearEMMode,
    ::AdaptiveOpticsSim.Detectors.EMOutput,
    ::AdaptiveOpticsSim.Detectors.ClippedGaussianMultiplicationApproximation,
) = nothing
validate_expectation_emccd_law(mode, path, model) = throw(
    ArgumentError("host expectation requires the qualified unsaturated linear EMCCD law"),
)
