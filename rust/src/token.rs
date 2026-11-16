use aes_gcm::aead::{Aead, KeyInit};
use aes_gcm::{Aes256Gcm, Nonce};

use crate::b64;
use crate::error::{Error, MalformedReason, Result};
use crate::key::{KEY_ID_LENGTH, Key, KeyId};

/// Every pnv secret starts with this, in every version.
///
/// Scripts outside pnv match on it (`SECRET;*`, `^\s*key:\s*SECRET;`), so a
/// version marker goes after it, never before.
pub const SECRET_PREFIX: &str = "SECRET;";

const V1_MARKER: &str = "v1:";

/// Length of the AES-GCM nonce.
pub const IV_LENGTH: usize = 12;

/// Length of the AES-GCM auth tag.
pub const TAG_LENGTH: usize = 16;

/// Whether `value` is a pnv secret of any version.
pub fn is_secret(value: &str) -> bool {
    value.starts_with(SECRET_PREFIX)
}

/// The layout version of a [`Token`].
#[derive(Debug, Clone, Copy, PartialEq, Eq, Hash)]
#[non_exhaustive]
pub enum Version {
    /// `SECRET;` + base64(tag, iv, ciphertext, tag), written before pnv 2.0.
    /// Read only.
    V0,
    /// `SECRET;v1:` + base64(key id, iv, ciphertext, tag). The only version
    /// written.
    V1,
}

/// A parsed `SECRET;` token of either version.
#[derive(Debug, Clone, PartialEq, Eq)]
pub struct Token {
    version: Version,
    key_id: Option<KeyId>,
    iv: [u8; IV_LENGTH],
    sealed: Vec<u8>,
}

impl Token {
    /// Parses a token without decrypting it.
    ///
    /// # Errors
    ///
    /// [`Error::NotASecret`] without the `SECRET;` prefix, and
    /// [`Error::Malformed`] when the payload is not base64 or too short.
    pub fn parse(value: &str) -> Result<Self> {
        let rest = value
            .strip_prefix(SECRET_PREFIX)
            .ok_or(Error::NotASecret { context: None })?;

        let (version, encoded) = match rest.strip_prefix(V1_MARKER) {
            Some(encoded) => (Version::V1, encoded),
            None => (Version::V0, rest),
        };

        let payload = b64::decode(encoded).ok_or(Error::Malformed {
            context: None,
            reason: MalformedReason::NotBase64,
        })?;

        let lead = match version {
            Version::V0 => TAG_LENGTH,
            Version::V1 => KEY_ID_LENGTH,
        };
        let header = lead + IV_LENGTH;

        if payload.len() < header + TAG_LENGTH {
            return Err(Error::Malformed {
                context: None,
                reason: MalformedReason::TooShort { len: payload.len() },
            });
        }

        let key_id = match version {
            Version::V0 => None,
            Version::V1 => {
                let mut id = [0; KEY_ID_LENGTH];
                id.copy_from_slice(&payload[..KEY_ID_LENGTH]);
                Some(id)
            }
        };
        let mut iv = [0; IV_LENGTH];
        iv.copy_from_slice(&payload[lead..header]);

        Ok(Self {
            version,
            key_id,
            iv,
            sealed: payload[header..].to_vec(),
        })
    }

    /// The layout version.
    pub fn version(&self) -> Version {
        self.version
    }

    /// The id of the key that encrypted this token, or `None` for v0, which
    /// carried nothing to identify its key.
    pub fn key_id(&self) -> Option<KeyId> {
        self.key_id
    }

    /// The AES-GCM nonce.
    pub fn iv(&self) -> &[u8; IV_LENGTH] {
        &self.iv
    }

    /// The encrypted value, without its auth tag.
    pub fn ciphertext(&self) -> &[u8] {
        &self.sealed[..self.sealed.len() - TAG_LENGTH]
    }

    /// The auth tag. For v0, the trailing copy, which is the one checked.
    pub fn tag(&self) -> &[u8] {
        &self.sealed[self.sealed.len() - TAG_LENGTH..]
    }

    /// Whether `key` made this token, or `None` when it cannot be known
    /// without decrypting (v0).
    pub fn matches_key(&self, key: &Key) -> Option<bool> {
        self.key_id.map(|id| id == key.id())
    }

    /// Decrypts the token.
    ///
    /// A v1 token whose key id does not match `key` fails before the cipher
    /// runs.
    ///
    /// # Errors
    ///
    /// [`Error::WrongKey`] when a v1 key id does not match, and
    /// [`Error::DecryptFailed`] when the auth tag does not verify or the
    /// plaintext is not UTF-8.
    pub fn decrypt(&self, key: &Key) -> Result<String> {
        if self.matches_key(key) == Some(false) {
            return Err(Error::WrongKey { context: None });
        }

        let failed = || Error::DecryptFailed { context: None };
        let plaintext = cipher(key)
            .decrypt(&Nonce::from(self.iv), self.sealed.as_slice())
            .map_err(|_| failed())?;

        String::from_utf8(plaintext).map_err(|_| failed())
    }
}

/// Encrypts `value` into a v1 token, with a fresh random IV.
///
/// The same value encrypted twice gives two different tokens.
///
/// # Errors
///
/// [`Error::Random`] when the system cannot supply random bytes.
pub fn encrypt(value: &str, key: &Key) -> Result<String> {
    let mut iv = [0; IV_LENGTH];
    getrandom::fill(&mut iv).map_err(Error::Random)?;
    Ok(encrypt_with_iv(value, key, iv))
}

/// Parses and decrypts a token in one step.
///
/// # Errors
///
/// Any of [`Token::parse`] and [`Token::decrypt`].
pub fn decrypt(value: &str, key: &Key) -> Result<String> {
    Token::parse(value)?.decrypt(key)
}

pub(crate) fn encrypt_with_iv(value: &str, key: &Key, iv: [u8; IV_LENGTH]) -> String {
    let sealed = cipher(key)
        .encrypt(&Nonce::from(iv), value.as_bytes())
        .expect("AES-GCM encrypts any value shorter than 64 GiB");

    let mut payload = Vec::with_capacity(KEY_ID_LENGTH + IV_LENGTH + sealed.len());
    payload.extend_from_slice(&key.id());
    payload.extend_from_slice(&iv);
    payload.extend_from_slice(&sealed);

    format!(
        "{SECRET_PREFIX}{V1_MARKER}{}",
        b64::encode_standard(&payload)
    )
}

fn cipher(key: &Key) -> Aes256Gcm {
    Aes256Gcm::new(&(*key.aes_key()).into())
}

#[cfg(test)]
mod tests {
    use super::*;

    const KEY: &str = "AAECAwQFBgcICQoLDA0ODxAREhMUFRYXGBkaGxwdHh8=";

    #[test]
    fn round_trips_with_a_fresh_iv_each_time() {
        let key = Key::decode(KEY).unwrap();
        let first = encrypt("hunter2", &key).unwrap();
        let second = encrypt("hunter2", &key).unwrap();

        assert!(first.starts_with("SECRET;v1:"));
        assert_ne!(first, second);
        assert_eq!(decrypt(&first, &key).unwrap(), "hunter2");
        assert_eq!(decrypt(&second, &key).unwrap(), "hunter2");
    }

    #[test]
    fn is_secret_is_case_sensitive() {
        assert!(is_secret("SECRET;anything"));
        assert!(!is_secret("secret;anything"));
        assert!(!is_secret(" SECRET;"));
    }

    #[test]
    fn errors_carry_a_context_and_the_dart_messages() {
        let key = Key::decode(KEY).unwrap();
        let err = decrypt("SECRET;v1:@@@@", &key)
            .unwrap_err()
            .with_context("app.yaml: db.password");

        assert_eq!(
            err.to_string(),
            "Malformed secret (app.yaml: db.password): the value after the prefix is not \
             valid base64. This is a corrupt value, not a key problem."
        );
    }
}
