//! Hands the values of a YAML file to the compiler from a build script.
//!
//! Each value becomes a compile-time environment variable that the crate
//! reads with [`env!`], so the program carries its configuration without
//! reading the file when it runs:
//!
//! ```no_run
//! // build.rs, in `fn main`
//! pnv::build::Build::new("config/app.production.yaml")
//!     .emit()
//!     .unwrap_or_else(|err| panic!("{err}"));
//! ```
//!
//! ```ignore
//! // src/main.rs
//! const DATABASE_URL: &str = env!("DATABASE_URL");
//! ```
//!
//! The key is found as [`KeyLookup`] finds it, from the build script's
//! directory (the package root). On a build server, set the flavor's
//! `PNV_KEY_<FLAVOR>` variable.
//!
//! Two things to know:
//!
//! - Printing `rerun-if-changed` tells cargo to rerun the build script only
//!   when the named files change, not on every change in the package, which
//!   is cargo's default. A build script that also depends on other files
//!   must name them too.
//! - The decrypted values are compiled into the program, and cargo keeps
//!   the build script's output under `target/`. Anyone with the binary or
//!   the build directory can read them.
//!
//! Nothing is written to the build script's own environment.

use std::path::{Path, PathBuf};

use crate::env::Env;
use crate::error::{Error, Result};
use crate::lookup::{KeyLookup, KeySource};

/// The cargo instructions for one YAML file. See the [module docs](self).
#[derive(Debug, Clone)]
pub struct Build {
    file: PathBuf,
    lookup: KeyLookup,
}

impl Build {
    /// Values from this YAML file, whose name picks the flavor and so the
    /// key (`app.production.yaml` gives `production`) unless
    /// [`flavor`](Self::flavor) or [`key_file`](Self::key_file) says
    /// otherwise. A relative path is from the package root.
    pub fn new(file: impl Into<PathBuf>) -> Self {
        let file = file.into();
        Self {
            lookup: KeyLookup::new().file(file.clone()),
            file,
        }
    }

    /// Uses this flavor's key instead of the one the file name implies.
    #[must_use]
    pub fn flavor(mut self, flavor: impl Into<String>) -> Self {
        self.lookup = self.lookup.flavor(flavor);
        self
    }

    /// Reads the key from this file instead of looking it up by flavor.
    #[must_use]
    pub fn key_file(mut self, path: impl Into<PathBuf>) -> Self {
        self.lookup = self.lookup.key_file(path);
        self
    }

    /// Prints the cargo instructions and returns the values, for a build
    /// script that also wants to use them.
    ///
    /// Nothing is printed unless every value can be passed on.
    ///
    /// # Errors
    ///
    /// As [`Build::instructions`].
    pub fn emit(&self) -> Result<Env> {
        let (env, lines) = self.run()?;
        for line in lines {
            println!("{line}");
        }
        Ok(env)
    }

    /// The cargo instructions, one per line, without printing them:
    ///
    /// - `cargo:rerun-if-changed=` for the YAML file, the `.pnvrc` and the
    ///   key file, when they were used and exist;
    /// - `cargo:rerun-if-env-changed=` for every `PNV_KEY_<FLAVOR>` variable
    ///   the key lookup read;
    /// - `cargo:rustc-env=NAME=value` for each value, in file order, as
    ///   plain text: a string unquoted, a float as Dart writes it (`1e3`
    ///   gives `1000.0`), and null as nothing.
    ///
    /// # Errors
    ///
    /// The errors of [`KeyLookup::resolve`] and [`Env::read`];
    /// [`Error::LineBreak`] for a value holding a line break, which cargo
    /// cannot pass on; and [`Error::InvalidEnvName`] for a key whose name is
    /// empty or holds `=`, a NUL or a line break.
    pub fn instructions(&self) -> Result<Vec<String>> {
        self.run().map(|(_, lines)| lines)
    }

    fn run(&self) -> Result<(Env, Vec<String>)> {
        let mut lines = vec![rerun_if_changed(&self.file)];

        let (resolved, trace) = self.lookup.resolve_traced();
        if let Some(pnvrc) = &trace.pnvrc {
            lines.push(rerun_if_changed(pnvrc));
        }
        for var in &trace.env_vars {
            lines.push(format!("cargo:rerun-if-env-changed={var}"));
        }
        let resolved = resolved?;
        if let KeySource::KeyFile(path) | KeySource::Storage(path) = &resolved.source {
            lines.push(rerun_if_changed(path));
        }

        let env = Env::read(&self.file, &resolved.key)?;
        for entry in &env {
            let name = entry.name();
            if name.is_empty() || name.contains(['=', '\0', '\n', '\r']) {
                return Err(Error::InvalidEnvName {
                    name: name.to_owned(),
                    key: entry.key(),
                });
            }
            let value = entry.value().to_string();
            if value.contains(['\n', '\r']) {
                return Err(Error::LineBreak {
                    name: name.to_owned(),
                    key: entry.key(),
                });
            }
            lines.push(format!("cargo:rustc-env={name}={value}"));
        }

        Ok((env, lines))
    }
}

fn rerun_if_changed(path: &Path) -> String {
    format!("cargo:rerun-if-changed={}", path.display())
}

#[cfg(test)]
mod tests {
    use super::*;

    const KEY: &str = "AAECAwQFBgcICQoLDA0ODxAREhMUFRYXGBkaGxwdHh8=";
    const SECRET: &str = "SECRET;v1:ikceywABAgMEBQYHCAkKCyLDfmHplmR3TDvBmf48BQQ9Ry9u/Zx9DFyk6Ao=";

    struct Project {
        dir: tempfile::TempDir,
        key_file: PathBuf,
    }

    impl Project {
        fn new() -> Self {
            let dir = tempfile::tempdir().unwrap();
            let key_file = dir.path().join("test.key");
            std::fs::write(&key_file, KEY).unwrap();
            Self { dir, key_file }
        }

        fn yaml(&self, text: &str) -> PathBuf {
            let path = self.dir.path().join("app.yaml");
            std::fs::write(&path, text).unwrap();
            path
        }

        fn build(&self, text: &str) -> Build {
            Build::new(self.yaml(text)).key_file(&self.key_file)
        }
    }

    #[test]
    fn values_become_rustc_env_lines_in_file_order() {
        let project = Project::new();
        let yaml = format!(
            "name: \"demo app\" # string\nport: 8080\nratio: 1e3\nempty:\ndb:\n  pass-word: {SECRET}\n"
        );
        let lines = project.build(&yaml).instructions().unwrap();
        assert_eq!(
            lines,
            [
                format!(
                    "cargo:rerun-if-changed={}",
                    project.dir.path().join("app.yaml").display()
                ),
                format!("cargo:rerun-if-changed={}", project.key_file.display()),
                "cargo:rustc-env=NAME=demo app".to_owned(),
                "cargo:rustc-env=PORT=8080".to_owned(),
                "cargo:rustc-env=RATIO=1000.0".to_owned(),
                "cargo:rustc-env=EMPTY=".to_owned(),
                "cargo:rustc-env=DB_PASS_WORD=s3cr3t-value".to_owned(),
            ]
        );
    }

    #[test]
    fn a_line_break_is_refused_naming_the_key() {
        let project = Project::new();
        let err = project
            .build("ok: 1\ndb:\n  cert: |\n    line one\n    line two\n")
            .instructions()
            .unwrap_err();
        assert_eq!(
            err,
            Error::LineBreak {
                name: "DB_CERT".into(),
                key: "db.cert".into()
            }
        );
        assert!(err.to_string().contains("\"db.cert\""), "{err}");

        let err = project.build("a: \"x\\ry\"\n").instructions().unwrap_err();
        assert_eq!(err.kind().as_str(), "line-break");
    }

    #[test]
    fn a_name_cargo_cannot_set_is_refused() {
        let project = Project::new();
        for yaml in ["\"a=b\": 1\n", "\"\": 1\n", "\"a\\nb\": 1\n"] {
            let err = project.build(yaml).instructions().unwrap_err();
            assert_eq!(err.kind().as_str(), "invalid-env-name", "{yaml:?}");
        }
    }

    #[test]
    fn every_key_variable_the_lookup_reads_is_watched() {
        let (result, trace) = KeyLookup::new()
            .flavor("pnv-build-test-unset")
            .resolve_traced();
        assert_eq!(result.unwrap_err().kind().as_str(), "key-not-found");
        assert_eq!(trace.env_vars, ["PNV_KEY_PNV_BUILD_TEST_UNSET"]);
    }

    #[test]
    fn a_missing_key_fails_before_anything_is_printed() {
        let project = Project::new();
        let file = project.yaml("a: 1\n");
        let err = Build::new(&file)
            .key_file(project.dir.path().join("missing.key"))
            .instructions()
            .unwrap_err();
        assert_eq!(err.kind().as_str(), "io");
    }
}
