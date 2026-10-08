//! Discovery and native clients for WirePlumber-owned sessions.

#[cfg(not(target_arch = "wasm32"))]
pub mod cli;
#[cfg(not(target_arch = "wasm32"))]
pub mod client;
#[cfg(not(target_arch = "wasm32"))]
pub mod discovery;
pub mod protocol;
pub mod replies;
pub mod requests;
pub mod transport;
