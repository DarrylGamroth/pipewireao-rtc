#![cfg(feature = "live")]

#[path = "live_private_core/fits_discard.rs"]
mod fits_discard;

use pipewireao_rtc::{
    ConfigurationInput, ExecutionGroupState, LifecycleEvent, LifecycleState, LiveGraphAdapter,
    Runner, ScientificDiagnostic,
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
    groups: &'a [(&'a str, &'a str)],
}

struct EndpointFaultCase<'a> {
    label: &'a str,
    running: bool,
    request_name: &'a str,
    confirmation: &'a str,
    expected_field: &'a str,
    surviving_endpoint: &'a str,
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
    std::env::set_var("PIPEWIREAO_DEBUG", "0");

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
            groups: &[("main", "pipewireao-rtc-sink")],
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
    let stop_file = temporary.join("stop-julia-graph");
    let provider_log = temporary.join("julia-graph.log");
    let log = std::fs::File::create(&provider_log).expect("Julia graph log");
    let mut command = command_with_environment("julia", environment);
    command.env(
        "JULIA_LOAD_PATH",
        format!(
            "{}:{}:@stdlib",
            pipewireao_julia.display(),
            julia_filter_graph
                .join("julia/FilterGraphPipeWire")
                .display()
        ),
    );
    let provider = command
        .args(["--startup-file=no", "--threads=2"])
        .arg(repository.join("tests/live_private_core/julia_graph_provider.jl"))
        .args([
            core_name,
            repository
                .join("fixtures/graphs/julia-leaky-integrator.conf")
                .to_str()
                .expect("UTF-8 Julia graph configuration"),
            stop_file.to_str().expect("UTF-8 Julia stop path"),
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

    let adapter = LiveGraphAdapter::connect(core_name).expect("connect Julia graph session");
    let mut runner = Runner::new(adapter);
    assert_eq!(
        runner
            .dispatch(LifecycleEvent::Load(ConfigurationInput::File(
                repository.join("fixtures/external-graph-development.conf"),
            )))
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

    stop_provider(&mut provider, &stop_file, &provider_log, "Julia graph");
    wait_for_dump_absent(
        pipewire_build,
        environment,
        core_name,
        "pipewireao-rtc-external-graph",
    );
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
    for _ in 0..200 {
        if provider.0.try_wait().unwrap().is_some() {
            return;
        }
        std::thread::sleep(Duration::from_millis(10));
    }
    panic!(
        "{label} provider did not stop; log: {}",
        std::fs::read_to_string(log).unwrap()
    );
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

    exercise_execution_groups(&mut runner, pipewire_build, environment, core_name, case);

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

fn fixture_environment(
    runtime: &Path,
    config_directory: &Path,
    pipewire_build: &Path,
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

fn wait_for_text(process: &mut Child, log: &Path, needle: &str) {
    let deadline = Instant::now() + Duration::from_secs(30);
    while Instant::now() < deadline {
        if let Some(status) = process.try_wait().unwrap() {
            panic!(
                "external process exited with {status}; log: {}",
                std::fs::read_to_string(log).unwrap_or_default()
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
        "external process never reported {needle}; log: {}",
        std::fs::read_to_string(log).unwrap_or_default()
    );
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
