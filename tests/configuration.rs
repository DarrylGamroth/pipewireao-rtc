use pipewireao_rtc::DevelopmentConfig;

const MINIMAL: &str = include_str!("../fixtures/minimal-development.conf");
const SERIAL: &str = include_str!("../fixtures/serial-development.conf");
const FORK: &str = include_str!("../fixtures/fork-development.conf");
const INDEPENDENT: &str = include_str!("../fixtures/independent-development.conf");
const EXTERNAL: &str = include_str!("../fixtures/external-development.conf");
const AOS_HIL: &str = include_str!("../fixtures/aos-hil-development.conf");
const AOS_HIL_ATMOSPHERE: &str = include_str!("../fixtures/aos-hil-atmosphere-development.conf");

fn replace_once(document: &str, before: &str, after: &str) -> String {
    assert!(
        document.contains(before),
        "fixture does not contain {before:?}"
    );
    document.replacen(before, after, 1)
}

#[test]
fn maintained_session_topologies_are_resolved() {
    let cases = [
        (MINIMAL, 3, 2, 1),
        (SERIAL, 4, 3, 1),
        (FORK, 5, 4, 2),
        (INDEPENDENT, 6, 4, 2),
    ];
    for (document, objects, links, execution_groups) in cases {
        let config = DevelopmentConfig::parse(document).expect("maintained topology");
        assert_eq!(config.object_count(), objects);
        assert_eq!(config.links.len(), links);
        assert_eq!(config.execution_groups.len(), execution_groups);
        assert_eq!(config.topological_node_names().len(), objects);
        assert!(config.properties.is_empty());
        assert!(config.parameters.is_empty());
        assert!(config.observations.is_empty());
    }

    let external = DevelopmentConfig::parse(EXTERNAL).expect("external topology");
    assert_eq!(external.object_count(), 3);
    assert_eq!(external.owned_object_count(), 1);
    assert_eq!(external.links.len(), 2);

    let atmosphere =
        DevelopmentConfig::parse(AOS_HIL_ATMOSPHERE).expect("atmospheric HIL topology");
    assert_eq!(atmosphere.object_count(), 3);
    assert_eq!(atmosphere.owned_object_count(), 1);
    assert_eq!(atmosphere.links.len(), 2);
}

#[test]
fn external_endpoints_are_selected_by_pipewire_contract_not_implementation() {
    let config = DevelopmentConfig::parse(AOS_HIL).expect("AOS HIL configuration");
    assert_eq!(config.object_count(), 3);
    assert_eq!(config.owned_object_count(), 1);
    assert_eq!(
        config.externally_owned_node_names(),
        ["pipewireao-aos-hil-wfs", "pipewireao-aos-hil-command"]
    );
    assert_eq!(config.owned_node_names(), ["pipewireao-rtc-aos-controller"]);
    assert_eq!(config.execution_groups[0].nodes.len(), 1);

    let cases = [
        (
            "ownership = external",
            "ownership = mystery",
            "sources[0].ownership",
        ),
        (
            "ownership = external",
            "ownership = external\n            factory = pipewireao.simulated-complete-frame",
            "sources[0].factory",
        ),
        (
            "node.name = pipewireao-aos-hil-wfs",
            "module = should-not-load\n            node.name = pipewireao-aos-hil-wfs",
            "sources[0].module",
        ),
        (
            "shape = [ 64 64 ]",
            "shape = [ 64 0 ]",
            "sources[0].ports.output_1.shape",
        ),
        (
            "org.adaptiveopticssim.hil-reference.shack-hartmann-frame.f32/1",
            "\"\"",
            "sources[0].ports.output_1.schema",
        ),
        (
            "name = input_1 direction = input element-type = F32_LE shape = [ 25 ]",
            "name = command direction = input element-type = F32_LE shape = [ 25 ]",
            "links[1].input",
        ),
        (
            "nodes = [ pipewireao-rtc-aos-controller ]",
            "nodes = [ pipewireao-aos-hil-wfs pipewireao-rtc-aos-controller ]",
            "execution-groups[0].nodes[0]",
        ),
    ];
    for (before, after, field) in cases {
        let error = DevelopmentConfig::parse(&replace_once(AOS_HIL, before, after))
            .expect_err("invalid external HIL endpoint");
        assert_eq!(error.field(), field, "configuration mutation: {after}");
    }

    let implementation_specific = replace_once(
        AOS_HIL,
        "ownership = external",
        "ownership = external\n            adapter = adaptive-optics-sim-pipewire-hil/1",
    );
    let error = DevelopmentConfig::parse(&implementation_specific)
        .expect_err("implementation identity is not part of the RTC contract");
    assert_eq!(error.field(), "sources[0].adapter");
}

#[test]
fn execution_group_membership_and_boundary_links_are_validated() {
    let cases = [
        (
            replace_once(
                FORK,
                "nodes = [ pipewireao-rtc-fork-graph-a pipewireao-rtc-fork-sink-a ]",
                "nodes = [ missing-node pipewireao-rtc-fork-sink-a ]",
            ),
            "execution-groups[0].nodes[0]",
        ),
        (
            replace_once(FORK, "name = branch-b", "name = branch-a"),
            "execution-groups[1].name",
        ),
        (
            replace_once(
                FORK,
                "nodes = [ pipewireao-rtc-fork-graph-a pipewireao-rtc-fork-sink-a ]",
                "nodes = []",
            ),
            "execution-groups[0].nodes",
        ),
        (
            replace_once(
                FORK,
                "nodes = [ pipewireao-rtc-fork-graph-b pipewireao-rtc-fork-sink-b ]",
                "nodes = [ pipewireao-rtc-fork-graph-a pipewireao-rtc-fork-graph-b pipewireao-rtc-fork-sink-b ]",
            ),
            "execution-groups[1].nodes[0]",
        ),
        (
            replace_once(
                FORK,
                "nodes = [ pipewireao-rtc-fork-graph-a pipewireao-rtc-fork-sink-a ]",
                "nodes = [ pipewireao-rtc-fork-sink-a ]",
            ),
            "execution-groups[0].nodes",
        ),
        (
            replace_once(
                FORK,
                "nodes = [ pipewireao-rtc-fork-graph-a pipewireao-rtc-fork-sink-a ]",
                "nodes = [ pipewireao-rtc-fork-graph-a ]",
            ),
            "sink pipewireao-rtc-fork-sink-a.execution-group",
        ),
        (
            SERIAL.replace(
                "execution-groups = [\n        {\n            name = chain\n            nodes = [\n                pipewireao-rtc-serial-source\n                pipewireao-rtc-serial-graph-a\n                pipewireao-rtc-serial-graph-b\n                pipewireao-rtc-serial-sink\n            ]\n        }\n    ]",
                "execution-groups = [\n        { name = upstream nodes = [ pipewireao-rtc-serial-source pipewireao-rtc-serial-graph-a ] }\n        { name = downstream nodes = [ pipewireao-rtc-serial-graph-b pipewireao-rtc-serial-sink ] }\n    ]",
            ),
            "links[1].execution-group",
        ),
        (
            replace_once(
                FORK,
                "pipewireao-rtc-fork-graph-a:input\" passive = true",
                "pipewireao-rtc-fork-graph-a:input\" passive = false",
            ),
            "links[0].passive",
        ),
        (
            replace_once(MINIMAL, "passive = false", "passive = true"),
            "links[0].passive",
        ),
    ];

    for (document, field) in cases {
        let error = DevelopmentConfig::parse(&document).expect_err("invalid execution group");
        assert_eq!(error.field(), field, "configuration mutation:\n{document}");
    }
}

#[test]
fn graph_bodies_are_delegated_as_opaque_pipewire_module_files() {
    let config = DevelopmentConfig::parse(MINIMAL).unwrap();
    let graph = &config.graphs[0];
    assert_eq!(
        graph.configuration_path.as_deref(),
        Some("${PIPEWIREAO_RTC_GRAPH_MINIMAL}")
    );
    assert!(graph.plugin_path.is_none());
    assert!(graph.arguments.is_empty());

    for (field, insertion) in [
        (
            "graphs[0].filter.graph",
            "filter.graph = { nodes = [] }\n            ",
        ),
        (
            "graphs[0].algorithm.label",
            "algorithm.label = leaky-integrator-f32\n            ",
        ),
        (
            "graphs[0].plugin.path",
            "plugin.path = \"${PIPEWIREAO_RTC_FGN_BUNDLE}\"\n            ",
        ),
    ] {
        let mutated = replace_once(
            MINIMAL,
            "ports = [\n                { name = input",
            &format!("{insertion}ports = [\n                {{ name = input"),
        );
        let error = DevelopmentConfig::parse(&mutated).expect_err("runner-private graph field");
        assert_eq!(error.field(), field);
    }
}

#[test]
fn serial_forked_and_independent_links_are_exactly_declared() {
    let serial = DevelopmentConfig::parse(SERIAL).unwrap();
    assert_eq!(serial.sources.len(), 1);
    assert_eq!(serial.graphs.len(), 2);
    assert_eq!(serial.sinks.len(), 1);

    let fork = DevelopmentConfig::parse(FORK).unwrap();
    assert_eq!(fork.sources.len(), 1);
    assert_eq!(fork.graphs.len(), 2);
    assert_eq!(fork.sinks.len(), 2);
    assert_eq!(fork.links[0].output, fork.links[1].output);
    assert_ne!(fork.links[0].input, fork.links[1].input);

    let independent = DevelopmentConfig::parse(INDEPENDENT).unwrap();
    assert_eq!(independent.sources.len(), 2);
    assert_eq!(independent.graphs.len(), 2);
    assert_eq!(independent.sinks.len(), 2);
}

#[test]
fn endpoint_and_scope_admission_is_an_explicit_negative_matrix() {
    let cases = [
        ("profile = development", "profile = operational", "profile"),
        (
            "execution = complete-frame",
            "execution = progressive",
            "execution",
        ),
        ("authority = none", "authority = correction", "authority"),
        (
            "claim = development-characterization",
            "claim = real-time-qualified",
            "claim",
        ),
        (
            "factory = api.fits.source",
            "factory = pipewireao.physical-camera",
            "sources[0].factory",
        ),
        (
            "factory = api.pipewireao.discard",
            "factory = pipewireao.physical-deformable-mirror",
            "sinks[0].factory",
        ),
        (
            "factory = api.pipewireao.discard",
            "factory = pipewireao.unlisted-sink",
            "sinks[0].factory",
        ),
        (
            "factory = pipewireao.fgn-native",
            "factory = pipewireao.calculon-fgn-native",
            "graphs[0].factory",
        ),
    ];
    for (before, after, field) in cases {
        let error = DevelopmentConfig::parse(&replace_once(MINIMAL, before, after))
            .expect_err("unsafe or unlisted configuration");
        assert_eq!(error.field(), field, "case {after}");
    }
}

#[test]
fn object_port_and_file_fields_report_scientific_names() {
    let cases = [
        (
            "node.name = pipewireao-rtc-source",
            "node.name = \"\"",
            "sources[0].node.name",
        ),
        (
            "${PIPEWIREAO_FITS_PLUGIN}",
            "/usr/lib/unreviewed-source.so",
            "sources[0].plugin.path",
        ),
        (
            "${PIPEWIREAO_RTC_GRAPH_MINIMAL}",
            "/tmp/generated-by-the-runner.conf",
            "graphs[0].config.path",
        ),
        (
            "${PIPEWIREAO_DISCARD_PLUGIN}",
            "/usr/lib/actuating.so",
            "sinks[0].plugin.path",
        ),
        (
            "name = output direction = output",
            "name = output direction = input",
            "sources[0].ports.output.direction",
        ),
        (
            "element-type = F32_LE shape = [ 2 ] schema = org.calculon.ao.docrime-excitation/1",
            "element-type = U16_LE shape = [ 2 ] schema = org.calculon.ao.docrime-excitation/1",
            "sources[0].ports.output.element-type",
        ),
        (
            "shape = [ 2 ] schema = org.calculon.ao.docrime-excitation/1",
            "shape = [ 3 ] schema = org.calculon.ao.docrime-excitation/1",
            "sources[0].ports.output.shape",
        ),
    ];
    for (before, after, field) in cases {
        let error = DevelopmentConfig::parse(&replace_once(MINIMAL, before, after))
            .expect_err("invalid scientific field");
        assert_eq!(error.field(), field, "mutation {before:?}");
    }
}

#[test]
fn fits_factory_arguments_are_validated_field_by_field() {
    let cases = [
        (
            "${PIPEWIREAO_RTC_FITS_PATH}",
            "/tmp/unreviewed.fits",
            "sources[0].args.api.fits.path",
        ),
        (
            "api.fits.hdu = 1",
            "api.fits.hdu = 2",
            "sources[0].args.api.fits.hdu",
        ),
        (
            "api.fits.rate = 1000/1",
            "api.fits.rate = 0/1",
            "sources[0].args.api.fits.rate",
        ),
        (
            "api.fits.output-mode = frame",
            "api.fits.output-mode = row-block",
            "sources[0].args.api.fits.output-mode",
        ),
    ];
    for (before, after, field) in cases {
        let error = DevelopmentConfig::parse(&replace_once(MINIMAL, before, after))
            .expect_err("invalid FITS field");
        assert_eq!(error.field(), field);
    }
}

#[test]
fn links_validate_ports_directions_shapes_schemas_and_producers() {
    let cases = [
        (
            "pipewireao-rtc-source:output",
            "pipewireao-rtc-source:missing",
            "links[0].output",
        ),
        (
            "pipewireao-rtc-graph:input",
            "pipewireao-rtc-graph:output",
            "links[0].input",
        ),
        (
            "schema = org.calculon.ao.controller-command/1",
            "schema = org.pipewireao.rtc.wrong/1",
            "links[1].schema",
        ),
    ];
    for (before, after, field) in cases {
        let error = DevelopmentConfig::parse(&replace_once(MINIMAL, before, after))
            .expect_err("invalid declared link");
        assert_eq!(error.field(), field, "link mutation {before:?}");
    }

    let duplicate = replace_once(
        FORK,
        "pipewireao-rtc-fork-graph-b:input",
        "pipewireao-rtc-fork-graph-a:input",
    );
    let error = DevelopmentConfig::parse(&duplicate).expect_err("duplicate fork link");
    assert_eq!(error.field(), "links[1]");
}

#[test]
fn optional_observer_cannot_become_a_gating_session_link() {
    let error = DevelopmentConfig::parse(&replace_once(
        MINIMAL,
        "observations = []",
        "observations = [ graph.output ]",
    ))
    .expect_err("no non-gating observation boundary exists");
    assert_eq!(error.field(), "observations");
}

#[test]
fn pipewire_relaxed_spa_json_comments_and_optional_separators_are_accepted() {
    let with_comments = MINIMAL.replace(
        "profile = development",
        "# PipeWire line comment\n    profile = development,",
    );
    DevelopmentConfig::parse(&with_comments).expect("public relaxed SPA-JSON syntax");
}

#[test]
fn runner_does_not_extend_or_reinterpret_pipewire_spa_json_syntax() {
    let error = DevelopmentConfig::parse(
        "{ profile = development execution = complete-frame authority = none claim = development-characterization sources = [ @include foo ] }",
    )
    .expect_err("runner-specific include syntax must not be accepted");
    assert!(error.message().contains("relaxed SPA-JSON"));
}
