use pipewireao_gui::operator_view::{parse_and_validate, ConfigLimits, OperatorViewSpec};
use std::num::NonZeroUsize;
#[test]
fn actual_application_profile_uses_the_public_parser_without_a_connection() {
    let path = "/home/dgamroth/workspaces/codex/pipewire/revolt-classic-rtc-series/operator-views.toml";
    let document = parse_and_validate(&std::fs::read_to_string(path).unwrap(), ConfigLimits {
        max_views: NonZeroUsize::new(64).unwrap(),
        max_identifier_bytes: NonZeroUsize::new(96).unwrap(),
        max_title_bytes: NonZeroUsize::new(160).unwrap(),
    }).unwrap();
    let series = document.views().iter().find_map(|view| match view {
        OperatorViewSpec::TimeSeries(series) => Some(series), _ => None,
    }).unwrap();
    assert_eq!(series.source.node_name, "simulator-wavefront-rms-queue-output");
    assert_eq!(series.source.media_name, "wavefront-rms");
    assert_eq!(series.expected_schema, "org.calculon.ao.pupil-opd-rms.nm.f32/1");
    assert_eq!(series.sample_period_seconds, Some(0.002));
    assert_eq!(series.time_axis_title, "Simulation time (s)");
    assert_eq!(series.channels.iter().map(|channel| channel.index).collect::<Vec<_>>(), [0, 1]);
    println!("Admitted {} logical views; time series {} with channels {:?}", document.views().len(), series.id, series.channels);
}
