//! Non-actuating `PipeWireAO` development runner.

pub mod calibration;
#[cfg(unix)]
pub mod calibration_socket;
mod config;
#[cfg(feature = "live")]
pub mod control;
mod ffi;
mod lifecycle;
#[cfg(feature = "live")]
mod live;
#[cfg(feature = "live")]
pub mod native_calibration_action_codec;
#[cfg(feature = "live")]
pub mod native_calibration_endpoint;
#[cfg(feature = "live")]
pub mod native_control_codec;
#[cfg(feature = "live")]
pub mod native_runner_codec;
#[cfg(feature = "live")]
pub mod native_runner_result;
#[cfg(feature = "live")]
pub mod native_supervisor_client;
#[cfg(feature = "live")]
pub mod native_supervisor_codec;
mod runner;

pub use config::{
    DevelopmentConfig, EndpointFactory, ExecutionGroupSpec, ExecutionMode, GraphFactory, LinkSpec,
    ObjectRealization, ObjectRole, ObjectSpec, PortDirection, PortSpec, RunControl,
    ScientificDiagnostic,
};
pub use lifecycle::{
    ConfigurationInput, DispatchError, DispatchOutcome, EffectKind, EffectOrigin, EffectTarget,
    EffectToken, ExecutionGroupState, LifecycleDispatcher, LifecycleEffect, LifecycleEffectResult,
    LifecycleEffectSuccess, LifecycleEvent, LifecycleState, NdArrayParameterValue,
    ParameterGeneration, PropertyGeneration, ScalarValue,
};
#[cfg(feature = "live")]
pub use live::{DiscardObservation, LiveGraphAdapter, LiveGraphStatus};
pub use runner::{EffectExecutor, RequiredObjectStatus, Runner};
