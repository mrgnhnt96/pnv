use std::fmt;
use std::io;
use std::path::{Path, PathBuf};

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
    /// A `.pnvrc` is not valid JSON, or a field is missing or of the wrong
    /// type.
    InvalidPnvrc {
        /// The file, when it was read from one.
        path: Option<PathBuf>,
        /// What is wrong with it.
        reason: String,
    },
    /// A name appears more than once among a `.pnvrc`'s flavors and aliases.
    FlavorConflict {
        /// The file, when it was read from one.
        path: Option<PathBuf>,
        /// The name that appears twice.
        name: String,
    },
    /// A new flavor's name has characters other than letters, digits, `_`
    /// and `-`.
    InvalidFlavorName {
        /// The name that was refused.
        name: String,
    },
    /// The home directory is needed to expand `~` and is not set.
    NoHome,
    /// A file could not be read or written.
    Io {
        /// What was being done, such as `read`.
        action: &'static str,
        /// The file.
        path: PathBuf,
        /// The operating system's kind of error.
        kind: io::ErrorKind,
        /// The operating system's message.
        message: String,
    },
    /// No key, key file or flavor was given, and none could be inferred.
    NoKey {
        /// The file being worked on, whose name implies no flavor.
        file: Option<PathBuf>,
    },
    /// A flavor was named, but none of the places its key may be holds one.
    KeyNotFound {
        /// The flavor or alias that was looked up.
        flavor: String,
        /// The environment variable that was checked.
        env_var: String,
        /// The key file that was checked; `None` when there is no `.pnvrc`.
        key_file: Option<PathBuf>,
        /// The file being worked on, when its name gave the flavor.
        file: Option<PathBuf>,
    },
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
    /// See [`Error::InvalidPnvrc`].
    InvalidPnvrc,
    /// See [`Error::FlavorConflict`].
    FlavorConflict,
    /// See [`Error::InvalidFlavorName`].
    InvalidFlavorName,
    /// See [`Error::NoHome`].
    NoHome,
    /// See [`Error::Io`].
    Io,
    /// See [`Error::NoKey`].
    NoKey,
    /// See [`Error::KeyNotFound`].
    KeyNotFound,
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
            Self::InvalidPnvrc => "invalid",
            Self::FlavorConflict => "conflict",
            Self::InvalidFlavorName => "invalid-flavor-name",
            Self::NoHome => "no-home",
            Self::Io => "io",
            Self::NoKey => "no-key",
            Self::KeyNotFound => "key-not-found",
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
            Self::InvalidPnvrc { .. } => ErrorKind::InvalidPnvrc,
            Self::FlavorConflict { .. } => ErrorKind::FlavorConflict,
            Self::InvalidFlavorName { .. } => ErrorKind::InvalidFlavorName,
            Self::NoHome => ErrorKind::NoHome,
            Self::Io { .. } => ErrorKind::Io,
            Self::NoKey { .. } => ErrorKind::NoKey,
            Self::KeyNotFound { .. } => ErrorKind::KeyNotFound,
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
            _ => {}
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
            _ => None,
        }
    }

    pub(crate) fn io(action: &'static str, path: &Path, err: &io::Error) -> Self {
        Self::Io {
            action,
            path: path.to_path_buf(),
            kind: err.kind(),
            message: err.to_string(),
        }
    }

    pub(crate) fn with_pnvrc_path(mut self, file: &Path) -> Self {
        if let Self::InvalidPnvrc { path, .. } | Self::FlavorConflict { path, .. } = &mut self {
            *path = Some(file.to_path_buf());
        }
        self
    }
}

struct In<'a>(Option<&'a Path>);

impl fmt::Display for In<'_> {
    fn fmt(&self, f: &mut fmt::Formatter<'_>) -> fmt::Result {
        match self.0 {
            Some(path) => write!(f, " in {}", path.display()),
            None => Ok(()),
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
            Self::InvalidPnvrc { path, reason } => {
                write!(f, "Invalid .pnvrc{}: {reason}", In(path.as_deref()))
            }
            Self::FlavorConflict { path, name } => write!(
                f,
                "Flavors have conflicts{}: \"{name}\" is used more than once. Every flavor \
                 and alias must be unique.",
                In(path.as_deref())
            ),
            Self::InvalidFlavorName { name } => write!(
                f,
                "Invalid flavor name \"{name}\": a flavor name can only contain letters, \
                 numbers, underscores and dashes."
            ),
            Self::NoHome => f.write_str(
                "Failed to find the home directory: set HOME (USERPROFILE on Windows) to expand \
                 `~` in the .pnvrc storage path.",
            ),
            Self::Io {
                action,
                path,
                message,
                ..
            } => write!(f, "Could not {action} \"{}\": {message}", path.display()),
            Self::NoKey { file: None } => f.write_str("Missing key, key file, or flavor."),
            Self::NoKey { file: Some(file) } => write!(
                f,
                "No key for \"{}\": its name implies no flavor. Pass a key, key file, or \
                 flavor.",
                file.display()
            ),
            Self::KeyNotFound {
                flavor,
                env_var,
                key_file,
                file,
            } => {
                match file {
                    Some(file) => write!(
                        f,
                        "No key for \"{}\": its name implies flavor \"{flavor}\", which has \
                         no key. ",
                        file.display()
                    )?,
                    None => write!(f, "No key for flavor \"{flavor}\". ")?,
                }
                match key_file {
                    Some(key_file) => write!(
                        f,
                        "{env_var} is not set and \"{}\" does not exist.",
                        key_file.display()
                    ),
                    None => write!(
                        f,
                        "{env_var} is not set and no .pnvrc was found. Run `pnv init` first."
                    ),
                }
            }
        }
    }
}

impl std::error::Error for Error {}
