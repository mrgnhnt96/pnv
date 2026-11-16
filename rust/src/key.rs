use std::fmt;
use std::fs;
use std::io::{self, Write};
use std::path::Path;

use sha2::{Digest, Sha256};

use crate::b64;
use crate::error::{Error, Result};

/// The shortest key accepted, in decoded bytes.
///
/// Keys made before pnv 2.0 are 12 bytes, so this cannot go up without
/// locking their owners out.
pub const MIN_KEY_LENGTH: usize = 12;

/// How many random bytes a new key holds.
pub const NEW_KEY_LENGTH: usize = 32;

/// How many bytes of key id a v1 token carries.
pub const KEY_ID_LENGTH: usize = 4;

const KEY_ID_DOMAIN: &[u8] = b"pnv:key-id:v1";

/// A label that shows which key encrypted a secret, without revealing the key.
pub type KeyId = [u8; KEY_ID_LENGTH];

/// A decoded, validated pnv key.
///
/// The key bytes are never the cipher key: the AES-256 key is their SHA-256,
/// so a key's length is its entropy, not the cipher's key size.
#[derive(Clone, PartialEq, Eq)]
pub struct Key {
    bytes: Vec<u8>,
    aes_key: [u8; 32],
    id: KeyId,
}

impl Key {
    /// Decodes a key string, as given to `--key`.
    ///
    /// The string is used as is, not trimmed. Either base64 alphabet is
    /// accepted.
    ///
    /// # Errors
    ///
    /// [`Error::InvalidKey`] when the string is not base64, and
    /// [`Error::KeyTooShort`] when it decodes to fewer than
    /// [`MIN_KEY_LENGTH`] bytes.
    pub fn decode(key: &str) -> Result<Self> {
        let bytes = b64::decode(key).ok_or(Error::InvalidKey)?;
        Self::from_bytes(bytes)
    }

    /// Decodes the contents of a key file, which are trimmed first.
    ///
    /// # Errors
    ///
    /// As [`Key::decode`]. An empty file is [`Error::KeyTooShort`].
    pub fn from_key_file(contents: &str) -> Result<Self> {
        Self::decode(contents.trim())
    }

    /// Reads and decodes a key file.
    ///
    /// # Errors
    ///
    /// [`Error::Io`] when the file cannot be read, then as
    /// [`Key::from_key_file`].
    pub fn read_file(path: impl AsRef<Path>) -> Result<Self> {
        let path = path.as_ref();
        let contents = fs::read_to_string(path).map_err(|err| Error::io("read", path, &err))?;
        Self::from_key_file(&contents)
    }

    /// Wraps raw key bytes.
    ///
    /// # Errors
    ///
    /// [`Error::KeyTooShort`] when there are fewer than [`MIN_KEY_LENGTH`].
    pub fn from_bytes(bytes: impl Into<Vec<u8>>) -> Result<Self> {
        let bytes = bytes.into();
        if bytes.len() < MIN_KEY_LENGTH {
            return Err(Error::KeyTooShort { len: bytes.len() });
        }

        let aes_key = Sha256::digest(&bytes).into();
        let fingerprint = Sha256::new()
            .chain_update(KEY_ID_DOMAIN)
            .chain_update(&bytes)
            .finalize();
        let mut id = [0; KEY_ID_LENGTH];
        id.copy_from_slice(&fingerprint[..KEY_ID_LENGTH]);

        Ok(Self { bytes, aes_key, id })
    }

    /// The decoded key.
    pub fn bytes(&self) -> &[u8] {
        &self.bytes
    }

    /// The AES-256 key: `SHA-256(key bytes)`.
    pub fn aes_key(&self) -> &[u8; 32] {
        &self.aes_key
    }

    /// The key id: the first 4 bytes of
    /// `SHA-256("pnv:key-id:v1" || key bytes)`.
    pub fn id(&self) -> KeyId {
        self.id
    }

    /// The key written as pnv writes key files: URL-safe base64 with padding.
    pub fn encode(&self) -> String {
        b64::encode_url_safe(&self.bytes)
    }
}

impl fmt::Debug for Key {
    fn fmt(&self, f: &mut fmt::Formatter<'_>) -> fmt::Result {
        let id: String = self.id.iter().map(|b| format!("{b:02x}")).collect();
        f.debug_struct("Key")
            .field("id", &id)
            .finish_non_exhaustive()
    }
}

/// Makes a new key string: [`NEW_KEY_LENGTH`] random bytes, URL-safe base64
/// with padding (44 characters).
///
/// # Errors
///
/// [`Error::Random`] when the system cannot supply random bytes.
pub fn create_key() -> Result<String> {
    let mut bytes = [0; NEW_KEY_LENGTH];
    getrandom::fill(&mut bytes).map_err(Error::Random)?;
    Ok(b64::encode_url_safe(&bytes))
}

/// Writes a key file: the key string with no trailing newline, readable and
/// writable by its owner only (mode `0600`) where the platform allows it.
///
/// The directory is created if needed. An existing file is replaced and its
/// mode tightened too.
///
/// # Errors
///
/// [`Error::Io`] when the directory or file cannot be written.
pub fn write_key_file(path: impl AsRef<Path>, key: &str) -> Result<()> {
    let path = path.as_ref();
    if let Some(dir) = path.parent().filter(|dir| !dir.as_os_str().is_empty()) {
        fs::create_dir_all(dir).map_err(|err| Error::io("create", dir, &err))?;
    }
    write_owner_only(path, key.as_bytes()).map_err(|err| Error::io("write", path, &err))
}

fn write_owner_only(path: &Path, contents: &[u8]) -> io::Result<()> {
    let mut options = fs::OpenOptions::new();
    options.write(true).create(true).truncate(true);

    #[cfg(unix)]
    {
        use std::os::unix::fs::{OpenOptionsExt, PermissionsExt};

        options.mode(0o600);
        let mut file = options.open(path)?;
        file.set_permissions(fs::Permissions::from_mode(0o600))?;
        file.write_all(contents)
    }

    #[cfg(not(unix))]
    {
        options.open(path)?.write_all(contents)
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn create_key_makes_a_44_character_url_safe_key() {
        let key = create_key().unwrap();
        assert_eq!(key.len(), 44);
        assert!(key.ends_with('='));
        assert!(!key.contains(['+', '/']));
        assert_eq!(Key::decode(&key).unwrap().bytes().len(), NEW_KEY_LENGTH);
        assert_ne!(key, create_key().unwrap());
    }

    #[test]
    fn key_file_contents_are_trimmed() {
        let key = Key::from_key_file("  oI0tNittVqP_nLwY\n").unwrap();
        assert_eq!(key.encode(), "oI0tNittVqP_nLwY");
        assert_eq!(
            Key::from_key_file("\n").unwrap_err(),
            Error::KeyTooShort { len: 0 }
        );
    }

    #[test]
    fn key_files_are_owner_only_with_no_newline() {
        let dir = tempfile::tempdir().unwrap();
        let path = dir.path().join("keys/local.key");
        let key = create_key().unwrap();

        write_key_file(&path, "old key, longer than the new one").unwrap();
        #[cfg(unix)]
        {
            use std::os::unix::fs::PermissionsExt;
            fs::set_permissions(&path, fs::Permissions::from_mode(0o644)).unwrap();
        }
        write_key_file(&path, &key).unwrap();

        assert_eq!(fs::read_to_string(&path).unwrap(), key);
        assert_eq!(Key::read_file(&path).unwrap().encode(), key);
        #[cfg(unix)]
        {
            use std::os::unix::fs::PermissionsExt;
            let mode = fs::metadata(&path).unwrap().permissions().mode();
            assert_eq!(mode & 0o777, 0o600);
        }
    }

    #[test]
    fn a_missing_key_file_is_an_io_error() {
        let err = Key::read_file("/no/such/dir/x.key").unwrap_err();
        assert_eq!(err.kind().as_str(), "io");
        assert!(err.to_string().contains("/no/such/dir/x.key"));
    }

    #[test]
    fn debug_hides_the_key() {
        let key = Key::decode("oI0tNittVqP_nLwY").unwrap();
        assert_eq!(format!("{key:?}"), r#"Key { id: "8fc2c735", .. }"#);
    }
}
