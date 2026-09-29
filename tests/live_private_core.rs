#![cfg(feature = "live")]

#[path = "live_private_core/fits_discard.rs"]
mod fits_discard;

use pipewireao_rtc::{
    ConfigurationInput, DiscardObservation, ExecutionGroupState, LifecycleEvent, LifecycleState,
    LiveGraphAdapter, NdArrayParameterValue, Runner, ScalarValue, ScientificDiagnostic,
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
const FNV1A_OFFSET_BASIS: u64 = 14_695_981_039_346_656_037;
const MAX_TOPOLOGY_STARTUP_PREFIX: usize = 64;

const LEAKY_INPUTS: [[f32; 2]; 4] = [[1.0, -1.0], [0.5, 2.0], [-0.25, 0.75], [3.0, -2.0]];

fn expected_leaky_digest(buffers: u64) -> u64 {
    expected_leaky_digest_from_phase(buffers, 0)
}

fn expected_leaky_digest_from_phase(buffers: u64, phase: usize) -> u64 {
    expected_leaky_digest_for(
        (0..buffers).map(|index| (phase + usize::try_from(index).unwrap()) % LEAKY_INPUTS.len()),
    )
}

fn expected_leaky_digest_for(inputs: impl IntoIterator<Item = usize>) -> u64 {
    let mut state = [0.0_f32; 2];
    let mut digest = FNV1A_OFFSET_BASIS;
    for index in inputs {
        let input = LEAKY_INPUTS[index];
        for element in 0..2 {
            state[element] = 0.75 * state[element] + 0.5 * input[element];
            for byte in state[element].to_le_bytes() {
                digest ^= u64::from(byte);
                digest = digest.wrapping_mul(1_099_511_628_211);
            }
        }
    }
    digest
}

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
    groups: &'a [(&'a str, &'a str)],
    payload_oracle: Option<PayloadOracle>,
}

#[derive(Clone, Copy)]
enum PayloadOracle {
    Direct,
    Serial,
}

struct EndpointFaultCase<'a> {
    label: &'a str,
    running: bool,
    request_name: &'a str,
    confirmation: &'a str,
    expected_field: &'a str,
    surviving_endpoint: &'a str,
}

#[derive(Debug)]
struct RevoltLatencyCollection {
    warmup: u64,
    samples: u64,
    csv: PathBuf,
}

impl RevoltLatencyCollection {
    fn from_environment() -> Option<Self> {
        let samples = match std::env::var("PIPEWIREAO_RTC_REVOLT_LATENCY_SAMPLES") {
            Ok(value) => value
                .parse::<u64>()
                .expect("PIPEWIREAO_RTC_REVOLT_LATENCY_SAMPLES must be an unsigned integer"),
            Err(std::env::VarError::NotPresent) => return None,
            Err(error) => panic!("invalid PIPEWIREAO_RTC_REVOLT_LATENCY_SAMPLES: {error}"),
        };
        assert!(samples > 0, "REVOLT latency samples must be positive");
        let warmup = std::env::var("PIPEWIREAO_RTC_REVOLT_LATENCY_WARMUP").map_or(100, |value| {
            value
                .parse::<u64>()
                .expect("PIPEWIREAO_RTC_REVOLT_LATENCY_WARMUP must be an unsigned integer")
        });
        let csv = std::env::var_os("PIPEWIREAO_RTC_REVOLT_LATENCY_CSV")
            .map(PathBuf::from)
            .expect("PIPEWIREAO_RTC_REVOLT_LATENCY_CSV is required when collecting REVOLT latency");
        Some(Self {
            warmup,
            samples,
            csv,
        })
    }
}

#[test]
#[ignore = "requires the maintained PipeWireAO and Rust FGN sibling build artifacts"]
#[allow(clippy::too_many_lines)]
fn private_core_transport_and_all_rtc_session_topologies_run_and_clean_up() {
    let repository = PathBuf::from(env!("CARGO_MANIFEST_DIR"));
    let workspace = repository.parent().expect("workspace parent");
    let pipewire_build = std::env::var_os("PIPEWIREAO_RTC_PIPEWIRE_BUILD")
        .map_or_else(|| workspace.join("pipewire/build"), PathBuf::from);
    let pipewireao_julia = std::env::var_os("PIPEWIREAO_RTC_PIPEWIREAO_JULIA")
        .map_or_else(|| workspace.join("PipeWireAO.jl"), PathBuf::from);
    let julia_filter_graph = std::env::var_os("PIPEWIREAO_RTC_JULIA_FILTER_GRAPH")
        .map_or_else(|| workspace.join("JuliaFilterGraph.jl"), PathBuf::from);
    let revolt_hil_package = std::env::var_os("PIPEWIREAO_RTC_REVOLT_HIL_PACKAGE").map_or_else(
        || {
            workspace
                .parent()
                .expect("repository group")
                .join("REVOLTClassicSimPipeWireHIL.jl")
        },
        PathBuf::from,
    );
    let plugin_build = std::env::var_os("PIPEWIREAO_SPA_PLUGINS_BUILD").map_or_else(
        || workspace.join("pipewireao-spa-plugins-core/build"),
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
    let diagnostic_directory = temporary.path().join("diagnostics");
    std::fs::create_dir_all(&diagnostic_directory).unwrap();

    let core_config =
        include_str!("../fixtures/private-core.conf.in").replace("@CORE_NAME@", &core_name);
    std::fs::write(config_directory.join("private-core.conf"), core_config).unwrap();
    std::fs::write(
        config_directory.join("client.conf"),
        std::fs::read(pipewire_build.join("src/daemon/client.conf"))
            .expect("maintained generated client.conf"),
    )
    .unwrap();

    let fgn_bundle = std::env::var_os("PIPEWIREAO_RTC_FGN_BUNDLE").map_or_else(
        || workspace.join("calculon-algorithms/target/release/libcalculon_fgn_bundle.so"),
        PathBuf::from,
    );
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
            &fgn_bundle,
            &core_name,
            node_name,
            input_schema,
            output_schema,
        );
        generated_graphs.insert(variable.to_owned(), path);
    }

    let mut environment =
        fixture_environment(&runtime, &config_directory, &pipewire_build, &plugin_build);
    environment.insert("PIPEWIREAO_RTC_FGN_BUNDLE".to_owned(), fgn_bundle.clone());
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
    let aos_graph = graph_directory.join("aos-hil.conf");
    environment.insert("PIPEWIREAO_RTC_GRAPH_AOS_HIL".to_owned(), aos_graph.clone());
    let revolt_native_graph = graph_directory.join("revolt-classic-native.conf");
    let revolt_julia_graph = graph_directory.join("revolt-classic-julia.conf");
    let revolt_parameter = temporary.path().join("revolt-reconstructor.f32");
    environment.insert(
        "PIPEWIREAO_RTC_GRAPH_REVOLT_NATIVE".to_owned(),
        revolt_native_graph.clone(),
    );
    environment.insert(
        "PIPEWIREAO_RTC_PARAMETER_REVOLT".to_owned(),
        revolt_parameter,
    );
    let external_fgn_graph = graph_directory.join("external-owned.conf");
    write_graph_configuration(
        &external_fgn_graph,
        &fgn_bundle,
        &core_name,
        "pipewireao-rtc-external-graph",
        EXCITATION_SCHEMA,
        COMMAND_SCHEMA,
    );
    for (name, value) in &environment {
        std::env::set_var(name, value);
    }
    if std::env::var_os("PIPEWIREAO_DEBUG").is_none() {
        std::env::set_var("PIPEWIREAO_DEBUG", "0");
    }

    let core_log = std::fs::File::create(diagnostic_directory.join("private-core.log"))
        .expect("create private core log");
    let core =
        command_with_environment(pipewire_build.join("src/daemon/pipewire-ao"), &environment)
            .args(["-c", "private-core.conf"])
            .stdout(Stdio::from(
                core_log.try_clone().expect("clone private core log"),
            ))
            .stderr(Stdio::from(core_log))
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
    let revolt_latency = RevoltLatencyCollection::from_environment();

    match std::env::var("PIPEWIREAO_RTC_LIVE_SCOPE").as_deref() {
        Ok("revolt-lockstep") => {
            run_revolt_classic_lockstep_case(
                &repository,
                &revolt_hil_package,
                &pipewire_build,
                &environment,
                &core_name,
                temporary.path(),
                &revolt_native_graph,
                &revolt_julia_graph,
                &pipewireao_julia,
                &julia_filter_graph,
            );
            return;
        }
        Ok("revolt") => {
            run_revolt_classic_reference_case(
                &repository,
                &revolt_hil_package,
                &pipewire_build,
                &environment,
                &core_name,
                temporary.path(),
                &revolt_native_graph,
                &revolt_julia_graph,
                &pipewireao_julia,
                &julia_filter_graph,
                revolt_latency.as_ref(),
            );
            return;
        }
        Ok("latest-hold") => {
            run_latest_hold_live_case(
                &repository,
                &pipewire_build,
                &environment,
                &core_name,
                temporary.path(),
                &pipewireao_julia,
                &julia_filter_graph,
            );
            return;
        }
        Ok("properties") => {
            run_live_property_update_cases(
                &repository,
                &pipewire_build,
                &environment,
                &core_name,
                temporary.path(),
                &pipewireao_julia,
                &julia_filter_graph,
            );
            run_structural_reload_case(&repository, &pipewire_build, &environment, &core_name);
            return;
        }
        Ok("all") | Err(std::env::VarError::NotPresent) => {}
        Ok(scope) => panic!("unsupported PIPEWIREAO_RTC_LIVE_SCOPE {scope:?}"),
        Err(error) => panic!("invalid PIPEWIREAO_RTC_LIVE_SCOPE: {error}"),
    }

    // The transport fixture deliberately precedes graph hosting. It proves the
    // maintained FITS source and discard SPA factories directly first.
    fits_discard::run(&core_name, &temporary.path().join("image.fits"));
    let transport_cleanup = dump(&pipewire_build, &environment, &core_name);
    assert!(transport_cleanup.contains("pipewireao-rtc-unrelated"));
    assert!(!transport_cleanup.contains(fits_discard::SOURCE_NAME));
    assert!(!transport_cleanup.contains(fits_discard::SINK_NAME));

    run_finite_source_completion_case(
        &repository,
        &pipewire_build,
        &environment,
        &core_name,
        temporary.path(),
    );
    run_native_numerical_group_restart_case(
        &repository,
        &core_name,
        temporary.path(),
        &environment,
    );
    run_latest_hold_live_case(
        &repository,
        &pipewire_build,
        &environment,
        &core_name,
        temporary.path(),
        &pipewireao_julia,
        &julia_filter_graph,
    );
    run_live_creation_failure_matrix(&repository, &pipewire_build, &environment, &core_name);

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
            groups: &[("main", "pipewireao-rtc-sink")],
            payload_oracle: None,
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
            groups: &[("chain", "pipewireao-rtc-serial-sink")],
            payload_oracle: Some(PayloadOracle::Serial),
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
            groups: &[
                ("branch-a", "pipewireao-rtc-fork-sink-a"),
                ("branch-b", "pipewireao-rtc-fork-sink-b"),
            ],
            payload_oracle: Some(PayloadOracle::Direct),
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
            groups: &[
                ("path-a", "pipewireao-rtc-independent-sink-a"),
                ("path-b", "pipewireao-rtc-independent-sink-b"),
            ],
            payload_oracle: Some(PayloadOracle::Direct),
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

    run_bounded_observer_case(
        &repository,
        &pipewire_build,
        &environment,
        &core_name,
        temporary.path(),
        &pipewireao_julia,
        &plugin_build,
    );

    run_external_processing_graph_case(
        &repository,
        &pipewire_build,
        &environment,
        &core_name,
        &external_fgn_graph,
    );
    run_external_julia_processing_graph_case(
        &repository,
        &pipewire_build,
        &environment,
        &core_name,
        temporary.path(),
        &pipewireao_julia,
        &julia_filter_graph,
    );
    run_live_property_update_cases(
        &repository,
        &pipewire_build,
        &environment,
        &core_name,
        temporary.path(),
        &pipewireao_julia,
        &julia_filter_graph,
    );
    run_structural_reload_case(&repository, &pipewire_build, &environment, &core_name);
    run_external_graph_equivalence_case(
        &repository,
        &pipewire_build,
        &environment,
        &core_name,
        temporary.path(),
        &external_fgn_graph,
        &pipewireao_julia,
        &julia_filter_graph,
    );

    let hil_package = std::env::var_os("PIPEWIREAO_RTC_AOS_HIL_PACKAGE").map_or_else(
        || {
            workspace
                .parent()
                .expect("repository group")
                .join("AdaptiveOpticsSimPipeWireHIL.jl")
        },
        PathBuf::from,
    );
    run_aos_hil_reference_case(
        &repository,
        &hil_package,
        &pipewire_build,
        &environment,
        &core_name,
        temporary.path(),
        &aos_graph,
        &fgn_bundle,
    );
    run_revolt_classic_reference_case(
        &repository,
        &revolt_hil_package,
        &pipewire_build,
        &environment,
        &core_name,
        temporary.path(),
        &revolt_native_graph,
        &revolt_julia_graph,
        &pipewireao_julia,
        &julia_filter_graph,
        revolt_latency.as_ref(),
    );
    run_external_endpoint_case(
        &repository,
        &hil_package,
        &pipewire_build,
        &environment,
        &core_name,
        temporary.path(),
    );
    run_external_endpoint_fault_cases(
        &repository,
        &hil_package,
        &pipewire_build,
        &environment,
        &core_name,
        temporary.path(),
    );
    run_external_endpoint_admission_failures(
        &repository,
        &hil_package,
        &pipewire_build,
        &environment,
        &core_name,
        temporary.path(),
    );

    drop(unrelated);
    drop(core);
}

fn run_external_processing_graph_case(
    repository: &Path,
    pipewire_build: &Path,
    environment: &BTreeMap<String, PathBuf>,
    core_name: &str,
    graph_configuration: &Path,
) {
    let provider = launch_external_fgn(pipewire_build, environment, core_name, graph_configuration);
    wait_for_dump(
        pipewire_build,
        environment,
        core_name,
        "pipewireao-rtc-external-graph",
    );

    let adapter = LiveGraphAdapter::connect(core_name).expect("connect external graph session");
    let mut runner = Runner::new(adapter);
    assert_eq!(
        runner
            .dispatch(LifecycleEvent::Load(ConfigurationInput::File(
                repository.join("fixtures/external-graph-development.conf"),
            )))
            .unwrap(),
        LifecycleState::Ready,
        "external graph load diagnostic: {:?}",
        runner.diagnostic(),
    );
    assert_eq!(runner.executor().status().owned_nodes, 2);
    assert_eq!(runner.executor().status().owned_links, 2);
    let external_before = dump(pipewire_build, environment, core_name);
    assert!(external_before.contains("pipewireao-rtc-external-graph"));

    assert_eq!(
        runner.dispatch(LifecycleEvent::Start).unwrap(),
        LifecycleState::Running,
        "external graph start diagnostic: {:?}",
        runner.diagnostic(),
    );
    let first_count = runner.executor().status().discarded_buffers;
    assert!(first_count > 0);
    assert_eq!(
        runner.dispatch(LifecycleEvent::Stop).unwrap(),
        LifecycleState::Ready,
        "external graph stop diagnostic: {:?}",
        runner.diagnostic(),
    );
    assert!(dump(pipewire_build, environment, core_name).contains("pipewireao-rtc-external-graph"));

    assert_eq!(
        runner.dispatch(LifecycleEvent::Start).unwrap(),
        LifecycleState::Running,
        "external graph restart diagnostic: {:?}",
        runner.diagnostic(),
    );
    assert!(runner.executor().status().discarded_buffers > first_count);
    assert_eq!(
        runner.dispatch(LifecycleEvent::Stop).unwrap(),
        LifecycleState::Ready,
        "external graph second stop diagnostic: {:?}",
        runner.diagnostic(),
    );
    assert_eq!(
        runner.dispatch(LifecycleEvent::Unload).unwrap(),
        LifecycleState::Offline,
    );
    let after_unload = dump(pipewire_build, environment, core_name);
    assert!(after_unload.contains("pipewireao-rtc-external-graph"));
    assert!(after_unload.contains("pipewireao-rtc-unrelated"));
    assert!(!after_unload.contains("pipewireao-rtc-source"));
    assert!(!after_unload.contains("pipewireao-rtc-sink"));

    drop(provider);
    wait_for_dump_absent(
        pipewire_build,
        environment,
        core_name,
        "pipewireao-rtc-external-graph",
    );

    run_external_processing_graph_fault_case(
        repository,
        pipewire_build,
        environment,
        core_name,
        graph_configuration,
    );
}

#[allow(clippy::too_many_arguments)]
fn run_bounded_observer_case(
    repository: &Path,
    pipewire_build: &Path,
    environment: &BTreeMap<String, PathBuf>,
    core_name: &str,
    temporary: &Path,
    pipewireao_julia: &Path,
    plugin_build: &Path,
) {
    let observer_graph = temporary.join("observer-equivalence-graph.conf");
    let graph = std::fs::read_to_string(&environment["PIPEWIREAO_RTC_GRAPH_MINIMAL"])
        .unwrap()
        .replace("rate = [ 1000 1 ]", "rate = [ 1 1 ]");
    assert!(graph.contains("rate = [ 1 1 ]"));
    std::fs::write(&observer_graph, graph).unwrap();
    let original_graph = std::env::var_os("PIPEWIREAO_RTC_GRAPH_MINIMAL");
    std::env::set_var("PIPEWIREAO_RTC_GRAPH_MINIMAL", &observer_graph);
    let fixture = write_finite_fixture(repository, temporary, "observer-equivalence", 1);
    let unobserved = run_unobserved_finite_replay(core_name, &fixture);
    for node_name in [
        "pipewireao-rtc-source",
        "pipewireao-rtc-graph",
        "pipewireao-rtc-sink",
    ] {
        wait_for_dump_absent(pipewire_build, environment, core_name, node_name);
    }
    let with_observer = run_observed_finite_replay(
        repository,
        pipewire_build,
        environment,
        core_name,
        temporary,
        pipewireao_julia,
        plugin_build,
        &fixture,
    );
    assert_eq!(with_observer, unobserved);
    match original_graph {
        Some(path) => std::env::set_var("PIPEWIREAO_RTC_GRAPH_MINIMAL", path),
        None => std::env::remove_var("PIPEWIREAO_RTC_GRAPH_MINIMAL"),
    }
}

#[allow(clippy::too_many_arguments)]
fn run_observed_finite_replay(
    repository: &Path,
    pipewire_build: &Path,
    environment: &BTreeMap<String, PathBuf>,
    core_name: &str,
    temporary: &Path,
    pipewireao_julia: &Path,
    plugin_build: &Path,
    fixture: &Path,
) -> DiscardObservation {
    let mut runner = load_observation_session(core_name, fixture);
    let hold_file = temporary.join("hold-observer-buffer");
    std::fs::write(&hold_file, "hold\n").unwrap();
    assert_eq!(
        runner.dispatch(LifecycleEvent::Start).unwrap(),
        LifecycleState::Running,
        "observer session start diagnostic: {:?}",
        runner.diagnostic()
    );
    observe_finite_replay(
        &mut runner,
        repository,
        pipewire_build,
        environment,
        core_name,
        temporary,
        pipewireao_julia,
        plugin_build,
        "pipewireao-rtc-observer-held",
        &hold_file,
        "held observer first replay",
    );
    assert_eq!(
        runner.executor().observe_discard_payloads().unwrap()["pipewireao-rtc-sink"].buffers,
        4
    );
    std::fs::remove_file(&hold_file).unwrap();
    assert_eq!(runner.state(), LifecycleState::Ready);
    assert_eq!(
        runner.dispatch(LifecycleEvent::Start).unwrap(),
        LifecycleState::Running,
        "reattached observer start diagnostic: {:?}",
        runner.diagnostic()
    );
    observe_finite_replay(
        &mut runner,
        repository,
        pipewire_build,
        environment,
        core_name,
        temporary,
        pipewireao_julia,
        plugin_build,
        "pipewireao-rtc-observer-reattached",
        &hold_file,
        "reattached observer second replay",
    );
    let with_observer =
        runner.executor().observe_discard_payloads().unwrap()["pipewireao-rtc-sink"];
    assert_two_replay_observation(with_observer);
    assert_eq!(
        runner.dispatch(LifecycleEvent::Unload).unwrap(),
        LifecycleState::Offline
    );
    assert!(dump(pipewire_build, environment, core_name).contains("pipewireao-rtc-unrelated"));
    with_observer
}

#[allow(clippy::too_many_arguments)]
fn observe_finite_replay(
    runner: &mut Runner<LiveGraphAdapter>,
    repository: &Path,
    pipewire_build: &Path,
    environment: &BTreeMap<String, PathBuf>,
    core_name: &str,
    temporary: &Path,
    pipewireao_julia: &Path,
    plugin_build: &Path,
    observer_name: &str,
    hold_file: &Path,
    label: &str,
) {
    let queue = launch_observation_queue(pipewire_build, plugin_build, environment, core_name);
    let input = fits_discard::NamedLink::connect_passive_usable(
        core_name,
        "pipewireao-rtc-source",
        fits_discard::OBSERVATION_INPUT_NAME,
    );
    let (mut observer, log) = launch_observer(
        repository,
        pipewire_build,
        pipewireao_julia,
        environment,
        core_name,
        observer_name,
        hold_file,
        temporary,
        1,
    );
    let output = fits_discard::NamedLink::connect(
        core_name,
        fits_discard::OBSERVATION_OUTPUT_NAME,
        observer_name,
    );
    wait_for_observer_buffer(&mut observer.0, &log, &input, &output, core_name);
    wait_for_finite_ready(runner, label);
    drop(output);
    drop(observer);
    drop(input);
    drop(queue);
    for node_name in [
        observer_name,
        fits_discard::OBSERVATION_INPUT_NAME,
        fits_discard::OBSERVATION_OUTPUT_NAME,
    ] {
        wait_for_dump_absent(pipewire_build, environment, core_name, node_name);
    }
}

fn load_observation_session(core_name: &str, fixture: &Path) -> Runner<LiveGraphAdapter> {
    let adapter = LiveGraphAdapter::connect(core_name).expect("connect observation session");
    let mut runner = Runner::new(adapter);
    assert_eq!(
        runner
            .dispatch(LifecycleEvent::Load(ConfigurationInput::File(
                fixture.to_owned(),
            )))
            .unwrap(),
        LifecycleState::Ready,
        "observer load diagnostic: {:?}",
        runner.diagnostic()
    );
    runner
}

fn run_unobserved_finite_replay(core_name: &str, fixture: &Path) -> DiscardObservation {
    let mut runner = load_observation_session(core_name, fixture);
    for replay in ["unobserved first replay", "unobserved second replay"] {
        assert_eq!(
            runner.dispatch(LifecycleEvent::Start).unwrap(),
            LifecycleState::Running,
            "{replay} start diagnostic: {:?}",
            runner.diagnostic()
        );
        wait_for_finite_ready(&mut runner, replay);
    }
    let observation = runner.executor().observe_discard_payloads().unwrap()["pipewireao-rtc-sink"];
    assert_two_replay_observation(observation);
    assert_eq!(
        runner.dispatch(LifecycleEvent::Unload).unwrap(),
        LifecycleState::Offline
    );
    observation
}

fn assert_two_replay_observation(observation: DiscardObservation) {
    assert_eq!(observation.buffers, 8);
    assert_eq!(observation.bytes, 8 * 2 * size_of::<f32>() as u64);
    assert_eq!(observation.digest_bytes, observation.bytes);
    assert_eq!(observation.payload_digest, expected_leaky_digest(8));
}

fn wait_for_finite_ready(runner: &mut Runner<LiveGraphAdapter>, label: &str) {
    for _ in 0..1_000 {
        if runner.poll_required_objects().unwrap() == LifecycleState::Ready {
            return;
        }
        std::thread::sleep(Duration::from_millis(5));
    }
    panic!(
        "{label} did not reach READY after finite completion: {:?}",
        runner.diagnostic()
    );
}

fn write_finite_fixture(repository: &Path, temporary: &Path, name: &str, rate: u32) -> PathBuf {
    let fixture = temporary.join(format!("{name}.conf"));
    let configured = std::fs::read_to_string(repository.join("fixtures/minimal-development.conf"))
        .expect("read minimal fixture")
        .replacen("api.fits.loop = true", "api.fits.loop = false", 1)
        .replacen(
            "api.fits.rate = 1000/1",
            &format!("api.fits.rate = {rate}/1"),
            1,
        )
        .replacen("\n    rate = 1000/1", &format!("\n    rate = {rate}/1"), 1);
    assert!(configured.contains("api.fits.loop = false"));
    assert!(configured.contains(&format!("api.fits.rate = {rate}/1")));
    std::fs::write(&fixture, configured).expect("write finite source fixture");
    fixture
}

fn launch_observation_queue(
    pipewire_build: &Path,
    plugin_build: &Path,
    environment: &BTreeMap<String, PathBuf>,
    core_name: &str,
) -> ChildGuard {
    let queue_owner = std::env::var_os("PIPEWIREAO_RTC_QUEUE_REMOTE_TEST").map_or_else(
        || plugin_build.join("src/modules/queue/pipewireao-queue-remote-test"),
        PathBuf::from,
    );
    let owner = command_with_environment(queue_owner, environment)
        .args([core_name, "--serve-rtc-observer"])
        .stdout(Stdio::null())
        .stderr(Stdio::null())
        .spawn()
        .expect("start bounded observation queue owner");
    wait_for_dump(
        pipewire_build,
        environment,
        core_name,
        fits_discard::OBSERVATION_INPUT_NAME,
    );
    wait_for_dump(
        pipewire_build,
        environment,
        core_name,
        fits_discard::OBSERVATION_OUTPUT_NAME,
    );
    ChildGuard(owner)
}

#[allow(clippy::too_many_arguments)]
fn launch_observer(
    repository: &Path,
    pipewire_build: &Path,
    pipewireao_julia: &Path,
    environment: &BTreeMap<String, PathBuf>,
    core_name: &str,
    node_name: &str,
    hold_file: &Path,
    temporary: &Path,
    rate: u32,
) -> (ChildGuard, PathBuf) {
    let log_path = temporary.join(format!("{node_name}.log"));
    let log = std::fs::File::create(&log_path).expect("observer log");
    let mut command = command_with_environment("julia", environment);
    command.env(
        "JULIA_LOAD_PATH",
        format!("{}:@stdlib", pipewireao_julia.display()),
    );
    let rate = rate.to_string();
    let process = command
        .args(["--startup-file=no", "--threads=2"])
        .arg(repository.join("tests/live_private_core/observer.jl"))
        .args([
            core_name,
            node_name,
            hold_file.to_str().expect("UTF-8 observer hold path"),
            &rate,
        ])
        .stdout(Stdio::from(log.try_clone().unwrap()))
        .stderr(Stdio::from(log))
        .spawn()
        .expect("start bounded observer");
    let mut process = ChildGuard(process);
    wait_for_text(&mut process.0, &log_path, "OBSERVER_READY");
    wait_for_dump(pipewire_build, environment, core_name, node_name);
    (process, log_path)
}

fn wait_for_observer_buffer(
    process: &mut Child,
    log: &Path,
    input: &fits_discard::NamedLink,
    output: &fits_discard::NamedLink,
    core_name: &str,
) {
    let deadline = Instant::now() + Duration::from_secs(10);
    while Instant::now() < deadline {
        if std::fs::read_to_string(log)
            .unwrap_or_default()
            .contains("OBSERVER_BUFFER")
        {
            return;
        }
        if let Some(status) = process.try_wait().unwrap() {
            panic!(
                "observer exited with {status}: {}",
                std::fs::read_to_string(log).unwrap_or_default()
            );
        }
        std::thread::sleep(Duration::from_millis(20));
    }
    panic!(
        "observer received no buffer; input link {}, output link {}, log: {}; queue input: {:?}; queue output: {:?}",
        input.state(),
        output.state(),
        std::fs::read_to_string(log).unwrap_or_default(),
        fits_discard::node_properties(core_name, fits_discard::OBSERVATION_INPUT_NAME),
        fits_discard::node_properties(core_name, fits_discard::OBSERVATION_OUTPUT_NAME),
    );
}

fn run_external_processing_graph_fault_case(
    repository: &Path,
    pipewire_build: &Path,
    environment: &BTreeMap<String, PathBuf>,
    core_name: &str,
    graph_configuration: &Path,
) {
    let provider = launch_external_fgn(pipewire_build, environment, core_name, graph_configuration);
    let adapter = LiveGraphAdapter::connect(core_name).expect("connect external graph fault case");
    let mut runner = Runner::new(adapter);
    assert_eq!(
        runner
            .dispatch(LifecycleEvent::Load(ConfigurationInput::File(
                repository.join("fixtures/external-graph-development.conf"),
            )))
            .unwrap(),
        LifecycleState::Ready,
    );
    assert_eq!(
        runner.dispatch(LifecycleEvent::Start).unwrap(),
        LifecycleState::Running,
        "replacement Julia graph start diagnostic: {:?}",
        runner.diagnostic(),
    );
    drop(provider);
    wait_for_dump_absent(
        pipewire_build,
        environment,
        core_name,
        "pipewireao-rtc-external-graph",
    );
    assert_eq!(
        runner.poll_required_objects().unwrap(),
        LifecycleState::Fault,
    );
    assert_eq!(
        runner.diagnostic().map(ScientificDiagnostic::field),
        Some("graph pipewireao-rtc-external-graph.node.name")
    );
    assert_eq!(runner.executor().status().owned_nodes, 2);
    assert_eq!(runner.executor().status().owned_links, 2);

    let replacement =
        launch_external_fgn(pipewire_build, environment, core_name, graph_configuration);
    assert_eq!(
        runner.dispatch(LifecycleEvent::Retry).unwrap(),
        LifecycleState::Ready,
        "external graph retry diagnostic: {:?}",
        runner.diagnostic(),
    );
    assert_eq!(runner.executor().status().owned_nodes, 2);
    assert_eq!(runner.executor().status().owned_links, 2);
    assert_eq!(
        runner.dispatch(LifecycleEvent::Unload).unwrap(),
        LifecycleState::Offline,
    );
    assert!(dump(pipewire_build, environment, core_name).contains("pipewireao-rtc-external-graph"));
    drop(replacement);
}

fn launch_external_fgn(
    pipewire_build: &Path,
    environment: &BTreeMap<String, PathBuf>,
    core_name: &str,
    graph_configuration: &Path,
) -> ChildGuard {
    let mut provider =
        command_with_environment(pipewire_build.join("src/tools/pwao-cli"), environment)
            .args(["-r", core_name])
            .stdin(Stdio::piped())
            .stdout(Stdio::null())
            .stderr(Stdio::null())
            .spawn()
            .expect("start external FGN owner");
    writeln!(
        provider.stdin.as_mut().unwrap(),
        "load-module libpipewire-module-ndarray-filter-chain {}",
        std::fs::read_to_string(graph_configuration)
            .expect("read external FGN configuration")
            .lines()
            .map(str::trim)
            .filter(|line| !line.is_empty())
            .collect::<Vec<_>>()
            .join(" ")
    )
    .unwrap();
    provider.stdin.as_mut().unwrap().flush().unwrap();
    ChildGuard(provider)
}

fn run_external_julia_processing_graph_case(
    repository: &Path,
    pipewire_build: &Path,
    environment: &BTreeMap<String, PathBuf>,
    core_name: &str,
    temporary: &Path,
    pipewireao_julia: &Path,
    julia_filter_graph: &Path,
) {
    let fixture = temporary.join("external-julia-session-development.conf");
    let configuration =
        std::fs::read_to_string(repository.join("fixtures/external-graph-development.conf"))
            .expect("read external graph fixture")
            .replace("api.fits.rate = 1000/1", "api.fits.rate = 10/1")
            .replacen("\n    rate = 1000/1", "\n    rate = 10/1", 1);
    std::fs::write(&fixture, configuration).expect("write external Julia session fixture");
    let (mut provider, stop_file, provider_log) = launch_external_julia(
        repository,
        pipewire_build,
        environment,
        core_name,
        temporary,
        pipewireao_julia,
        julia_filter_graph,
        "session",
        10,
    );

    let adapter = LiveGraphAdapter::connect(core_name).expect("connect Julia graph session");
    let mut runner = Runner::new(adapter);
    assert_eq!(
        runner
            .dispatch(LifecycleEvent::Load(ConfigurationInput::File(fixture,)))
            .unwrap(),
        LifecycleState::Ready,
        "Julia graph load diagnostic: {:?}",
        runner.diagnostic(),
    );
    assert_eq!(runner.executor().status().owned_nodes, 2);
    assert_eq!(runner.executor().status().owned_links, 2);
    assert_eq!(
        runner.dispatch(LifecycleEvent::Start).unwrap(),
        LifecycleState::Running,
        "Julia graph start diagnostic: {:?}",
        runner.diagnostic(),
    );
    let first_count = runner.executor().status().discarded_buffers;
    assert!(first_count > 0);
    assert_eq!(
        runner.dispatch(LifecycleEvent::Stop).unwrap(),
        LifecycleState::Ready,
        "Julia graph stop diagnostic: {:?}",
        runner.diagnostic(),
    );
    assert_eq!(
        runner.dispatch(LifecycleEvent::Start).unwrap(),
        LifecycleState::Running,
        "Julia graph restart diagnostic: {:?}",
        runner.diagnostic(),
    );
    assert!(runner.executor().status().discarded_buffers > first_count);
    assert_eq!(
        runner.dispatch(LifecycleEvent::Stop).unwrap(),
        LifecycleState::Ready,
    );
    assert_eq!(
        runner.dispatch(LifecycleEvent::Unload).unwrap(),
        LifecycleState::Offline,
    );
    let after_unload = dump(pipewire_build, environment, core_name);
    assert!(after_unload.contains("pipewireao-rtc-external-graph"));
    assert!(after_unload.contains("pipewireao-rtc-unrelated"));
    assert!(!after_unload.contains("pipewireao-rtc-source"));
    assert!(!after_unload.contains("pipewireao-rtc-sink"));

    stop_julia_graph_after_unload(&mut provider, &stop_file, &provider_log, "Julia graph");
    wait_for_dump_absent(
        pipewire_build,
        environment,
        core_name,
        "pipewireao-rtc-external-graph",
    );

    run_external_julia_processing_graph_fault_case(
        repository,
        pipewire_build,
        environment,
        core_name,
        temporary,
        pipewireao_julia,
        julia_filter_graph,
    );
}

fn exercise_live_property_updates(runner: &mut Runner<LiveGraphAdapter>, graph: &str, node: &str) {
    let mut previous = runner
        .executor()
        .observe_property_generation(graph, node)
        .expect("observe initial property generations");
    for (gain, pole) in [(0.25_f32, 0.5_f32), (0.125_f32, 0.75_f32)] {
        let values = BTreeMap::from([
            (format!("{node}:gain"), ScalarValue::float(gain)),
            (format!("{node}:pole"), ScalarValue::float(pole)),
        ]);
        assert_eq!(
            runner
                .dispatch(LifecycleEvent::UpdateProperties {
                    graph: graph.to_owned(),
                    values: values.clone(),
                })
                .unwrap(),
            LifecycleState::Running,
            "multi-property update diagnostic: {:?}",
            runner.diagnostic(),
        );
        let generation = runner
            .executor()
            .observe_property_generation(graph, node)
            .expect("observe active multi-property transaction");
        assert_eq!(generation.requested, previous.requested + 1);
        assert_eq!(generation.active, Some(generation.requested));
        let snapshot = runner
            .executor()
            .observe_properties(graph)
            .expect("inspect standard scientific Props snapshot");
        for (name, value) in &values {
            assert_eq!(snapshot.get(name), Some(value), "{name} active value");
        }
        previous = generation;
    }
    assert_eq!(
        runner
            .dispatch(LifecycleEvent::UpdateProperties {
                graph: graph.to_owned(),
                values: BTreeMap::from([(format!("{node}:unknown"), ScalarValue::float(1.0),)]),
            })
            .unwrap(),
        LifecycleState::Fault,
        "rejected property diagnostic: {:?}",
        runner.diagnostic(),
    );
    let diagnostic = runner.diagnostic().expect("rejected property diagnostic");
    assert_eq!(
        diagnostic.field(),
        format!("graph {graph}.properties.{node}:unknown")
    );
    assert!(diagnostic.message().contains("not declared"));
    assert_eq!(
        runner
            .executor()
            .observe_property_generation(graph, node)
            .expect("rejected update preserves property generations"),
        previous,
    );
    assert!(!runner
        .executor()
        .observe_properties(graph)
        .expect("rejected update preserves property snapshot")
        .contains_key(&format!("{node}:unknown")));
}

#[allow(clippy::too_many_arguments)]
fn run_live_property_update_cases(
    repository: &Path,
    pipewire_build: &Path,
    environment: &BTreeMap<String, PathBuf>,
    core_name: &str,
    temporary: &Path,
    pipewireao_julia: &Path,
    julia_filter_graph: &Path,
) {
    let mut native =
        Runner::new(LiveGraphAdapter::connect(core_name).expect("connect native property session"));
    assert_eq!(
        native
            .dispatch(LifecycleEvent::Load(ConfigurationInput::File(
                repository.join("fixtures/minimal-development.conf"),
            )))
            .unwrap(),
        LifecycleState::Ready,
        "native property load diagnostic: {:?}",
        native.diagnostic(),
    );
    assert_eq!(
        native.dispatch(LifecycleEvent::Start).unwrap(),
        LifecycleState::Running,
    );
    exercise_live_property_updates(&mut native, "pipewireao-rtc-graph", "graph");
    assert_eq!(
        native.dispatch(LifecycleEvent::Unload).unwrap(),
        LifecycleState::Offline,
        "native property unload diagnostic: {:?}",
        native.diagnostic(),
    );
    for node in [
        "pipewireao-rtc-source",
        "pipewireao-rtc-graph",
        "pipewireao-rtc-sink",
    ] {
        wait_for_dump_absent(pipewire_build, environment, core_name, node);
    }

    let fixture = temporary.join("external-julia-property-development.conf");
    let configuration =
        std::fs::read_to_string(repository.join("fixtures/external-graph-development.conf"))
            .expect("read external graph fixture")
            .replace("api.fits.rate = 1000/1", "api.fits.rate = 10/1")
            .replacen("\n    rate = 1000/1", "\n    rate = 10/1", 1);
    std::fs::write(&fixture, configuration).expect("write Julia property fixture");
    let (mut provider, stop_file, provider_log) = launch_external_julia(
        repository,
        pipewire_build,
        environment,
        core_name,
        temporary,
        pipewireao_julia,
        julia_filter_graph,
        "property",
        10,
    );
    let mut julia =
        Runner::new(LiveGraphAdapter::connect(core_name).expect("connect Julia property session"));
    assert_eq!(
        julia
            .dispatch(LifecycleEvent::Load(ConfigurationInput::File(fixture)))
            .unwrap(),
        LifecycleState::Ready,
        "Julia property load diagnostic: {:?}",
        julia.diagnostic(),
    );
    assert_eq!(
        julia.dispatch(LifecycleEvent::Start).unwrap(),
        LifecycleState::Running,
        "Julia property start diagnostic: {:?}",
        julia.diagnostic(),
    );
    exercise_live_property_updates(&mut julia, "pipewireao-rtc-external-graph", "integrate");
    assert_eq!(
        julia.dispatch(LifecycleEvent::Unload).unwrap(),
        LifecycleState::Offline,
    );
    stop_julia_graph_after_unload(
        &mut provider,
        &stop_file,
        &provider_log,
        "Julia property graph",
    );
    wait_for_dump_absent(
        pipewire_build,
        environment,
        core_name,
        "pipewireao-rtc-external-graph",
    );
}

fn run_structural_reload_case(
    repository: &Path,
    pipewire_build: &Path,
    environment: &BTreeMap<String, PathBuf>,
    core_name: &str,
) {
    let mut runner =
        Runner::new(LiveGraphAdapter::connect(core_name).expect("connect reload session"));
    assert_eq!(
        runner
            .dispatch(LifecycleEvent::Load(ConfigurationInput::File(
                repository.join("fixtures/minimal-development.conf"),
            )))
            .unwrap(),
        LifecycleState::Ready,
    );
    assert_eq!(
        runner.dispatch(LifecycleEvent::Start).unwrap(),
        LifecycleState::Running
    );
    assert_eq!(
        runner.dispatch(LifecycleEvent::Stop).unwrap(),
        LifecycleState::Ready
    );
    assert_eq!(
        runner
            .dispatch(LifecycleEvent::Reload(ConfigurationInput::File(
                repository.join("fixtures/serial-development.conf"),
            )))
            .unwrap(),
        LifecycleState::Ready,
        "structural reload diagnostic: {:?}",
        runner.diagnostic(),
    );
    let realized = dump(pipewire_build, environment, core_name);
    assert!(realized.contains("pipewireao-rtc-serial-graph-a"));
    assert!(realized.contains("pipewireao-rtc-serial-graph-b"));
    assert!(!realized.contains("pipewireao-rtc-graph"));
    assert_eq!(
        runner.dispatch(LifecycleEvent::Start).unwrap(),
        LifecycleState::Running
    );
    let delivered = runner
        .executor_mut()
        .observe_discarded_buffers()
        .expect("observe reloaded topology");
    assert!(delivered["pipewireao-rtc-serial-sink"] > 0);
    assert_eq!(
        runner.dispatch(LifecycleEvent::Unload).unwrap(),
        LifecycleState::Offline
    );
    for node in [
        "pipewireao-rtc-serial-source",
        "pipewireao-rtc-serial-graph-a",
        "pipewireao-rtc-serial-graph-b",
        "pipewireao-rtc-serial-sink",
    ] {
        wait_for_dump_absent(pipewire_build, environment, core_name, node);
    }
}

#[allow(clippy::too_many_arguments)]
fn launch_external_julia(
    repository: &Path,
    pipewire_build: &Path,
    environment: &BTreeMap<String, PathBuf>,
    core_name: &str,
    temporary: &Path,
    pipewireao_julia: &Path,
    julia_filter_graph: &Path,
    label: &str,
    rate: u32,
) -> (ChildGuard, PathBuf, PathBuf) {
    let stop_file = temporary.join(format!("stop-julia-graph-{label}"));
    let provider_log = temporary.join(format!("julia-graph-{label}.log"));
    let log = std::fs::File::create(&provider_log).expect("Julia graph log");
    let mut command = command_with_environment("julia", environment);
    command.env(
        "JULIA_LOAD_PATH",
        format!("{}:@:@stdlib", pipewireao_julia.display()),
    );
    let provider = command
        .args([
            "--startup-file=no",
            "--threads=2",
            &format!(
                "--project={}",
                julia_filter_graph.join("deployment").display()
            ),
        ])
        .arg(repository.join("tests/live_private_core/julia_graph_provider.jl"))
        .args([
            core_name,
            repository
                .join("fixtures/graphs/julia-leaky-integrator.conf")
                .to_str()
                .expect("UTF-8 Julia graph configuration"),
            stop_file.to_str().expect("UTF-8 Julia stop path"),
            &rate.to_string(),
        ])
        .stdout(Stdio::from(log.try_clone().unwrap()))
        .stderr(Stdio::from(log))
        .spawn()
        .expect("start external Julia graph owner");
    let mut provider = ChildGuard(provider);
    wait_for_text(&mut provider.0, &provider_log, "JULIA_GRAPH_READY");
    wait_for_dump(
        pipewire_build,
        environment,
        core_name,
        "pipewireao-rtc-external-graph",
    );
    (provider, stop_file, provider_log)
}

#[allow(clippy::too_many_arguments)]
fn launch_latest_hold_external_julia(
    repository: &Path,
    pipewire_build: &Path,
    environment: &BTreeMap<String, PathBuf>,
    core_name: &str,
    temporary: &Path,
    pipewireao_julia: &Path,
    julia_filter_graph: &Path,
) -> (ChildGuard, PathBuf, PathBuf) {
    let stop_file = temporary.join("stop-latest-hold-julia-graph");
    let provider_log = temporary.join("latest-hold-julia-graph.log");
    let log = std::fs::File::create(&provider_log).expect("Julia latest/hold graph log");
    let mut command = command_with_environment("julia", environment);
    command.env(
        "JULIA_LOAD_PATH",
        format!("{}:@:@stdlib", pipewireao_julia.display()),
    );
    let provider = command
        .args([
            "--startup-file=no",
            "--threads=2",
            &format!(
                "--project={}",
                julia_filter_graph.join("deployment").display()
            ),
        ])
        .arg(repository.join("tests/live_private_core/latest_hold_julia_graph_provider.jl"))
        .args([
            core_name,
            repository
                .join("fixtures/graphs/julia-latest-hold-pass.conf")
                .to_str()
                .expect("UTF-8 Julia latest/hold graph configuration"),
            stop_file
                .to_str()
                .expect("UTF-8 Julia latest/hold stop path"),
            "1000",
        ])
        .stdout(Stdio::from(log.try_clone().unwrap()))
        .stderr(Stdio::from(log))
        .spawn()
        .expect("start external Julia latest/hold graph owner");
    let mut provider = ChildGuard(provider);
    wait_for_text(
        &mut provider.0,
        &provider_log,
        "LATEST_HOLD_JULIA_GRAPH_READY",
    );
    wait_for_dump(
        pipewire_build,
        environment,
        core_name,
        "pipewireao-rtc-latest-hold-graph",
    );
    (provider, stop_file, provider_log)
}

#[allow(clippy::too_many_arguments)]
fn run_external_julia_processing_graph_fault_case(
    repository: &Path,
    pipewire_build: &Path,
    environment: &BTreeMap<String, PathBuf>,
    core_name: &str,
    temporary: &Path,
    pipewireao_julia: &Path,
    julia_filter_graph: &Path,
) {
    let fixture = temporary.join("external-julia-fault-development.conf");
    let configuration =
        std::fs::read_to_string(repository.join("fixtures/external-graph-development.conf"))
            .expect("read external graph fixture")
            .replace("api.fits.rate = 1000/1", "api.fits.rate = 10/1")
            .replacen("\n    rate = 1000/1", "\n    rate = 10/1", 1);
    assert!(configuration.contains("api.fits.rate = 10/1"));
    std::fs::write(&fixture, configuration).expect("write external Julia fault fixture");
    let (provider, _, _) = launch_external_julia(
        repository,
        pipewire_build,
        environment,
        core_name,
        temporary,
        pipewireao_julia,
        julia_filter_graph,
        "fault",
        10,
    );
    let adapter = LiveGraphAdapter::connect(core_name).expect("connect Julia graph fault case");
    let mut runner = Runner::new(adapter);
    assert_eq!(
        runner
            .dispatch(LifecycleEvent::Load(ConfigurationInput::File(
                fixture.clone(),
            )))
            .unwrap(),
        LifecycleState::Ready,
    );
    assert_eq!(
        runner.dispatch(LifecycleEvent::Start).unwrap(),
        LifecycleState::Running,
        "fault-case Julia graph start diagnostic: {:?}",
        runner.diagnostic(),
    );
    drop(provider);
    wait_for_dump_absent(
        pipewire_build,
        environment,
        core_name,
        "pipewireao-rtc-external-graph",
    );
    assert_eq!(
        runner.poll_required_objects().unwrap(),
        LifecycleState::Fault,
    );
    assert_eq!(
        runner.diagnostic().map(ScientificDiagnostic::field),
        Some("graph pipewireao-rtc-external-graph.node.name")
    );

    let (mut replacement, stop_file, provider_log) = launch_external_julia(
        repository,
        pipewire_build,
        environment,
        core_name,
        temporary,
        pipewireao_julia,
        julia_filter_graph,
        "replacement",
        10,
    );
    assert_eq!(
        runner.dispatch(LifecycleEvent::Retry).unwrap(),
        LifecycleState::Ready,
        "Julia graph retry diagnostic: {:?}",
        runner.diagnostic(),
    );
    assert_eq!(
        runner.dispatch(LifecycleEvent::Start).unwrap(),
        LifecycleState::Running,
        "replacement Julia graph start diagnostic: {:?}",
        runner.diagnostic(),
    );
    assert!(runner.executor().status().discarded_buffers > 0);
    assert_eq!(
        runner.dispatch(LifecycleEvent::Stop).unwrap(),
        LifecycleState::Ready,
    );
    assert_eq!(
        runner.dispatch(LifecycleEvent::Unload).unwrap(),
        LifecycleState::Offline,
    );
    assert!(dump(pipewire_build, environment, core_name).contains("pipewireao-rtc-external-graph"));
    stop_julia_graph_after_unload(
        &mut replacement,
        &stop_file,
        &provider_log,
        "replacement Julia graph",
    );
    wait_for_dump_absent(
        pipewire_build,
        environment,
        core_name,
        "pipewireao-rtc-external-graph",
    );
}

#[allow(clippy::too_many_arguments)]
fn run_external_graph_equivalence_case(
    repository: &Path,
    pipewire_build: &Path,
    environment: &BTreeMap<String, PathBuf>,
    core_name: &str,
    temporary: &Path,
    native_graph_configuration: &Path,
    pipewireao_julia: &Path,
    julia_filter_graph: &Path,
) {
    let fixture = temporary.join("finite-external-graph-development.conf");
    let configured =
        std::fs::read_to_string(repository.join("fixtures/external-graph-development.conf"))
            .expect("read external graph fixture")
            .replacen("api.fits.loop = true", "api.fits.loop = false", 1)
            .replacen("api.fits.rate = 1000/1", "api.fits.rate = 10/1", 1)
            .replacen("\n    rate = 1000/1", "\n    rate = 10/1", 1);
    assert!(configured.contains("api.fits.loop = false"));
    assert!(configured.contains("api.fits.rate = 10/1"));
    std::fs::write(&fixture, configured).expect("write finite external graph fixture");

    let native_graph = temporary.join("external-owned-equivalence.conf");
    let configured_native = std::fs::read_to_string(native_graph_configuration)
        .expect("read native external graph")
        .replace("rate = [ 1000 1 ]", "rate = [ 10 1 ]");
    assert!(configured_native.contains("rate = [ 10 1 ]"));
    std::fs::write(&native_graph, configured_native).expect("write native equivalence graph");
    let native = launch_external_fgn(pipewire_build, environment, core_name, &native_graph);
    wait_for_dump(
        pipewire_build,
        environment,
        core_name,
        "pipewireao-rtc-external-graph",
    );
    let native_digest = run_finite_external_graph(core_name, &fixture, "native FGN");
    drop(native);
    wait_for_dump_absent(
        pipewire_build,
        environment,
        core_name,
        "pipewireao-rtc-external-graph",
    );

    let (mut julia, stop_file, provider_log) = launch_external_julia(
        repository,
        pipewire_build,
        environment,
        core_name,
        temporary,
        pipewireao_julia,
        julia_filter_graph,
        "equivalence",
        10,
    );
    let julia_digest = run_finite_external_graph(core_name, &fixture, "Julia graph");
    assert_eq!(julia_digest, native_digest);
    assert_eq!(julia_digest, expected_leaky_digest(4));
    stop_julia_graph_after_unload(
        &mut julia,
        &stop_file,
        &provider_log,
        "equivalence Julia graph",
    );
    wait_for_dump_absent(
        pipewire_build,
        environment,
        core_name,
        "pipewireao-rtc-external-graph",
    );
}

fn run_finite_external_graph(core_name: &str, fixture: &Path, implementation: &str) -> u64 {
    let adapter = LiveGraphAdapter::connect(core_name).expect("connect finite external graph");
    let mut runner = Runner::new(adapter);
    assert_eq!(
        runner
            .dispatch(LifecycleEvent::Load(ConfigurationInput::File(
                fixture.to_owned(),
            )))
            .unwrap(),
        LifecycleState::Ready,
        "{implementation} finite load diagnostic: {:?}",
        runner.diagnostic(),
    );
    assert_eq!(
        runner.dispatch(LifecycleEvent::Start).unwrap(),
        LifecycleState::Running,
        "{implementation} finite start diagnostic: {:?}",
        runner.diagnostic(),
    );
    for _ in 0..200 {
        let count = runner
            .executor_mut()
            .observe_discarded_buffers()
            .expect("observe finite external output")["pipewireao-rtc-sink"];
        if count == 4 {
            break;
        }
        std::thread::sleep(Duration::from_millis(5));
    }
    for _ in 0..200 {
        if runner.poll_required_objects().unwrap() == LifecycleState::Ready {
            break;
        }
        std::thread::sleep(Duration::from_millis(5));
    }
    assert_eq!(
        runner.state(),
        LifecycleState::Ready,
        "{implementation} finite source did not complete: {:?}",
        runner.diagnostic(),
    );
    let observation = runner
        .executor()
        .observe_discard_payloads()
        .expect("read external graph output evidence")["pipewireao-rtc-sink"];
    assert_eq!(observation.buffers, 4, "{implementation} output count");
    assert_eq!(observation.digest_bytes, observation.bytes);
    assert_eq!(
        runner.dispatch(LifecycleEvent::Unload).unwrap(),
        LifecycleState::Offline,
    );
    observation.payload_digest
}

#[allow(clippy::too_many_arguments)]
#[allow(
    clippy::too_many_lines,
    reason = "the live SCAO fixture keeps its ordered lifecycle and numerical assertions together"
)]
fn run_aos_hil_reference_case(
    repository: &Path,
    hil_package: &Path,
    pipewire_build: &Path,
    environment: &BTreeMap<String, PathBuf>,
    core_name: &str,
    temporary: &Path,
    graph_configuration: &Path,
    fgn_bundle: &Path,
) {
    let phase_1_request = temporary.join("aos-hil-phase-1");
    let phase_2_request = temporary.join("aos-hil-phase-2");
    let atmosphere_request = temporary.join("aos-hil-atmosphere");
    let atmosphere_phase_1_request = temporary.join("aos-hil-atmosphere-phase-1");
    let atmosphere_phase_2_request = temporary.join("aos-hil-atmosphere-phase-2");
    let stop_file = temporary.join("stop-aos-hil");
    let provider_log = temporary.join("aos-hil.log");
    let log = std::fs::File::create(&provider_log).expect("AOS HIL log");
    let provider = command_with_environment("julia", environment)
        .args([
            "--startup-file=no",
            "--threads=2",
            &format!("--project={}", hil_package.display()),
        ])
        .arg(repository.join("tests/live_private_core/aos_hil_provider.jl"))
        .args([
            core_name,
            temporary.to_str().expect("UTF-8 control directory"),
            graph_configuration
                .to_str()
                .expect("UTF-8 graph configuration path"),
            fgn_bundle.to_str().expect("UTF-8 FGN bundle path"),
        ])
        .stdout(Stdio::from(log.try_clone().unwrap()))
        .stderr(Stdio::from(log))
        .spawn()
        .expect("start AOS HIL reference provider");
    let mut provider = ChildGuard(provider);
    wait_for_text(&mut provider.0, &provider_log, "AOS_HIL_READY");
    wait_for_dump(
        pipewire_build,
        environment,
        core_name,
        "pipewireao-aos-hil-wfs",
    );
    wait_for_dump(
        pipewire_build,
        environment,
        core_name,
        "pipewireao-aos-hil-command",
    );

    let adapter = LiveGraphAdapter::connect(core_name).expect("connect AOS HIL session");
    let mut runner = Runner::new(adapter);
    assert_eq!(
        runner
            .dispatch(LifecycleEvent::Load(ConfigurationInput::File(
                repository.join("fixtures/aos-hil-development.conf"),
            )))
            .unwrap(),
        LifecycleState::Ready,
        "AOS HIL load diagnostic: {:?}",
        runner.diagnostic(),
    );
    assert_eq!(runner.executor().status().owned_nodes, 1);
    assert_eq!(runner.executor().status().owned_links, 2);
    assert_eq!(
        runner.dispatch(LifecycleEvent::Start).unwrap(),
        LifecycleState::Running,
        "AOS HIL start diagnostic: {:?}",
        runner.diagnostic(),
    );
    std::fs::write(&phase_1_request, "run\n").unwrap();
    wait_for_text(
        &mut provider.0,
        &provider_log,
        "AOS_HIL_PHASE_1_DONE sequence=7",
    );
    wait_for_text(
        &mut provider.0,
        &provider_log,
        "AOS_HIL_CAUSALITY_DONE command_sequence=1 frame_sequence=2",
    );
    assert_eq!(
        runner.dispatch(LifecycleEvent::Stop).unwrap(),
        LifecycleState::Ready,
        "AOS HIL stop diagnostic: {:?}",
        runner.diagnostic(),
    );
    assert_eq!(
        runner.dispatch(LifecycleEvent::Start).unwrap(),
        LifecycleState::Running,
        "AOS HIL restart diagnostic: {:?}",
        runner.diagnostic(),
    );
    std::fs::write(&phase_2_request, "run\n").unwrap();
    wait_for_text(
        &mut provider.0,
        &provider_log,
        "AOS_HIL_CLOSED_LOOP_DONE sequence=15",
    );
    assert_eq!(
        runner.dispatch(LifecycleEvent::Stop).unwrap(),
        LifecycleState::Ready,
    );
    assert_eq!(
        runner.dispatch(LifecycleEvent::Unload).unwrap(),
        LifecycleState::Offline,
    );
    let after = dump(pipewire_build, environment, core_name);
    assert!(after.contains("pipewireao-aos-hil-wfs"));
    assert!(after.contains("pipewireao-aos-hil-command"));
    assert!(after.contains("pipewireao-rtc-unrelated"));
    assert!(!after.contains("pipewireao-rtc-aos-controller"));

    std::fs::write(&atmosphere_request, "run\n").unwrap();
    wait_for_text(&mut provider.0, &provider_log, "AOS_HIL_ATMOSPHERE_READY");
    wait_for_dump(
        pipewire_build,
        environment,
        core_name,
        "pipewireao-aos-hil-atmosphere-wfs",
    );
    wait_for_dump(
        pipewire_build,
        environment,
        core_name,
        "pipewireao-aos-hil-atmosphere-command",
    );

    let adapter = LiveGraphAdapter::connect(core_name).expect("connect atmospheric HIL session");
    let mut runner = Runner::new(adapter);
    assert_eq!(
        runner
            .dispatch(LifecycleEvent::Load(ConfigurationInput::File(
                repository.join("fixtures/aos-hil-atmosphere-development.conf"),
            )))
            .unwrap(),
        LifecycleState::Ready,
        "atmospheric HIL load diagnostic: {:?}",
        runner.diagnostic(),
    );
    assert_eq!(runner.executor().status().owned_nodes, 1);
    assert_eq!(runner.executor().status().owned_links, 2);
    assert_eq!(
        runner.dispatch(LifecycleEvent::Start).unwrap(),
        LifecycleState::Running,
        "atmospheric HIL start diagnostic: {:?}",
        runner.diagnostic(),
    );
    std::fs::write(&atmosphere_phase_1_request, "run\n").unwrap();
    wait_for_text(
        &mut provider.0,
        &provider_log,
        "AOS_HIL_ATMOSPHERE_PHASE_1_DONE sequence=10",
    );
    assert_eq!(
        runner.dispatch(LifecycleEvent::Stop).unwrap(),
        LifecycleState::Ready,
    );
    assert_eq!(
        runner.dispatch(LifecycleEvent::Start).unwrap(),
        LifecycleState::Running,
        "atmospheric HIL restart diagnostic: {:?}",
        runner.diagnostic(),
    );
    std::fs::write(&atmosphere_phase_2_request, "run\n").unwrap();
    wait_for_text(
        &mut provider.0,
        &provider_log,
        "AOS_HIL_ATMOSPHERE_DONE sequence=20",
    );
    assert_eq!(
        runner.dispatch(LifecycleEvent::Stop).unwrap(),
        LifecycleState::Ready,
    );
    assert_eq!(
        runner.dispatch(LifecycleEvent::Unload).unwrap(),
        LifecycleState::Offline,
    );
    let after = dump(pipewire_build, environment, core_name);
    assert!(after.contains("pipewireao-aos-hil-atmosphere-wfs"));
    assert!(after.contains("pipewireao-aos-hil-atmosphere-command"));
    assert!(after.contains("pipewireao-rtc-unrelated"));
    assert!(!after.contains("pipewireao-rtc-aos-controller"));

    stop_provider(&mut provider, &stop_file, &provider_log, "AOS HIL");
}

#[allow(clippy::too_many_arguments, clippy::too_many_lines)]
fn run_revolt_classic_lockstep_case(
    repository: &Path,
    revolt_hil_package: &Path,
    pipewire_build: &Path,
    environment: &BTreeMap<String, PathBuf>,
    core_name: &str,
    temporary: &Path,
    native_graph: &Path,
    julia_graph: &Path,
    pipewireao_julia: &Path,
    julia_filter_graph: &Path,
) {
    let hil_log = temporary.join("revolt-lockstep-hil.log");
    let log = std::fs::File::create(&hil_log).expect("REVOLT lockstep HIL log");
    let provider = command_with_environment("julia", environment)
        .env("PIPEWIREAO_RTC_REVOLT_LOCKSTEP", "1")
        .args([
            "--startup-file=no",
            "--threads=2",
            &format!("--project={}", revolt_hil_package.display()),
        ])
        .arg(repository.join("tests/live_private_core/revolt_hil_provider.jl"))
        .args([
            core_name,
            temporary.to_str().expect("UTF-8 control directory"),
            native_graph.to_str().expect("UTF-8 native graph path"),
            julia_graph.to_str().expect("UTF-8 Julia graph path"),
        ])
        .stdout(Stdio::from(log.try_clone().unwrap()))
        .stderr(Stdio::from(log))
        .spawn()
        .expect("start REVOLT lockstep HIL provider");
    let mut provider = ChildGuard(provider);
    wait_for_text_for(
        &mut provider.0,
        &hil_log,
        "REVOLT_HIL_LOCKSTEP_READY",
        Duration::from_secs(300),
    );
    for node in [
        "revolt-classic-sim-wfs",
        "revolt-classic-sim-hsdm277-command",
        "revolt-classic-sim-hsdm277-command-julia",
    ] {
        wait_for_dump(pipewire_build, environment, core_name, node);
    }

    let stop_julia_graph = temporary.join("stop-revolt-lockstep-julia-graph");
    let expected_julia_disconnect = temporary.join("revolt-lockstep-julia-disconnect");
    let julia_log = temporary.join("revolt-lockstep-julia-graph.log");
    let log = std::fs::File::create(&julia_log).expect("REVOLT lockstep Julia log");
    let mut command = command_with_environment("julia", environment);
    command.env(
        "JULIA_LOAD_PATH",
        format!("{}:@:@stdlib", pipewireao_julia.display()),
    );
    let julia_provider = command
        .args([
            "--startup-file=no",
            "--threads=2",
            &format!(
                "--project={}",
                julia_filter_graph.join("deployment").display()
            ),
        ])
        .arg(repository.join("tests/live_private_core/revolt_julia_graph_provider.jl"))
        .args([
            core_name,
            julia_graph.to_str().expect("UTF-8 Julia graph path"),
            stop_julia_graph.to_str().expect("UTF-8 Julia stop file"),
            "pipewireao-rtc-revolt-julia",
            expected_julia_disconnect
                .to_str()
                .expect("UTF-8 expected disconnect file"),
        ])
        .stdout(Stdio::from(log.try_clone().unwrap()))
        .stderr(Stdio::from(log))
        .spawn()
        .expect("start REVOLT lockstep Julia graph");
    let mut julia_provider = ChildGuard(julia_provider);
    wait_for_text(
        &mut julia_provider.0,
        &julia_log,
        "REVOLT_JULIA_GRAPH_READY",
    );

    let adapter = LiveGraphAdapter::connect(core_name).expect("connect REVOLT lockstep session");
    let mut runner = Runner::new(adapter);
    assert_eq!(
        runner
            .dispatch(LifecycleEvent::Load(ConfigurationInput::File(
                repository.join("fixtures/revolt-classic-lockstep-development.conf"),
            )))
            .unwrap(),
        LifecycleState::Ready,
        "REVOLT lockstep load diagnostic: {:?}; HIL log: {}",
        runner.diagnostic(),
        private_core_log(&hil_log),
    );
    assert_eq!(runner.executor().status().owned_nodes, 3);
    assert_eq!(runner.executor().status().owned_links, 6);
    assert_eq!(
        runner.dispatch(LifecycleEvent::Start).unwrap(),
        LifecycleState::Running,
        "REVOLT lockstep start diagnostic: {:?}",
        runner.diagnostic(),
    );
    std::fs::write(temporary.join("revolt-lockstep-run"), "run\n").unwrap();
    wait_for_text_with_runner(
        &mut provider.0,
        &hil_log,
        "REVOLT_HIL_LOCKSTEP_DONE sequence=10",
        &mut runner,
    );
    let log_text = std::fs::read_to_string(&hil_log).expect("read REVOLT lockstep log");
    assert_eq!(
        log_text
            .matches("REVOLT_HIL_LOCKSTEP_MATCH sequence=")
            .count(),
        10
    );
    assert_eq!(
        runner.dispatch(LifecycleEvent::Stop).unwrap(),
        LifecycleState::Ready,
    );
    let before_external_stop = dump(pipewire_build, environment, core_name);
    assert!(before_external_stop.contains("pipewireao-rtc-revolt-julia"));
    assert!(before_external_stop.contains("revolt-classic-sim-wfs"));
    assert_eq!(
        runner.dispatch(LifecycleEvent::Unload).unwrap(),
        LifecycleState::Offline,
    );
    std::fs::write(&expected_julia_disconnect, "RTC unloaded\n").unwrap();
    let after = dump(pipewire_build, environment, core_name);
    assert!(!after.contains("pipewireao-rtc-revolt-native"));
    assert!(after.contains("revolt-classic-sim-wfs"));
    stop_provider(
        &mut julia_provider,
        &stop_julia_graph,
        &julia_log,
        "REVOLT lockstep Julia graph",
    );
    stop_provider(
        &mut provider,
        &temporary.join("stop-revolt-hil"),
        &hil_log,
        "REVOLT lockstep HIL",
    );
    for node in [
        "pipewireao-rtc-revolt-julia",
        "revolt-classic-sim-wfs",
        "revolt-classic-sim-hsdm277-command",
        "revolt-classic-sim-hsdm277-command-julia",
    ] {
        wait_for_dump_absent(pipewire_build, environment, core_name, node);
    }
}

#[allow(clippy::too_many_arguments, clippy::too_many_lines)]
fn run_revolt_classic_reference_case(
    repository: &Path,
    revolt_hil_package: &Path,
    pipewire_build: &Path,
    environment: &BTreeMap<String, PathBuf>,
    core_name: &str,
    temporary: &Path,
    native_graph: &Path,
    julia_graph: &Path,
    pipewireao_julia: &Path,
    julia_filter_graph: &Path,
    latency: Option<&RevoltLatencyCollection>,
) {
    let native_phase_1 = temporary.join("revolt-native-phase-1");
    let native_phase_2 = temporary.join("revolt-native-phase-2");
    let native_phase_2_continue = temporary.join("revolt-native-phase-2-continue");
    let native_phase_3 = temporary.join("revolt-native-phase-3");
    let native_source_end = temporary.join("revolt-native-source-end");
    let native_after_ready = temporary.join("revolt-native-after-ready");
    let native_latency_phase = temporary.join("revolt-native-latency");
    let switch_to_julia = temporary.join("revolt-switch-to-julia");
    let julia_phase_1 = temporary.join("revolt-julia-phase-1");
    let julia_phase_2 = temporary.join("revolt-julia-phase-2");
    let julia_phase_2_continue = temporary.join("revolt-julia-phase-2-continue");
    let julia_phase_3 = temporary.join("revolt-julia-phase-3");
    let julia_source_end = temporary.join("revolt-julia-source-end");
    let julia_after_ready = temporary.join("revolt-julia-after-ready");
    let julia_latency_phase = temporary.join("revolt-julia-latency");
    let stop_hil = temporary.join("stop-revolt-hil");
    let hil_log = temporary.join("revolt-hil.log");
    let log = std::fs::File::create(&hil_log).expect("REVOLT HIL log");
    let provider = command_with_environment("julia", environment)
        .args([
            "--startup-file=no",
            "--threads=2",
            &format!("--project={}", revolt_hil_package.display()),
        ])
        .arg(repository.join("tests/live_private_core/revolt_hil_provider.jl"))
        .args([
            core_name,
            temporary.to_str().expect("UTF-8 control directory"),
            native_graph.to_str().expect("UTF-8 native graph path"),
            julia_graph.to_str().expect("UTF-8 Julia graph path"),
        ])
        .stdout(Stdio::from(log.try_clone().unwrap()))
        .stderr(Stdio::from(log))
        .spawn()
        .expect("start REVOLT Classic HIL provider");
    let mut provider = ChildGuard(provider);
    wait_for_text_for(
        &mut provider.0,
        &hil_log,
        "REVOLT_HIL_NATIVE_READY",
        Duration::from_secs(300),
    );
    wait_for_dump(
        pipewire_build,
        environment,
        core_name,
        "revolt-classic-sim-wfs",
    );
    wait_for_dump(
        pipewire_build,
        environment,
        core_name,
        "revolt-classic-sim-hsdm277-command",
    );
    let adapter = LiveGraphAdapter::connect(core_name).expect("connect native REVOLT session");
    let mut runner = Runner::new(adapter);
    assert_eq!(
        runner
            .dispatch(LifecycleEvent::Load(ConfigurationInput::File(
                repository.join("fixtures/revolt-classic-native-development.conf"),
            )))
            .unwrap(),
        LifecycleState::Ready,
        "native REVOLT load diagnostic: {:?}; private core log: {}",
        runner.diagnostic(),
        private_core_log(&hil_log),
    );
    assert_eq!(runner.executor().status().owned_nodes, 2);
    assert_eq!(runner.executor().status().owned_links, 3);
    assert_eq!(
        runner.dispatch(LifecycleEvent::Start).unwrap(),
        LifecycleState::Running,
        "native REVOLT start diagnostic: {:?}",
        runner.diagnostic(),
    );
    std::fs::write(&native_phase_1, "run\n").unwrap();
    wait_for_text_with_runner(
        &mut provider.0,
        &hil_log,
        "REVOLT_HIL_NATIVE_PHASE_1_DONE sequence=4",
        &mut runner,
    );
    assert_eq!(
        runner.dispatch(LifecycleEvent::Stop).unwrap(),
        LifecycleState::Ready,
    );
    let native_generations = apply_revolt_runtime_property_update(&mut runner, "reconstruct");
    assert_eq!(
        runner.dispatch(LifecycleEvent::Start).unwrap(),
        LifecycleState::Running,
        "native REVOLT restart diagnostic: {:?}",
        runner.diagnostic(),
    );
    std::fs::write(&native_phase_2, "run\n").unwrap();
    wait_for_text_with_runner(
        &mut provider.0,
        &hil_log,
        "REVOLT_HIL_NATIVE_PHASE_2_FIRST_DONE sequence=5",
        &mut runner,
    );
    // A frame boundary settles the gain/pole transaction before the parameter
    // source uses the graph host's bounded control slot.
    assert_revolt_property_update_active(&mut runner, native_generations.0, -0.1, 0.9);
    apply_revolt_runtime_parameter_update(
        &mut runner,
        &environment["PIPEWIREAO_RTC_PARAMETER_REVOLT"],
        "reconstruct:reconstructor",
    );
    std::fs::write(&native_phase_2_continue, "run\n").unwrap();
    wait_for_text_with_runner(
        &mut provider.0,
        &hil_log,
        "REVOLT_HIL_NATIVE_PARAMETER_DONE sequence=8",
        &mut runner,
    );
    assert_eq!(
        runner.dispatch(LifecycleEvent::Stop).unwrap(),
        LifecycleState::Ready,
    );
    let native_second_property = apply_revolt_final_property_update(&mut runner);
    assert_eq!(
        runner.dispatch(LifecycleEvent::Start).unwrap(),
        LifecycleState::Running,
    );
    std::fs::write(&native_phase_3, "run\n").unwrap();
    wait_for_text_with_runner(
        &mut provider.0,
        &hil_log,
        "REVOLT_HIL_NATIVE_DONE sequence=10",
        &mut runner,
    );
    assert_revolt_property_update_active(&mut runner, native_second_property, -0.05, 0.8);
    if let Some(latency) = latency {
        wait_for_text_with_runner(
            &mut provider.0,
            &hil_log,
            &format!(
                "REVOLT_HIL_NATIVE_LATENCY_READY warmup={} samples={}",
                latency.warmup, latency.samples
            ),
            &mut runner,
        );
        std::fs::write(&native_latency_phase, "run\n").unwrap();
        wait_for_text_with_runner(
            &mut provider.0,
            &hil_log,
            &format!("REVOLT_HIL_NATIVE_LATENCY_DONE samples={}", latency.samples),
            &mut runner,
        );
        assert_revolt_latency_csv(latency, "native");
    }
    assert_revolt_runtime_update_active(&runner, "reconstruct", native_generations);
    if latency.is_none() {
        std::fs::write(&native_source_end, "end\n").unwrap();
        wait_for_text_with_runner(
            &mut provider.0,
            &hil_log,
            "REVOLT_HIL_NATIVE_SOURCE_END sequence=10 commands=10",
            &mut runner,
        );
        assert_eq!(
            runner
                .dispatch(LifecycleEvent::FiniteSourceCompleted)
                .unwrap(),
            LifecycleState::Ready,
        );
        assert!(runner.diagnostic().is_none());
        assert_eq!(
            runner.poll_required_objects().unwrap(),
            LifecycleState::Ready
        );
        std::fs::write(&native_after_ready, "check\n").unwrap();
        wait_for_text(
            &mut provider.0,
            &hil_log,
            "REVOLT_HIL_NATIVE_READY_END_CHECK sequence=10",
        );
        let after_end = dump(pipewire_build, environment, core_name);
        assert!(after_end.contains("revolt-classic-sim-wfs"));
        assert!(after_end.contains("revolt-classic-sim-hsdm277-command"));
        assert_eq!(
            std::fs::read_to_string(&hil_log)
                .unwrap()
                .matches("REVOLT_HIL_FRAME_EXCHANGED implementation=native")
                .count(),
            10,
        );
    } else {
        assert_eq!(
            runner.dispatch(LifecycleEvent::Stop).unwrap(),
            LifecycleState::Ready,
        );
    }
    assert_eq!(
        runner.dispatch(LifecycleEvent::Unload).unwrap(),
        LifecycleState::Offline,
    );
    let after_native = dump(pipewire_build, environment, core_name);
    assert!(after_native.contains("revolt-classic-sim-wfs"));
    assert!(after_native.contains("revolt-classic-sim-hsdm277-command"));
    assert!(!after_native.contains("revolt-classic-controller-reconstructor"));
    assert!(after_native.contains("pipewireao-rtc-unrelated"));
    assert!(!after_native.contains("pipewireao-rtc-revolt-controller"));

    std::fs::write(&switch_to_julia, "switch\n").unwrap();
    wait_for_text(&mut provider.0, &hil_log, "REVOLT_HIL_JULIA_READY");

    let stop_julia_graph = temporary.join("stop-revolt-julia-graph");
    let expected_julia_disconnect = temporary.join("revolt-julia-disconnect");
    let julia_log = temporary.join("revolt-julia-graph.log");
    let log = std::fs::File::create(&julia_log).expect("REVOLT Julia graph log");
    let mut command = command_with_environment("julia", environment);
    command.env(
        "JULIA_LOAD_PATH",
        format!("{}:@:@stdlib", pipewireao_julia.display()),
    );
    let julia_provider = command
        .args([
            "--startup-file=no",
            "--threads=2",
            &format!(
                "--project={}",
                julia_filter_graph.join("deployment").display()
            ),
        ])
        .arg(repository.join("tests/live_private_core/revolt_julia_graph_provider.jl"))
        .args([
            core_name,
            julia_graph.to_str().expect("UTF-8 Julia graph path"),
            stop_julia_graph
                .to_str()
                .expect("UTF-8 Julia stop-file path"),
            "pipewireao-rtc-revolt-controller",
            expected_julia_disconnect
                .to_str()
                .expect("UTF-8 expected disconnect file"),
        ])
        .stdout(Stdio::from(log.try_clone().unwrap()))
        .stderr(Stdio::from(log))
        .spawn()
        .expect("start REVOLT JuliaFilterGraph provider");
    let mut julia_provider = ChildGuard(julia_provider);
    wait_for_text(
        &mut julia_provider.0,
        &julia_log,
        "REVOLT_JULIA_GRAPH_READY",
    );
    wait_for_dump(
        pipewire_build,
        environment,
        core_name,
        "pipewireao-rtc-revolt-controller",
    );

    let adapter = LiveGraphAdapter::connect(core_name).expect("connect Julia REVOLT session");
    let mut runner = Runner::new(adapter);
    assert_eq!(
        runner
            .dispatch(LifecycleEvent::Load(ConfigurationInput::File(
                repository.join("fixtures/revolt-classic-julia-development.conf"),
            )))
            .unwrap(),
        LifecycleState::Ready,
        "Julia REVOLT load diagnostic: {:?}",
        runner.diagnostic(),
    );
    assert_eq!(runner.executor().status().owned_nodes, 1);
    assert_eq!(runner.executor().status().owned_links, 3);
    assert_eq!(
        runner.dispatch(LifecycleEvent::Start).unwrap(),
        LifecycleState::Running,
        "Julia REVOLT start diagnostic: {:?}; provider log: {}",
        runner.diagnostic(),
        std::fs::read_to_string(&julia_log).unwrap_or_else(|error| error.to_string()),
    );
    std::fs::write(&julia_phase_1, "run\n").unwrap();
    wait_for_text_with_runner(
        &mut provider.0,
        &hil_log,
        "REVOLT_HIL_JULIA_PHASE_1_DONE sequence=4",
        &mut runner,
    );
    assert_eq!(
        runner.dispatch(LifecycleEvent::Stop).unwrap(),
        LifecycleState::Ready,
    );
    let julia_generations = apply_revolt_runtime_property_update(&mut runner, "reconstruct");
    assert_eq!(
        runner.dispatch(LifecycleEvent::Start).unwrap(),
        LifecycleState::Running,
        "Julia REVOLT restart diagnostic: {:?}; provider log: {}; HIL log: {}",
        runner.diagnostic(),
        std::fs::read_to_string(&julia_log).unwrap_or_default(),
        std::fs::read_to_string(&hil_log).unwrap_or_default(),
    );
    std::fs::write(&julia_phase_2, "run\n").unwrap();
    wait_for_text_with_runner(
        &mut provider.0,
        &hil_log,
        "REVOLT_HIL_JULIA_PHASE_2_FIRST_DONE sequence=5",
        &mut runner,
    );
    assert_revolt_property_update_active(&mut runner, julia_generations.0, -0.1, 0.9);
    apply_revolt_runtime_parameter_update(
        &mut runner,
        &environment["PIPEWIREAO_RTC_PARAMETER_REVOLT"],
        "reconstructor",
    );
    std::fs::write(&julia_phase_2_continue, "run\n").unwrap();
    wait_for_text_with_runner(
        &mut provider.0,
        &hil_log,
        "REVOLT_HIL_JULIA_PARAMETER_DONE sequence=8",
        &mut runner,
    );
    assert_eq!(
        runner.dispatch(LifecycleEvent::Stop).unwrap(),
        LifecycleState::Ready,
    );
    let julia_second_property = apply_revolt_final_property_update(&mut runner);
    assert_eq!(
        runner.dispatch(LifecycleEvent::Start).unwrap(),
        LifecycleState::Running,
    );
    std::fs::write(&julia_phase_3, "run\n").unwrap();
    wait_for_text_with_runner(
        &mut provider.0,
        &hil_log,
        "REVOLT_HIL_JULIA_DONE sequence=10",
        &mut runner,
    );
    assert_revolt_property_update_active(&mut runner, julia_second_property, -0.05, 0.8);
    if let Some(latency) = latency {
        wait_for_text_with_runner(
            &mut provider.0,
            &hil_log,
            &format!(
                "REVOLT_HIL_JULIA_LATENCY_READY warmup={} samples={}",
                latency.warmup, latency.samples
            ),
            &mut runner,
        );
        std::fs::write(&julia_latency_phase, "run\n").unwrap();
        wait_for_text_with_runner(
            &mut provider.0,
            &hil_log,
            &format!("REVOLT_HIL_JULIA_LATENCY_DONE samples={}", latency.samples),
            &mut runner,
        );
        assert_revolt_latency_csv(latency, "julia");
    }
    assert_revolt_runtime_update_active(&runner, "reconstruct", julia_generations);
    if latency.is_none() {
        std::fs::write(&julia_source_end, "end\n").unwrap();
        wait_for_text_with_runner(
            &mut provider.0,
            &hil_log,
            "REVOLT_HIL_JULIA_SOURCE_END sequence=10 commands=10",
            &mut runner,
        );
        assert_eq!(
            runner
                .dispatch(LifecycleEvent::FiniteSourceCompleted)
                .unwrap(),
            LifecycleState::Ready,
        );
        assert!(runner.diagnostic().is_none());
        assert_eq!(
            runner.poll_required_objects().unwrap(),
            LifecycleState::Ready
        );
        std::fs::write(&julia_after_ready, "check\n").unwrap();
        wait_for_text(
            &mut provider.0,
            &hil_log,
            "REVOLT_HIL_JULIA_READY_END_CHECK sequence=10",
        );
        let after_end = dump(pipewire_build, environment, core_name);
        assert!(after_end.contains("revolt-classic-sim-wfs"));
        assert!(after_end.contains("revolt-classic-sim-hsdm277-command"));
        assert_eq!(
            std::fs::read_to_string(&hil_log)
                .unwrap()
                .matches("REVOLT_HIL_FRAME_EXCHANGED implementation=julia")
                .count(),
            10,
        );
    } else {
        assert_eq!(
            runner.dispatch(LifecycleEvent::Stop).unwrap(),
            LifecycleState::Ready,
        );
    }
    assert_eq!(
        runner.dispatch(LifecycleEvent::Unload).unwrap(),
        LifecycleState::Offline,
    );
    std::fs::write(&expected_julia_disconnect, "RTC unloaded\n").unwrap();
    let after_julia = dump(pipewire_build, environment, core_name);
    assert!(after_julia.contains("revolt-classic-sim-wfs"));
    assert!(after_julia.contains("revolt-classic-sim-hsdm277-command"));
    assert!(!after_julia.contains("revolt-classic-controller-reconstructor"));
    assert!(after_julia.contains("pipewireao-rtc-revolt-controller"));
    assert!(after_julia.contains("pipewireao-rtc-unrelated"));

    stop_provider(
        &mut julia_provider,
        &stop_julia_graph,
        &julia_log,
        "REVOLT Julia graph",
    );
    wait_for_dump_absent(
        pipewire_build,
        environment,
        core_name,
        "pipewireao-rtc-revolt-controller",
    );
    stop_provider(&mut provider, &stop_hil, &hil_log, "REVOLT HIL");
    wait_for_dump_absent(
        pipewire_build,
        environment,
        core_name,
        "revolt-classic-sim-wfs",
    );
    wait_for_dump_absent(
        pipewire_build,
        environment,
        core_name,
        "revolt-classic-sim-hsdm277-command",
    );
    wait_for_dump_absent(
        pipewire_build,
        environment,
        core_name,
        "revolt-classic-controller-reconstructor",
    );
}

fn assert_revolt_latency_csv(latency: &RevoltLatencyCollection, implementation: &str) {
    let contents = std::fs::read_to_string(&latency.csv).unwrap_or_else(|error| {
        panic!(
            "read {implementation} REVOLT latency CSV {}: {error}",
            latency.csv.display()
        )
    });
    let mut previous_sequence = None;
    let mut warmup = 0_u64;
    let mut measurements = 0_u64;
    let mut expected_observation = 1_u64;
    let expected_header =
        "implementation,phase,observation,sequence,source_published_ns,command_received_ns,latency_ns";
    assert_eq!(
        contents.lines().next(),
        Some(expected_header),
        "unexpected REVOLT latency CSV header"
    );
    for line in contents.lines().skip(1) {
        let fields: Vec<_> = line.split(',').collect();
        assert_eq!(fields.len(), 7, "malformed REVOLT latency record: {line}");
        if fields[0] != implementation {
            continue;
        }
        let phase = fields[1];
        let observation = fields[2]
            .parse::<u64>()
            .expect("REVOLT latency observation index");
        let sequence = fields[3].parse::<u64>().expect("REVOLT latency sequence");
        let source = fields[4]
            .parse::<u64>()
            .expect("REVOLT source publication timestamp");
        let received = fields[5]
            .parse::<u64>()
            .expect("REVOLT command receipt timestamp");
        let elapsed = fields[6].parse::<u64>().expect("REVOLT latency");
        assert_eq!(
            observation, expected_observation,
            "non-contiguous observation index"
        );
        assert!(
            previous_sequence.map_or(true, |previous| sequence > previous),
            "non-increasing {implementation} sequence {sequence}"
        );
        assert!(
            received >= source,
            "command receipt preceded source publication for sequence {sequence}"
        );
        assert_eq!(
            elapsed,
            received - source,
            "inconsistent latency for sequence {sequence}"
        );
        match phase {
            "warmup" => warmup += 1,
            "measurement" => measurements += 1,
            _ => panic!("unknown REVOLT latency phase {phase:?}"),
        }
        previous_sequence = Some(sequence);
        expected_observation += 1;
    }
    assert_eq!(warmup, latency.warmup, "{implementation} warmup records");
    assert_eq!(
        measurements, latency.samples,
        "{implementation} measurement records"
    );
}

#[test]
fn revolt_latency_csv_requires_sequence_correlated_warmup_and_measurements() {
    let temporary = tempfile::tempdir().expect("latency CSV directory");
    let csv = temporary.path().join("revolt.csv");
    std::fs::write(
        &csv,
        concat!(
            "implementation,phase,observation,sequence,source_published_ns,command_received_ns,latency_ns\n",
            "native,warmup,1,9,100,120,20\n",
            "native,measurement,2,10,200,260,60\n",
            "julia,warmup,1,9,100,130,30\n",
            "julia,measurement,2,10,200,280,80\n",
        ),
    )
    .expect("write latency CSV");
    let latency = RevoltLatencyCollection {
        warmup: 1,
        samples: 1,
        csv,
    };
    assert_revolt_latency_csv(&latency, "native");
    assert_revolt_latency_csv(&latency, "julia");
}

fn apply_revolt_runtime_property_update(
    runner: &mut Runner<LiveGraphAdapter>,
    parameter_node: &str,
) -> (
    pipewireao_rtc::PropertyGeneration,
    pipewireao_rtc::ParameterGeneration,
) {
    let graph = "pipewireao-rtc-revolt-controller";
    let property_before = runner
        .executor()
        .observe_property_generation(graph, "integrate")
        .expect("observe REVOLT property generation before update");
    let parameter_before = runner
        .executor()
        .observe_parameter_generation(graph, parameter_node)
        .expect("observe REVOLT parameter generation before update");
    assert_eq!(
        runner.dispatch(LifecycleEvent::Reset).unwrap(),
        LifecycleState::Ready,
        "REVOLT reset diagnostic: {:?}",
        runner.diagnostic()
    );
    assert_eq!(
        runner
            .dispatch(LifecycleEvent::UpdateProperties {
                graph: graph.to_owned(),
                values: BTreeMap::from([
                    ("integrate:gain".to_owned(), ScalarValue::float(-0.1)),
                    ("integrate:pole".to_owned(), ScalarValue::float(0.9)),
                ]),
            })
            .unwrap(),
        LifecycleState::Ready,
        "REVOLT property update diagnostic: {:?}",
        runner.diagnostic()
    );
    (property_before, parameter_before)
}

fn apply_revolt_final_property_update(
    runner: &mut Runner<LiveGraphAdapter>,
) -> pipewireao_rtc::PropertyGeneration {
    let graph = "pipewireao-rtc-revolt-controller";
    let before = runner
        .executor()
        .observe_property_generation(graph, "integrate")
        .expect("observe property generation before second REVOLT update");
    assert_eq!(
        runner
            .dispatch(LifecycleEvent::UpdateProperties {
                graph: graph.to_owned(),
                values: BTreeMap::from([
                    ("integrate:gain".to_owned(), ScalarValue::float(-0.05)),
                    ("integrate:pole".to_owned(), ScalarValue::float(0.8)),
                ]),
            })
            .unwrap(),
        LifecycleState::Ready,
        "second REVOLT property update diagnostic: {:?}",
        runner.diagnostic(),
    );
    before
}

fn apply_revolt_runtime_parameter_update(
    runner: &mut Runner<LiveGraphAdapter>,
    parameter_path: &Path,
    parameter_name: &str,
) {
    let graph = "pipewireao-rtc-revolt-controller";
    let initial = std::fs::read(parameter_path).expect("read calibrated REVOLT reconstructor");
    assert_eq!(initial.len() % size_of::<f32>(), 0);
    let mut scaled = Vec::with_capacity(initial.len());
    for value in initial.chunks_exact(size_of::<f32>()) {
        let value = f32::from_le_bytes(value.try_into().unwrap()) * 0.5;
        scaled.extend_from_slice(&value.to_le_bytes());
    }
    assert_eq!(
        runner
            .dispatch(LifecycleEvent::UpdateParameter {
                graph: graph.to_owned(),
                parameter: parameter_name.to_owned(),
                value: NdArrayParameterValue {
                    element_type: "F32_LE".to_owned(),
                    shape: vec![277, 376],
                    schema: "org.calculon.ao.shwfs-reconstructor/1".to_owned(),
                    bytes: scaled,
                },
            })
            .unwrap(),
        LifecycleState::Running,
        "REVOLT parameter update diagnostic: {:?}",
        runner.diagnostic()
    );
}

fn assert_revolt_property_update_active(
    runner: &mut Runner<LiveGraphAdapter>,
    before: pipewireao_rtc::PropertyGeneration,
    gain: f32,
    pole: f32,
) {
    for _ in 0..1_000 {
        assert_eq!(
            runner.poll_required_objects().unwrap(),
            LifecycleState::Running
        );
        let after = runner
            .executor()
            .observe_property_generation("pipewireao-rtc-revolt-controller", "integrate")
            .expect("observe active REVOLT gain after the first restart frame");
        if after.requested > before.requested && after.active == Some(after.requested) {
            let values = runner
                .executor()
                .observe_properties("pipewireao-rtc-revolt-controller")
                .expect("observe active REVOLT gain and pole");
            assert_eq!(
                values.get("integrate:gain"),
                Some(&ScalarValue::float(gain))
            );
            assert_eq!(
                values.get("integrate:pole"),
                Some(&ScalarValue::float(pole))
            );
            return;
        }
        std::thread::sleep(Duration::from_millis(5));
    }
    panic!("REVOLT gain was not reported active after the first restart frame");
}

fn assert_revolt_runtime_update_active(
    runner: &Runner<LiveGraphAdapter>,
    parameter_node: &str,
    before: (
        pipewireao_rtc::PropertyGeneration,
        pipewireao_rtc::ParameterGeneration,
    ),
) {
    let graph = "pipewireao-rtc-revolt-controller";
    let property_after = runner
        .executor()
        .observe_property_generation(graph, "integrate")
        .expect("observe active REVOLT property generation");
    assert_eq!(property_after.requested, before.0.requested + 2);
    assert_eq!(property_after.active, Some(property_after.requested));
    let parameter_after = runner
        .executor()
        .observe_parameter_generation(graph, parameter_node)
        .expect("observe active REVOLT parameter generation");
    assert!(parameter_after.requested > before.1.requested);
    assert_eq!(parameter_after.active, parameter_after.requested);
}

fn run_external_endpoint_case(
    repository: &Path,
    hil_package: &Path,
    pipewire_build: &Path,
    environment: &BTreeMap<String, PathBuf>,
    core_name: &str,
    temporary: &Path,
) {
    assert!(hil_package.join("Project.toml").is_file());
    let control = temporary.join("external-normal");
    let (mut provider, provider_log) = launch_external_provider(
        repository,
        hil_package,
        environment,
        core_name,
        &control,
        "external_hil_provider.jl",
    );
    let phase_1_request = control.join("external-hil-phase-1");
    let phase_2_request = control.join("external-hil-phase-2");
    let stop_file = control.join("stop-external-hil");
    wait_for_dump(
        pipewire_build,
        environment,
        core_name,
        "pipewireao-rtc-external-source",
    );
    wait_for_dump(
        pipewire_build,
        environment,
        core_name,
        "pipewireao-rtc-external-sink",
    );

    let adapter = LiveGraphAdapter::connect(core_name).expect("connect external-node session");
    let mut runner = Runner::new(adapter);
    assert_eq!(
        runner
            .dispatch(LifecycleEvent::Load(ConfigurationInput::File(
                repository.join("fixtures/external-development.conf"),
            )))
            .unwrap(),
        LifecycleState::Ready,
        "external load diagnostic: {:?}",
        runner.diagnostic(),
    );
    assert_eq!(runner.executor().status().owned_nodes, 1);
    assert_eq!(runner.executor().status().owned_links, 2);
    assert_eq!(
        runner.dispatch(LifecycleEvent::Start).unwrap(),
        LifecycleState::Running,
        "external start diagnostic: {:?}",
        runner.diagnostic(),
    );
    std::fs::write(&phase_1_request, "exchange\n").unwrap();
    wait_for_text(
        &mut provider.0,
        &provider_log,
        "EXTERNAL_HIL_PHASE_1_DONE sequence=3",
    );
    assert_eq!(
        runner.dispatch(LifecycleEvent::Stop).unwrap(),
        LifecycleState::Ready,
    );
    assert_eq!(
        runner.dispatch(LifecycleEvent::Start).unwrap(),
        LifecycleState::Running,
        "external restart diagnostic: {:?}",
        runner.diagnostic(),
    );
    std::fs::write(&phase_2_request, "exchange\n").unwrap();
    wait_for_text(
        &mut provider.0,
        &provider_log,
        "EXTERNAL_HIL_PHASE_2_DONE sequence=6",
    );
    assert_eq!(
        runner.dispatch(LifecycleEvent::Stop).unwrap(),
        LifecycleState::Ready,
    );
    assert_eq!(
        runner.dispatch(LifecycleEvent::Unload).unwrap(),
        LifecycleState::Offline,
    );
    let after = dump(pipewire_build, environment, core_name);
    assert!(after.contains("pipewireao-rtc-external-source"));
    assert!(after.contains("pipewireao-rtc-external-sink"));
    assert!(after.contains("pipewireao-rtc-unrelated"));
    assert!(!after.contains("pipewireao-rtc-graph"));

    stop_provider(&mut provider, &stop_file, &provider_log, "external HIL");
}

fn run_external_endpoint_fault_cases(
    repository: &Path,
    hil_package: &Path,
    pipewire_build: &Path,
    environment: &BTreeMap<String, PathBuf>,
    core_name: &str,
    temporary: &Path,
) {
    let cases = [
        EndpointFaultCase {
            label: "ready-source-loss",
            running: false,
            request_name: "close-external-hil-source",
            confirmation: "EXTERNAL_HIL_SOURCE_CLOSED",
            expected_field: "source pipewireao-rtc-external-source.node.name",
            surviving_endpoint: "pipewireao-rtc-external-sink",
        },
        EndpointFaultCase {
            label: "running-sink-loss",
            running: true,
            request_name: "close-external-hil-sink",
            confirmation: "EXTERNAL_HIL_SINK_CLOSED",
            expected_field: "sink pipewireao-rtc-external-sink.node.name",
            surviving_endpoint: "pipewireao-rtc-external-source",
        },
        EndpointFaultCase {
            label: "ready-source-format",
            running: false,
            request_name: "mutate-external-hil-source",
            confirmation: "EXTERNAL_HIL_SOURCE_MUTATED",
            expected_field: "source.ports.output_1.shape",
            surviving_endpoint: "pipewireao-rtc-external-sink",
        },
        EndpointFaultCase {
            label: "running-sink-format",
            running: true,
            request_name: "mutate-external-hil-sink",
            confirmation: "EXTERNAL_HIL_SINK_MUTATED",
            expected_field: "sink.ports.input_1.shape",
            surviving_endpoint: "pipewireao-rtc-external-source",
        },
    ];

    for case in cases {
        run_external_endpoint_fault_case(
            repository,
            hil_package,
            pipewire_build,
            environment,
            core_name,
            temporary,
            &case,
        );
    }
}

fn run_external_endpoint_fault_case(
    repository: &Path,
    hil_package: &Path,
    pipewire_build: &Path,
    environment: &BTreeMap<String, PathBuf>,
    core_name: &str,
    temporary: &Path,
    case: &EndpointFaultCase<'_>,
) {
    let control = temporary.join(case.label);
    let (mut provider, provider_log) = launch_external_provider(
        repository,
        hil_package,
        environment,
        core_name,
        &control,
        "external_contract_provider.jl",
    );
    wait_for_dump(
        pipewire_build,
        environment,
        core_name,
        "pipewireao-rtc-external-source",
    );
    wait_for_dump(
        pipewire_build,
        environment,
        core_name,
        "pipewireao-rtc-external-sink",
    );

    let adapter = LiveGraphAdapter::connect(core_name).expect("connect endpoint-fault session");
    let mut runner = Runner::new(adapter);
    assert_eq!(
        runner
            .dispatch(LifecycleEvent::Load(ConfigurationInput::File(
                repository.join("fixtures/external-development.conf"),
            )))
            .unwrap(),
        LifecycleState::Ready,
        "{} load diagnostic: {:?}",
        case.label,
        runner.diagnostic(),
    );
    if case.running {
        assert_eq!(
            runner.dispatch(LifecycleEvent::Start).unwrap(),
            LifecycleState::Running,
            "{} start diagnostic: {:?}",
            case.label,
            runner.diagnostic(),
        );
    }

    std::fs::write(control.join(case.request_name), "fault\n").unwrap();
    wait_for_text(&mut provider.0, &provider_log, case.confirmation);
    assert_eq!(
        runner.poll_required_objects().unwrap(),
        LifecycleState::Fault,
        "{} did not enter FAULT",
        case.label,
    );
    assert_eq!(
        runner.diagnostic().map(ScientificDiagnostic::field),
        Some(case.expected_field),
        "{} diagnostic: {:?}",
        case.label,
        runner.diagnostic(),
    );
    assert_eq!(
        runner.dispatch(LifecycleEvent::Unload).unwrap(),
        LifecycleState::Offline,
        "{} unload diagnostic: {:?}",
        case.label,
        runner.diagnostic(),
    );
    let after = dump(pipewire_build, environment, core_name);
    assert!(after.contains(case.surviving_endpoint));
    assert!(after.contains("pipewireao-rtc-unrelated"));
    assert!(!after.contains("pipewireao-rtc-graph"));

    stop_provider(
        &mut provider,
        &control.join("stop-external-hil"),
        &provider_log,
        case.label,
    );
}

fn run_external_endpoint_admission_failures(
    repository: &Path,
    hil_package: &Path,
    pipewire_build: &Path,
    environment: &BTreeMap<String, PathBuf>,
    core_name: &str,
    temporary: &Path,
) {
    run_missing_endpoint_retry(
        repository,
        hil_package,
        pipewire_build,
        environment,
        core_name,
        &temporary.join("external-missing"),
    );
    run_duplicate_endpoint_retry(
        repository,
        hil_package,
        pipewire_build,
        environment,
        core_name,
        temporary,
    );
}

fn run_missing_endpoint_retry(
    repository: &Path,
    hil_package: &Path,
    pipewire_build: &Path,
    environment: &BTreeMap<String, PathBuf>,
    core_name: &str,
    control: &Path,
) {
    let adapter = LiveGraphAdapter::connect(core_name).expect("connect missing-endpoint session");
    let mut runner = Runner::new(adapter);
    assert_eq!(
        runner
            .dispatch(LifecycleEvent::Load(ConfigurationInput::File(
                repository.join("fixtures/external-development.conf"),
            )))
            .unwrap(),
        LifecycleState::Fault,
    );
    assert_eq!(
        runner.diagnostic().map(ScientificDiagnostic::field),
        Some("source.node.name")
    );
    let failed_dump = dump(pipewire_build, environment, core_name);
    assert!(failed_dump.contains("pipewireao-rtc-unrelated"));
    assert!(!failed_dump.contains("pipewireao-rtc-graph"));

    let (mut provider, provider_log) = launch_external_provider(
        repository,
        hil_package,
        environment,
        core_name,
        control,
        "external_contract_provider.jl",
    );
    assert_eq!(
        runner.dispatch(LifecycleEvent::Retry).unwrap(),
        LifecycleState::Ready,
        "missing-endpoint retry diagnostic: {:?}",
        runner.diagnostic(),
    );
    assert_eq!(
        runner.dispatch(LifecycleEvent::Unload).unwrap(),
        LifecycleState::Offline,
    );
    assert_external_nodes_survive(pipewire_build, environment, core_name);
    stop_provider(
        &mut provider,
        &control.join("stop-external-hil"),
        &provider_log,
        "missing-endpoint retry",
    );
}

fn run_duplicate_endpoint_retry(
    repository: &Path,
    hil_package: &Path,
    pipewire_build: &Path,
    environment: &BTreeMap<String, PathBuf>,
    core_name: &str,
    temporary: &Path,
) {
    let primary_control = temporary.join("external-duplicate-primary");
    let duplicate_control = temporary.join("external-duplicate-second");
    let (mut primary, primary_log) = launch_external_provider(
        repository,
        hil_package,
        environment,
        core_name,
        &primary_control,
        "external_contract_provider.jl",
    );
    let (mut duplicate, duplicate_log) = launch_external_provider(
        repository,
        hil_package,
        environment,
        core_name,
        &duplicate_control,
        "external_contract_provider.jl",
    );

    let adapter = LiveGraphAdapter::connect(core_name).expect("connect duplicate-endpoint session");
    let mut runner = Runner::new(adapter);
    assert_eq!(
        runner
            .dispatch(LifecycleEvent::Load(ConfigurationInput::File(
                repository.join("fixtures/external-development.conf"),
            )))
            .unwrap(),
        LifecycleState::Fault,
    );
    assert_eq!(
        runner.diagnostic().map(ScientificDiagnostic::field),
        Some("source.node.name")
    );
    stop_provider(
        &mut duplicate,
        &duplicate_control.join("stop-external-hil"),
        &duplicate_log,
        "duplicate external HIL",
    );
    assert_eq!(
        runner.dispatch(LifecycleEvent::Retry).unwrap(),
        LifecycleState::Ready,
        "duplicate-endpoint retry diagnostic: {:?}",
        runner.diagnostic(),
    );
    assert_eq!(
        runner.dispatch(LifecycleEvent::Unload).unwrap(),
        LifecycleState::Offline,
    );
    assert_external_nodes_survive(pipewire_build, environment, core_name);
    stop_provider(
        &mut primary,
        &primary_control.join("stop-external-hil"),
        &primary_log,
        "primary external HIL",
    );
}

fn assert_external_nodes_survive(
    pipewire_build: &Path,
    environment: &BTreeMap<String, PathBuf>,
    core_name: &str,
) {
    let after = dump(pipewire_build, environment, core_name);
    assert!(after.contains("pipewireao-rtc-external-source"));
    assert!(after.contains("pipewireao-rtc-external-sink"));
    assert!(after.contains("pipewireao-rtc-unrelated"));
    assert!(!after.contains("pipewireao-rtc-graph"));
}

fn launch_external_provider(
    repository: &Path,
    hil_package: &Path,
    environment: &BTreeMap<String, PathBuf>,
    core_name: &str,
    control: &Path,
    provider_script: &str,
) -> (ChildGuard, PathBuf) {
    std::fs::create_dir_all(control).unwrap();
    let provider_log = control.join("external-hil.log");
    let log = std::fs::File::create(&provider_log).expect("external HIL log");
    let provider = command_with_environment("julia", environment)
        .args([
            "--startup-file=no",
            "--threads=2",
            &format!("--project={}", hil_package.display()),
        ])
        .arg(
            repository
                .join("tests/live_private_core")
                .join(provider_script),
        )
        .args([
            core_name,
            control.to_str().expect("UTF-8 control directory"),
        ])
        .stdout(Stdio::from(log.try_clone().unwrap()))
        .stderr(Stdio::from(log))
        .spawn()
        .expect("start external HIL provider");
    let mut provider = ChildGuard(provider);
    wait_for_text(&mut provider.0, &provider_log, "EXTERNAL_HIL_READY");
    (provider, provider_log)
}

fn stop_provider(provider: &mut ChildGuard, stop_file: &Path, log: &Path, label: &str) {
    std::fs::write(stop_file, "stop\n").unwrap();
    for _ in 0..1_000 {
        if let Some(status) = provider.0.try_wait().unwrap() {
            assert!(
                status.success(),
                "{label} provider exited with {status}; log: {}",
                std::fs::read_to_string(log).unwrap_or_default()
            );
            return;
        }
        std::thread::sleep(Duration::from_millis(10));
    }
    panic!(
        "{label} provider did not stop; log: {}",
        std::fs::read_to_string(log).unwrap()
    );
}

fn stop_julia_graph_after_unload(
    provider: &mut ChildGuard,
    stop_file: &Path,
    log: &Path,
    label: &str,
) {
    std::fs::write(stop_file.with_extension("rtc-unloaded"), "RTC unloaded\n").unwrap();
    stop_provider(provider, stop_file, log, label);
}

#[allow(clippy::too_many_lines)]
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
        "{} initial stop diagnostic: {:?}",
        case.fixture,
        runner.diagnostic()
    );
    assert_session_payloads(&runner, case);
    assert_eq!(
        runner.dispatch(LifecycleEvent::Start).unwrap(),
        LifecycleState::Running,
        "{} restart after payload observation diagnostic: {:?}",
        case.fixture,
        runner.diagnostic()
    );
    exercise_execution_groups(&mut runner, pipewire_build, environment, core_name, case);

    assert_eq!(
        runner.dispatch(LifecycleEvent::Stop).unwrap(),
        LifecycleState::Ready,
        "{} stop diagnostic: {:?}",
        case.fixture,
        runner.diagnostic()
    );
    if case.fixture == "minimal-development.conf" {
        assert_eq!(
            runner.dispatch(LifecycleEvent::Reset).unwrap(),
            LifecycleState::Ready,
            "{} reset diagnostic: {:?}",
            case.fixture,
            runner.diagnostic()
        );
        assert_eq!(
            runner
                .dispatch(LifecycleEvent::UpdateProperties {
                    graph: "pipewireao-rtc-graph".to_owned(),
                    values: BTreeMap::from([("graph:gain".to_owned(), ScalarValue::float(0.25),)]),
                })
                .unwrap(),
            LifecycleState::Ready,
            "{} property diagnostic: {:?}",
            case.fixture,
            runner.diagnostic()
        );
    }
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

fn assert_session_payloads(runner: &Runner<LiveGraphAdapter>, case: &SessionCase<'_>) {
    let Some(oracle) = case.payload_oracle else {
        return;
    };
    let observations = runner
        .executor()
        .observe_discard_payloads()
        .expect("read topology discard payload evidence");
    for &sink in case.sinks {
        let observation = observations.get(sink).unwrap_or_else(|| {
            panic!("{} did not expose payload metrics for {sink}", case.fixture)
        });
        assert_eq!(
            observation.bytes,
            observation.buffers * 2 * size_of::<f32>() as u64,
            "{} {sink} payload size",
            case.fixture
        );
        assert_eq!(
            observation.digest_bytes, observation.bytes,
            "{} {sink} digest coverage",
            case.fixture
        );
        let startup = match oracle {
            PayloadOracle::Direct => (0..LEAKY_INPUTS.len()).find_map(|phase| {
                (0..=MAX_TOPOLOGY_STARTUP_PREFIX).find_map(|prefix| {
                    (observation.payload_digest
                        == expected_leaky_digest_after_prefix(observation.buffers, phase, prefix))
                    .then_some(format!("phase={phase}, graph-prefix={prefix}"))
                })
            }),
            PayloadOracle::Serial => (0..LEAKY_INPUTS.len()).find_map(|phase| {
                (0..=MAX_TOPOLOGY_STARTUP_PREFIX).find_map(|upstream_prefix| {
                    (0..=MAX_TOPOLOGY_STARTUP_PREFIX).find_map(|downstream_prefix| {
                        (observation.payload_digest
                            == expected_serial_leaky_digest_after_prefixes(
                                observation.buffers,
                                phase,
                                upstream_prefix,
                                downstream_prefix,
                            ))
                        .then_some(format!(
                            "phase={phase}, graph-a-prefix={upstream_prefix}, graph-b-prefix={downstream_prefix}"
                        ))
                    })
                })
            }),
        };
        assert!(
            startup.is_some(),
            "{} {sink} payload does not match fixture graph arithmetic for phase 0..{} and startup prefixes 0..{MAX_TOPOLOGY_STARTUP_PREFIX}: {observation:?}",
            case.fixture,
            LEAKY_INPUTS.len() - 1,
        );
        eprintln!(
            "{} {sink} payload oracle matched {}",
            case.fixture,
            startup.unwrap()
        );
    }
}

fn expected_leaky_digest_after_prefix(buffers: u64, phase: usize, prefix: usize) -> u64 {
    let mut state = [0.0_f32; 2];
    let mut digest = FNV1A_OFFSET_BASIS;
    for index in 0..(prefix + usize::try_from(buffers).unwrap()) {
        let input = LEAKY_INPUTS[(phase + index) % LEAKY_INPUTS.len()];
        for element in 0..2 {
            state[element] = 0.75 * state[element] + 0.5 * input[element];
            if index >= prefix {
                for byte in state[element].to_le_bytes() {
                    digest ^= u64::from(byte);
                    digest = digest.wrapping_mul(1_099_511_628_211);
                }
            }
        }
    }
    digest
}

fn expected_serial_leaky_digest_after_prefixes(
    buffers: u64,
    phase: usize,
    upstream_prefix: usize,
    downstream_prefix: usize,
) -> u64 {
    let mut first_state = [0.0_f32; 2];
    let mut second_state = [0.0_f32; 2];
    let mut digest = FNV1A_OFFSET_BASIS;
    let observed_buffers = usize::try_from(buffers).unwrap();
    for index in 0..(upstream_prefix + downstream_prefix + observed_buffers) {
        let input = LEAKY_INPUTS[(phase + index) % LEAKY_INPUTS.len()];
        for element in 0..2 {
            first_state[element] = 0.75 * first_state[element] + 0.5 * input[element];
            if index >= upstream_prefix {
                second_state[element] = 0.75 * second_state[element] + 0.5 * first_state[element];
                if index >= upstream_prefix + downstream_prefix {
                    for byte in second_state[element].to_le_bytes() {
                        digest ^= u64::from(byte);
                        digest = digest.wrapping_mul(1_099_511_628_211);
                    }
                }
            }
        }
    }
    digest
}

fn assert_leaky_history(
    runner: &Runner<LiveGraphAdapter>,
    expected_inputs: impl IntoIterator<Item = usize>,
) {
    let observation = runner
        .executor()
        .observe_discard_payloads()
        .expect("read minimal graph numerical evidence")["pipewireao-rtc-sink"];
    assert_eq!(
        observation.bytes,
        observation.buffers * 2 * size_of::<f32>() as u64
    );
    assert_eq!(observation.digest_bytes, observation.bytes);
    assert_eq!(
        observation.payload_digest,
        expected_leaky_digest_for(expected_inputs),
        "native graph state did not continue across selective/session stop and restart"
    );
}

fn run_native_numerical_group_restart_case(
    repository: &Path,
    core_name: &str,
    temporary: &Path,
    environment: &BTreeMap<String, PathBuf>,
) {
    let slow_graph = temporary.join("leaky-integrator-1hz.conf");
    let graph = std::fs::read_to_string(&environment["PIPEWIREAO_RTC_GRAPH_MINIMAL"])
        .unwrap()
        .replace("rate = [ 1000 1 ]", "rate = [ 1 1 ]");
    assert!(graph.contains("rate = [ 1 1 ]"));
    std::fs::write(&slow_graph, graph).unwrap();
    let slow_fixture = temporary.join("minimal-1hz.conf");
    let fixture = std::fs::read_to_string(repository.join("fixtures/minimal-development.conf"))
        .unwrap()
        .replace("api.fits.rate = 1000/1", "api.fits.rate = 1/1")
        .replacen("\n    rate = 1000/1", "\n    rate = 1/1", 1);
    assert!(fixture.contains("api.fits.rate = 1/1"));
    std::fs::write(&slow_fixture, fixture).unwrap();

    let original_graph = std::env::var_os("PIPEWIREAO_RTC_GRAPH_MINIMAL");
    std::env::set_var("PIPEWIREAO_RTC_GRAPH_MINIMAL", &slow_graph);
    let adapter = LiveGraphAdapter::connect(core_name).expect("connect numerical restart case");
    let mut runner = Runner::new(adapter);
    assert_eq!(
        runner
            .dispatch(LifecycleEvent::Load(ConfigurationInput::File(slow_fixture)))
            .unwrap(),
        LifecycleState::Ready,
        "numerical restart load diagnostic: {:?}",
        runner.diagnostic()
    );
    assert_eq!(
        runner.dispatch(LifecycleEvent::Start).unwrap(),
        LifecycleState::Running
    );
    assert_eq!(
        runner
            .dispatch(LifecycleEvent::StopExecutionGroup("main".to_owned()))
            .unwrap(),
        LifecycleState::Running
    );
    assert_leaky_history(&runner, [0]);

    assert_eq!(
        runner
            .dispatch(LifecycleEvent::StartExecutionGroup("main".to_owned()))
            .unwrap(),
        LifecycleState::Running
    );
    assert_eq!(
        runner
            .dispatch(LifecycleEvent::StopExecutionGroup("main".to_owned()))
            .unwrap(),
        LifecycleState::Running
    );
    assert_leaky_history(&runner, [0, 0]);
    assert_eq!(
        runner.dispatch(LifecycleEvent::Stop).unwrap(),
        LifecycleState::Ready
    );
    assert_eq!(
        runner.dispatch(LifecycleEvent::Unload).unwrap(),
        LifecycleState::Offline
    );
    match original_graph {
        Some(path) => std::env::set_var("PIPEWIREAO_RTC_GRAPH_MINIMAL", path),
        None => std::env::remove_var("PIPEWIREAO_RTC_GRAPH_MINIMAL"),
    }
}

fn run_latest_hold_live_case(
    repository: &Path,
    pipewire_build: &Path,
    environment: &BTreeMap<String, PathBuf>,
    core_name: &str,
    temporary: &Path,
    pipewireao_julia: &Path,
    julia_filter_graph: &Path,
) {
    let native = run_native_latest_hold_live_case(
        repository,
        pipewire_build,
        environment,
        core_name,
        temporary,
    );
    let julia = run_julia_latest_hold_live_case(
        repository,
        pipewire_build,
        environment,
        core_name,
        temporary,
        pipewireao_julia,
        julia_filter_graph,
    );
    assert_eq!(
        native.received, julia.received,
        "native and Julia processing graphs must observe the same held-output availability"
    );
    assert_eq!(native.last_command_sequence, julia.last_command_sequence);
    assert_eq!(
        native.metrics.updates_accepted, julia.metrics.updates_accepted,
        "latest/hold accepted-update counter must not depend on the downstream graph owner"
    );
    assert_eq!(
        native.metrics.updates_rejected, julia.metrics.updates_rejected,
        "latest/hold rejected-update counter must not depend on the downstream graph owner"
    );
    assert_eq!(
        native.metrics.protocol_errors, julia.metrics.protocol_errors,
        "latest/hold protocol-error counter must not depend on the downstream graph owner"
    );
    assert_eq!(
        native.metrics.outputs_published, julia.metrics.outputs_published,
        "latest/hold output counter must not depend on the downstream graph owner"
    );
    assert_eq!(
        native.metrics.output_starvations, julia.metrics.output_starvations,
        "latest/hold starvation counter must not depend on the downstream graph owner"
    );
    assert!(native.metrics.unavailable_cycles >= 20);
    assert!(julia.metrics.unavailable_cycles >= 20);
}

#[derive(Clone, Copy, Debug, Eq, PartialEq)]
struct LatestHoldCaseResult {
    received: u32,
    last_command_sequence: u64,
    metrics: fits_discard::LatestHoldMetrics,
}

const LATEST_HOLD_SAMPLES: u32 = 10;
const LATEST_HOLD_CYCLES_PER_SAMPLE: u32 = 10;
const LATEST_HOLD_EXPECTED_OUTPUTS: u32 = LATEST_HOLD_SAMPLES * LATEST_HOLD_CYCLES_PER_SAMPLE;
const LATEST_HOLD_STEADY_START: u64 = 11;

#[allow(clippy::too_many_lines)]
fn run_native_latest_hold_live_case(
    repository: &Path,
    pipewire_build: &Path,
    environment: &BTreeMap<String, PathBuf>,
    core_name: &str,
    temporary: &Path,
) -> LatestHoldCaseResult {
    let graph = temporary.join("latest-hold-native.conf");
    write_latest_hold_graph_configuration(
        &graph,
        &environment["PIPEWIREAO_RTC_FGN_BUNDLE"],
        core_name,
    );
    let original_graph = std::env::var_os("PIPEWIREAO_RTC_GRAPH_LATEST_HOLD");
    std::env::set_var("PIPEWIREAO_RTC_GRAPH_LATEST_HOLD", &graph);
    let source = build_latest_hold_fixture_source(repository, pipewire_build, temporary);
    let log = temporary.join("latest-hold-source.log");
    let output = std::fs::File::create(&log).expect("latest/hold source log");
    let mut source = ChildGuard(
        command_with_environment(&source, environment)
            .arg(core_name)
            .stdin(Stdio::piped())
            .stdout(Stdio::from(output.try_clone().expect("clone source log")))
            .stderr(Stdio::from(output))
            .spawn()
            .expect("start deterministic latest/hold source"),
    );
    wait_for_text(&mut source.0, &log, "READY");

    let adapter = LiveGraphAdapter::connect(core_name).expect("connect latest/hold adapter");
    let mut runner = Runner::new(adapter);
    assert_eq!(
        runner
            .dispatch(LifecycleEvent::Load(ConfigurationInput::File(
                repository.join("fixtures/latest-hold-live.conf"),
            )))
            .expect("load latest/hold fixture"),
        LifecycleState::Ready,
        "latest/hold realization diagnostic: {:?}",
        runner.diagnostic()
    );
    assert_eq!(runner.executor().status().owned_nodes, 2);
    assert_eq!(runner.executor().status().owned_links, 5);
    send_latest_hold_source_command(&mut source, b'a');
    wait_for_text(&mut source.0, &log, "ACTIVE");
    assert_eq!(
        runner
            .dispatch(LifecycleEvent::Start)
            .expect("start latest/hold"),
        LifecycleState::Running,
        "latest/hold start diagnostic: {:?}",
        runner.diagnostic()
    );
    assert!(
        dump(pipewire_build, environment, core_name).contains("PipeWireAO-RTC-Dummy-Driver"),
        "latest/hold fixture requires its private Dummy Driver"
    );
    send_latest_hold_source_command(&mut source, b's');
    wait_for_text(&mut source.0, &log, "STARTED");
    let progress = wait_for_latest_hold_progress(&mut source, &log, 120);
    assert_eq!(
        progress.data, LATEST_HOLD_SAMPLES,
        "source must publish only the configured identities"
    );
    assert_eq!(
        (
            progress.position_rate_num,
            progress.position_rate_denom,
            progress.position_quantum
        ),
        (1, 1000, 1),
        "native fixture must follow the Dummy Driver's 1/1000 Position cadence: {progress:?}"
    );
    assert!(
        progress.primary >= progress.cycles,
        "the primary source must own every fast driver cycle"
    );
    assert_eq!(
        progress.empty + progress.data,
        progress.cycles,
        "every non-publication fast cycle must leave source output empty"
    );
    let metrics = fits_discard::latest_hold_metrics(core_name, "pipewireao-rtc-latest-hold");
    assert_eq!(
        progress.received, LATEST_HOLD_EXPECTED_OUTPUTS,
        "hold must publish each retained value ten times: {progress:?}, {metrics:?}\nsource log: {}\nprivate core log: {}",
        std::fs::read_to_string(&log).unwrap_or_default(),
        private_core_log(&log),
    );
    assert_eq!(
        u64::from(progress.commands),
        progress.last_command_sequence - progress.first_command_sequence + 1,
        "native FGN command identities must form one contiguous suffix: {progress:?}"
    );
    assert!(
        progress.first_command_sequence <= LATEST_HOLD_STEADY_START,
        "native FGN must publish every command after the designated ten-cycle startup window: {progress:?}"
    );
    assert_eq!(
        progress.last_command_sequence,
        u64::from(LATEST_HOLD_EXPECTED_OUTPUTS)
    );

    assert_eq!(metrics.updates_accepted, u64::from(LATEST_HOLD_SAMPLES));
    assert_eq!(metrics.updates_rejected, 0);
    assert_eq!(metrics.protocol_errors, 0);
    assert_eq!(
        metrics.outputs_published,
        u64::from(LATEST_HOLD_EXPECTED_OUTPUTS)
    );
    assert!(
        metrics.unavailable_cycles >= 20,
        "missing first samples and post-expiry cycles must be visible: {metrics:?}"
    );
    assert_eq!(metrics.output_starvations, 0);

    assert_eq!(
        runner
            .dispatch(LifecycleEvent::Stop)
            .expect("pause latest/hold"),
        LifecycleState::Ready
    );
    assert_eq!(
        runner
            .dispatch(LifecycleEvent::Start)
            .expect("restart latest/hold after pause"),
        LifecycleState::Running
    );
    let after_restart = wait_for_latest_hold_progress(&mut source, &log, 130);
    assert_eq!(
        after_restart.received, LATEST_HOLD_EXPECTED_OUTPUTS,
        "pause/restart must not replay expired output"
    );
    assert_eq!(
        fits_discard::latest_hold_metrics(core_name, "pipewireao-rtc-latest-hold")
            .outputs_published,
        u64::from(LATEST_HOLD_EXPECTED_OUTPUTS),
        "no backlog may appear after restart"
    );
    assert_eq!(
        runner
            .dispatch(LifecycleEvent::Stop)
            .expect("stop latest/hold"),
        LifecycleState::Ready
    );
    assert_eq!(
        runner
            .dispatch(LifecycleEvent::Unload)
            .expect("unload latest/hold"),
        LifecycleState::Offline
    );
    assert!(
        !fits_discard::node_is_visible(core_name, "pipewireao-rtc-latest-hold"),
        "RTC-owned latest/hold node survived unload"
    );
    send_latest_hold_source_command(&mut source, b'q');
    wait_for_child_exit(&mut source.0, &log, "deterministic latest/hold source");
    match original_graph {
        Some(path) => std::env::set_var("PIPEWIREAO_RTC_GRAPH_LATEST_HOLD", path),
        None => std::env::remove_var("PIPEWIREAO_RTC_GRAPH_LATEST_HOLD"),
    }
    LatestHoldCaseResult {
        received: progress.received,
        last_command_sequence: progress.last_command_sequence,
        metrics,
    }
}

#[allow(clippy::too_many_arguments, clippy::too_many_lines)]
fn run_julia_latest_hold_live_case(
    repository: &Path,
    pipewire_build: &Path,
    environment: &BTreeMap<String, PathBuf>,
    core_name: &str,
    temporary: &Path,
    pipewireao_julia: &Path,
    julia_filter_graph: &Path,
) -> LatestHoldCaseResult {
    let (mut provider, stop_file, provider_log) = launch_latest_hold_external_julia(
        repository,
        pipewire_build,
        environment,
        core_name,
        temporary,
        pipewireao_julia,
        julia_filter_graph,
    );
    let source = build_latest_hold_fixture_source(repository, pipewire_build, temporary);
    let log = temporary.join("latest-hold-julia-source.log");
    let output = std::fs::File::create(&log).expect("Julia latest/hold source log");
    let mut source = ChildGuard(
        command_with_environment(&source, environment)
            .arg(core_name)
            .stdin(Stdio::piped())
            .stdout(Stdio::from(
                output.try_clone().expect("clone Julia source log"),
            ))
            .stderr(Stdio::from(output))
            .spawn()
            .expect("start deterministic Julia latest/hold source"),
    );
    wait_for_text(&mut source.0, &log, "READY");

    let adapter = LiveGraphAdapter::connect(core_name).expect("connect Julia latest/hold adapter");
    let mut runner = Runner::new(adapter);
    assert_eq!(
        runner
            .dispatch(LifecycleEvent::Load(ConfigurationInput::File(
                repository.join("fixtures/latest-hold-julia-live.conf"),
            )))
            .expect("load Julia latest/hold fixture"),
        LifecycleState::Ready,
        "Julia latest/hold realization diagnostic: {:?}",
        runner.diagnostic()
    );
    assert_eq!(runner.executor().status().owned_nodes, 1);
    assert_eq!(runner.executor().status().owned_links, 5);
    send_latest_hold_source_command(&mut source, b'a');
    wait_for_text(&mut source.0, &log, "ACTIVE");
    assert_eq!(
        runner
            .dispatch(LifecycleEvent::Start)
            .expect("start Julia latest/hold"),
        LifecycleState::Running,
        "Julia latest/hold start diagnostic: {:?}",
        runner.diagnostic()
    );
    assert!(
        dump(pipewire_build, environment, core_name).contains("PipeWireAO-RTC-Dummy-Driver"),
        "Julia latest/hold fixture requires its private Dummy Driver"
    );
    send_latest_hold_source_command(&mut source, b's');
    wait_for_text(&mut source.0, &log, "STARTED");
    let progress = wait_for_latest_hold_progress(&mut source, &log, 120);
    assert_eq!(
        progress.data, LATEST_HOLD_SAMPLES,
        "Julia case source must publish only the configured identities"
    );
    assert_eq!(
        (
            progress.position_rate_num,
            progress.position_rate_denom,
            progress.position_quantum
        ),
        (1, 1000, 1),
        "Julia fixture must follow the Dummy Driver's 1/1000 Position cadence: {progress:?}"
    );
    assert!(
        progress.primary >= progress.cycles,
        "Julia case primary source must own every fast driver cycle"
    );
    assert_eq!(
        progress.empty + progress.data,
        progress.cycles,
        "Julia case non-publication fast cycles must leave source output empty"
    );
    let metrics = fits_discard::latest_hold_metrics(core_name, "pipewireao-rtc-latest-hold");
    assert_eq!(
        progress.received, LATEST_HOLD_EXPECTED_OUTPUTS,
        "Julia case hold must publish each retained value ten times: {progress:?}, {metrics:?}\nsource log: {}\nprivate core log: {}",
        std::fs::read_to_string(&log).unwrap_or_default(),
        private_core_log(&log),
    );
    assert_eq!(
        u64::from(progress.commands),
        progress.last_command_sequence - progress.first_command_sequence + 1,
        "Julia command identities must form one contiguous suffix under drain-to-latest admission: {progress:?}"
    );
    assert!(
        progress.first_command_sequence <= LATEST_HOLD_STEADY_START,
        "Julia must publish every command after the designated ten-cycle startup window: {progress:?}"
    );
    assert_eq!(
        progress.last_command_sequence,
        u64::from(LATEST_HOLD_EXPECTED_OUTPUTS)
    );

    assert_eq!(metrics.updates_accepted, u64::from(LATEST_HOLD_SAMPLES));
    assert_eq!(metrics.updates_rejected, 0);
    assert_eq!(metrics.protocol_errors, 0);
    assert_eq!(
        metrics.outputs_published,
        u64::from(LATEST_HOLD_EXPECTED_OUTPUTS)
    );
    assert!(
        metrics.unavailable_cycles >= 20,
        "Julia case missing first samples and post-expiry cycles must be visible: {metrics:?}"
    );
    assert_eq!(metrics.output_starvations, 0);

    assert_eq!(
        runner
            .dispatch(LifecycleEvent::Stop)
            .expect("pause Julia latest/hold"),
        LifecycleState::Ready
    );
    assert_eq!(
        runner
            .dispatch(LifecycleEvent::Start)
            .expect("restart Julia latest/hold after pause"),
        LifecycleState::Running
    );
    let after_restart = wait_for_latest_hold_progress(&mut source, &log, 130);
    assert_eq!(
        after_restart.received, LATEST_HOLD_EXPECTED_OUTPUTS,
        "Julia pause/restart must not replay expired output"
    );
    assert_eq!(
        fits_discard::latest_hold_metrics(core_name, "pipewireao-rtc-latest-hold")
            .outputs_published,
        u64::from(LATEST_HOLD_EXPECTED_OUTPUTS),
        "Julia pause/restart must not create a backlog"
    );
    assert_eq!(
        runner
            .dispatch(LifecycleEvent::Stop)
            .expect("stop Julia latest/hold"),
        LifecycleState::Ready
    );
    assert_eq!(
        runner
            .dispatch(LifecycleEvent::Unload)
            .expect("unload Julia latest/hold"),
        LifecycleState::Offline
    );
    assert!(
        !fits_discard::node_is_visible(core_name, "pipewireao-rtc-latest-hold"),
        "RTC-owned Julia latest/hold node survived unload"
    );
    assert!(
        fits_discard::node_is_visible(core_name, "pipewireao-rtc-latest-hold-graph"),
        "runner unload must not destroy the externally owned Julia graph"
    );
    stop_julia_graph_after_unload(
        &mut provider,
        &stop_file,
        &provider_log,
        "Julia latest/hold graph",
    );
    wait_for_dump_absent(
        pipewire_build,
        environment,
        core_name,
        "pipewireao-rtc-latest-hold-graph",
    );
    send_latest_hold_source_command(&mut source, b'q');
    wait_for_child_exit(
        &mut source.0,
        &log,
        "deterministic Julia latest/hold source",
    );
    LatestHoldCaseResult {
        received: progress.received,
        last_command_sequence: progress.last_command_sequence,
        metrics,
    }
}

#[derive(Clone, Copy, Debug)]
struct LatestHoldProgress {
    cycles: u32,
    primary: u32,
    data: u32,
    empty: u32,
    received: u32,
    commands: u32,
    first_command_sequence: u64,
    last_command_sequence: u64,
    position_rate_num: u32,
    position_rate_denom: u32,
    position_quantum: u32,
}

fn build_latest_hold_fixture_source(
    repository: &Path,
    pipewire_build: &Path,
    temporary: &Path,
) -> PathBuf {
    let pkg_config = pipewire_build.join("meson-uninstalled");
    let flags = Command::new("pkg-config")
        .env("PKG_CONFIG_PATH", &pkg_config)
        .args(["--cflags", "--libs", "libpipewire-ao-0.3"])
        .output()
        .expect("run pkg-config for deterministic latest/hold source");
    assert!(
        flags.status.success(),
        "pkg-config could not describe maintained PipeWire build {}: {}",
        pkg_config.display(),
        String::from_utf8_lossy(&flags.stderr)
    );
    let binary = temporary.join("latest-hold-slow-source");
    let compilation = Command::new("cc")
        .args(["-std=c11", "-Wall", "-Wextra", "-Werror"])
        .arg(repository.join("tests/fixtures/latest_hold_slow_source.c"))
        .arg("-o")
        .arg(&binary)
        .args(
            String::from_utf8(flags.stdout)
                .expect("UTF-8 pkg-config flags")
                .split_whitespace(),
        )
        .arg(format!(
            "-Wl,-rpath,{}",
            pipewire_build.join("src/pipewire").display()
        ))
        .output()
        .expect("compile deterministic latest/hold source");
    assert!(
        compilation.status.success(),
        "could not compile deterministic latest/hold source: {}",
        String::from_utf8_lossy(&compilation.stderr)
    );
    binary
}

fn send_latest_hold_source_command(source: &mut ChildGuard, command: u8) {
    source
        .0
        .stdin
        .as_mut()
        .expect("deterministic latest/hold source stdin")
        .write_all(&[command])
        .expect("send deterministic latest/hold source command");
    source
        .0
        .stdin
        .as_mut()
        .expect("deterministic latest/hold source stdin")
        .flush()
        .expect("flush deterministic latest/hold source command");
}

fn wait_for_latest_hold_progress(
    source: &mut ChildGuard,
    log: &Path,
    minimum_cycles: u32,
) -> LatestHoldProgress {
    let deadline = Instant::now() + Duration::from_secs(5);
    while Instant::now() < deadline {
        assert!(
            source
                .0
                .try_wait()
                .expect("poll deterministic latest/hold source")
                .is_none(),
            "deterministic latest/hold source exited early: {}",
            std::fs::read_to_string(log).unwrap_or_default()
        );
        send_latest_hold_source_command(source, b'p');
        std::thread::sleep(Duration::from_millis(5));
        if let Some(progress) = latest_hold_progress(log) {
            if progress.cycles >= minimum_cycles
                && progress.received >= LATEST_HOLD_EXPECTED_OUTPUTS
                && progress.last_command_sequence >= u64::from(LATEST_HOLD_EXPECTED_OUTPUTS)
            {
                return progress;
            }
        }
    }
    panic!(
        "deterministic latest/hold source did not reach {minimum_cycles} fast cycles, {} held outputs, and the final command identity: {}\nprivate core log: {}",
        LATEST_HOLD_EXPECTED_OUTPUTS,
        std::fs::read_to_string(log).unwrap_or_default(),
        private_core_log(log),
    );
}

fn latest_hold_progress(log: &Path) -> Option<LatestHoldProgress> {
    std::fs::read_to_string(log)
        .ok()?
        .lines()
        .rev()
        .find_map(|line| {
            let values = line
                .strip_prefix("PROGRESS ")?
                .split_whitespace()
                .collect::<Vec<_>>();
            if values.len() != 10 {
                return None;
            }
            let parse = |field: &str, value: &str| value.strip_prefix(field)?.parse().ok();
            let parse_u64 =
                |field: &str, value: &str| value.strip_prefix(field)?.parse::<u64>().ok();
            let (position_rate_num, position_rate_denom) =
                values[8].strip_prefix("rate=")?.split_once('/')?;
            Some(LatestHoldProgress {
                cycles: parse("cycles=", values[0])?,
                primary: parse("primary=", values[1])?,
                data: parse("data=", values[2])?,
                empty: parse("empty=", values[3])?,
                received: parse("received=", values[4])?,
                commands: parse("commands=", values[5])?,
                first_command_sequence: parse_u64("first=", values[6])?,
                last_command_sequence: parse_u64("last=", values[7])?,
                position_rate_num: position_rate_num.parse().ok()?,
                position_rate_denom: position_rate_denom.parse().ok()?,
                position_quantum: parse("quantum=", values[9])?,
            })
        })
}

fn wait_for_child_exit(child: &mut Child, log: &Path, label: &str) {
    let deadline = Instant::now() + Duration::from_secs(5);
    while Instant::now() < deadline {
        if let Some(status) = child.try_wait().expect("wait for fixture process") {
            assert!(
                status.success(),
                "{label} failed: {}",
                std::fs::read_to_string(log).unwrap_or_default()
            );
            return;
        }
        std::thread::sleep(Duration::from_millis(5));
    }
    panic!(
        "{label} did not exit: {}",
        std::fs::read_to_string(log).unwrap_or_default()
    );
}

fn run_finite_source_completion_case(
    repository: &Path,
    pipewire_build: &Path,
    environment: &BTreeMap<String, PathBuf>,
    core_name: &str,
    temporary: &Path,
) {
    let fixture = write_finite_fixture(repository, temporary, "finite-source-development", 1000);

    let adapter = LiveGraphAdapter::connect(core_name).expect("connect finite-source adapter");
    let mut runner = Runner::new(adapter);
    assert_eq!(
        runner
            .dispatch(LifecycleEvent::Load(ConfigurationInput::File(fixture)))
            .expect("load finite-source fixture"),
        LifecycleState::Ready,
        "finite-source realization diagnostic: {:?}",
        runner.diagnostic()
    );
    assert_eq!(
        runner
            .dispatch(LifecycleEvent::Start)
            .expect("start finite source"),
        LifecycleState::Running,
        "finite-source start diagnostic: {:?}",
        runner.diagnostic()
    );
    for _ in 0..200 {
        let state = runner
            .poll_required_objects()
            .expect("poll finite source completion");
        if state == LifecycleState::Ready {
            break;
        }
        std::thread::sleep(Duration::from_millis(5));
    }
    assert_eq!(
        runner.state(),
        LifecycleState::Ready,
        "finite FITS source did not return the session to READY: {:?}; dump: {}",
        runner.diagnostic(),
        dump(pipewire_build, environment, core_name)
    );
    let completed_counts = runner
        .executor_mut()
        .observe_discarded_buffers()
        .expect("refresh finite-source discard evidence");
    assert_eq!(completed_counts["pipewireao-rtc-sink"], 4);
    let observation = runner
        .executor()
        .observe_discard_payloads()
        .expect("read finite-source output evidence")["pipewireao-rtc-sink"];
    assert_eq!(observation.buffers, 4);
    assert_eq!(observation.bytes, 4 * 2 * size_of::<f32>() as u64);
    assert_eq!(observation.digest_bytes, observation.bytes);
    assert_eq!(observation.payload_digest, expected_leaky_digest(4));
    assert_eq!(
        runner
            .dispatch(LifecycleEvent::Unload)
            .expect("unload finite source"),
        LifecycleState::Offline
    );
    let unloaded = dump(pipewire_build, environment, core_name);
    assert!(unloaded.contains("pipewireao-rtc-unrelated"));
    for node in [
        "pipewireao-rtc-source",
        "pipewireao-rtc-graph",
        "pipewireao-rtc-sink",
    ] {
        assert!(
            !unloaded.contains(node),
            "finite fixture node survived: {node}"
        );
    }
}

fn run_live_creation_failure_matrix(
    repository: &Path,
    pipewire_build: &Path,
    environment: &BTreeMap<String, PathBuf>,
    core_name: &str,
) {
    let fixture = repository.join("fixtures/minimal-development.conf");
    let owned_names = [
        "pipewireao-rtc-source",
        "pipewireao-rtc-graph",
        "pipewireao-rtc-sink",
    ];
    for point in 1..=5 {
        let adapter = LiveGraphAdapter::connect_with_creation_failure(core_name, point)
            .expect("connect failure-injection adapter");
        let mut runner = Runner::new(adapter);
        assert_eq!(
            runner
                .dispatch(LifecycleEvent::Load(ConfigurationInput::File(
                    fixture.clone(),
                )))
                .expect("dispatch injected live failure"),
            LifecycleState::Fault
        );
        let diagnostic = runner.diagnostic().expect("injected live diagnostic");
        assert!(
            diagnostic
                .message()
                .contains(&format!("creation point {point}")),
            "unexpected failure-point {point} diagnostic: {diagnostic}"
        );
        assert_eq!(runner.executor().status().owned_nodes, 0);
        assert_eq!(runner.executor().status().owned_links, 0);
        let after_failure = dump(pipewire_build, environment, core_name);
        assert!(after_failure.contains("pipewireao-rtc-unrelated"));
        for name in owned_names {
            assert!(
                !after_failure.contains(name),
                "creation-point {point} left {name} behind"
            );
        }

        assert_eq!(
            runner
                .dispatch(LifecycleEvent::Retry)
                .expect("retry after live creation failure"),
            LifecycleState::Ready,
            "creation-point {point} retry diagnostic: {:?}",
            runner.diagnostic()
        );
        assert_eq!(
            runner
                .dispatch(LifecycleEvent::Unload)
                .expect("unload creation-failure retry"),
            LifecycleState::Offline
        );
        let after_retry = dump(pipewire_build, environment, core_name);
        assert!(after_retry.contains("pipewireao-rtc-unrelated"));
        for name in owned_names {
            assert!(
                !after_retry.contains(name),
                "creation-point {point} retry left {name} behind"
            );
        }
    }
}

fn exercise_execution_groups(
    runner: &mut Runner<LiveGraphAdapter>,
    pipewire_build: &Path,
    environment: &BTreeMap<String, PathBuf>,
    core_name: &str,
    case: &SessionCase<'_>,
) {
    for &(group, sink) in case.groups {
        let before_stop = runner
            .executor_mut()
            .observe_discarded_buffers()
            .expect("observe counters before execution-group stop");
        assert_eq!(
            runner
                .dispatch(LifecycleEvent::StopExecutionGroup(group.to_owned()))
                .unwrap(),
            LifecycleState::Running,
            "{} {group} stop diagnostic: {:?}",
            case.fixture,
            runner.diagnostic()
        );
        let stopped = runner.executor().status();
        assert_eq!(
            runner.execution_group_states()[group],
            ExecutionGroupState::Stopped
        );
        assert_eq!(stopped.owned_nodes, case.nodes.len());
        assert_eq!(stopped.owned_links, case.links);
        for &(other, _) in case.groups {
            if other != group {
                assert_eq!(
                    runner.execution_group_states()[other],
                    ExecutionGroupState::Running
                );
            }
        }
        let stopped_dump = dump(pipewire_build, environment, core_name);
        for node in case.nodes {
            assert!(stopped_dump.contains(node));
        }

        let at_stop = runner
            .executor_mut()
            .observe_discarded_buffers()
            .expect("observe stopped execution group");
        std::thread::sleep(Duration::from_millis(20));
        let after_wait = runner
            .executor_mut()
            .observe_discarded_buffers()
            .expect("observe branch isolation");
        assert_eq!(
            after_wait[sink], at_stop[sink],
            "{} {group} continued processing after stop",
            case.fixture
        );
        for &(other, other_sink) in case.groups {
            if other != group {
                assert!(
                    after_wait[other_sink] > at_stop[other_sink],
                    "{} stopping {group} stalled {other}: before={at_stop:?} after={after_wait:?}",
                    case.fixture
                );
            }
        }

        assert_eq!(
            runner
                .dispatch(LifecycleEvent::StartExecutionGroup(group.to_owned()))
                .unwrap(),
            LifecycleState::Running,
            "{} {group} restart diagnostic: {:?}",
            case.fixture,
            runner.diagnostic()
        );
        let restarted_group = runner
            .executor_mut()
            .observe_discarded_buffers()
            .expect("observe restarted execution group");
        assert!(restarted_group[sink] > before_stop[sink]);
        assert_eq!(
            runner.execution_group_states()[group],
            ExecutionGroupState::Running
        );
    }
}

fn write_graph_configuration(
    path: &Path,
    fgn_bundle: &Path,
    remote_name: &str,
    node_name: &str,
    input_schema: &str,
    output_schema: &str,
) {
    let graph = include_str!("../fixtures/graphs/leaky-integrator.conf.in")
        .replace("@FGN_BUNDLE@", &fgn_bundle.display().to_string())
        .replace("@REMOTE_NAME@", remote_name)
        .replace("@NODE_NAME@", node_name)
        .replace("@INPUT_SCHEMA@", input_schema)
        .replace("@OUTPUT_SCHEMA@", output_schema);
    std::fs::write(path, graph).expect("materialize standard filter.graph configuration");
}

fn write_latest_hold_graph_configuration(path: &Path, fgn_bundle: &Path, remote_name: &str) {
    let graph = include_str!("fixtures/latest-hold-two-input.conf.in")
        .replace("@FGN_BUNDLE@", &fgn_bundle.display().to_string())
        .replace("@REMOTE_NAME@", remote_name)
        .replace("@NODE_NAME@", "pipewireao-rtc-latest-hold-graph");
    std::fs::write(path, graph).expect("materialize two-input latest/hold FGN configuration");
}

fn fixture_environment(
    runtime: &Path,
    config_directory: &Path,
    pipewire_build: &Path,
    plugin_build: &Path,
) -> BTreeMap<String, PathBuf> {
    let fits_plugin = std::env::var_os("PIPEWIREAO_RTC_FITS_PLUGIN").map_or_else(
        || {
            let combined = plugin_build.join("spa/plugins/fits/libspa-fits.so");
            if combined.is_file() {
                combined
            } else {
                plugin_build
                    .parent()
                    .and_then(Path::parent)
                    .expect("SPA plugin workspace")
                    .join("pipewireao-spa-plugin-fits/build/spa/plugins/fits/libspa-fits.so")
            }
        },
        PathBuf::from,
    );
    let plugin_search_path = std::env::join_paths([
        pipewire_build.join("spa/plugins"),
        plugin_build.join("spa/plugins"),
        fits_plugin
            .parent()
            .and_then(Path::parent)
            .expect("FITS plugin build directory")
            .to_owned(),
    ])
    .expect("private SPA plugin search path");
    let module_search_path = std::env::join_paths([
        pipewire_build.join("src/modules"),
        plugin_build.join("src/modules"),
    ])
    .expect("private PipeWire module search path");
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
            PathBuf::from(module_search_path),
        ),
        (
            "PIPEWIREAO_SPA_PLUGIN_DIR".to_owned(),
            PathBuf::from(plugin_search_path),
        ),
        (
            "PIPEWIREAO_NDARRAY_EXAMPLE".to_owned(),
            pipewire_build.join("spa/plugins/filter-graph/libspa-filter-graph-ndarray-example.so"),
        ),
        (
            "PIPEWIREAO_DISCARD_PLUGIN".to_owned(),
            plugin_build.join("spa/plugins/discard/libspa-pipewireao-discard.so"),
        ),
        ("PIPEWIREAO_FITS_PLUGIN".to_owned(), fits_plugin),
        (
            "PIPEWIREAO_NDARRAY_PLUGIN".to_owned(),
            plugin_build.join("spa/plugins/ndarray/libspa-ndarray.so"),
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

fn wait_for_text(process: &mut Child, log: &Path, needle: &str) {
    wait_for_text_for(process, log, needle, Duration::from_secs(300));
}

fn wait_for_text_with_runner(
    process: &mut Child,
    log: &Path,
    needle: &str,
    runner: &mut Runner<LiveGraphAdapter>,
) {
    let deadline = Instant::now() + Duration::from_secs(300);
    while Instant::now() < deadline {
        if let Some(status) = process.try_wait().unwrap() {
            panic!(
                "external process exited with {status}; log: {}\nprivate core log: {}",
                std::fs::read_to_string(log).unwrap_or_default(),
                private_core_log(log),
            );
        }
        if std::fs::read_to_string(log)
            .unwrap_or_default()
            .contains(needle)
        {
            return;
        }
        let state = runner.poll_required_objects().unwrap();
        assert_eq!(
            state,
            LifecycleState::Running,
            "required REVOLT object failed while waiting for {needle}: {:?}; provider log: {}",
            runner.diagnostic(),
            std::fs::read_to_string(log).unwrap_or_default(),
        );
        std::thread::sleep(Duration::from_millis(20));
    }
    panic!(
        "external process never reported {needle}; log: {}\nprivate core log: {}",
        std::fs::read_to_string(log).unwrap_or_default(),
        private_core_log(log),
    );
}

fn wait_for_text_for(process: &mut Child, log: &Path, needle: &str, timeout: Duration) {
    let deadline = Instant::now() + timeout;
    while Instant::now() < deadline {
        if let Some(status) = process.try_wait().unwrap() {
            panic!(
                "external process exited with {status}; log: {}\nprivate core log: {}",
                std::fs::read_to_string(log).unwrap_or_default(),
                private_core_log(log),
            );
        }
        if std::fs::read_to_string(log)
            .unwrap_or_default()
            .contains(needle)
        {
            return;
        }
        std::thread::sleep(Duration::from_millis(20));
    }
    panic!(
        "external process never reported {needle}; log: {}\nprivate core log: {}",
        std::fs::read_to_string(log).unwrap_or_default(),
        private_core_log(log),
    );
}

fn private_core_log(process_log: &Path) -> String {
    process_log
        .parent()
        .map(|directory| directory.join("diagnostics/private-core.log"))
        .and_then(|path| std::fs::read_to_string(path).ok())
        .unwrap_or_default()
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

fn wait_for_dump_absent(
    pipewire_build: &Path,
    environment: &BTreeMap<String, PathBuf>,
    core_name: &str,
    needle: &str,
) {
    let deadline = Instant::now() + Duration::from_secs(5);
    while Instant::now() < deadline {
        if !dump(pipewire_build, environment, core_name).contains(needle) {
            return;
        }
        std::thread::sleep(Duration::from_millis(20));
    }
    panic!("PipeWire dump still contains {needle:?}");
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
