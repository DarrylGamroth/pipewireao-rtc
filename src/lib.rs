//! Clients and calibration acquisition for `WirePlumber`-owned `PipeWireAO` sessions.

pub mod calibration;
#[cfg(feature = "live")]
mod connection;
pub mod control;
#[cfg(feature = "live")]
pub mod session;

#[cfg(feature = "live")]
pub use control::types::LiveGraphStatus;
pub use control::types::{
    ExecutionGroupState, LifecycleState, NdArrayParameterValue, ParameterGeneration,
    PropertyGeneration, ScalarValue,
};

// Existing GUI and external clients use these module paths. Keep import aliases
// while source organization and new callers use the domain modules above.
#[cfg(feature = "live")]
#[doc(hidden)]
pub use calibration::{
    client as native_calibration_endpoint, protocol as native_calibration_action_codec,
};
#[cfg(feature = "live")]
#[doc(hidden)]
pub use control::envelope as native_control_codec;
#[doc(hidden)]
pub use control::types as control_dto;
#[cfg(all(feature = "live", not(target_arch = "wasm32")))]
#[doc(hidden)]
pub use session::{
    cli as session_cli, client as native_session_client, discovery as native_session_discovery,
};
#[cfg(feature = "live")]
#[doc(hidden)]
pub use session::{
    protocol as native_session_codec, replies as native_runner_result,
    requests as native_runner_codec, transport as native_session_transport,
};
