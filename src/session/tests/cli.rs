use super::*;

#[test]
fn direct_session_cli_requires_explicit_selection_and_command() {
    assert!(parse_options(&[]).is_err());
    assert!(parse_options(&["--session".into(), "uuid".into()]).is_err());
    assert!(parse_options(&["--list".into(), "--".into(), "status".into()]).is_err());
    let parsed = parse_options(&[
        "--timeout".into(),
        "2.5".into(),
        "--session".into(),
        "uuid".into(),
        "--".into(),
        "status".into(),
    ])
    .unwrap();
    assert_eq!(parsed.command, vec!["status"]);
    assert_eq!(parsed.session.as_deref(), Some("uuid"));
    assert_eq!(parsed.timeout, Duration::from_millis(2500));
}
