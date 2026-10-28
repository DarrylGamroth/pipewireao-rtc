using Test, PipeWireAORTC

for name in ("configuration_store", "simulator_configuration", "artifacts", "parameter_fits", "owner_entrypoints", "physical_offsets", "correction_loops", "correction_timers", "correction_recovery", "correction_recovery_client", "correction_supervision", "correction_supervision_observer", "correction_supervision_client", "graph_supervision", "graph_owner", "aos_owner", "aos_graph_selection", "phase_timing", "registered_application")
    Base.include(Module(gensym(:ArtifactSuite)), joinpath(@__DIR__, "test_" * name * ".jl"))
end
Base.include(Module(:AuxiliarySourceTests), joinpath(@__DIR__, "test_auxiliary_sources.jl"))
include("test_native_session_discovery.jl")
Base.include(Module(:ExternalPupilOwnerTests), joinpath(@__DIR__, "test_external_pupil_owner.jl"))
Base.include(Module(:ApplicationCompositionTests), joinpath(@__DIR__, "test_application_composition.jl"))
Base.include(Module(:CalibrationMaterializationTests), joinpath(@__DIR__, "test_calibration_materialization.jl"))
include("test_native_session_client.jl")
include("test_calibration_acquisition.jl")
include("test_calibration_bundle.jl")
include("test_calibration_procedure.jl")
Base.include(Module(:CalibrationPreparationTests), joinpath(@__DIR__, "test_calibration_preparation.jl"))
Base.include(Module(:CalibrationCaptureFilesTests), joinpath(@__DIR__, "test_calibration_capture_files.jl"))
Base.include(Module(:NativeCalibrationOwnerTests), joinpath(@__DIR__, "native_calibration_owner.jl"))
include("test_calibration_install.jl")
include("test_session_configuration.jl")
include("test_instrument_definition.jl")

for name in ("schemas", "common", "runtime_export", "spa_config", "loop_placement", "systemd_owners", "analysis", "session_runtime", "session_stop", "native_control_codec", "native_runner_codec", "native_control_client", "native_owner_bootstrap_codec", "native_acquisition_lifecycle_codec", "native_acquisition_lifecycle_client", "native_calibration_action_codec", "native_calibration_action_client", "runner_commands", "installed_wireplumber", "package")
    suite = Module(Symbol("Suite_", name))
    Base.include(suite, joinpath(@__DIR__, "test_" * name * ".jl"))
end

for name in ("modal_calibration_io", "calibration_context", "instrument_geometry", "instrument_influences", "instrument_declaration_schema", "external_optical_instrument", "zemax_components", "simulation_source", "optical_masks", "optical_spectra", "instrument_configuration_bindings", "pyramid_instrument", "hil_declaration", "instrument_catalogs", "instrument_components", "instrument_settings_transforms", "instrument_profiles", "owner_scheduling", "native_configuration", "instrument_authoring", "instrument_dimensions", "instrument_export", "graph_configuration")
    Base.include(Module(gensym(:InstrumentSuite)), joinpath(@__DIR__, "test_" * name * ".jl"))
end
