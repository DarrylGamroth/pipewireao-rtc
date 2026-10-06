//! Filesystem checks for the native runner's same-user private core.

use std::fs;
use std::io;
use std::os::unix::fs::MetadataExt;
use std::path::{Path, PathBuf};

pub(crate) fn validate_socket_path(path: &Path) -> io::Result<PathBuf> {
    if !path.is_absolute() {
        return Err(io::Error::new(
            io::ErrorKind::InvalidInput,
            "native remote path must be absolute",
        ));
    }
    let name = path
        .file_name()
        .filter(|name| !name.is_empty())
        .ok_or_else(|| {
            io::Error::new(io::ErrorKind::InvalidInput, "socket path must name a file")
        })?;
    let parent = path.parent().ok_or_else(|| {
        io::Error::new(
            io::ErrorKind::InvalidInput,
            "socket path has no parent directory",
        )
    })?;
    let parent = fs::canonicalize(parent)?;
    let metadata = fs::symlink_metadata(&parent)?;
    let self_uid = effective_uid()?;
    if !metadata.is_dir() || metadata.uid() != self_uid || metadata.mode() & 0o077 != 0 {
        return Err(io::Error::new(
            io::ErrorKind::PermissionDenied,
            format!("socket parent must be a directory owned by the effective user with no group/other access (dir={}, uid={} expected={}, mode={:o})", metadata.is_dir(), metadata.uid(), self_uid, metadata.mode() & 0o777),
        ));
    }
    Ok(parent.join(name))
}

pub(crate) fn effective_uid() -> io::Result<u32> {
    fs::read_to_string("/proc/self/status")?
        .lines()
        .find_map(|line| line.strip_prefix("Uid:"))
        .and_then(|uids| uids.split_whitespace().nth(1))
        .and_then(|uid| uid.parse::<u32>().ok())
        .ok_or_else(|| {
            io::Error::new(
                io::ErrorKind::PermissionDenied,
                "cannot determine effective uid",
            )
        })
}

#[cfg(test)]
mod tests {
    use super::*;
    use std::os::unix::fs::{symlink, PermissionsExt};

    #[test]
    fn native_path_requires_absolute_path_and_private_owned_directory() {
        let directory = tempfile::tempdir().unwrap();
        fs::set_permissions(directory.path(), fs::Permissions::from_mode(0o700)).unwrap();
        assert_eq!(
            fs::metadata(directory.path()).unwrap().uid(),
            effective_uid().unwrap()
        );
        let path = directory.path().join("native-core");
        assert_eq!(validate_socket_path(&path).unwrap(), path);
        assert!(validate_socket_path(Path::new("relative/core")).is_err());

        for mode in [0o750, 0o707] {
            fs::set_permissions(directory.path(), fs::Permissions::from_mode(mode)).unwrap();
            assert_eq!(
                validate_socket_path(&path).unwrap_err().kind(),
                io::ErrorKind::PermissionDenied
            );
        }
        fs::set_permissions(directory.path(), fs::Permissions::from_mode(0o700)).unwrap();
    }

    #[test]
    fn native_path_resolves_parent_and_does_not_create_or_replace_endpoint() {
        let directory = tempfile::tempdir().unwrap();
        fs::set_permissions(directory.path(), fs::Permissions::from_mode(0o700)).unwrap();
        let private = directory.path().join("private");
        fs::create_dir(&private).unwrap();
        fs::set_permissions(&private, fs::Permissions::from_mode(0o700)).unwrap();
        let alias = directory.path().join("alias");
        symlink(&private, &alias).unwrap();
        let path = private.join("native-core");
        assert_eq!(
            validate_socket_path(&alias.join("native-core")).unwrap(),
            path
        );
        assert!(!path.exists());
        fs::write(&path, b"preserved").unwrap();
        assert_eq!(validate_socket_path(&path).unwrap(), path);
        assert_eq!(fs::read(&path).unwrap(), b"preserved");
        assert!(validate_socket_path(&path.join("child")).is_err());
    }
}
