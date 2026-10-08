//! Direct clients for the `PipeWireAO` `WirePlumber` session and calibration APIs.

pub mod calibration;
#[cfg(feature = "live")]
pub mod control;
pub mod control_dto;
#[cfg(feature = "live")]
pub mod native_calibration_action_codec;
#[cfg(feature = "live")]
pub mod native_calibration_endpoint;
#[cfg(feature = "live")]
mod native_connection;
#[cfg(feature = "live")]
pub mod native_control_codec;
#[cfg(feature = "live")]
pub mod native_runner_codec;
#[cfg(feature = "live")]
pub mod native_runner_result;
#[cfg(all(feature = "live", not(target_arch = "wasm32")))]
pub mod native_session_client;
#[cfg(feature = "live")]
pub mod native_session_codec;
#[cfg(all(feature = "live", not(target_arch = "wasm32")))]
pub mod native_session_discovery;
#[cfg(feature = "live")]
pub mod native_session_transport;
#[cfg(all(feature = "live", not(target_arch = "wasm32")))]
pub mod session_cli;

#[cfg(feature = "live")]
pub use control_dto::LiveGraphStatus;
pub use control_dto::{
    ExecutionGroupState, LifecycleState, NdArrayParameterValue, ParameterGeneration,
    PropertyGeneration, ScalarValue,
};
