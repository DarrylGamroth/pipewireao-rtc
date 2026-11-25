function Calibration.apply_calibration_settings!(simulation, specification, declaration)
    Instruments = PipeWireAORTC.InstrumentConfiguration
    base = Instruments.settings(declaration, simulation["plant"]["settings"])
    overrides = get(specification, "settings", Dict())
    schema = Instruments.settings_description(declaration, merge(base, overrides))["schema"]
    startup = Instruments.merge_settings(base, overrides, schema)
    configured = Instruments.settings(declaration, startup)
    simulation["plant"]["settings"] = configured
    return configured
end

# Match acquisition settings when checking source identity during replay/staging.
function Calibration.calibration_settings(application, recipe, declaration)
    kind = IC.sensor_kind(
        declaration.instrument.document["wavefront_sensors"][recipe["sensor"]]
    )
    return calibration_settings(kind, application, recipe, declaration)
end
calibration_settings(::Val, application, recipe, declaration) =
    IC.settings(declaration, get(recipe, "settings", Dict()))
function calibration_settings(::Val{:shack_hartmann}, application, recipe, declaration)
    simulation = PipeWireAORTC.DeploymentConfiguration.decode(
        joinpath(application, "simulation.conf"),
        get(ENV, "PIPEWIREAO_PREFIX", "/opt/pipewireao"),
    )
    return Calibration.apply_calibration_settings!(simulation, recipe, declaration)
end
