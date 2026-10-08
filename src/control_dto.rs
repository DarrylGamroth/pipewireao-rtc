//! Pure values shared by lifecycle execution and versioned control profiles.
//!
//! These types carry lifecycle observations and typed control data. They do not
//! own or execute a lifecycle.

use std::collections::BTreeMap;
use std::sync::Arc;

#[derive(Clone, Copy, Debug, Eq, PartialEq)]
pub enum LifecycleState {
    Offline,
    Configuring,
    Ready,
    Running,
    Fault,
}

#[derive(Clone, Copy, Debug, Eq, PartialEq)]
pub enum ExecutionGroupState {
    Stopped,
    Running,
}

/// One scalar value admitted to a graph's standard `SPA_PARAM_Props` surface.
#[derive(Clone, Debug, Eq, PartialEq)]
pub enum ScalarValue {
    Bool(bool),
    Int(i32),
    Long(i64),
    Float(u32),
    Double(u64),
    Id(u32),
    String(String),
}

impl ScalarValue {
    #[must_use]
    pub fn float(value: f32) -> Self {
        Self::Float(value.to_bits())
    }

    #[must_use]
    pub fn double(value: f64) -> Self {
        Self::Double(value.to_bits())
    }

    #[must_use]
    pub fn as_float(&self) -> Option<f32> {
        match self {
            Self::Float(bits) => Some(f32::from_bits(*bits)),
            _ => None,
        }
    }

    #[must_use]
    pub fn as_double(&self) -> Option<f64> {
        match self {
            Self::Double(bits) => Some(f64::from_bits(*bits)),
            _ => None,
        }
    }
}

/// One complete ndarray value for a declared graph parameter input.
#[derive(Clone, Debug, Eq, PartialEq)]
pub struct NdArrayParameterValue {
    pub element_type: String,
    pub shape: Vec<u32>,
    pub schema: String,
    /// Owned payload shared without byte copies across lifecycle effects and
    /// pending publication. Construct from a prepared `Vec` before owner-thread
    /// dispatch; treat the bytes as immutable. Publication copies them into SPA
    /// storage, whose lifetime is independent of this value.
    pub bytes: Arc<Vec<u8>>,
}

#[derive(Clone, Copy, Debug, Eq, PartialEq)]
pub struct PropertyGeneration {
    pub requested: i64,
    pub active: Option<i64>,
}

#[derive(Clone, Copy, Debug, Eq, PartialEq)]
pub struct ParameterGeneration {
    pub requested: i64,
    pub active: i64,
}

/// Observation DTO reported by an owner of live graph objects.
#[derive(Clone, Debug, Default, Eq, PartialEq)]
pub struct LiveGraphStatus {
    pub owned_nodes: usize,
    pub owned_links: usize,
    pub running: bool,
    pub discarded_buffers: u64,
    pub discarded_by_sink: BTreeMap<String, u64>,
}

/// Operation IDs shared by the direct session and retained runner profiles.
#[derive(Clone, Copy, Debug, Eq, PartialEq)]
#[repr(u32)]
pub enum Operation {
    Quit = 1,
    Groups = 2,
    Status = 3,
    Properties = 4,
    PropertyGeneration = 5,
    ParameterGeneration = 6,
    StopGroup = 7,
    StartGroup = 8,
    SessionStop = 9,
    SessionStart = 10,
    SourceEnded = 11,
    Reset = 12,
    PropertiesSet = 13,
    Parameter = 14,
}

#[cfg(feature = "live")]
impl TryFrom<u32> for Operation {
    type Error = crate::control::ControlError;

    fn try_from(value: u32) -> Result<Self, Self::Error> {
        use Operation as O;
        Ok(match value {
            1 => O::Quit,
            2 => O::Groups,
            3 => O::Status,
            4 => O::Properties,
            5 => O::PropertyGeneration,
            6 => O::ParameterGeneration,
            7 => O::StopGroup,
            8 => O::StartGroup,
            9 => O::SessionStop,
            10 => O::SessionStart,
            11 => O::SourceEnded,
            12 => O::Reset,
            13 => O::PropertiesSet,
            14 => O::Parameter,
            _ => {
                return Err(crate::control::ControlError::new(
                    "native.runner.request",
                    "unknown runner operation",
                ));
            }
        })
    }
}
