using Test, PipeWireAORTC

for name in ("configuration_store", "simulator_configuration", "artifacts", "parameter_fits", "owner_entrypoints", "correction_loops", "correction_timers", "graph_owner", "aos_owner", "phase_timing", "registered_application")
    Base.include(Module(gensym(:ArtifactSuite)), joinpath(@__DIR__, "test_" * name * ".jl"))
end
include("test_native_session_discovery.jl")
include("test_native_session_client.jl")
include("test_calibration_acquisition.jl")
include("test_calibration_bundle.jl")
include("test_calibration_procedure.jl")
include("test_calibration_install.jl")
include("test_session_configuration.jl")
include("test_instrument_definition.jl")

for name in ("schemas", "common", "runtime_export", "spa_config", "loop_placement", "systemd_owners", "analysis", "session_stop", "native_control_codec", "native_runner_codec", "native_control_client", "native_owner_bootstrap_codec", "native_acquisition_lifecycle_codec", "native_acquisition_lifecycle_client", "native_calibration_action_codec", "native_calibration_action_client", "runner_commands", "installed_wireplumber", "package")
    suite = Module(Symbol("Suite_", name))
    Base.include(suite, joinpath(@__DIR__, "test_" * name * ".jl"))
end

for name in ("modal_calibration_io", "instrument_geometry", "instrument_influences", "instrument_declaration_schema", "instrument_configuration_bindings", "pyramid_instrument", "hil_declaration", "instrument_catalogs", "instrument_components", "instrument_settings_transforms", "instrument_profiles", "owner_scheduling", "native_configuration", "instrument_authoring", "instrument_dimensions", "instrument_export", "graph_configuration")
    Base.include(Module(gensym(:InstrumentSuite)), joinpath(@__DIR__, "test_" * name * ".jl"))
end
