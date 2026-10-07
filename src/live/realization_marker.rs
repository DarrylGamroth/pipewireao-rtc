//! RTC-owned, inactive no-port realization marker on the public Filter API.

use super::realization::{self, Intent, Phase};
use crate::ScientificDiagnostic;
use pipewire as pw;
use pw::properties::properties;
use pw::spa::pod::Pod;
use std::ffi::CString;
use std::sync::{Arc, Mutex};

pub(super) const PROFILE: &str = "pipewireao.rtc.realization/1";

pub(super) struct Marker {
    // Unregister callbacks before releasing the retained Filter.
    _listener: pw::filter::FilterListenerRc<'static, ()>,
    filter: pw::filter::FilterRc,
    error: Arc<Mutex<Option<String>>>,
    intent: Option<Intent>,
    phase: Option<Phase>,
    attempted_realize: bool,
}

fn diagnostic(error: impl std::fmt::Display) -> ScientificDiagnostic {
    ScientificDiagnostic::new("WirePlumber realization marker", error.to_string())
}

fn pod(bytes: &[u8]) -> Result<&Pod, ScientificDiagnostic> {
    Pod::from_bytes(bytes).ok_or_else(|| diagnostic("serialized realization Props is incomplete"))
}

impl Marker {
    /// Connect without an intent so the owner can discover its exact creator
    /// client from this marker's registry identity. No Props authorizes links.
    pub(super) fn new(core: pw::core::CoreRc, name: &str) -> Result<Self, ScientificDiagnostic> {
        if name.is_empty() {
            return Err(diagnostic("marker name must not be empty"));
        }
        let filter_name = CString::new(name).map_err(diagnostic)?;
        let filter = pw::filter::FilterRc::new_cstr(
            core,
            &filter_name,
            properties! {
                "node.name" => name,
                "media.class" => "Control",
                "pipewireao.rtc-realization.profile" => PROFILE,
            },
        )
        .map_err(diagnostic)?;
        let error = Arc::new(Mutex::new(None));
        let filter_error = Arc::clone(&error);
        let listener = filter
            .add_local_listener::<()>()
            .state_changed(move |_, (), _, state| {
                if let pw::filter::FilterState::Error(message) = state {
                    let mut error = filter_error
                        .lock()
                        .expect("realization marker error poisoned");
                    if error.is_none() {
                        *error = Some(if message.len() <= 256 {
                            message
                        } else {
                            "realization Filter failed with oversized diagnostic".into()
                        });
                    }
                }
            })
            .register()
            .map_err(diagnostic)?;
        filter
            .connect(pw::filter::FilterFlags::INACTIVE, &mut [])
            .map_err(diagnostic)?;
        Ok(Self {
            _listener: listener,
            filter,
            error,
            intent: None,
            phase: None,
            attempted_realize: false,
        })
    }

    /// Retain the one immutable intent before its first Prepared publication.
    /// A failed publication still leaves that intent fixed for this marker.
    pub(super) fn prepare(&mut self, intent: Intent) -> Result<(), ScientificDiagnostic> {
        if self.intent.is_some() {
            return Err(diagnostic("marker intent is already prepared"));
        }
        let bytes = realization::encode(&intent, Phase::Prepared)?;
        let param = pod(&bytes)?;
        self.intent = Some(intent);
        self.phase = Some(Phase::Prepared);
        self.filter.update_params(&mut [param]).map_err(diagnostic)
    }

    pub(super) fn realize(&mut self) -> Result<(), ScientificDiagnostic> {
        if self.phase != Some(Phase::Prepared) {
            return Err(diagnostic("Realize requires the initial Prepared phase"));
        }
        self.publish(Phase::Realize)
    }

    pub(super) fn withdraw(&mut self) -> Result<(), ScientificDiagnostic> {
        self.publish(Phase::Withdraw)
    }

    fn publish(&mut self, phase: Phase) -> Result<(), ScientificDiagnostic> {
        let intent = self
            .intent
            .as_ref()
            .ok_or_else(|| diagnostic("marker intent has not been prepared"))?;
        let bytes = realization::encode(intent, phase)?;
        let param = pod(&bytes)?;
        // Set the fence before the public call: an error cannot prove that
        // Realize was never published, or permit a later phase regression.
        if phase == Phase::Realize {
            self.attempted_realize = true;
        }
        self.phase = Some(phase);
        self.filter.update_params(&mut [param]).map_err(diagnostic)
    }

    /// The ID may be `SPA_ID_INVALID` until the parent advances its main loop.
    pub(super) fn node_id(&self) -> u32 {
        self.filter.node_id()
    }

    pub(super) fn state_error(&self) -> Option<ScientificDiagnostic> {
        self.error
            .lock()
            .expect("realization marker error poisoned")
            .as_ref()
            .map(diagnostic)
    }

    /// Once true, retain the marker through the parent's withdrawal fence.
    /// Successful `update_params` alone does not establish remote application.
    pub(super) fn attempted_realize(&self) -> bool {
        self.attempted_realize
    }
}
