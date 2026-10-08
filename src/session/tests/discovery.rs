use super::*;
use pipewire::spa::pod::{serialize::PodSerializer, Value};
use pipewire::spa::utils::Id;
use std::io::Cursor;
use std::os::unix::fs::{symlink, PermissionsExt};

pub(super) fn record() -> SessionRecord {
    SessionRecord {
        label: "Classic α".into(),
        session_id: "12345678-1234-1234-1234-123456789abc".into(),
        owner_pid: u32::MAX,
        incarnation: i64::MAX,
        remote: "/tmp/private/core".into(),
        node_name: "rtc.supervisor-1".into(),
    }
}
pub(super) fn encode(record: &SessionRecord) -> Vec<u8> {
    PodSerializer::serialize(
        Cursor::new(Vec::new()),
        &Value::Struct(vec![
            Value::Int(1),
            Value::String(record.label.clone()),
            Value::String(record.session_id.clone()),
            Value::Id(Id(record.owner_pid)),
            Value::Long(record.incarnation),
            Value::String(record.remote.clone()),
            Value::String(record.node_name.clone()),
        ]),
    )
    .unwrap()
    .0
    .into_inner()
}
fn permission(path: &Path, mode: u32) {
    fs::set_permissions(path, fs::Permissions::from_mode(mode)).unwrap();
}
fn temporary_registry() -> (tempfile::TempDir, PathBuf) {
    let temp = tempfile::tempdir().unwrap();
    permission(temp.path(), 0o700);
    let app = temp.path().join("pipewireao-rtc");
    fs::create_dir(&app).unwrap();
    permission(&app, 0o700);
    let registry = app.join("sessions");
    fs::create_dir(&registry).unwrap();
    permission(&registry, 0o700);
    (temp, registry)
}
fn put(directory: &Path, record: &SessionRecord) -> PathBuf {
    let path = directory.join(format!("session-{}.pod", record.session_id));
    fs::write(&path, encode(record)).unwrap();
    permission(&path, 0o600);
    path
}

#[test]
fn record_extent_and_closed_fields() {
    let original = record();
    let bytes = encode(&original);
    let julia = fs::read(
        Path::new(env!("CARGO_MANIFEST_DIR")).join("tests/data/native-session/record.pod"),
    )
    .unwrap();
    assert_eq!(bytes, julia);
    assert_eq!(decode_record(&bytes).unwrap(), original);
    for length in 0..bytes.len() {
        assert!(decode_record(&bytes[..length]).is_err());
    }
    let mut trailing = bytes.clone();
    trailing.push(0);
    assert!(decode_record(&trailing).is_err());
    let mut wrong_type = bytes.clone();
    wrong_type[12..16].copy_from_slice(&SpaTypes::Long.as_raw().to_ne_bytes());
    assert!(decode_record(&wrong_type).is_err());
    let mut wrong_version = bytes;
    wrong_version[16..20].copy_from_slice(&2_i32.to_ne_bytes());
    assert!(decode_record(&wrong_version).is_err());
    let mut boundary = original;
    boundary.label = "a".repeat(256);
    boundary.remote = format!("/{}", "b".repeat(2047));
    boundary.node_name = "n".repeat(128);
    assert!(decode_record(&encode(&boundary)).is_ok());
    boundary.label.push('a');
    assert!(decode_record(&encode(&boundary)).is_err());
    for invalid in ["UPPERCASE-1234-1234-1234-123456789abc", "not-a-uuid"] {
        boundary.session_id = invalid.into();
        assert!(boundary.validate().is_err());
    }
    let mut invalid = record();
    invalid.owner_pid = 0;
    assert!(invalid.validate().is_err());
    invalid = record();
    invalid.incarnation = 0;
    assert!(invalid.validate().is_err());
    invalid = record();
    invalid.remote = "relative".into();
    assert!(invalid.validate().is_err());
    invalid = record();
    invalid.node_name = "bad/name".into();
    assert!(invalid.validate().is_err());
    invalid = record();
    invalid.label = "NUL\0".into();
    assert!(invalid.validate().is_err());
    assert!(decode_record(&vec![0; MAX_RECORD_BYTES + 1]).is_err());
}

#[test]
fn listing_is_read_only_and_rejects_special_modes_links_and_capacity() {
    let (temp, registry) = temporary_registry();
    let item = record();
    let path = put(&registry, &item);
    let listed = list_sessions(temp.path()).unwrap();
    assert_eq!(listed.len(), 1);
    assert_eq!(listed[0].record.as_ref(), Some(&item));
    assert_eq!(listed[0].verification, Verification::Unverified);
    for mode in [0o644, 0o4600, 0o2600, 0o1600] {
        permission(&path, mode);
        assert_eq!(
            list_sessions(temp.path()).unwrap()[0].verification,
            Verification::Malformed
        );
    }
    permission(&path, 0o600);
    fs::remove_file(&path).unwrap();
    let external = temp.path().join("outside");
    fs::write(&external, encode(&item)).unwrap();
    permission(&external, 0o600);
    symlink(&external, &path).unwrap();
    assert_eq!(
        list_sessions(temp.path()).unwrap()[0].verification,
        Verification::Malformed
    );
    fs::remove_file(&path).unwrap();
    fs::hard_link(&external, &path).unwrap();
    assert_eq!(
        list_sessions(temp.path()).unwrap()[0].verification,
        Verification::Malformed
    );
    fs::remove_file(&path).unwrap();
    fs::write(&path, vec![0; MAX_RECORD_BYTES + 1]).unwrap();
    permission(&path, 0o600);
    assert_eq!(
        list_sessions(temp.path()).unwrap()[0].verification,
        Verification::Malformed
    );
    fs::remove_file(&path).unwrap();
    for i in 0..MAX_ENTRIES {
        fs::write(registry.join(format!("invalid-{i}.pod")), []).unwrap();
    }
    assert_eq!(list_sessions(temp.path()).unwrap().len(), MAX_ENTRIES);
    fs::write(registry.join("overflow.pod"), []).unwrap();
    assert!(list_sessions(temp.path()).is_err());
    assert!(registry.join("overflow.pod").exists());
    permission(&registry, 0o1700);
    assert!(list_sessions(temp.path()).is_err());
    permission(&registry, 0o700);
    permission(temp.path(), 0o755);
    assert!(list_sessions(temp.path()).is_err());
}

#[test]
fn absent_registry_is_not_created_and_diagnostics_are_utf8_bounded() {
    let temp = tempfile::tempdir().unwrap();
    permission(temp.path(), 0o700);
    assert!(list_sessions(temp.path()).is_err());
    assert!(!temp.path().join("pipewireao-rtc").exists());
    let entry = DiscoveryEntry::new(
        None,
        Verification::Malformed,
        &format!("\0{}", "α".repeat(400)),
    );
    assert!(entry.detail.len() <= 512);
    assert!(!entry.detail.contains('\0'));
}
