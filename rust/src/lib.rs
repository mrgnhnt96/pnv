//! Encrypted secrets in YAML files that are safe to commit.
//!
//! This crate reads and writes the same keys and `SECRET;` tokens as the Dart
//! `pnv` tool, following the shared format spec in the repository's `spec/`
//! folder.
//!
//! ```
//! use pnv::{Key, create_key, decrypt, encrypt};
//!
//! let key = Key::decode(&create_key()?)?;
//! let token = encrypt("hunter2", &key)?;
//!
//! assert!(token.starts_with("SECRET;v1:"));
//! assert_eq!(decrypt(&token, &key)?, "hunter2");
//! # Ok::<(), pnv::Error>(())
//! ```
//!
//! The `pnv` command is behind the default `cli` feature. A build script that
//! only needs the library can turn it off:
//!
//! ```toml
//! [build-dependencies]
//! pnv = { version = "0.1", default-features = false }
//! ```

#![warn(missing_docs)]

mod b64;
mod error;
mod flavor;
mod key;
mod lookup;
mod pnvrc;
mod token;

#[cfg(test)]
mod vectors;

pub use error::{Error, ErrorKind, MalformedReason, Result};
pub use flavor::{KEY_ENV_PREFIX, flavor_from_path, is_valid_flavor_name, key_env_var};
pub use key::{
    KEY_ID_LENGTH, Key, KeyId, MIN_KEY_LENGTH, NEW_KEY_LENGTH, create_key, write_key_file,
};
pub use lookup::{KeyLookup, KeySource, ResolvedKey};
pub use pnvrc::{Flavor, KEY_FILE_EXTENSION, PNVRC_FILE_NAME, Pnvrc};
pub use token::{
    IV_LENGTH, SECRET_PREFIX, TAG_LENGTH, Token, Version, decrypt, encrypt, is_secret,
};
