//! Exact per-connection transport for already validated private native sockets.
//! No process environment mutation, remote fallback, or connection retry.
use rustix::event::{poll, PollFd, PollFlags, Timespec};
use rustix::fd::OwnedFd;
use rustix::io::Errno;
use rustix::net::{
    connect, socket_with, sockopt, AddressFamily, SocketAddrUnix, SocketFlags, SocketType,
};
use std::path::Path;
use std::time::Instant;

/// Connect once to the client's validated absolute socket, within its original
/// deadline. The returned nonblocking descriptor is consumed by the public
/// `ContextRc::connect_fd_rc` API, which owns it on success or failure.
pub(crate) fn connect_socket(remote: &str, deadline: Instant) -> Result<OwnedFd, String> {
    if !Path::new(remote).is_absolute() {
        return Err("native connection requires an absolute socket path".into());
    }
    remaining(deadline)?;
    let address = SocketAddrUnix::new(remote).map_err(|e| e.to_string())?;
    let socket = socket_with(
        AddressFamily::UNIX,
        SocketType::STREAM,
        SocketFlags::NONBLOCK | SocketFlags::CLOEXEC,
        None,
    )
    .map_err(|e| e.to_string())?;
    match connect(&socket, &address) {
        Ok(()) => {}
        Err(Errno::INPROGRESS) => wait_connected(&socket, deadline)?,
        // In particular, AF_UNIX EAGAIN means a full listener backlog, not an
        // accepted asynchronous connect. Never poll it as a successful connect.
        Err(error) => return Err(format!("native socket connect failed: {error}")),
    }
    remaining(deadline)?;
    Ok(socket)
}

fn remaining(deadline: Instant) -> Result<Timespec, String> {
    let duration = deadline
        .checked_duration_since(Instant::now())
        .filter(|duration| !duration.is_zero())
        .ok_or("native socket connection deadline expired")?;
    Timespec::try_from(duration).map_err(|e| e.to_string())
}

fn wait_connected(socket: &OwnedFd, deadline: Instant) -> Result<(), String> {
    loop {
        let timeout = remaining(deadline)?;
        let mut descriptors = [PollFd::new(socket, PollFlags::OUT)];
        match poll(&mut descriptors, Some(&timeout)) {
            Err(Errno::INTR) => continue,
            Err(error) => return Err(format!("native socket poll failed: {error}")),
            Ok(0) => return Err("native socket connection deadline expired".into()),
            Ok(_) => {}
        }
        remaining(deadline)?;
        sockopt::socket_error(socket)
            .map_err(|e| e.to_string())?
            .map_err(|e| format!("native socket connect failed: {e}"))?;
        let events = descriptors[0].revents();
        if events.intersects(PollFlags::ERR | PollFlags::HUP | PollFlags::NVAL)
            || !events.contains(PollFlags::OUT)
        {
            return Err("native socket closed before connection completed".into());
        }
        return Ok(());
    }
}

#[cfg(test)]
#[path = "tests/connection.rs"]
mod tests;
