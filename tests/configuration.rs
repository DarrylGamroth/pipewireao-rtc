use pipewireao_rtc::DevelopmentConfig;

const VALID: &str = include_str!("../fixtures/minimal-development.conf");

fn replace_once(before: &str, after: &str) -> String {
    assert!(
        VALID.contains(before),
        "fixture does not contain {before:?}"
    );
    VALID.replacen(before, after, 1)
}

#[test]
fn valid_minimal_development_configuration_is_resolved() {
    let config = DevelopmentConfig::parse(VALID).expect("valid development fixture");
    assert_eq!(config.object_count(), 3);
    assert_eq!(config.links.len(), 2);
    assert!(config.observations.is_empty());
    assert!(config.parameters.is_empty());
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
            "claim = development-characterization",
            "claim = deadline-qualified",
            "claim",
        ),
        (
            "claim = development-characterization",
            "claim = safety-qualified",
            "claim",
        ),
        (
            "pipewireao.simulated-complete-frame",
            "pipewireao.physical-camera",
            "source.factory",
        ),
        (
            "pipewireao.simulated-complete-frame",
            "pipewireao.unlisted-source",
            "source.factory",
        ),
        (
            "pipewireao.discard-complete-frame",
            "pipewireao.physical-deformable-mirror",
            "sink.factory",
        ),
        (
            "pipewireao.discard-complete-frame",
            "pipewireao.actuating-sink",
            "sink.factory",
        ),
        (
            "pipewireao.discard-complete-frame",
            "pipewireao.unlisted-sink",
            "sink.factory",
        ),
    ];

    for (before, after, field) in cases {
        let error = DevelopmentConfig::parse(&replace_once(before, after))
            .expect_err("unsafe or unlisted case must be rejected");
        assert_eq!(error.field(), field, "case {after}");
    }
}

#[test]
fn invalid_fields_report_scientific_names() {
    let cases = [
        (
            "node.name = pipewireao-rtc-source",
            "node.name = ''",
            "source.node.name",
        ),
        (
            "${CALCULON_FGN_BUNDLE}",
            "/usr/lib/unreviewed-source.so",
            "source.plugin.path",
        ),
        (
            "module = libpipewire-module-ndarray-filter-chain",
            "module = private-module",
            "source.module",
        ),
        (
            "algorithm.label = docrime-excitation-f32",
            "algorithm.label = camera-driver",
            "source.algorithm.label",
        ),
        (
            "name = excitation",
            "name = image",
            "source.ports.image.name",
        ),
        (
            "direction = output",
            "direction = input",
            "source.ports.excitation.direction",
        ),
        (
            "element-type = F32_LE",
            "element-type = U16_LE",
            "source.ports.excitation.element-type",
        ),
        (
            "shape = [ 2 ]",
            "shape = [ 3 ]",
            "source.ports.excitation.shape",
        ),
        (
            "schema = org.calculon.ao.docrime-excitation/1",
            "schema = wrong.image/1",
            "source.ports.excitation.schema",
        ),
        (
            "amplitudes = [ 1.0 2.0 ]",
            "amplitudes = [ 1.0 ]",
            "source.algorithm.config",
        ),
        ("graph.gain = 0.5", "graph.unknown = 0.5", "properties"),
        ("graph.pole = 0.75", "graph.pole = nan", "graph.pole"),
        (
            "parameters = {}",
            "parameters = { graph.matrix = matrix.npy }",
            "parameters",
        ),
        (
            "observations = []",
            "observations = [ graph.output ]",
            "observations",
        ),
        (
            "pipewireao-rtc-graph:input",
            "pipewireao-rtc-sink:in",
            "links",
        ),
    ];

    for (before, after, field) in cases {
        let error = DevelopmentConfig::parse(&replace_once(before, after))
            .expect_err("mutated field must fail validation");
        assert_eq!(error.field(), field, "mutation {before:?} -> {after:?}");
    }
}

#[test]
fn relaxed_spa_json_comments_and_optional_separators_are_accepted() {
    let with_block_comment = VALID.replacen(
        "profile = development",
        "/* standard SPA block comment */ profile: development,",
        1,
    );
    DevelopmentConfig::parse(&with_block_comment).expect("relaxed SPA-JSON syntax");

    let with_unicode_name = VALID
        .replacen(
            "node.name = pipewireao-rtc-source",
            "node.name = \"pipewireao-rtc-sourcé\"",
            1,
        )
        .replacen(
            "pipewireao-rtc-source:excitation",
            "pipewireao-rtc-sourcé:excitation",
            1,
        );
    DevelopmentConfig::parse(&with_unicode_name).expect("quoted UTF-8 is accepted");
}
