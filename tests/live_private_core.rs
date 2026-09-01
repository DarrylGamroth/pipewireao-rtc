#![cfg(feature = "live")]

#[path = "live_private_core/fits_discard.rs"]
mod fits_discard;

use pipewireao_rtc::{
    ConfigurationInput, LifecycleEvent, LifecycleState, LiveGraphAdapter, Runner,
};
use std::collections::BTreeMap;
use std::io::Write;
use std::path::{Path, PathBuf};
use std::process::{Child, Command, Stdio};
use std::time::{Duration, Instant, SystemTime};

const EXCITATION_SCHEMA: &str = "org.calculon.ao.docrime-excitation/1";
const INTERMEDIATE_SCHEMA: &str = "org.pipewireao.rtc.intermediate/1";
const COMMAND_SCHEMA: &str = "org.calculon.ao.controller-command/1";
const EXCITATION_A_SCHEMA: &str = "org.calculon.ao.docrime-excitation-a/1";
const EXCITATION_B_SCHEMA: &str = "org.calculon.ao.docrime-excitation-b/1";
const COMMAND_A_SCHEMA: &str = "org.calculon.ao.controller-command-a/1";
const COMMAND_B_SCHEMA: &str = "org.calculon.ao.controller-command-b/1";

struct ChildGuard(Child);

impl Drop for ChildGuard {
    fn drop(&mut self) {
        let _ = self.0.kill();
        let _ = self.0.wait();
    }
}

struct SessionCase<'a> {
    fixture: &'a str,
    nodes: &'a [&'a str],
    links: usize,
    sinks: &'a [&'a str],
}

#[test]
#[ignore = "requires the maintained PipeWireAO and Calculon sibling build artifacts"]
#[allow(clippy::too_many_lines)]
fn private_core_transport_and_all_rtc_session_topologies_run_and_clean_up() {
    let repository = PathBuf::from(env!("CARGO_MANIFEST_DIR"));
    let workspace = repository.parent().expect("workspace parent");
    let pipewire_build = workspace.join("pipewire/build");
    let calculon = workspace.join("calculon-algorithms");
    let plugin_build = std::env::var_os("PIPEWIREAO_SPA_PLUGINS_BUILD").map_or_else(
        || workspace.join("pipewireao-spa-plugins/build"),
        PathBuf::from,
    );
    let temporary = tempfile::tempdir().expect("private fixture directory");
    let fits_a = temporary.path().join("excitation-a.fits");
    let fits_b = temporary.path().join("excitation-b.fits");
    fits_discard::write_vector_sequence(&fits_a);
    fits_discard::write_vector_sequence(&fits_b);
    let runtime = temporary.path().join("runtime");
    let config_directory = temporary.path().join("config");
    let graph_directory = temporary.path().join("graphs");
    std::fs::create_dir_all(&runtime).unwrap();
    std::fs::create_dir_all(&config_directory).unwrap();
    std::fs::create_dir_all(&graph_directory).unwrap();
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

    let calculon_bundle = calculon.join("target/release/libcalculon_fgn_bundle.so");
    let graph_files = [
        (
            "PIPEWIREAO_RTC_GRAPH_MINIMAL",
            "minimal.conf",
            "pipewireao-rtc-graph",
            EXCITATION_SCHEMA,
            COMMAND_SCHEMA,
        ),
        (
            "PIPEWIREAO_RTC_GRAPH_SERIAL_A",
            "serial-a.conf",
            "pipewireao-rtc-serial-graph-a",
            EXCITATION_SCHEMA,
            INTERMEDIATE_SCHEMA,
        ),
        (
            "PIPEWIREAO_RTC_GRAPH_SERIAL_B",
            "serial-b.conf",
            "pipewireao-rtc-serial-graph-b",
            INTERMEDIATE_SCHEMA,
            COMMAND_SCHEMA,
        ),
        (
            "PIPEWIREAO_RTC_GRAPH_FORK_A",
            "fork-a.conf",
            "pipewireao-rtc-fork-graph-a",
            EXCITATION_SCHEMA,
            COMMAND_A_SCHEMA,
        ),
        (
            "PIPEWIREAO_RTC_GRAPH_FORK_B",
            "fork-b.conf",
            "pipewireao-rtc-fork-graph-b",
            EXCITATION_SCHEMA,
            COMMAND_B_SCHEMA,
        ),
        (
            "PIPEWIREAO_RTC_GRAPH_INDEPENDENT_A",
            "independent-a.conf",
            "pipewireao-rtc-independent-graph-a",
            EXCITATION_A_SCHEMA,
            COMMAND_A_SCHEMA,
        ),
        (
            "PIPEWIREAO_RTC_GRAPH_INDEPENDENT_B",
            "independent-b.conf",
            "pipewireao-rtc-independent-graph-b",
            EXCITATION_B_SCHEMA,
            COMMAND_B_SCHEMA,
        ),
    ];
    let mut generated_graphs = BTreeMap::new();
    for (variable, file_name, node_name, input_schema, output_schema) in graph_files {
        let path = graph_directory.join(file_name);
        write_graph_configuration(
            &path,
            &calculon_bundle,
            &core_name,
            node_name,
            input_schema,
            output_schema,
        );
        generated_graphs.insert(variable.to_owned(), path);
    }

    let mut environment = fixture_environment(
        &runtime,
        &config_directory,
        &pipewire_build,
        &calculon_bundle,
        &plugin_build,
    );
    for (name, path) in generated_graphs {
        environment.insert(name, path);
    }
    for name in [
        "PIPEWIREAO_RTC_FITS_PATH",
        "PIPEWIREAO_RTC_FITS_PATH_SERIAL",
        "PIPEWIREAO_RTC_FITS_PATH_FORK",
        "PIPEWIREAO_RTC_FITS_PATH_INDEPENDENT_A",
    ] {
        environment.insert(name.to_owned(), fits_a.clone());
    }
    environment.insert("PIPEWIREAO_RTC_FITS_PATH_INDEPENDENT_B".to_owned(), fits_b);
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

    // The transport fixture deliberately precedes graph hosting. It proves the
    // maintained FITS source and discard SPA factories directly first.
    fits_discard::run(&core_name, &temporary.path().join("image.fits"));
    let transport_cleanup = dump(&pipewire_build, &environment, &core_name);
    assert!(transport_cleanup.contains("pipewireao-rtc-unrelated"));
    assert!(!transport_cleanup.contains(fits_discard::SOURCE_NAME));
    assert!(!transport_cleanup.contains(fits_discard::SINK_NAME));

    let cases = [
        SessionCase {
            fixture: "minimal-development.conf",
            nodes: &[
                "pipewireao-rtc-source",
                "pipewireao-rtc-graph",
                "pipewireao-rtc-sink",
            ],
            links: 2,
            sinks: &["pipewireao-rtc-sink"],
        },
        SessionCase {
            fixture: "serial-development.conf",
            nodes: &[
                "pipewireao-rtc-serial-source",
                "pipewireao-rtc-serial-graph-a",
                "pipewireao-rtc-serial-graph-b",
                "pipewireao-rtc-serial-sink",
            ],
            links: 3,
            sinks: &["pipewireao-rtc-serial-sink"],
        },
        SessionCase {
            fixture: "fork-development.conf",
            nodes: &[
                "pipewireao-rtc-fork-source",
                "pipewireao-rtc-fork-graph-a",
                "pipewireao-rtc-fork-graph-b",
                "pipewireao-rtc-fork-sink-a",
                "pipewireao-rtc-fork-sink-b",
            ],
            links: 4,
            sinks: &["pipewireao-rtc-fork-sink-a", "pipewireao-rtc-fork-sink-b"],
        },
        SessionCase {
            fixture: "independent-development.conf",
            nodes: &[
                "pipewireao-rtc-independent-source-a",
                "pipewireao-rtc-independent-source-b",
                "pipewireao-rtc-independent-graph-a",
                "pipewireao-rtc-independent-graph-b",
                "pipewireao-rtc-independent-sink-a",
                "pipewireao-rtc-independent-sink-b",
            ],
            links: 4,
            sinks: &[
                "pipewireao-rtc-independent-sink-a",
                "pipewireao-rtc-independent-sink-b",
            ],
        },
    ];
    for case in cases {
        run_session_case(
            &repository,
            &pipewire_build,
            &environment,
            &core_name,
            &case,
        );
    }

    drop(unrelated);
    drop(core);
}

fn run_session_case(
    repository: &Path,
    pipewire_build: &Path,
    environment: &BTreeMap<String, PathBuf>,
    core_name: &str,
    case: &SessionCase<'_>,
) {
    let adapter = LiveGraphAdapter::connect(core_name).expect("connect runner adapter");
    let mut runner = Runner::new(adapter);
    let state = runner
        .dispatch(LifecycleEvent::Load(ConfigurationInput::File(
            repository.join("fixtures").join(case.fixture),
        )))
        .expect("serialized load dispatch");
    assert_eq!(
        state,
        LifecycleState::Ready,
        "{} realization diagnostic: {:?}",
        case.fixture,
        runner.diagnostic()
    );
    assert_eq!(runner.executor().status().owned_nodes, case.nodes.len());
    assert_eq!(runner.executor().status().owned_links, case.links);

    let state = runner.dispatch(LifecycleEvent::Start).unwrap();
    assert_eq!(
        state,
        LifecycleState::Running,
        "{} start diagnostic: {:?}",
        case.fixture,
        runner.diagnostic()
    );
    let running = runner.executor().status();
    assert!(running.running);
    for sink in case.sinks {
        assert!(
            running
                .discarded_by_sink
                .get(*sink)
                .is_some_and(|count| *count > 0),
            "{} did not receive a complete frame: {:?}",
            case.fixture,
            running.discarded_by_sink
        );
    }
    let active_dump = dump(pipewire_build, environment, core_name);
    for node in case
        .nodes
        .iter()
        .copied()
        .chain(std::iter::once("pipewireao-rtc-unrelated"))
    {
        assert!(
            active_dump.contains(node),
            "missing inspectable node {node}"
        );
    }

    assert_eq!(
        runner.dispatch(LifecycleEvent::Stop).unwrap(),
        LifecycleState::Ready,
        "{} stop diagnostic: {:?}",
        case.fixture,
        runner.diagnostic()
    );
    let before_restart = runner.executor().status().discarded_by_sink;
    assert_eq!(
        runner.dispatch(LifecycleEvent::Start).unwrap(),
        LifecycleState::Running
    );
    let restarted = runner.executor().status().discarded_by_sink;
    for &sink in case.sinks {
        assert!(restarted[sink] > before_restart[sink]);
    }
    assert_eq!(
        runner.dispatch(LifecycleEvent::Stop).unwrap(),
        LifecycleState::Ready,
        "{} second stop diagnostic: {:?}",
        case.fixture,
        runner.diagnostic()
    );
    assert_eq!(
        runner.dispatch(LifecycleEvent::Unload).unwrap(),
        LifecycleState::Offline,
        "{} unload diagnostic: {:?}",
        case.fixture,
        runner.diagnostic()
    );
    assert_eq!(runner.executor().status().owned_nodes, 0);
    assert_eq!(runner.executor().status().owned_links, 0);
    let unloaded_dump = dump(pipewire_build, environment, core_name);
    assert!(unloaded_dump.contains("pipewireao-rtc-unrelated"));
    for node in case.nodes {
        assert!(!unloaded_dump.contains(node), "owned node survived: {node}");
    }
}

fn write_graph_configuration(
    path: &Path,
    calculon_bundle: &Path,
    remote_name: &str,
    node_name: &str,
    input_schema: &str,
    output_schema: &str,
) {
    let graph = include_str!("../fixtures/graphs/leaky-integrator.conf.in")
        .replace(
            "@CALCULON_FGN_BUNDLE@",
            &calculon_bundle.display().to_string(),
        )
        .replace("@REMOTE_NAME@", remote_name)
        .replace("@NODE_NAME@", node_name)
        .replace("@INPUT_SCHEMA@", input_schema)
        .replace("@OUTPUT_SCHEMA@", output_schema);
    std::fs::write(path, graph).expect("materialize standard filter.graph configuration");
}

fn fixture_environment(
    runtime: &Path,
    config_directory: &Path,
    pipewire_build: &Path,
    calculon_bundle: &Path,
    plugin_build: &Path,
) -> BTreeMap<String, PathBuf> {
    let plugin_search_path = std::env::join_paths([
        pipewire_build.join("spa/plugins"),
        plugin_build.join("spa/plugins"),
    ])
    .expect("private SPA plugin search path");
    BTreeMap::from([
        ("PIPEWIRE_RUNTIME_DIR".to_owned(), runtime.to_owned()),
        ("PIPEWIREAO_RUNTIME_DIR".to_owned(), runtime.to_owned()),
        ("XDG_RUNTIME_DIR".to_owned(), runtime.to_owned()),
        (
            "PIPEWIREAO_CONFIG_DIR".to_owned(),
            config_directory.to_owned(),
        ),
        (
            "PIPEWIREAO_MODULE_DIR".to_owned(),
            pipewire_build.join("src/modules"),
        ),
        (
            "PIPEWIREAO_SPA_PLUGIN_DIR".to_owned(),
            PathBuf::from(plugin_search_path),
        ),
        ("CALCULON_FGN_BUNDLE".to_owned(), calculon_bundle.to_owned()),
        (
            "PIPEWIREAO_NDARRAY_EXAMPLE".to_owned(),
            pipewire_build.join("spa/plugins/filter-graph/libspa-filter-graph-ndarray-example.so"),
        ),
        (
            "PIPEWIREAO_DISCARD_PLUGIN".to_owned(),
            plugin_build.join("spa/plugins/discard/libspa-pipewireao-discard.so"),
        ),
        (
            "PIPEWIREAO_FITS_PLUGIN".to_owned(),
            plugin_build.join("spa/plugins/fits/libspa-fits.so"),
        ),
    ])
}

fn command_with_environment(
    executable: impl AsRef<std::ffi::OsStr>,
    environment: &BTreeMap<String, PathBuf>,
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
    environment: &BTreeMap<String, PathBuf>,
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

fn dump(pipewire_build: &Path, environment: &BTreeMap<String, PathBuf>, core_name: &str) -> String {
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
