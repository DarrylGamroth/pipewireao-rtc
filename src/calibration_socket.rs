//! Bounded local transport for the completion-driven calibration coordinator.
//!
//! An endpoint server must keep ordinary operation inhibited on disconnect.
//! This client does not establish DM ownership or invent acquisition evidence.

use crate::calibration::{
    AcquisitionCursor, CalibrationAction, CalibrationCompletion, CalibrationEffect,
    CalibrationEndpoint, CalibrationEvidence, CalibrationFailure, CalibrationRequest, Exposure,
    ResponseBatch, SettlingRule,
};
use rustix::event::{poll, PollFd, PollFlags, Timespec};
use serde::{Deserialize, Serialize};
use std::io::{self, Read, Write};
use std::net::Shutdown;
use std::os::unix::net::UnixStream;
use std::sync::Arc;
use std::time::Instant;

const MAX_REQUEST_BYTES: usize = 16 * 1024;
const MAX_REPLY_BYTES: usize = 128 * 1024;

/// One preconnected, nonblocking endpoint channel. No reconnect or retry of an
/// operation with an unknown outcome is performed. Setup occurs before Hold.
pub struct CalibrationSocketEndpoint {
    stream: UnixStream,
    outgoing: Vec<u8>,
    written: usize,
    incoming: Vec<u8>,
    fault: Option<CalibrationFailure>,
}

impl CalibrationSocketEndpoint {
    /// Prepare a connected stream. The server must serialize effects and fence
    /// outstanding work during Restore, including work whose caller timed out.
    ///
    /// # Errors
    /// Returns an I/O error if the socket cannot be made nonblocking.
    pub fn new(stream: UnixStream) -> io::Result<Self> {
        stream.set_nonblocking(true)?;
        Ok(Self {
            stream,
            outgoing: Vec::with_capacity(MAX_REQUEST_BYTES),
            written: 0,
            incoming: Vec::with_capacity(MAX_REPLY_BYTES),
            fault: None,
        })
    }

    #[must_use]
    pub const fn fault_reason(&self) -> Option<CalibrationFailure> {
        self.fault
    }

    fn flush(&mut self) -> Result<(), CalibrationFailure> {
        while self.written < self.outgoing.len() {
            match self.stream.write(&self.outgoing[self.written..]) {
                Ok(0) => return Err(CalibrationFailure::Endpoint),
                Ok(count) => self.written += count,
                Err(error) if error.kind() == io::ErrorKind::WouldBlock => break,
                Err(error) if error.kind() == io::ErrorKind::Interrupted => break,
                Err(_) => return Err(CalibrationFailure::Endpoint),
            }
        }
        Ok(())
    }

    fn completion(&mut self) -> Result<Option<CalibrationCompletion>, CalibrationFailure> {
        let Some(end) = self.incoming.iter().position(|byte| *byte == b'\n') else {
            return Ok(None);
        };
        let reply: WireReply = serde_json::from_slice(&self.incoming[..end])
            .map_err(|_| CalibrationFailure::InvalidEvidence)?;
        self.incoming.drain(..=end);
        if reply.version != 1 || reply.run == 0 || reply.serial == 0 {
            return Err(CalibrationFailure::InvalidEvidence);
        }
        Ok(Some(CalibrationCompletion {
            request: CalibrationRequest {
                run: reply.run,
                serial: reply.serial,
            },
            result: reply.result.into_result()?,
        }))
    }
}

impl CalibrationEndpoint for CalibrationSocketEndpoint {
    fn submit(&mut self, effect: &CalibrationEffect) -> Result<(), CalibrationFailure> {
        if self.fault.is_some()
            || self.written != self.outgoing.len()
            || effect.request.run == 0
            || effect.request.serial == 0
        {
            return Err(CalibrationFailure::Endpoint);
        }
        let timeout_ns = effect
            .deadline
            .checked_duration_since(Instant::now())
            .and_then(|duration| u64::try_from(duration.as_nanos()).ok())
            .filter(|value| *value != 0)
            .ok_or(CalibrationFailure::Endpoint)?;
        self.outgoing.clear();
        self.written = 0;
        let request = WireRequest {
            version: 1,
            run: effect.request.run,
            serial: effect.request.serial,
            timeout_ns,
            action: WireAction::from_action(&effect.action)?,
        };
        let mut writer = BoundedWriter(&mut self.outgoing);
        let encoded = serde_json::to_writer(&mut writer, &request)
            .map_err(|_| CalibrationFailure::Endpoint)
            .and_then(|()| {
                writer
                    .write_all(b"\n")
                    .map_err(|_| CalibrationFailure::Endpoint)
            });
        if let Err(error) = encoded {
            // Nothing has reached the wire. Keep restoration submission usable
            // rather than retaining a partial JSON record in the output queue.
            self.outgoing.clear();
            return Err(error);
        }
        // Submission only queues a bounded request. receive drives its I/O.
        // Even a full socket cannot block the serialized coordinator here.
        Ok(())
    }

    fn receive(
        &mut self,
        deadline: Instant,
    ) -> Result<Option<CalibrationCompletion>, CalibrationFailure> {
        if self.fault.is_some() {
            return Err(CalibrationFailure::Endpoint);
        }
        loop {
            let Some(remaining) = deadline.checked_duration_since(Instant::now()) else {
                return Ok(None);
            };
            if remaining.is_zero() {
                return Ok(None);
            }
            self.flush()?;
            if let Some(completion) = self.completion()? {
                return Ok(Some(completion));
            }
            let mut flags = PollFlags::IN;
            if self.written != self.outgoing.len() {
                flags |= PollFlags::OUT;
            }
            let mut pending = [PollFd::new(&self.stream, flags)];
            let timeout =
                Timespec::try_from(remaining).map_err(|_| CalibrationFailure::Endpoint)?;
            match poll(&mut pending, Some(&timeout)) {
                Ok(0) | Err(rustix::io::Errno::INTR) => continue,
                Ok(_) => {}
                Err(_) => return Err(CalibrationFailure::Endpoint),
            }
            if pending[0].revents().contains(PollFlags::IN)
                || pending[0]
                    .revents()
                    .intersects(PollFlags::HUP | PollFlags::ERR)
            {
                let room = MAX_REPLY_BYTES - self.incoming.len();
                if room == 0 {
                    return Err(CalibrationFailure::InvalidEvidence);
                }
                let mut block = [0_u8; 4096];
                let extent = room.min(block.len());
                match self.stream.read(&mut block[..extent]) {
                    Ok(0) => return Err(CalibrationFailure::Endpoint),
                    Ok(count) => self.incoming.extend_from_slice(&block[..count]),
                    Err(error) if error.kind() == io::ErrorKind::WouldBlock => {}
                    Err(error) if error.kind() == io::ErrorKind::Interrupted => {}
                    Err(_) => return Err(CalibrationFailure::Endpoint),
                }
            }
        }
    }

    fn fault(&mut self, failure: CalibrationFailure) {
        self.fault = Some(failure);
        let _ = self.stream.shutdown(Shutdown::Both);
    }
}

struct BoundedWriter<'a>(&'a mut Vec<u8>);

impl Write for BoundedWriter<'_> {
    fn write(&mut self, bytes: &[u8]) -> io::Result<usize> {
        if bytes.len() > MAX_REQUEST_BYTES - self.0.len() {
            return Err(io::Error::other("calibration request exceeds 16 KiB"));
        }
        self.0.extend_from_slice(bytes);
        Ok(bytes.len())
    }
    fn flush(&mut self) -> io::Result<()> {
        Ok(())
    }
}

#[derive(Serialize)]
struct WireRequest<'a> {
    version: u8,
    run: u64,
    serial: u64,
    timeout_ns: u64,
    action: WireAction<'a>,
}

#[derive(Serialize)]
#[serde(tag = "kind", rename_all = "snake_case")]
enum WireAction<'a> {
    Hold,
    Adopt {
        probe: usize,
        figure: &'a [f32],
    },
    Settle {
        probe: usize,
        after: WireCursor,
        rule: WireSettling,
    },
    Collect {
        probe: usize,
        after: WireCursor,
        measurements: usize,
        frames: usize,
    },
    Restore {
        figure: &'a [f32],
        rule: WireSettling,
    },
    Release,
}

impl<'a> WireAction<'a> {
    fn from_action(action: &'a CalibrationAction) -> Result<Self, CalibrationFailure> {
        Ok(match action {
            CalibrationAction::Hold => Self::Hold,
            CalibrationAction::Adopt { probe, figure } => Self::Adopt {
                probe: *probe,
                figure,
            },
            CalibrationAction::Settle { probe, after, rule } => Self::Settle {
                probe: *probe,
                after: (*after).into(),
                rule: WireSettling::new(*rule)?,
            },
            CalibrationAction::Collect {
                probe,
                after,
                measurements,
                frames,
            } => Self::Collect {
                probe: *probe,
                after: (*after).into(),
                measurements: *measurements,
                frames: *frames,
            },
            CalibrationAction::Restore { figure, rule } => Self::Restore {
                figure,
                rule: WireSettling::new(*rule)?,
            },
            CalibrationAction::Release => Self::Release,
        })
    }
}

#[derive(Serialize)]
#[serde(tag = "kind", rename_all = "snake_case")]
enum WireSettling {
    Immediate,
    DiscardExposures { frames: u32 },
    ModelTime { duration_ns: u64 },
}

impl WireSettling {
    fn new(rule: SettlingRule) -> Result<Self, CalibrationFailure> {
        Ok(match rule {
            SettlingRule::Immediate => Self::Immediate,
            SettlingRule::DiscardExposures(frames) => Self::DiscardExposures { frames },
            SettlingRule::ModelTime(duration) => Self::ModelTime {
                duration_ns: u64::try_from(duration.as_nanos())
                    .map_err(|_| CalibrationFailure::Endpoint)?,
            },
        })
    }
}

#[derive(Serialize, Deserialize)]
#[serde(deny_unknown_fields)]
struct WireCursor {
    domain: u64,
    generation: u64,
    sequence: u64,
    model_ns: u64,
}

impl From<AcquisitionCursor> for WireCursor {
    fn from(cursor: AcquisitionCursor) -> Self {
        Self {
            domain: cursor.domain,
            generation: cursor.generation,
            sequence: cursor.sequence,
            model_ns: cursor.model_ns,
        }
    }
}
impl From<WireCursor> for AcquisitionCursor {
    fn from(cursor: WireCursor) -> Self {
        Self {
            domain: cursor.domain,
            generation: cursor.generation,
            sequence: cursor.sequence,
            model_ns: cursor.model_ns,
        }
    }
}

#[derive(Deserialize)]
#[serde(deny_unknown_fields)]
struct WireExposure {
    domain: u64,
    generation: u64,
    sequence: u64,
    start_model_ns: u64,
    duration_ns: u64,
}

#[derive(Deserialize)]
#[serde(deny_unknown_fields)]
struct WireReply {
    version: u8,
    run: u64,
    serial: u64,
    result: WireResult,
}

#[derive(Deserialize)]
#[serde(tag = "kind", rename_all = "snake_case", deny_unknown_fields)]
enum WireResult {
    Held {
        cursor: WireCursor,
    },
    Adopted {
        cursor: WireCursor,
        figure: Vec<f32>,
        clipped: bool,
    },
    Settled {
        cursor: WireCursor,
    },
    Responses {
        values: Vec<f32>,
        exposures: Vec<WireExposure>,
        valid: bool,
    },
    Restored {
        figure: Vec<f32>,
        clipped: bool,
    },
    Released {},
    Failed {
        reason: String,
    },
}

impl WireResult {
    fn into_result(
        self,
    ) -> Result<Result<CalibrationEvidence, CalibrationFailure>, CalibrationFailure> {
        Ok(Ok(match self {
            Self::Held { cursor } => CalibrationEvidence::Held(cursor.into()),
            Self::Adopted {
                cursor,
                figure,
                clipped,
            } => CalibrationEvidence::Adopted {
                cursor: cursor.into(),
                figure: Arc::from(figure),
                clipped,
            },
            Self::Settled { cursor } => CalibrationEvidence::Settled(cursor.into()),
            Self::Responses {
                values,
                exposures,
                valid,
            } => CalibrationEvidence::Responses(ResponseBatch {
                values,
                valid,
                exposures: exposures
                    .into_iter()
                    .map(|exposure| Exposure {
                        domain: exposure.domain,
                        generation: exposure.generation,
                        sequence: exposure.sequence,
                        start_model_ns: exposure.start_model_ns,
                        duration_ns: exposure.duration_ns,
                    })
                    .collect(),
            }),
            Self::Restored { figure, clipped } => CalibrationEvidence::Restored {
                figure: Arc::from(figure),
                clipped,
            },
            Self::Released {} => CalibrationEvidence::Released,
            Self::Failed { reason } => {
                return match reason.as_str() {
                    "cancelled" => Ok(Err(CalibrationFailure::Cancelled)),
                    "endpoint" => Ok(Err(CalibrationFailure::Endpoint)),
                    "invalid_evidence" => Ok(Err(CalibrationFailure::InvalidEvidence)),
                    "probe_clipped" => Ok(Err(CalibrationFailure::ProbeClipped)),
                    _ => Err(CalibrationFailure::InvalidEvidence),
                }
            }
        }))
    }
}
