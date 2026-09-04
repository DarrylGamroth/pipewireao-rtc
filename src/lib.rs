//! Non-actuating `PipeWireAO` development runner.

mod config;
mod ffi;
mod lifecycle;
#[cfg(feature = "live")]
mod live;
#[cfg(feature = "live")]
mod run_control;
mod runner;

pub use config::{
    DevelopmentConfig, EndpointFactory, ExecutionGroupSpec, GraphFactory, LinkSpec,
    ObjectRealization, ObjectRole, ObjectSpec, PortDirection, PortSpec, RunControl,
    ScientificDiagnostic,
};
pub use lifecycle::{
    ConfigurationInput, DispatchError, DispatchOutcome, EffectKind, EffectOrigin, EffectTarget,
    EffectToken, ExecutionGroupState, LifecycleDispatcher, LifecycleEffect, LifecycleEffectResult,
    LifecycleEffectSuccess, LifecycleEvent, LifecycleState,
};
#[cfg(feature = "live")]
pub use live::{LiveGraphAdapter, LiveGraphStatus};
pub use runner::{EffectExecutor, Runner};
