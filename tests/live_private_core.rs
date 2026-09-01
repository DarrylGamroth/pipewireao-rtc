#![cfg(feature = "live")]

use pipewireao_rtc::{
    ConfigurationInput, LifecycleEvent, LifecycleState, LiveGraphAdapter, Runner,
};
use std::collections::BTreeMap;
use std::io::Write;
use std::path::{Path, PathBuf};
use std::process::{Child, Command, Stdio};
use std::time::{Duration, Instant, SystemTime};

struct ChildGuard(Child);

impl Drop for ChildGuard {
    fn drop(&mut self) {
        let _ = self.0.kill();
        let _ = self.0.wait();
    }
}

#[test]
#[ignore = "blocked by PipeWireAO ndarray set_param EINVAL during link negotiation"]
#[allow(clippy::too_many_lines)]
fn private_core_three_object_fixture_runs_and_cleans_up() {
    let repository = PathBuf::from(env!("CARGO_MANIFEST_DIR"));
    let workspace = repository.parent().expect("workspace parent");
    let pipewire_build = workspace.join("pipewire/build");
    let calculon = workspace.join("calculon-algorithms");
    let temporary = tempfile::tempdir().expect("private fixture directory");
    let runtime = temporary.path().join("runtime");
    let config_directory = temporary.path().join("config");
    std::fs::create_dir_all(&runtime).unwrap();
    std::fs::create_dir_all(&config_directory).unwrap();
    let unique = SystemTime::now()
        .duration_since(SystemTime::UNIX_EPOCH)
        .unwrap()
        .as_nanos();
    let core_name = format!("pipewireao-rtc-{}-{unique}", std::process::id());

    let core_config =
        include_str!("../fixtures/private-core.conf.in").replace("@CORE_NAME@", &core_name);
    std::fs::write(config_directory.join("private-core.conf"), core_config).unwrap();
    std::fs::write(
        config_directory.join("client.conf"),
        std::fs::read(pipewire_build.join("src/daemon/client.conf"))
            .expect("maintained generated client.conf"),
    )
    .unwrap();

    let environment = fixture_environment(&runtime, &config_directory, &pipewire_build, &calculon);
    for (name, value) in &environment {
        std::env::set_var(name, value);
    }
    std::env::set_var("PIPEWIREAO_DEBUG", "0");

    let core =
        command_with_environment(pipewire_build.join("src/daemon/pipewire-ao"), &environment)
            .args(["-c", "private-core.conf"])
            .stdout(Stdio::piped())
            .stderr(Stdio::piped())
            .spawn()
            .expect("start private PipeWireAO core");
    let mut core = ChildGuard(core);
    wait_for_core(&mut core.0, &runtime.join(&core_name));

    let example_plugin = environment
        .get("PIPEWIREAO_NDARRAY_EXAMPLE")
        .unwrap()
        .display();
    let mut unrelated =
        command_with_environment(pipewire_build.join("src/tools/pwao-cli"), &environment)
            .args(["-r", &core_name])
            .stdin(Stdio::piped())
            .stdout(Stdio::null())
            .stderr(Stdio::null())
            .spawn()
            .expect("start unrelated fixture owner");
    writeln!(
        unrelated.stdin.as_mut().unwrap(),
        "load-module libpipewire-module-ndarray-filter-chain {{ remote.name = \"{core_name}\" node.name = pipewireao-rtc-unrelated filter.graph = {{ nodes = [ {{ type = ndarray name = unrelated plugin = \"{example_plugin}\" label = scale-f32 config = {{ shape = [ 1 ] schema = unrelated.test/1 }} }} ] inputs = [ \"unrelated:in\" ] outputs = [ ] }} }}"
    )
    .unwrap();
    unrelated.stdin.as_mut().unwrap().flush().unwrap();
    let unrelated = ChildGuard(unrelated);
    wait_for_dump(
        &pipewire_build,
        &environment,
        &core_name,
        "pipewireao-rtc-unrelated",
    );

    let adapter = LiveGraphAdapter::connect(&core_name).expect("connect runner adapter");
    let mut runner = Runner::new(adapter);
    let state = runner
        .dispatch(LifecycleEvent::Load(ConfigurationInput::File(
            repository.join("fixtures/minimal-development.conf"),
        )))
        .expect("serialized load dispatch");
    assert_eq!(
        state,
        LifecycleState::Ready,
        "live realization diagnostic: {:?}",
        runner.diagnostic()
    );
    assert_eq!(runner.executor().status().owned_nodes, 3);
    assert_eq!(runner.executor().status().owned_links, 2);

    assert_eq!(
        runner.dispatch(LifecycleEvent::Start).unwrap(),
        LifecycleState::Running
    );
    assert!(runner.executor().status().running);
    let active_dump = dump(&pipewire_build, &environment, &core_name);
    for node in [
        "pipewireao-rtc-source",
        "pipewireao-rtc-graph",
        "pipewireao-rtc-sink",
        "pipewireao-rtc-unrelated",
    ] {
        assert!(
            active_dump.contains(node),
            "missing inspectable node {node}"
        );
    }

    assert_eq!(
        runner.dispatch(LifecycleEvent::Stop).unwrap(),
        LifecycleState::Ready
    );
    assert_eq!(
        runner.dispatch(LifecycleEvent::Unload).unwrap(),
        LifecycleState::Offline
    );
    assert_eq!(runner.executor().status().owned_nodes, 0);
    assert_eq!(runner.executor().status().owned_links, 0);
    let unloaded_dump = dump(&pipewire_build, &environment, &core_name);
    assert!(unloaded_dump.contains("pipewireao-rtc-unrelated"));
    for node in [
        "pipewireao-rtc-source",
        "pipewireao-rtc-graph",
        "pipewireao-rtc-sink",
    ] {
        assert!(!unloaded_dump.contains(node), "owned node survived: {node}");
    }

    drop(runner);
    drop(unrelated);
    drop(core);
}

fn fixture_environment(
    runtime: &Path,
    config_directory: &Path,
    pipewire_build: &Path,
    calculon: &Path,
) -> BTreeMap<&'static str, PathBuf> {
    BTreeMap::from([
        ("PIPEWIRE_RUNTIME_DIR", runtime.to_owned()),
        ("PIPEWIREAO_RUNTIME_DIR", runtime.to_owned()),
        ("XDG_RUNTIME_DIR", runtime.to_owned()),
        ("PIPEWIREAO_CONFIG_DIR", config_directory.to_owned()),
        ("PIPEWIREAO_MODULE_DIR", pipewire_build.join("src/modules")),
        (
            "PIPEWIREAO_SPA_PLUGIN_DIR",
            pipewire_build.join("spa/plugins"),
        ),
        (
            "CALCULON_FGN_BUNDLE",
            calculon.join("target/release/libcalculon_fgn_bundle.so"),
        ),
        (
            "PIPEWIREAO_NDARRAY_EXAMPLE",
            pipewire_build.join("spa/plugins/filter-graph/libspa-filter-graph-ndarray-example.so"),
        ),
    ])
}

fn command_with_environment(
    executable: impl AsRef<std::ffi::OsStr>,
    environment: &BTreeMap<&str, PathBuf>,
) -> Command {
    let mut command = Command::new(executable);
    command.envs(environment);
    command
}

fn wait_for_core(core: &mut Child, socket: &Path) {
    let deadline = Instant::now() + Duration::from_secs(5);
    while Instant::now() < deadline {
        assert!(core.try_wait().unwrap().is_none(), "private core exited");
        if socket.exists() {
            return;
        }
        std::thread::sleep(Duration::from_millis(20));
    }
    panic!("private core socket {} was not created", socket.display());
}

fn wait_for_dump(
    pipewire_build: &Path,
    environment: &BTreeMap<&str, PathBuf>,
    core_name: &str,
    needle: &str,
) {
    let deadline = Instant::now() + Duration::from_secs(5);
    while Instant::now() < deadline {
        if dump(pipewire_build, environment, core_name).contains(needle) {
            return;
        }
        std::thread::sleep(Duration::from_millis(20));
    }
    panic!("private core never exposed {needle}");
}

fn dump(pipewire_build: &Path, environment: &BTreeMap<&str, PathBuf>, core_name: &str) -> String {
    let output = command_with_environment(pipewire_build.join("src/tools/pwao-cli"), environment)
        .args(["-r", core_name, "list-objects"])
        .output()
        .expect("run pwao-cli list-objects");
    assert!(
        output.status.success(),
        "pwao-cli list-objects failed: {}",
        String::from_utf8_lossy(&output.stderr)
    );
    String::from_utf8(output.stdout).expect("pwao-cli UTF-8")
}
