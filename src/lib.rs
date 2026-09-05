//! Non-actuating `PipeWireAO` development runner.

mod config;
mod ffi;
mod lifecycle;
#[cfg(feature = "live")]
mod live;
mod runner;

pub use config::{
    DevelopmentConfig, EndpointFactory, ExecutionGroupSpec, GraphFactory, LinkSpec,
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
