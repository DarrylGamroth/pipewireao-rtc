use crate::control::{
    self, ControlError, ControlErrorResponse, ControlResponse, SocketRequest, MAX_ARGUMENTS,
    MAX_REQUEST_BYTES,
};
use crate::ControlInput;
use pipewire::channel::Sender;
use std::fs;
use std::io::{self, BufReader, Read, Write};
use std::os::unix::fs::{FileTypeExt, MetadataExt, PermissionsExt};
use std::os::unix::net::{UnixListener, UnixStream};
use std::path::{Path, PathBuf};
use std::sync::atomic::{AtomicBool, Ordering};
use std::sync::{mpsc, Arc};
use std::thread::{self, JoinHandle};
use std::time::{Duration, Instant};

const SOCKET_CONNECT_TIMEOUT: Duration = Duration::from_secs(2);
const SOCKET_READ_TIMEOUT: Duration = Duration::from_secs(2);
const SOCKET_WRITE_TIMEOUT: Duration = Duration::from_secs(2);
const CLIENT_RESPONSE_TIMEOUT: Duration = Duration::from_secs(10);
const OWNER_REPLY_TIMEOUT: Duration = Duration::from_secs(7);
const MAX_RESPONSE_BYTES: usize = 64 * 1024;
const ACCEPT_POLL: Duration = Duration::from_millis(20);

pub struct ControlSocketServer {
    stop: Arc<AtomicBool>,
    worker: Option<JoinHandle<()>>,
    socket: Option<OwnedSocketPath>,
}

struct OwnedSocketPath {
    path: PathBuf,
    device: u64,
    inode: u64,
    uid: u32,
}

impl ControlSocketServer {
    #[allow(clippy::needless_pass_by_value)]
    pub fn bind(path: &Path, sender: Sender<ControlInput>, session_id: String) -> io::Result<Self> {
        let path = validate_socket_path(path)?;
        if fs::symlink_metadata(&path).is_ok() {
            return Err(io::Error::new(
                io::ErrorKind::AddrInUse,
                format!(
                    "refusing to replace existing control socket path {}",
                    path.display()
                ),
            ));
        }
        let listener = UnixListener::bind(&path)?;
        if let Err(error) = fs::set_permissions(&path, fs::Permissions::from_mode(0o600)) {
            remove_owned_socket(&path);
            return Err(error);
        }
        let metadata = fs::symlink_metadata(&path)?;
        if !metadata.file_type().is_socket() || metadata.mode() & 0o777 != 0o600 {
            remove_owned_socket(&path);
            return Err(io::Error::new(
                io::ErrorKind::PermissionDenied,
                "control socket permissions could not be restricted to owner-only",
            ));
        }
        let socket = OwnedSocketPath {
            path,
            device: metadata.dev(),
            inode: metadata.ino(),
            uid: metadata.uid(),
        };
        listener.set_nonblocking(true)?;
        let stop = Arc::new(AtomicBool::new(false));
        let worker_stop = Arc::clone(&stop);
        let worker_session_id = session_id.clone();
        let worker = thread::Builder::new()
            .name("rtc-control-socket".to_owned())
            .spawn(move || serve(listener, sender, worker_stop, worker_session_id))?;
        Ok(Self {
            stop,
            worker: Some(worker),
            socket: Some(socket),
        })
    }

    pub fn shutdown(&self) {
        self.stop.store(true, Ordering::Release);
    }
}

impl Drop for ControlSocketServer {
    fn drop(&mut self) {
        self.shutdown();
        if let Some(worker) = self.worker.take() {
            let _ = worker.join();
        }
        // Drop only removes the inode created by this server. A replacement
        // path or any pre-existing object is never unlinked.
        self.socket.take();
    }
}

impl Drop for OwnedSocketPath {
    fn drop(&mut self) {
        let Ok(metadata) = fs::symlink_metadata(&self.path) else {
            return;
        };
        if metadata.file_type().is_socket()
            && metadata.uid() == self.uid
            && metadata.dev() == self.device
            && metadata.ino() == self.inode
        {
            let _ = fs::remove_file(&self.path);
        }
    }
}

fn validate_socket_path(path: &Path) -> io::Result<PathBuf> {
    if !path.is_absolute() {
        return Err(io::Error::new(
            io::ErrorKind::InvalidInput,
            "control socket path must be absolute",
        ));
    }
    let name = path
        .file_name()
        .filter(|name| !name.is_empty())
        .ok_or_else(|| {
            io::Error::new(io::ErrorKind::InvalidInput, "socket path must name a file")
        })?;
    let parent = path.parent().ok_or_else(|| {
        io::Error::new(
            io::ErrorKind::InvalidInput,
            "socket path has no parent directory",
        )
    })?;
    let parent = fs::canonicalize(parent)?;
    let metadata = fs::symlink_metadata(&parent)?;
    let self_uid = effective_uid()?;
    if !metadata.is_dir() || metadata.uid() != self_uid || metadata.mode() & 0o077 != 0 {
        return Err(io::Error::new(
            io::ErrorKind::PermissionDenied,
            format!("socket parent must be a directory owned by the effective user with no group/other access (dir={}, uid={} expected={}, mode={:o})", metadata.is_dir(), metadata.uid(), self_uid, metadata.mode() & 0o777),
        ));
    }
    Ok(parent.join(name))
}

fn remove_owned_socket(path: &Path) {
    if let Ok(metadata) = fs::symlink_metadata(path) {
        if metadata.file_type().is_socket() && metadata.uid() == effective_uid().unwrap_or(u32::MAX)
        {
            let _ = fs::remove_file(path);
        }
    }
}

fn effective_uid() -> io::Result<u32> {
    fs::read_to_string("/proc/self/status")?
        .lines()
        .find_map(|line| line.strip_prefix("Uid:"))
        .and_then(|uids| uids.split_whitespace().nth(1))
        .and_then(|uid| uid.parse::<u32>().ok())
        .ok_or_else(|| {
            io::Error::new(
                io::ErrorKind::PermissionDenied,
                "cannot determine effective uid",
            )
        })
}

#[allow(clippy::needless_pass_by_value)]
fn serve(
    listener: UnixListener,
    sender: Sender<ControlInput>,
    stop: Arc<AtomicBool>,
    session_id: String,
) {
    while !stop.load(Ordering::Acquire) {
        match listener.accept() {
            Ok((stream, _address)) => {
                if let Err(error) = serve_client(stream, &sender, &session_id, &stop) {
                    if error.kind() != io::ErrorKind::TimedOut
                        && error.kind() != io::ErrorKind::WouldBlock
                        && error.kind() != io::ErrorKind::UnexpectedEof
                    {
                        eprintln!("control socket client rejected: {error}");
                    }
                }
            }
            Err(error) if error.kind() == io::ErrorKind::WouldBlock => {
                thread::sleep(ACCEPT_POLL);
            }
            Err(error) if error.kind() == io::ErrorKind::Interrupted => {}
            Err(error) => {
                eprintln!("control socket accept failed: {error}");
                thread::sleep(ACCEPT_POLL);
            }
        }
    }
}

fn serve_client(
    mut stream: UnixStream,
    sender: &Sender<ControlInput>,
    session_id: &str,
    stop: &AtomicBool,
) -> io::Result<()> {
    // One request per connection prevents an idle client from holding the
    // worker after its response. The read deadline covers the entire line.
    let mut reader = DeadlineReader {
        reader: BufReader::new(stream.try_clone()?),
        deadline: Instant::now() + SOCKET_READ_TIMEOUT,
    };
    let (id, command) = match read_limited_line(&mut reader, MAX_REQUEST_BYTES) {
        Ok(Some(line)) => parse_request(&line),
        Ok(None) => return Ok(()),
        Err(ReadLineError::TooLarge) => (
            None,
            Err(ControlError::new(
                "protocol.request",
                "request exceeds 16384 bytes",
            )),
        ),
        Err(ReadLineError::Io(error)) => return Err(error),
    };
    if stop.load(Ordering::Acquire) {
        return Ok(());
    }
    let (reply, response) = mpsc::sync_channel(1);
    if sender
        .send(ControlInput::Request {
            id: id.clone(),
            command,
            reply,
        })
        .is_err()
    {
        return write_response(
            &mut stream,
            &rejected(
                id,
                Some(session_id),
                None,
                "service.shutdown",
                "RTC control owner is no longer available",
            ),
        );
    }
    await_owner_reply(
        &mut stream,
        &response,
        id,
        session_id,
        stop,
        OWNER_REPLY_TIMEOUT,
    )
}

fn parse_request(line: &[u8]) -> (Option<String>, Result<control::Command, ControlError>) {
    match serde_json::from_slice::<SocketRequest>(line) {
        Ok(request) => {
            let id =
                (!request.id.is_empty() && request.id.len() <= 128).then(|| request.id.clone());
            let command = if request.version != 1 {
                Err(ControlError::new(
                    "protocol.version",
                    format!(
                        "unsupported protocol version {}; expected 1",
                        request.version
                    ),
                ))
            } else if request.id.is_empty() || request.id.len() > 128 {
                Err(ControlError::new(
                    "protocol.id",
                    "request id must contain 1 to 128 UTF-8 bytes",
                ))
            } else if request.argv.len() > MAX_ARGUMENTS {
                Err(ControlError::new(
                    "command.arguments",
                    format!("at most {MAX_ARGUMENTS} command fields are allowed"),
                ))
            } else {
                control::parse(&request.argv).and_then(control::prepare)
            };
            (id, command)
        }
        Err(error) => (
            None,
            Err(ControlError::new("protocol.request", error.to_string())),
        ),
    }
}

fn await_owner_reply(
    stream: &mut UnixStream,
    response: &mpsc::Receiver<ControlResponse>,
    id: Option<String>,
    session_id: &str,
    stop: &AtomicBool,
    timeout: Duration,
) -> io::Result<()> {
    let deadline = Instant::now() + timeout;
    let mut timed_out = false;
    let mut write_result = Ok(());
    loop {
        if stop.load(Ordering::Acquire) {
            // The shutdown command queues its acknowledgement before revoking
            // admission. Return that ready result even when stop wins the race.
            return match response.try_recv() {
                Ok(reply) if !timed_out => write_response(stream, &reply),
                _ => write_result,
            };
        }
        match response.recv_timeout(ACCEPT_POLL) {
            Ok(reply) => {
                // Keep the only admitted slot until the owner acknowledges,
                // even if the client disconnected or received an unknown outcome.
                return if timed_out {
                    write_result
                } else {
                    write_response(stream, &reply)
                };
            }
            Err(mpsc::RecvTimeoutError::Disconnected) => {
                return if timed_out {
                    write_result
                } else {
                    write_response(stream, &rejected(id, Some(session_id), None,
                        "service.shutdown", "RTC control owner stopped before replying; the command outcome is unknown"))
                };
            }
            Err(mpsc::RecvTimeoutError::Timeout) if !timed_out && Instant::now() >= deadline => {
                timed_out = true;
                write_result = write_response(stream, &rejected(id.clone(), Some(session_id), None,
                    "control.outcome", "response deadline elapsed; the command may already have been applied; do not retry automatically"));
            }
            Err(mpsc::RecvTimeoutError::Timeout) => {}
        }
    }
}

fn rejected(
    id: Option<String>,
    session_id: Option<&str>,
    state: Option<String>,
    field: &str,
    message: &str,
) -> ControlResponse {
    ControlResponse {
        version: 1,
        id,
        session_id: session_id.map(str::to_owned),
        state,
        result: None,
        ok: false,
        error: Some(ControlErrorResponse {
            field: field.to_owned(),
            message: message.to_owned(),
        }),
    }
}

pub fn write_response(stream: &mut UnixStream, response: &ControlResponse) -> io::Result<()> {
    let mut bytes = Vec::with_capacity(1024);
    let serialized = {
        let mut limited = LimitedWriter {
            bytes: &mut bytes,
            limit: MAX_RESPONSE_BYTES - 1,
        };
        serde_json::to_writer(&mut limited, response).is_ok()
    };
    if !serialized {
        bytes.clear();
        serde_json::to_writer(
            &mut bytes,
            &rejected(
                response.id.clone(),
                response.session_id.as_deref(),
                response.state.clone(),
                "protocol.response",
                "response exceeds 65536 bytes",
            ),
        )?;
    }
    bytes.push(b'\n');
    write_with_deadline(stream, &bytes, Instant::now() + SOCKET_WRITE_TIMEOUT)
}

struct LimitedWriter<'a> {
    bytes: &'a mut Vec<u8>,
    limit: usize,
}

impl Write for LimitedWriter<'_> {
    fn write(&mut self, bytes: &[u8]) -> io::Result<usize> {
        if self.bytes.len().saturating_add(bytes.len()) > self.limit {
            return Err(io::Error::new(
                io::ErrorKind::InvalidData,
                "response exceeds protocol bound",
            ));
        }
        self.bytes.extend_from_slice(bytes);
        Ok(bytes.len())
    }

    fn flush(&mut self) -> io::Result<()> {
        Ok(())
    }
}

#[derive(Debug)]
enum ReadLineError {
    TooLarge,
    Io(io::Error),
}

fn read_limited_line<R: Read>(
    reader: &mut R,
    limit: usize,
) -> Result<Option<Vec<u8>>, ReadLineError> {
    let mut line = Vec::with_capacity(limit.min(4096));
    let mut byte = [0_u8; 1];
    loop {
        match reader.read(&mut byte) {
            Ok(0) if line.is_empty() => return Ok(None),
            Ok(0) => {
                return Err(ReadLineError::Io(io::Error::new(
                    io::ErrorKind::UnexpectedEof,
                    "connection closed before request newline",
                )))
            }
            Ok(_) if byte[0] == b'\n' => return Ok(Some(line)),
            Ok(_) => {
                if line.len() >= limit.saturating_sub(1) {
                    return Err(ReadLineError::TooLarge);
                }
                line.push(byte[0]);
            }
            Err(error) => return Err(ReadLineError::Io(error)),
        }
    }
}

// Refresh the kernel timeout from the remaining monotonic budget before each
// syscall. Partial progress cannot extend either deadline.
struct DeadlineReader {
    reader: BufReader<UnixStream>,
    deadline: Instant,
}

impl Read for DeadlineReader {
    fn read(&mut self, bytes: &mut [u8]) -> io::Result<usize> {
        self.reader
            .get_ref()
            .set_read_timeout(Some(remaining(self.deadline)?))?;
        self.reader.read(bytes)
    }
}

fn remaining(deadline: Instant) -> io::Result<Duration> {
    let duration = deadline.saturating_duration_since(Instant::now());
    if duration.is_zero() {
        Err(io::Error::new(
            io::ErrorKind::TimedOut,
            "control I/O deadline elapsed",
        ))
    } else {
        Ok(duration)
    }
}

fn write_with_deadline(
    stream: &mut UnixStream,
    mut bytes: &[u8],
    deadline: Instant,
) -> io::Result<()> {
    while !bytes.is_empty() {
        stream.set_write_timeout(Some(remaining(deadline)?))?;
        match stream.write(bytes) {
            Ok(0) => {
                return Err(io::Error::new(
                    io::ErrorKind::WriteZero,
                    "control write made no progress",
                ))
            }
            Ok(count) => bytes = &bytes[count..],
            Err(error) if error.kind() == io::ErrorKind::Interrupted => {}
            Err(error) => return Err(error),
        }
    }
    Ok(())
}

fn connect_with_deadline(path: &Path, deadline: Instant) -> io::Result<UnixStream> {
    use rustix::event::{poll, PollFd, PollFlags, Timespec};
    use rustix::io::Errno;
    use rustix::net::{self, AddressFamily, SocketAddrUnix, SocketFlags, SocketType};
    let address = SocketAddrUnix::new(path)?;
    loop {
        remaining(deadline)?;
        let socket = net::socket_with(
            AddressFamily::UNIX,
            SocketType::STREAM,
            SocketFlags::NONBLOCK | SocketFlags::CLOEXEC,
            None,
        )?;
        match net::connect(&socket, &address) {
            Ok(()) => {}
            Err(Errno::AGAIN) => {
                // A full Unix backlog has not accepted this connection. Retry
                // connection admission only; no command bytes have been sent.
                thread::sleep(ACCEPT_POLL.min(remaining(deadline)?));
                continue;
            }
            Err(Errno::INTR) => continue,
            Err(Errno::INPROGRESS) => {
                let mut pending = [PollFd::new(&socket, PollFlags::OUT)];
                loop {
                    let timeout =
                        Timespec::try_from(remaining(deadline)?).map_err(io::Error::other)?;
                    match poll(&mut pending, Some(&timeout)) {
                        Ok(0) => {
                            return Err(io::Error::new(
                                io::ErrorKind::TimedOut,
                                "control connection deadline elapsed",
                            ))
                        }
                        Ok(_) => break,
                        Err(Errno::INTR) => {}
                        Err(error) => return Err(error.into()),
                    }
                }
                net::sockopt::socket_error(&socket)??;
            }
            Err(error) => return Err(error.into()),
        }
        let stream = UnixStream::from(socket);
        stream.set_nonblocking(false)?;
        return Ok(stream);
    }
}

pub fn send_request(path: &Path, argv: Vec<String>, id: &str) -> io::Result<ControlResponse> {
    if argv.len() > MAX_ARGUMENTS {
        return Err(io::Error::new(
            io::ErrorKind::InvalidInput,
            format!("at most {MAX_ARGUMENTS} command fields are allowed"),
        ));
    }
    let mut stream = connect_with_deadline(path, Instant::now() + SOCKET_CONNECT_TIMEOUT)?;
    let request = serde_json::to_vec(&SocketRequest {
        version: 1,
        id: id.to_owned(),
        argv,
    })?;
    if request.len() + 1 > MAX_REQUEST_BYTES {
        return Err(io::Error::new(
            io::ErrorKind::InvalidInput,
            "serialized request exceeds 16384 bytes",
        ));
    }
    let deadline = Instant::now() + SOCKET_WRITE_TIMEOUT;
    write_with_deadline(&mut stream, &request, deadline)?;
    write_with_deadline(&mut stream, b"\n", deadline)?;
    let mut reader = DeadlineReader {
        reader: BufReader::new(stream),
        deadline: Instant::now() + CLIENT_RESPONSE_TIMEOUT,
    };
    let line = read_limited_line(&mut reader, MAX_RESPONSE_BYTES)
        .map_err(|error| match error {
            ReadLineError::TooLarge => {
                io::Error::new(io::ErrorKind::InvalidData, "response too large")
            }
            ReadLineError::Io(error) if matches!(error.kind(), io::ErrorKind::TimedOut | io::ErrorKind::WouldBlock) => {
                io::Error::new(io::ErrorKind::TimedOut, "response deadline elapsed; command outcome is unknown; do not retry automatically")
            }
            ReadLineError::Io(error) => error,
        })?
        .ok_or_else(|| {
            io::Error::new(
                io::ErrorKind::UnexpectedEof,
                "socket closed without a response",
            )
        })?;
    let response: ControlResponse = serde_json::from_slice(&line)
        .map_err(|error| io::Error::new(io::ErrorKind::InvalidData, error))?;
    if response.version != 1 {
        return Err(io::Error::new(
            io::ErrorKind::InvalidData,
            "unsupported response protocol version",
        ));
    }
    if response.id.as_deref() != Some(id) {
        return Err(io::Error::new(
            io::ErrorKind::InvalidData,
            "response request id does not match",
        ));
    }
    Ok(response)
}

#[cfg(test)]
mod tests {
    use super::{read_limited_line, validate_socket_path, ControlSocketServer};
    use crate::control::MAX_REQUEST_BYTES;
    use pipewire::channel::channel;
    use std::fs;
    use std::io::{self, Cursor};
    use std::os::unix::fs::PermissionsExt;

    #[test]
    fn line_reader_enforces_byte_limit_and_detects_partial_eof() {
        let mut valid = Cursor::new(b"abc\nnext".to_vec());
        assert_eq!(
            read_limited_line(&mut valid, 4).unwrap(),
            Some(b"abc".to_vec())
        );
        let mut oversized = Cursor::new(b"abcd\n".to_vec());
        assert!(matches!(
            read_limited_line(&mut oversized, 4),
            Err(super::ReadLineError::TooLarge)
        ));
        let mut partial = Cursor::new(b"abc".to_vec());
        assert!(
            matches!(read_limited_line(&mut partial, 4), Err(super::ReadLineError::Io(error)) if error.kind() == io::ErrorKind::UnexpectedEof)
        );
    }

    #[test]
    fn socket_requires_private_owned_parent_and_never_replaces_existing_path() {
        let directory = tempfile::tempdir().unwrap();
        fs::set_permissions(directory.path(), fs::Permissions::from_mode(0o700)).unwrap();
        let socket = directory.path().join("control.sock");
        let (sender, _receiver) = channel();
        let server = ControlSocketServer::bind(&socket, sender, "123-test".to_owned()).unwrap();
        let metadata = fs::symlink_metadata(&socket).unwrap();
        assert_eq!(metadata.permissions().mode() & 0o777, 0o600);
        assert!(ControlSocketServer::bind(&socket, channel().0, "123-test".to_owned()).is_err());
        drop(server);
        assert!(!socket.exists());

        let broad = directory.path().join("broad");
        fs::create_dir(&broad).unwrap();
        fs::set_permissions(&broad, fs::Permissions::from_mode(0o750)).unwrap();
        assert!(validate_socket_path(&broad.join("control.sock")).is_err());
    }

    fn response(id: &str) -> crate::control::ControlResponse {
        crate::control::ControlResponse {
            version: 1,
            id: Some(id.to_owned()),
            session_id: Some("test".to_owned()),
            state: Some("Ready".to_owned()),
            result: Some(serde_json::json!({"outcome":"submitted"})),
            ok: true,
            error: None,
        }
    }

    #[test]
    fn slow_drip_cannot_extend_whole_line_deadline() {
        use std::io::Write;
        use std::os::unix::net::UnixStream;
        use std::time::{Duration, Instant};
        let (server, mut client) = UnixStream::pair().unwrap();
        let writer = std::thread::spawn(move || {
            for _ in 0..20 {
                if client.write_all(b"a").is_err() {
                    break;
                }
                std::thread::sleep(Duration::from_millis(20));
            }
        });
        let start = Instant::now();
        let mut reader = super::DeadlineReader {
            reader: std::io::BufReader::new(server),
            deadline: start + Duration::from_millis(80),
        };
        assert!(matches!(read_limited_line(&mut reader, MAX_REQUEST_BYTES),
            Err(super::ReadLineError::Io(error)) if matches!(error.kind(), io::ErrorKind::TimedOut | io::ErrorKind::WouldBlock)));
        assert!(start.elapsed() < Duration::from_secs(1));
        drop(reader);
        writer.join().unwrap();
    }

    #[test]
    fn slow_response_reader_cannot_extend_write_deadline() {
        use std::os::unix::net::UnixStream;
        use std::time::{Duration, Instant};
        let (mut server, _client) = UnixStream::pair().unwrap();
        let start = Instant::now();
        let error = super::write_with_deadline(
            &mut server,
            &vec![0; 2 * 1024 * 1024],
            start + Duration::from_millis(80),
        )
        .unwrap_err();
        assert!(matches!(
            error.kind(),
            io::ErrorKind::TimedOut | io::ErrorKind::WouldBlock
        ));
        assert!(start.elapsed() < Duration::from_secs(1));
    }

    #[test]
    fn owner_timeout_retains_slot_until_actual_acknowledgement() {
        use std::os::unix::net::UnixStream;
        use std::sync::{atomic::AtomicBool, mpsc, Arc};
        use std::time::Duration;
        let (mut server, client) = UnixStream::pair().unwrap();
        let (ack, pending) = mpsc::sync_channel(1);
        let (finished, completion) = mpsc::channel();
        let stop = Arc::new(AtomicBool::new(false));
        let worker = std::thread::spawn(move || {
            let result = super::await_owner_reply(
                &mut server,
                &pending,
                Some("one".to_owned()),
                "test",
                &stop,
                Duration::from_millis(40),
            );
            finished.send(()).unwrap();
            result
        });
        client
            .set_read_timeout(Some(Duration::from_secs(1)))
            .unwrap();
        let mut reader = std::io::BufReader::new(client);
        let line = read_limited_line(&mut reader, super::MAX_RESPONSE_BYTES)
            .unwrap()
            .unwrap();
        let reply: crate::control::ControlResponse = serde_json::from_slice(&line).unwrap();
        assert_eq!(reply.error.unwrap().field, "control.outcome");
        drop(reader);
        assert!(matches!(
            completion.recv_timeout(Duration::from_millis(80)),
            Err(mpsc::RecvTimeoutError::Timeout)
        ));
        ack.send(response("one")).unwrap();
        completion.recv_timeout(Duration::from_secs(1)).unwrap();
        worker.join().unwrap().unwrap();
    }

    #[test]
    fn shutdown_delivers_already_acknowledged_command_response() {
        use std::os::unix::net::UnixStream;
        use std::sync::{atomic::AtomicBool, mpsc};
        let (mut server, client) = UnixStream::pair().unwrap();
        let (ack, pending) = mpsc::sync_channel(1);
        ack.send(response("quit")).unwrap();
        let stop = AtomicBool::new(true);
        super::await_owner_reply(
            &mut server,
            &pending,
            Some("quit".into()),
            "test",
            &stop,
            std::time::Duration::from_secs(7),
        )
        .unwrap();
        let line = read_limited_line(
            &mut std::io::BufReader::new(client),
            super::MAX_RESPONSE_BYTES,
        )
        .unwrap()
        .unwrap();
        let reply: crate::control::ControlResponse = serde_json::from_slice(&line).unwrap();
        assert!(reply.ok);
        assert_eq!(reply.id.as_deref(), Some("quit"));
    }

    #[test]
    fn disconnected_parameter_flood_admits_one_prepared_request_until_ack() {
        use std::cell::RefCell;
        use std::collections::VecDeque;
        use std::io::Write;
        use std::os::unix::net::UnixStream;
        use std::rc::Rc;
        use std::time::{Duration, Instant};
        let directory = tempfile::tempdir().unwrap();
        fs::set_permissions(directory.path(), fs::Permissions::from_mode(0o700)).unwrap();
        let socket = directory.path().join("control.sock");
        let payload = directory.path().join("payload");
        fs::write(&payload, [0; 4]).unwrap();
        let main_loop = pipewire::main_loop::MainLoopRc::new(None).unwrap();
        let queued = Rc::new(RefCell::new(VecDeque::new()));
        let inputs = Rc::clone(&queued);
        let (sender, receiver) = channel();
        let _attached = receiver.attach(main_loop.loop_(), move |input| {
            inputs.borrow_mut().push_back(input);
        });
        let server = ControlSocketServer::bind(&socket, sender, "test".to_owned()).unwrap();
        for index in 0..8 {
            let mut client = UnixStream::connect(&socket).unwrap();
            let request = crate::control::SocketRequest {
                version: 1,
                id: index.to_string(),
                argv: vec![
                    "parameter".into(),
                    "g".into(),
                    "p".into(),
                    "F32_LE".into(),
                    "1".into(),
                    "schema".into(),
                    payload.to_str().unwrap().into(),
                ],
            };
            serde_json::to_writer(&mut client, &request).unwrap();
            client.write_all(b"\n").unwrap();
            // All clients abandon their requests before owner acknowledgement.
        }
        for index in 0..8 {
            let deadline = Instant::now() + Duration::from_secs(1);
            while queued.borrow().is_empty() && Instant::now() < deadline {
                main_loop
                    .loop_()
                    .iterate(pipewire::loop_::Timeout::Finite(Duration::from_millis(10)));
            }
            let pending = Instant::now() + Duration::from_millis(30);
            while Instant::now() < pending {
                main_loop
                    .loop_()
                    .iterate(pipewire::loop_::Timeout::Finite(Duration::from_millis(5)));
            }
            assert_eq!(
                queued.borrow().len(),
                1,
                "more than one prepared payload was admitted"
            );
            let crate::ControlInput::Request { id, command, reply } =
                queued.borrow_mut().pop_front().unwrap()
            else {
                panic!("expected request");
            };
            assert_eq!(id.as_deref(), Some(index.to_string().as_str()));
            assert!(matches!(
                command,
                Ok(crate::control::Command::PreparedParameter { .. })
            ));
            reply.try_send(response(&index.to_string())).unwrap();
        }
        drop(server);
    }

    #[test]
    fn shutdown_releases_worker_with_undrained_owner_queue() {
        use std::io::Write;
        use std::os::unix::net::UnixStream;
        use std::time::{Duration, Instant};
        let directory = tempfile::tempdir().unwrap();
        fs::set_permissions(directory.path(), fs::Permissions::from_mode(0o700)).unwrap();
        let socket = directory.path().join("control.sock");
        let (sender, _receiver) = channel();
        let server = ControlSocketServer::bind(&socket, sender, "test".to_owned()).unwrap();
        let mut client = UnixStream::connect(&socket).unwrap();
        client
            .write_all(b"{\"version\":1,\"id\":\"one\",\"argv\":[\"status\"]}\n")
            .unwrap();
        std::thread::sleep(Duration::from_millis(80));
        let start = Instant::now();
        drop(server);
        assert!(start.elapsed() < Duration::from_secs(1));
    }

    #[test]
    fn response_bound_allows_64_kib_and_rejects_larger_values() {
        use std::os::unix::net::UnixStream;
        for size in [20 * 1024, 70 * 1024] {
            let (mut server, client) = UnixStream::pair().unwrap();
            let mut response = response("one");
            response.result = Some(serde_json::json!({"value":"x".repeat(size)}));
            super::write_response(&mut server, &response).unwrap();
            let line = read_limited_line(
                &mut std::io::BufReader::new(client),
                super::MAX_RESPONSE_BYTES,
            )
            .unwrap()
            .unwrap();
            assert!(line.len() < super::MAX_RESPONSE_BYTES);
            let reply: crate::control::ControlResponse = serde_json::from_slice(&line).unwrap();
            assert_eq!(reply.ok, size < super::MAX_RESPONSE_BYTES);
            if !reply.ok {
                assert_eq!(reply.error.unwrap().field, "protocol.response");
            }
        }
    }

    #[test]
    fn full_unix_backlog_cannot_block_client_connect_past_deadline() {
        use std::os::unix::net::UnixListener;
        use std::time::{Duration, Instant};
        let directory = tempfile::tempdir().unwrap();
        let socket = directory.path().join("control.sock");
        let listener = UnixListener::bind(&socket).unwrap();
        rustix::net::listen(&listener, 1).unwrap();
        let _first =
            super::connect_with_deadline(&socket, Instant::now() + Duration::from_secs(1)).unwrap();
        let _second =
            super::connect_with_deadline(&socket, Instant::now() + Duration::from_secs(1)).unwrap();
        let start = Instant::now();
        let error =
            super::connect_with_deadline(&socket, start + Duration::from_millis(80)).unwrap_err();
        assert_eq!(error.kind(), io::ErrorKind::TimedOut);
        assert!(start.elapsed() < Duration::from_secs(1));
    }

    #[test]
    fn client_rejects_response_with_another_request_identity() {
        use std::os::unix::net::UnixListener;
        let directory = tempfile::tempdir().unwrap();
        let socket = directory.path().join("control.sock");
        let listener = UnixListener::bind(&socket).unwrap();
        let worker = std::thread::spawn(move || {
            let (mut client, _) = listener.accept().unwrap();
            let mut reader = std::io::BufReader::new(client.try_clone().unwrap());
            read_limited_line(&mut reader, MAX_REQUEST_BYTES)
                .unwrap()
                .unwrap();
            super::write_response(&mut client, &response("other")).unwrap();
        });
        let error = super::send_request(&socket, vec!["status".into()], "one").unwrap_err();
        assert_eq!(error.kind(), io::ErrorKind::InvalidData);
        worker.join().unwrap();
    }

    #[test]
    fn max_request_constant_is_finite() {
        assert_eq!(MAX_REQUEST_BYTES, 16 * 1024);
    }
}
