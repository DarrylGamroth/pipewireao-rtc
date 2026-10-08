use super::*;
use std::fmt::Write as _;

struct SourceSpec {
    name: &'static str,
    schema: &'static str,
    variant: &'static str,
}

struct SourceProcess {
    child: ChildGuard,
    log: PathBuf,
    control: PathBuf,
}

const SERIAL_SOURCE: &[SourceSpec] = &[SourceSpec {
    name: "pipewireao-rtc-serial-source",
    schema: EXCITATION_SCHEMA,
    variant: "a",
}];
const MINIMAL_SOURCE: &[SourceSpec] = &[SourceSpec {
    name: "pipewireao-rtc-source",
    schema: EXCITATION_SCHEMA,
    variant: "a",
}];
const FORK_SOURCE: &[SourceSpec] = &[SourceSpec {
    name: "pipewireao-rtc-fork-source",
    schema: EXCITATION_SCHEMA,
    variant: "a",
}];
const INDEPENDENT_SOURCES: &[SourceSpec] = &[
    SourceSpec {
        name: "pipewireao-rtc-independent-source-a",
        schema: EXCITATION_A_SCHEMA,
        variant: "a",
    },
    SourceSpec {
        name: "pipewireao-rtc-independent-source-b",
        schema: EXCITATION_B_SCHEMA,
        variant: "b",
    },
];
const FRAME_COUNT: usize = 8;

fn sources(case: &SessionCase<'_>) -> &'static [SourceSpec] {
    match case.fixture {
        "minimal-development.conf" => MINIMAL_SOURCE,
        "serial-development.conf" => SERIAL_SOURCE,
        "fork-development.conf" => FORK_SOURCE,
        "independent-development.conf" => INDEPENDENT_SOURCES,
        other => panic!("no stepped source specification for {other}"),
    }
}

fn stepped_fixture(repository: &Path, temporary: &Path, case: &SessionCase<'_>) -> PathBuf {
    let template = std::fs::read_to_string(repository.join("configs").join(case.fixture))
        .expect("read topology fixture");
    let source_start = template.find("    sources = [").expect("source section");
    let graph_start = template.find("    graphs = [").expect("graph section");
    assert!(source_start < graph_start);
    let mut configured = String::from(&template[..source_start]);
    configured.push_str("    sources = [\n");
    for source in sources(case) {
        writeln!(
            configured,
            "        {{ ownership = external node.name = {} ports = [ {{ name = output direction = output element-type = F32_LE shape = [ 2 ] schema = {} }} ] }}",
            source.name, source.schema
        ).expect("append external source declaration");
    }
    configured.push_str("    ]\n");
    configured.push_str(&template[graph_start..]);
    for source in sources(case) {
        let group_member = format!("                {}\n", source.name);
        if configured.contains(&group_member) {
            configured = configured.replacen(&group_member, "", 1);
        }
        if case.fixture == "minimal-development.conf" {
            let before =
                "nodes = [ pipewireao-rtc-source pipewireao-rtc-graph pipewireao-rtc-sink ]";
            assert!(configured.contains(before));
            configured = configured.replace(
                before,
                "nodes = [ pipewireao-rtc-graph pipewireao-rtc-sink ]",
            );
        }
        let source_link = format!("output = \"{}:output\"", source.name);
        assert_eq!(
            configured.matches(&source_link).count(),
            if case.fixture == "fork-development.conf" {
                2
            } else {
                1
            }
        );
        configured = configured
            .lines()
            .map(|line| {
                if line.contains(&source_link) {
                    assert!(line.contains("passive = false") || line.contains("passive = true"));
                    line.replace("passive = false", "passive = true")
                } else {
                    line.to_owned()
                }
            })
            .collect::<Vec<_>>()
            .join("\n")
            + "\n";
    }
    let path = temporary.join(format!("stepped-{}", case.fixture));
    std::fs::write(&path, configured).expect("write stepped topology fixture");
    path
}

fn launch_source(
    repository: &Path,
    pipewireao_julia: &Path,
    environment: &BTreeMap<String, PathBuf>,
    core_name: &str,
    temporary: &Path,
    spec: &SourceSpec,
) -> SourceProcess {
    let control = temporary.join(format!("stepped-{}", spec.name));
    std::fs::create_dir_all(&control).expect("create stepped source control directory");
    let log = control.join("source.log");
    let output = std::fs::File::create(&log).expect("create stepped source log");
    let child = command_with_environment("julia", environment)
        .args([
            "--startup-file=no",
            "--threads=2",
            &format!("--project={}", pipewireao_julia.display()),
        ])
        .arg(repository.join("tests/live_private_core/stepped_vector_source.jl"))
        .args([core_name, spec.name, spec.schema])
        .arg(&control)
        .arg(spec.variant)
        .stdout(Stdio::from(output.try_clone().expect("clone source log")))
        .stderr(Stdio::from(output))
        .spawn()
        .expect("start stepped source");
    let mut source = SourceProcess {
        child: ChildGuard(child),
        log,
        control,
    };
    wait_for_text(&mut source.child.0, &source.log, "STEPPED_SOURCE_READY");
    source
}

fn wait_for_ack(source: &mut SourceProcess, name: &str) {
    let path = source.control.join(format!("{name}.ack"));
    let deadline = Instant::now() + Duration::from_secs(10);
    while Instant::now() < deadline {
        if path.is_file() {
            return;
        }
        if let Some(status) = source.child.0.try_wait().expect("poll stepped source") {
            panic!(
                "stepped source exited with {status} before {name}: {}",
                std::fs::read_to_string(&source.log).unwrap_or_default()
            );
        }
        std::thread::sleep(Duration::from_millis(5));
    }
    panic!(
        "stepped source did not acknowledge {name}: {}",
        std::fs::read_to_string(&source.log).unwrap_or_default()
    );
}

fn reference_digests(repository: &Path, case: &SessionCase<'_>, sink: &str) -> Vec<u64> {
    let topology = if matches!(case.payload_oracle, Some(PayloadOracle::Serial)) {
        "serial"
    } else {
        "direct"
    };
    let variant = if case.fixture == "independent-development.conf" && sink.ends_with("-b") {
        "b"
    } else {
        "a"
    };
    let mut command = if let Some(path) = std::env::var_os("PIPEWIREAO_RTC_CALCULON_ORACLE") {
        Command::new(path)
    } else {
        let workspace = std::env::var_os("PIPEWIREAO_RTC_CALCULON_WORKSPACE").map_or_else(
            || {
                repository
                    .parent()
                    .unwrap()
                    .join("calculon-algorithms-main-copper")
            },
            PathBuf::from,
        );
        let mut command = Command::new("cargo");
        command.args([
            "run",
            "--quiet",
            "--manifest-path",
            workspace
                .join("Cargo.toml")
                .to_str()
                .expect("UTF-8 Calculon path"),
            "-p",
            "calculon-algorithms",
            "--example",
            "leaky_integrator_oracle",
            "--",
        ]);
        command
    };
    let output = command
        .args([topology, variant, "digest"])
        .output()
        .expect("run direct Calculon Algorithm oracle");
    assert!(
        output.status.success(),
        "direct Calculon oracle failed: {}",
        String::from_utf8_lossy(&output.stderr)
    );
    let lines = String::from_utf8(output.stdout).expect("UTF-8 direct Calculon oracle");
    let digests = lines
        .lines()
        .enumerate()
        .map(|(index, line)| {
            let (frame, digest) = line.split_once(' ').expect("oracle frame and digest");
            assert_eq!(frame.parse::<usize>().unwrap(), index + 1);
            u64::from_str_radix(digest, 16).expect("oracle FNV digest")
        })
        .collect::<Vec<_>>();
    assert_eq!(
        digests.len(),
        FRAME_COUNT,
        "direct Calculon oracle frame count"
    );
    digests
}

fn request_frame(providers: &[SourceProcess], frame_count: usize) {
    for provider in providers {
        std::fs::write(
            provider.control.join(format!("step-{frame_count}")),
            "step\n",
        )
        .expect("request source frame");
    }
}

fn await_frame(providers: &mut [SourceProcess], frame_count: usize) {
    for provider in providers {
        wait_for_ack(provider, &format!("step-{frame_count}"));
    }
}

fn start_with_frame(
    runner: &mut Runner<LiveGraphAdapter>,
    providers: &mut [SourceProcess],
    case: &SessionCase<'_>,
    expected: &BTreeMap<&str, Vec<u64>>,
    frame_count: usize,
) {
    eprintln!("{} starting stepped frame {frame_count}", case.fixture);
    assert_eq!(
        runner
            .dispatch(LifecycleEvent::Start)
            .expect("start stepped topology"),
        LifecycleState::Running,
        "{} stepped start diagnostic: {:?}",
        case.fixture,
        runner.diagnostic()
    );
    request_frame(providers, frame_count);
    await_frame(providers, frame_count);
    wait_for_outputs(runner, case, expected, frame_count);
}

fn wait_for_outputs(
    runner: &Runner<LiveGraphAdapter>,
    case: &SessionCase<'_>,
    expected: &BTreeMap<&str, Vec<u64>>,
    frame_count: usize,
) {
    let deadline = Instant::now() + Duration::from_secs(10);
    loop {
        let observations = runner
            .executor()
            .observe_discard_payloads()
            .expect("observe stepped topology outputs");
        let mut complete = true;
        for &sink in case.sinks {
            let observation = observations.get(sink).unwrap_or_else(|| {
                panic!("{} has no discard observation for {sink}", case.fixture)
            });
            assert!(
                observation.buffers <= frame_count as u64,
                "{} {sink} produced an unrequested frame: {observation:?}",
                case.fixture
            );
            if observation.buffers < frame_count as u64
                || observation.digest_bytes != observation.bytes
            {
                complete = false;
                continue;
            }
            assert_eq!(
                observation.bytes,
                (frame_count * 2 * size_of::<f32>()) as u64,
                "{} {sink} stepped output size",
                case.fixture
            );
            assert_eq!(
                observation.payload_digest,
                expected[sink][frame_count - 1],
                "{} {sink} output after frame {frame_count}",
                case.fixture
            );
        }
        if complete {
            return;
        }
        assert!(
            Instant::now() < deadline,
            "{} did not deliver all outputs after frame {frame_count}: {observations:?}",
            case.fixture
        );
        std::thread::sleep(Duration::from_millis(5));
    }
}

#[allow(clippy::too_many_arguments)]
#[allow(clippy::too_many_lines)]
pub(super) fn run(
    repository: &Path,
    pipewire_build: &Path,
    environment: &BTreeMap<String, PathBuf>,
    core_name: &str,
    temporary: &Path,
    pipewireao_julia: &Path,
    case: &SessionCase<'_>,
) {
    let expected = case
        .sinks
        .iter()
        .map(|sink| (*sink, reference_digests(repository, case, sink)))
        .collect::<BTreeMap<_, _>>();
    let fixture = stepped_fixture(repository, temporary, case);
    let mut providers = sources(case)
        .iter()
        .map(|source| {
            launch_source(
                repository,
                pipewireao_julia,
                environment,
                core_name,
                temporary,
                source,
            )
        })
        .collect::<Vec<_>>();
    let adapter = LiveGraphAdapter::connect(core_name).expect("connect stepped topology adapter");
    let mut runner = Runner::new(adapter);
    assert_eq!(
        runner
            .dispatch(LifecycleEvent::Load(ConfigurationInput::File(fixture)))
            .expect("load stepped topology"),
        LifecycleState::Ready,
        "{} stepped load diagnostic: {:?}",
        case.fixture,
        runner.diagnostic()
    );

    start_with_frame(&mut runner, &mut providers, case, &expected, 1);

    for frame_count in 2..=4 {
        request_frame(&providers, frame_count);
        await_frame(&mut providers, frame_count);
        wait_for_outputs(&runner, case, &expected, frame_count);
    }

    for provider in &providers {
        std::fs::write(provider.control.join("source-end"), "end\n")
            .expect("notify source completion");
    }
    for provider in &mut providers {
        wait_for_ack(provider, "source-end");
    }
    assert_eq!(
        runner
            .dispatch(LifecycleEvent::FiniteSourceCompleted)
            .expect("dispatch external-owner source completion"),
        LifecycleState::Ready
    );
    wait_for_outputs(&runner, case, &expected, 4);
    for provider in &providers {
        std::fs::write(provider.control.join("source-resume"), "resume\n")
            .expect("resume external source");
    }
    for provider in &mut providers {
        wait_for_ack(provider, "source-resume");
    }
    start_with_frame(&mut runner, &mut providers, case, &expected, 5);
    request_frame(&providers, 6);
    await_frame(&mut providers, 6);
    wait_for_outputs(&runner, case, &expected, 6);
    assert_eq!(
        runner
            .dispatch(LifecycleEvent::Stop)
            .expect("stop stepped topology"),
        LifecycleState::Ready
    );
    assert_eq!(
        runner
            .dispatch(LifecycleEvent::Reset)
            .expect("reset stepped topology"),
        LifecycleState::Ready
    );
    for graph in case
        .nodes
        .iter()
        .copied()
        .filter(|node| node.contains("-graph"))
    {
        assert_eq!(
            runner
                .dispatch(LifecycleEvent::UpdateProperties {
                    graph: graph.to_owned(),
                    values: BTreeMap::from([("graph:gain".to_owned(), ScalarValue::float(0.25))]),
                })
                .expect("update stepped graph gain"),
            LifecycleState::Ready
        );
    }
    start_with_frame(&mut runner, &mut providers, case, &expected, 7);
    request_frame(&providers, 8);
    await_frame(&mut providers, 8);
    wait_for_outputs(&runner, case, &expected, 8);
    assert_eq!(
        runner
            .dispatch(LifecycleEvent::Stop)
            .expect("stop final stepped phase"),
        LifecycleState::Ready
    );
    assert_eq!(
        runner
            .dispatch(LifecycleEvent::Unload)
            .expect("unload stepped topology"),
        LifecycleState::Offline
    );
    let unloaded = dump(pipewire_build, environment, core_name);
    for source in sources(case) {
        assert!(
            unloaded.contains(source.name),
            "external source was removed"
        );
    }
    for node in case.nodes {
        if !sources(case).iter().any(|source| source.name == *node) {
            assert!(
                !unloaded.contains(node),
                "runner-owned node survived: {node}"
            );
        }
    }
    for provider in &mut providers {
        stop_provider(
            &mut provider.child,
            &provider.control.join("stop"),
            &provider.log,
            "stepped vector source",
        );
    }
}
