use std::fmt;

use crate::key::MIN_KEY_LENGTH;

/// Shorthand for a result whose error is [`Error`].
pub type Result<T, E = Error> = std::result::Result<T, E>;

/// Everything that can go wrong with a key or a secret.
///
/// The messages match the Dart tool's word for word, so a user sees the same
/// text whichever tool they run. A corrupt value ([`Error::Malformed`]) is
/// always told apart from a key problem ([`Error::WrongKey`],
/// [`Error::DecryptFailed`]).
#[derive(Debug, Clone, PartialEq, Eq)]
#[non_exhaustive]
pub enum Error {
    /// The key string is not valid base64.
    InvalidKey,
    /// The key decodes to fewer than [`MIN_KEY_LENGTH`] bytes.
    KeyTooShort {
        /// How many bytes the key decoded to.
        len: usize,
    },
    /// The value does not start with `SECRET;`.
    NotASecret {
        /// Where the value came from, such as a file and key path.
        context: Option<String>,
    },
    /// The token's payload is not base64, or too short to hold its fields.
    Malformed {
        /// Where the value came from, such as a file and key path.
        context: Option<String>,
        /// What is wrong with the payload.
        reason: MalformedReason,
    },
    /// A v1 token's key id does not match the key in hand.
    WrongKey {
        /// Where the value came from, such as a file and key path.
        context: Option<String>,
    },
    /// The auth tag did not verify, or the plaintext is not UTF-8.
    DecryptFailed {
        /// Where the value came from, such as a file and key path.
        context: Option<String>,
    },
    /// The operating system could not supply random bytes.
    Random(getrandom::Error),
}

/// Why a token is [`Error::Malformed`].
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
#[non_exhaustive]
pub enum MalformedReason {
    /// The payload is not valid base64.
    NotBase64,
    /// The payload decoded, but is too short for a header and an auth tag.
    TooShort {
        /// How many bytes the payload decoded to.
        len: usize,
    },
}

/// The kind of an [`Error`], named as in the format spec's test vectors.
#[derive(Debug, Clone, Copy, PartialEq, Eq, Hash)]
#[non_exhaustive]
pub enum ErrorKind {
    /// See [`Error::InvalidKey`].
    InvalidKey,
    /// See [`Error::KeyTooShort`].
    KeyTooShort,
    /// See [`Error::NotASecret`].
    NotASecret,
    /// See [`Error::Malformed`].
    Malformed,
    /// See [`Error::WrongKey`].
    WrongKey,
    /// See [`Error::DecryptFailed`].
    DecryptFailed,
    /// See [`Error::Random`].
    Random,
}

impl ErrorKind {
    /// The name the format spec uses for this kind, such as `wrong-key`.
    pub fn as_str(self) -> &'static str {
        match self {
            Self::InvalidKey => "invalid-key",
            Self::KeyTooShort => "key-too-short",
            Self::NotASecret => "not-a-secret",
            Self::Malformed => "malformed",
            Self::WrongKey => "wrong-key",
            Self::DecryptFailed => "decrypt-failed",
            Self::Random => "random",
        }
    }
}

impl fmt::Display for ErrorKind {
    fn fmt(&self, f: &mut fmt::Formatter<'_>) -> fmt::Result {
        f.write_str(self.as_str())
    }
}

impl Error {
    /// The kind of this error.
    pub fn kind(&self) -> ErrorKind {
        match self {
            Self::InvalidKey => ErrorKind::InvalidKey,
            Self::KeyTooShort { .. } => ErrorKind::KeyTooShort,
            Self::NotASecret { .. } => ErrorKind::NotASecret,
            Self::Malformed { .. } => ErrorKind::Malformed,
            Self::WrongKey { .. } => ErrorKind::WrongKey,
            Self::DecryptFailed { .. } => ErrorKind::DecryptFailed,
            Self::Random(_) => ErrorKind::Random,
        }
    }

    /// Names where a secret came from, such as `app.yaml: db.password`, so a
    /// failure in a file of forty values says which one failed.
    ///
    /// Errors that are not about one secret are returned unchanged.
    #[must_use]
    pub fn with_context(mut self, where_: impl Into<String>) -> Self {
        match &mut self {
            Self::NotASecret { context }
            | Self::Malformed { context, .. }
            | Self::WrongKey { context }
            | Self::DecryptFailed { context } => *context = Some(where_.into()),
            Self::InvalidKey | Self::KeyTooShort { .. } | Self::Random(_) => {}
        }
        self
    }

    /// Where the secret came from, if [`Error::with_context`] named it.
    pub fn context(&self) -> Option<&str> {
        match self {
            Self::NotASecret { context }
            | Self::Malformed { context, .. }
            | Self::WrongKey { context }
            | Self::DecryptFailed { context } => context.as_deref(),
            Self::InvalidKey | Self::KeyTooShort { .. } | Self::Random(_) => None,
        }
    }
}

struct Where<'a>(Option<&'a str>);

impl fmt::Display for Where<'_> {
    fn fmt(&self, f: &mut fmt::Formatter<'_>) -> fmt::Result {
        match self.0 {
            Some(context) => write!(f, " ({context})"),
            None => Ok(()),
        }
    }
}

impl fmt::Display for Error {
    fn fmt(&self, f: &mut fmt::Formatter<'_>) -> fmt::Result {
        let at = Where(self.context());
        match self {
            Self::InvalidKey => f.write_str(
                "Key is not valid base64. A key looks like the output of `pnv create key`.",
            ),
            Self::KeyTooShort { len } => write!(
                f,
                "Key is too short: {len} bytes, minimum is {MIN_KEY_LENGTH}. \
                 Generate one with `pnv create key`."
            ),
            Self::NotASecret { .. } => write!(
                f,
                "Not a pnv secret{at}: expected it to start with \"{}\".",
                crate::token::SECRET_PREFIX
            ),
            Self::Malformed {
                reason: MalformedReason::NotBase64,
                ..
            } => write!(
                f,
                "Malformed secret{at}: the value after the prefix is not valid base64. \
                 This is a corrupt value, not a key problem."
            ),
            Self::Malformed {
                reason: MalformedReason::TooShort { len },
                ..
            } => write!(
                f,
                "Malformed secret{at}: {len} bytes is too short to contain a header and an \
                 auth tag. This is a corrupt value, not a key problem."
            ),
            Self::WrongKey { .. } => write!(
                f,
                "Wrong key{at}: this secret was encrypted with a different key. Check the \
                 flavor \u{2014} a secret from another environment may have been pasted into \
                 this file."
            ),
            Self::DecryptFailed { .. } => write!(
                f,
                "Failed to decrypt{at}. The value is well formed, so this is most likely the \
                 wrong key."
            ),
            Self::Random(err) => write!(f, "Could not get random bytes from the system: {err}"),
        }
    }
}

impl std::error::Error for Error {}
