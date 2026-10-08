use super::*;

/// RTC-DEV-004/021: removal remains a loss even if a replacement appears before a poll.
pub(super) fn external_replacement(
    repository: &Path,
    pipewire_build: &Path,
    environment: &BTreeMap<String, PathBuf>,
    core_name: &str,
    graph_configuration: &Path,
) {
    const NAME: &str = "pipewireao-rtc-external-graph";
    for running in [false, true] {
        let provider =
            launch_external_fgn(pipewire_build, environment, core_name, graph_configuration);
        wait_for_dump(pipewire_build, environment, core_name, NAME);
        let mut runner = load_observation_session(
            core_name,
            &repository.join("configs/external-graph-development.conf"),
        );
        if running {
            assert_eq!(
                runner.dispatch(LifecycleEvent::Start).unwrap(),
                LifecycleState::Running
            );
        }
        let before = external_identity(pipewire_build, environment, core_name);
        drop(provider);
        wait_for_dump_absent(pipewire_build, environment, core_name, NAME);
        let replacement =
            launch_external_fgn(pipewire_build, environment, core_name, graph_configuration);
        wait_for_dump(pipewire_build, environment, core_name, NAME);
        let after = external_identity(pipewire_build, environment, core_name);
        assert_ne!(
            before, after,
            "replacement must have a new native incarnation"
        );
        eprintln!("required external replacement (running={running}): {before:?} -> {after:?}");
        assert_eq!(
            runner.poll_required_objects().unwrap(),
            LifecycleState::Fault,
            "external replacement retained admission; diagnostic: {:?}",
            runner.diagnostic()
        );
        assert_eq!(
            runner.diagnostic().map(ScientificDiagnostic::field),
            Some("graph pipewireao-rtc-external-graph.node.name")
        );
        assert_eq!(
            runner.dispatch(LifecycleEvent::Unload).unwrap(),
            LifecycleState::Offline
        );
        let cleaned = dump(pipewire_build, environment, core_name);
        assert!(
            cleaned.contains(NAME),
            "cleanup must retain the replacement's owner"
        );
        assert!(cleaned.contains("pipewireao-rtc-unrelated"));
        assert!(!cleaned.contains("pipewireao-rtc-source"));
        assert!(!cleaned.contains("pipewireao-rtc-sink"));
        drop(replacement);
        wait_for_dump_absent(pipewire_build, environment, core_name, NAME);
    }
}

fn external_identity(
    pipewire_build: &Path,
    environment: &BTreeMap<String, PathBuf>,
    core_name: &str,
) -> (u64, String) {
    let objects: serde_json::Value =
        serde_json::from_str(&dump_state(pipewire_build, environment, core_name)).unwrap();
    let node = objects
        .as_array()
        .unwrap()
        .iter()
        .find(|object| {
            object["type"].as_str() == Some("PipeWire:Interface:Node")
                && object["info"]["props"]["node.name"].as_str()
                    == Some("pipewireao-rtc-external-graph")
        })
        .expect("required external node");
    (
        node["id"].as_u64().unwrap(),
        node["info"]["props"]["object.serial"].to_string(),
    )
}

/// RTC-DEV-003/004: losing an admitted link faults both stable session states.
pub(super) fn run(
    repository: &Path,
    pipewire_build: &Path,
    environment: &BTreeMap<String, PathBuf>,
    core_name: &str,
) {
    for running in [false, true] {
        let mut runner = load_observation_session(
            core_name,
            &repository.join("configs/minimal-development.conf"),
        );
        assert_eq!(
            runner.poll_required_objects().unwrap(),
            LifecycleState::Ready
        );
        if running {
            assert_eq!(
                runner.dispatch(LifecycleEvent::Start).unwrap(),
                LifecycleState::Running,
                "start diagnostic: {:?}",
                runner.diagnostic(),
            );
            // A normal stop and its Paused links retain admission.
            assert_eq!(
                runner.dispatch(LifecycleEvent::Stop).unwrap(),
                LifecycleState::Ready
            );
            assert_eq!(
                runner.poll_required_objects().unwrap(),
                LifecycleState::Ready
            );
            assert_eq!(
                runner.dispatch(LifecycleEvent::Start).unwrap(),
                LifecycleState::Running
            );
        }
        let objects: serde_json::Value =
            serde_json::from_str(&dump_state(pipewire_build, environment, core_name))
                .expect("private-core JSON dump");
        let links = objects
            .as_array()
            .unwrap()
            .iter()
            .filter(|object| object["type"].as_str() == Some("PipeWire:Interface:Link"))
            .collect::<Vec<_>>();
        assert_eq!(
            links.len(),
            2,
            "only the fixture's two required links may exist"
        );
        let id = links[0]["id"].as_u64().unwrap().to_string();
        let output =
            command_with_environment(pipewire_build.join("src/tools/pwao-cli"), environment)
                .args(["-r", core_name, "destroy", &id])
                .output()
                .unwrap();
        assert!(
            output.status.success(),
            "destroy required link: {}",
            String::from_utf8_lossy(&output.stderr)
        );
        assert_eq!(
            runner.poll_required_objects().unwrap(),
            LifecycleState::Fault,
            "deleted link {id} retained admission (running={running}); diagnostic: {:?}",
            runner.diagnostic(),
        );
        assert!(
            runner
                .diagnostic()
                .is_some_and(|diagnostic| diagnostic.field().starts_with("links[")),
            "lost-link diagnostic: {:?}",
            runner.diagnostic()
        );
        assert_eq!(
            runner.dispatch(LifecycleEvent::Unload).unwrap(),
            LifecycleState::Offline
        );
        let after = dump(pipewire_build, environment, core_name);
        assert!(after.contains("pipewireao-rtc-unrelated"));
        for name in [
            "pipewireao-rtc-source",
            "pipewireao-rtc-graph",
            "pipewireao-rtc-sink",
        ] {
            assert!(!after.contains(name), "fault cleanup retained {name}");
        }
    }
}
