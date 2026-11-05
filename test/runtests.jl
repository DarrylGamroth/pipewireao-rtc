using Test, PipeWireAORTC

Base.include(Module(:MediaSessionMachineTests), joinpath(@__DIR__, "test_media_session.jl"))
Base.include(Module(:MediaSessionControlTests), joinpath(@__DIR__, "media_session_controls.jl"))

Base.include(Module(:ControlTypeDispatchTests), joinpath(@__DIR__, "control_type_dispatch.jl"))

include("test_recovery_observations.jl")
Base.include(Module(:CalibrationRecipeTests), joinpath(@__DIR__, "test_calibration_recipe.jl"))

for name in ("configuration_store", "management_cli", "simulator_configuration", "artifacts", "parameter_fits", "owner_entrypoints", "physical_offsets", "physical_offset_inputs", "pupil_source_owner", "correction_loops", "correction_timers", "correction_recovery", "correction_recovery_client", "correction_supervision", "correction_supervision_observer", "correction_supervision_client", "graph_supervision", "graph_owner", "aos_owner", "aos_graph_selection", "phase_timing", "registered_application")
    Base.include(Module(gensym(:ArtifactSuite)), joinpath(@__DIR__, "test_" * name * ".jl"))
end
Base.include(Module(:AuxiliarySourceTests), joinpath(@__DIR__, "test_auxiliary_sources.jl"))
Base.include(Module(:CoupledRecoveryTests), joinpath(@__DIR__, "test_correction_recovery_controllers.jl"))
Base.include(Module(:QueueMetadataProfilesTests), joinpath(@__DIR__, "queue_metadata_profiles.jl"))
include("test_session_discovery.jl")
Base.include(Module(:ExternalPupilOwnerTests), joinpath(@__DIR__, "test_external_pupil_owner.jl"))
Base.include(Module(:ApplicationCompositionTests), joinpath(@__DIR__, "test_application_composition.jl"))
Base.include(Module(:ExecutionGroupTests), joinpath(@__DIR__, "test_execution_groups.jl"))
Base.include(Module(:CanonicalMetadataTests), joinpath(@__DIR__, "test_canonical_metadata.jl"))
Base.include(Module(:CAL2CaptureTests), joinpath(@__DIR__, "test_cal2_capture.jl"))
Base.include(Module(:CalibrationMaterializationTests), joinpath(@__DIR__, "test_calibration_materialization.jl"))
include("test_session_client.jl")
include("test_calibration_acquisition.jl")
include("test_calibration_endpoint.jl")
include("test_calibration_bundle.jl")
include("test_calibration_procedure.jl")
Base.include(Module(:CalibrationPreparationTests), joinpath(@__DIR__, "test_calibration_preparation.jl"))
Base.include(Module(:CalibrationCaptureFilesTests), joinpath(@__DIR__, "test_calibration_capture_files.jl"))
Base.include(Module(:CalibrationOwnerTests), joinpath(@__DIR__, "calibration_owner.jl"))
include("test_calibration_install.jl")
include("test_session_configuration.jl")
include("test_instrument_definition.jl")
Base.include(Module(:AnalysisCaptureTests), joinpath(@__DIR__, "test_analysis_capture.jl"))
Base.include(Module(:SimulationBindingFilesTests), joinpath(@__DIR__, "simulation_binding_files.jl"))
Base.include(Module(:ClockedPlaneContractTests), joinpath(@__DIR__, "test_clocked_plane_contract.jl"))

for name in ("schemas", "common", "runtime_export", "spa_config", "loop_placement", "systemd_owners", "analysis", "session_runtime", "session_stop", "control_codec", "runner_codec", "control_client", "owner_bootstrap_codec", "acquisition_lifecycle_codec", "acquisition_lifecycle_client", "calibration_action_codec", "calibration_action_client", "runner_commands", "installed_wireplumber", "package")
    suite = Module(Symbol("Suite_", name))
    Base.include(suite, joinpath(@__DIR__, "test_" * name * ".jl"))
end

for name in ("modal_calibration_io", "calibration_context", "instrument_geometry", "instrument_influences", "instrument_declaration_schema", "external_optical_instrument", "zemax_components", "simulation_source", "optical_masks", "optical_spectra", "instrument_configuration_bindings", "pyramid_instrument", "hil_declaration", "instrument_catalogs", "instrument_components", "instrument_settings_transforms", "instrument_profiles", "owner_scheduling", "pipewire_configuration", "instrument_authoring", "instrument_dimensions", "instrument_export", "graph_configuration")
    Base.include(Module(gensym(:InstrumentSuite)), joinpath(@__DIR__, "test_" * name * ".jl"))
end
