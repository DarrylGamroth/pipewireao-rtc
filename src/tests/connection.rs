use super::*;
use std::io::Read;
use std::os::unix::net::{UnixListener, UnixStream};
use std::process::Command;
use std::time::Duration;

#[test]
fn explicit_socket_ignores_environment_in_owned_child() {
    const CHILD: &str = "RTC_EXPLICIT_SOCKET_TEST_CHILD";
    if std::env::var_os(CHILD).is_some() {
        let directory = tempfile::tempdir().unwrap();
        let selected_path = directory.path().join("selected");
        let selected = UnixListener::bind(&selected_path).unwrap();
        selected.set_nonblocking(true).unwrap();
        let other_path = std::env::var("PIPEWIREAO_REMOTE").unwrap();
        let other = UnixListener::bind(other_path).unwrap();
        other.set_nonblocking(true).unwrap();
        let fd = connect_socket(
            selected_path.to_str().unwrap(),
            Instant::now() + Duration::from_secs(2),
        )
        .unwrap();
        // Passing the connected socket through the public API also cannot
        // choose the environment's different listener.
        let loop_ = pipewire::main_loop::MainLoopRc::new(None).unwrap();
        let context = pipewire::context::ContextRc::new(&loop_, None).unwrap();
        let core = context.connect_fd_rc(fd, None).unwrap();
        let selected_connection = selected.accept();
        let other_connection = other.accept();
        eprintln!(
            "EXPLICIT_SOCKET requested_accepted={} environment_accepted={}",
            selected_connection.is_ok(),
            other_connection.is_ok()
        );
        let (_accepted, _) = selected_connection.unwrap();
        assert_eq!(
            other_connection.unwrap_err().kind(),
            std::io::ErrorKind::WouldBlock
        );
        drop(core);
        return;
    }
    let directory = tempfile::tempdir().unwrap();
    let (_, module) = module_path!().split_once("::").unwrap();
    let child_test = format!("{module}::explicit_socket_ignores_environment_in_owned_child");
    let mut child = Command::new(std::env::current_exe().unwrap())
        .args(["--exact", &child_test, "--nocapture"])
        .env(CHILD, "1")
        .env("PIPEWIREAO_REMOTE", directory.path().join("other"))
        .env("PIPEWIRE_REMOTE", "another-unselected-socket")
        .spawn()
        .unwrap();
    let deadline = Instant::now() + Duration::from_secs(10);
    let status = loop {
        if let Some(status) = child.try_wait().unwrap() {
            break status;
        }
        if Instant::now() >= deadline {
            child.kill().unwrap();
            child.wait().unwrap();
            panic!("owned explicit-socket child exceeded its deadline");
        }
        std::thread::sleep(Duration::from_millis(5));
    };
    assert!(status.success());
}

#[test]
fn socket_is_nonblocking_and_failure_does_not_fall_back() {
    let directory = tempfile::tempdir().unwrap();
    let path = directory.path().join("selected");
    let listener = UnixListener::bind(&path).unwrap();
    let fd = connect_socket(
        path.to_str().unwrap(),
        Instant::now() + Duration::from_secs(2),
    )
    .unwrap();
    let (_accepted, _) = listener.accept().unwrap();
    let mut stream = UnixStream::from(fd);
    assert_eq!(
        stream.read(&mut [0_u8]).unwrap_err().kind(),
        std::io::ErrorKind::WouldBlock
    );
    assert!(connect_socket(path.to_str().unwrap(), Instant::now()).is_err());
    assert!(connect_socket("relative", Instant::now() + Duration::from_secs(2)).is_err());
    assert!(connect_socket(
        directory.path().join("missing").to_str().unwrap(),
        Instant::now() + Duration::from_secs(2)
    )
    .is_err());
}

#[test]
fn full_unix_backlog_is_failure_without_wait_or_retry() {
    let directory = tempfile::tempdir().unwrap();
    let path = directory.path().join("full");
    let listener = socket_with(
        AddressFamily::UNIX,
        SocketType::STREAM,
        SocketFlags::CLOEXEC,
        None,
    )
    .unwrap();
    rustix::net::bind(&listener, &SocketAddrUnix::new(&path).unwrap()).unwrap();
    rustix::net::listen(&listener, 0).unwrap();
    let _first = connect_socket(
        path.to_str().unwrap(),
        Instant::now() + Duration::from_secs(2),
    )
    .unwrap();
    let started = Instant::now();
    let result = connect_socket(path.to_str().unwrap(), started + Duration::from_secs(2));
    assert!(result.unwrap_err().contains("connect failed"));
    assert!(started.elapsed() < Duration::from_secs(1));
}
