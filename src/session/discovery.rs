//! Bounded, read-only discovery hints for local `WirePlumber` sessions.
//! Listing never queries an owner, creates a directory, or removes a stale record.
use pipewire::spa::utils::SpaTypes;
use std::fs::{self, Metadata, OpenOptions};
use std::io::Read;
use std::os::unix::fs::{MetadataExt, OpenOptionsExt};
use std::path::{Path, PathBuf};

/// Largest native discovery record.
pub const MAX_RECORD_BYTES: usize = 4096;
/// Maximum `.pod` candidates in one complete listing.
pub const MAX_ENTRIES: usize = 128;

/// An unverified owner-published locator, never a cached status.
#[derive(Clone, Debug, Eq, PartialEq)]
pub struct SessionRecord {
    /// Operator label; duplicate labels are allowed.
    pub label: String,
    /// Immutable supervisor endpoint UUID.
    pub session_id: String,
    /// Supervisor process, rather than the internal runner process.
    pub owner_pid: u32,
    /// Positive supervisor endpoint incarnation.
    pub incarnation: i64,
    /// Exact absolute private `PipeWire` socket path.
    pub remote: String,
    /// Exact public supervisor node name.
    pub node_name: String,
}

impl SessionRecord {
    /// Checks the selected seven-field record contract.
    ///
    /// # Errors
    /// Rejects invalid identity, name, remote, or excessive strings.
    pub fn validate(&self) -> Result<(), String> {
        string(&self.label, 256)?;
        validate_uuid(&self.session_id)?;
        if self.owner_pid == 0 || self.incarnation <= 0 {
            return Err("discovery PID and incarnation must be positive".into());
        }
        string(&self.remote, 2048)?;
        if !Path::new(&self.remote).is_absolute() {
            return Err("discovery remote must be absolute".into());
        }
        string(&self.node_name, 128)?;
        if !self
            .node_name
            .bytes()
            .all(|b| b.is_ascii_alphanumeric() || b"_.-".contains(&b))
        {
            return Err("invalid supervisor node name".into());
        }
        Ok(())
    }
}

/// Local verification state; listing returns only Unverified or Malformed.
#[derive(Clone, Copy, Debug, Eq, PartialEq)]
pub enum Verification {
    /// Well-formed hint, no live status query.
    Unverified,
    /// Exact live identity and a fresh Status query matched.
    Verified,
    /// Recorded endpoint could not be reached or queried.
    Inaccessible,
    /// Fresh identity differs from the selected record.
    Replaced,
    /// Malformed file or record.
    Malformed,
}

/// One bounded listing or failed selection result.
#[derive(Clone, Debug, Eq, PartialEq)]
pub struct DiscoveryEntry {
    /// Present only for a well-formed record.
    pub record: Option<SessionRecord>,
    /// Verification never confers authority without a retained live connection.
    pub verification: Verification,
    /// UTF-8 diagnostic, at most 512 bytes.
    pub detail: String,
}

impl DiscoveryEntry {
    /// Construct a bounded diagnostic result.
    #[must_use]
    pub fn new(record: Option<SessionRecord>, verification: Verification, detail: &str) -> Self {
        let mut detail = detail.replace('\0', " ");
        let mut end = detail.len().min(512);
        while !detail.is_char_boundary(end) {
            end -= 1;
        }
        detail.truncate(end);
        Self {
            record,
            verification,
            detail,
        }
    }
}

fn string(value: &str, bound: usize) -> Result<(), String> {
    if value.is_empty() || value.len() > bound || value.contains('\0') {
        Err("invalid or excessive discovery string".into())
    } else {
        Ok(())
    }
}

fn validate_uuid(value: &str) -> Result<(), String> {
    if value.len() != 36
        || !value.bytes().enumerate().all(|(i, b)| {
            if [8, 13, 18, 23].contains(&i) {
                b == b'-'
            } else {
                b.is_ascii_digit() || (b'a'..=b'f').contains(&b)
            }
        })
    {
        return Err("discovery UUID must be canonical lowercase".into());
    }
    Ok(())
}

fn u32_at(bytes: &[u8], offset: usize) -> Result<u32, String> {
    Ok(u32::from_ne_bytes(
        bytes
            .get(offset..offset + 4)
            .ok_or("truncated discovery POD")?
            .try_into()
            .map_err(|_| "discovery scalar width")?,
    ))
}

/// Decode one flat native SPA Struct after checking every extent and type.
///
/// # Errors
/// Rejects overcapacity, malformed/trailing bytes, wrong types/arity or schema.
pub fn decode_record(bytes: &[u8]) -> Result<SessionRecord, String> {
    if !(8..=MAX_RECORD_BYTES).contains(&bytes.len()) {
        return Err("discovery POD must fit 4 KiB".into());
    }
    if u32_at(bytes, 4)? != SpaTypes::Struct.as_raw()
        || usize::try_from(u32_at(bytes, 0)?).map_err(|_| "discovery size")? + 8 != bytes.len()
    {
        return Err("discovery POD must be one exact Struct".into());
    }
    let types = [
        SpaTypes::Int,
        SpaTypes::String,
        SpaTypes::String,
        SpaTypes::Id,
        SpaTypes::Long,
        SpaTypes::String,
        SpaTypes::String,
    ];
    let mut fields = Vec::with_capacity(7);
    let mut offset = 8;
    for expected in types {
        let size = usize::try_from(u32_at(bytes, offset)?).map_err(|_| "discovery size")?;
        if u32_at(bytes, offset + 4)? != expected.as_raw() {
            return Err("wrong discovery POD field type".into());
        }
        let body = offset.checked_add(8).ok_or("discovery extent overflow")?;
        let end = body.checked_add(size).ok_or("discovery extent overflow")?;
        fields.push(bytes.get(body..end).ok_or("truncated discovery field")?);
        offset = end.checked_add(7).ok_or("discovery extent overflow")? & !7;
        if offset > bytes.len() {
            return Err("truncated discovery padding".into());
        }
    }
    if offset != bytes.len() || fields[0].len() != 4 || fields[3].len() != 4 || fields[4].len() != 8
    {
        return Err("wrong discovery arity or scalar width".into());
    }
    if i32::from_ne_bytes(fields[0].try_into().map_err(|_| "schema width")?) != 1 {
        return Err("unsupported discovery schema".into());
    }
    let text = |field: &[u8]| -> Result<String, String> {
        let text = field
            .strip_suffix(&[0])
            .ok_or("unterminated discovery string")?;
        if text.contains(&0) {
            return Err("embedded NUL in discovery string".into());
        }
        std::str::from_utf8(text)
            .map(str::to_owned)
            .map_err(|_| "invalid discovery UTF-8".into())
    };
    let record = SessionRecord {
        label: text(fields[1])?,
        session_id: text(fields[2])?,
        owner_pid: u32::from_ne_bytes(fields[3].try_into().map_err(|_| "PID width")?),
        incarnation: i64::from_ne_bytes(fields[4].try_into().map_err(|_| "incarnation width")?),
        remote: text(fields[5])?,
        node_name: text(fields[6])?,
    };
    record.validate()?;
    Ok(record)
}

fn uid() -> Result<u32, String> {
    // The existing public client uses the same public process identity API.
    let status = fs::read_to_string("/proc/self/status").map_err(|e| e.to_string())?;
    status
        .lines()
        .find_map(|line| line.strip_prefix("Uid:"))
        .and_then(|line| line.split_whitespace().nth(1))
        .ok_or("effective UID unavailable")?
        .parse()
        .map_err(|_| "invalid effective UID".into())
}

fn directory(path: &Path, owner: u32) -> Result<Metadata, String> {
    let metadata = fs::symlink_metadata(path).map_err(|e| e.to_string())?;
    if !metadata.is_dir() || metadata.uid() != owner || metadata.mode() & 0o7777 != 0o700 {
        return Err("discovery directory must be owned, non-symlink, and exactly mode0700".into());
    }
    Ok(metadata)
}

/// Validate the existing per-user registry without creating or repairing it.
///
/// # Errors
/// Rejects absent, linked, foreign-owned or incorrectly permissioned components.
pub fn registry_directory(runtime_dir: &Path) -> Result<PathBuf, String> {
    if !runtime_dir.is_absolute() || runtime_dir.as_os_str().len() > 4096 {
        return Err("XDG_RUNTIME_DIR must be a bounded absolute path".into());
    }
    let owner = uid()?;
    directory(runtime_dir, owner)?;
    let app = runtime_dir.join("pipewireao-rtc");
    directory(&app, owner)?;
    let registry = app.join("sessions");
    directory(&registry, owner)?;
    Ok(registry)
}

fn read_record(path: &Path, owner: u32) -> Result<SessionRecord, String> {
    let file = OpenOptions::new()
        .read(true)
        .custom_flags(libc::O_NOFOLLOW | libc::O_NONBLOCK)
        .open(path)
        .map_err(|e| e.to_string())?;
    let metadata = file.metadata().map_err(|e| e.to_string())?;
    if !metadata.is_file()
        || metadata.uid() != owner
        || metadata.mode() & 0o7777 != 0o600
        || metadata.nlink() != 1
        || metadata.len() > MAX_RECORD_BYTES as u64
    {
        return Err("discovery record must be owned, unlinked, mode0600 and fit 4KiB".into());
    }
    let mut bytes = Vec::with_capacity(MAX_RECORD_BYTES);
    file.take((MAX_RECORD_BYTES + 1) as u64)
        .read_to_end(&mut bytes)
        .map_err(|e| e.to_string())?;
    let after = fs::symlink_metadata(path).map_err(|e| e.to_string())?;
    if !after.is_file() || (metadata.dev(), metadata.ino()) != (after.dev(), after.ino()) {
        return Err("discovery record changed while reading".into());
    }
    decode_record(&bytes)
}

/// List at most 128 candidates without a status query or filesystem mutation.
///
/// # Errors
/// Rejects an unsafe registry or an overcapacity catalogue as a whole.
pub fn list_sessions(runtime_dir: &Path) -> Result<Vec<DiscoveryEntry>, String> {
    let registry = registry_directory(runtime_dir)?;
    let owner = uid()?;
    let before = directory(&registry, owner)?;
    let mut paths = Vec::with_capacity(MAX_ENTRIES);
    for candidate in fs::read_dir(&registry).map_err(|e| e.to_string())? {
        let path = candidate.map_err(|e| e.to_string())?.path();
        if path.extension().is_some_and(|ext| ext == "pod") {
            if paths.len() == MAX_ENTRIES {
                return Err("discovery exceeds 128 records".into());
            }
            paths.push(path);
        }
    }
    paths.sort();
    let entries = paths
        .iter()
        .map(|path| {
            let record: Result<SessionRecord, String> = (|| {
                let name = path
                    .file_name()
                    .and_then(|name| name.to_str())
                    .ok_or("invalid discovery filename")?;
                let id = name
                    .strip_prefix("session-")
                    .and_then(|name| name.strip_suffix(".pod"))
                    .ok_or("invalid discovery filename")?;
                validate_uuid(id)?;
                let record = read_record(path, owner)?;
                if record.session_id != id {
                    return Err("discovery UUID differs from filename".into());
                }
                Ok(record)
            })();
            match record {
                Ok(record) => DiscoveryEntry::new(
                    Some(record),
                    Verification::Unverified,
                    "locator hint; live status has not been queried",
                ),
                Err(detail) => DiscoveryEntry::new(None, Verification::Malformed, &detail),
            }
        })
        .collect();
    let after = directory(&registry, owner)?;
    if (before.dev(), before.ino()) != (after.dev(), after.ino()) {
        return Err("discovery registry changed while listing".into());
    }
    Ok(entries)
}

#[cfg(test)]
#[path = "tests/discovery.rs"]
mod tests;
