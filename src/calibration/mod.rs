//! Completion-driven calibration acquisition and native owner clients.

pub mod acquisition;
#[cfg(feature = "live")]
pub mod client;
#[cfg(feature = "live")]
pub mod protocol;

pub use acquisition::*;
