use std::cell::RefCell;
use std::path::{Path, PathBuf};

use crate::error::{Error, Result};
use crate::flavor::{flavor_from_path, key_env_var};
use crate::key::Key;
use crate::pnvrc::Pnvrc;

/// Where a [`KeyLookup`] found its key.
#[derive(Debug, Clone, PartialEq, Eq)]
#[non_exhaustive]
pub enum KeySource {
    /// The key string itself was given.
    Key,
    /// A key file was named.
    KeyFile(PathBuf),
    /// An environment variable such as `PNV_KEY_PRODUCTION`.
    EnvVar(String),
    /// A flavor's key file in the `.pnvrc` storage directory.
    Storage(PathBuf),
}

/// A key and where it came from.
#[derive(Debug, Clone, PartialEq, Eq)]
pub struct ResolvedKey {
    /// The key.
    pub key: Key,
    /// Where it came from.
    pub source: KeySource,
    /// The flavor whose key it is, when it was found through one. For an
    /// alias, this is the flavor it belongs to.
    pub flavor: Option<String>,
}

/// Picks the key for a command, the same way for every command.
///
/// The first match wins:
///
/// 1. [`key`](Self::key): the key string itself.
/// 2. [`key_file`](Self::key_file): the contents of that file, trimmed.
/// 3. [`flavor`](Self::flavor), or else the flavor the
///    [`file`](Self::file)'s name implies (see [`flavor_from_path`]):
///    1. the `PNV_KEY_<FLAVOR>` environment variable (see [`key_env_var`]),
///       trimmed;
///    2. `<storage>/<flavor>.key` from the `.pnvrc`;
///    3. otherwise, for each flavor in file order that lists it as an alias,
///       that flavor's environment variable, then its key file.
///
/// The environment variable lets a build server supply a key with no
/// `.pnvrc` or key file at all. The `.pnvrc` is only read when it is needed.
///
/// ```no_run
/// let found = pnv::KeyLookup::new().file("config/app.production.yaml").resolve()?;
/// println!("using the key from {:?}", found.source);
/// # Ok::<(), pnv::Error>(())
/// ```
#[derive(Debug, Clone, Default)]
pub struct KeyLookup {
    key: Option<String>,
    key_file: Option<PathBuf>,
    flavor: Option<String>,
    file: Option<PathBuf>,
}

impl KeyLookup {
    /// A lookup with nothing given yet.
    pub fn new() -> Self {
        Self::default()
    }

    /// Uses this key string, as given to `--key`. It is not trimmed; an
    /// empty or blank string counts as no key.
    #[must_use]
    pub fn key(mut self, key: impl Into<String>) -> Self {
        self.key = Some(key.into());
        self
    }

    /// Reads the key from this file, as given to `--key-file`.
    #[must_use]
    pub fn key_file(mut self, path: impl Into<PathBuf>) -> Self {
        self.key_file = Some(path.into());
        self
    }

    /// Uses this flavor's key, as given to `--flavor`. A blank name counts as
    /// no flavor.
    #[must_use]
    pub fn flavor(mut self, flavor: impl Into<String>) -> Self {
        self.flavor = Some(flavor.into());
        self
    }

    /// The file being worked on. When no key, key file or flavor is given,
    /// its name picks the flavor.
    #[must_use]
    pub fn file(mut self, path: impl Into<PathBuf>) -> Self {
        self.file = Some(path.into());
        self
    }

    /// Finds the key, reading the process environment and, when a flavor is
    /// involved, the nearest `.pnvrc` above the current directory.
    ///
    /// # Errors
    ///
    /// [`Error::NoKey`] when nothing names a key, [`Error::KeyNotFound`] when
    /// a flavor has no key anywhere, and the errors of reading and decoding
    /// the key or loading the `.pnvrc`.
    pub fn resolve(&self) -> Result<ResolvedKey> {
        self.resolve_inner(
            &mut || {
                let cwd = std::env::current_dir()
                    .map_err(|err| Error::io("find", Path::new("."), &err))?;
                Ok(Pnvrc::discover(cwd)?.map(|(_, pnvrc)| pnvrc))
            },
            &|name| std::env::var(name).ok(),
        )
    }

    /// Finds the key with a `.pnvrc` already in hand and `env` standing in
    /// for the process environment.
    ///
    /// # Errors
    ///
    /// As [`KeyLookup::resolve`].
    pub fn resolve_with(
        &self,
        pnvrc: Option<&Pnvrc>,
        env: impl Fn(&str) -> Option<String>,
    ) -> Result<ResolvedKey> {
        self.resolve_inner(&mut || Ok(pnvrc.cloned()), &env)
    }

    /// As [`KeyLookup::resolve`], also saying what the lookup looked at: the
    /// environment variables it read and the `.pnvrc` it loaded, so a build
    /// script can ask cargo to rerun when one of them changes.
    pub(crate) fn resolve_traced(&self) -> (Result<ResolvedKey>, Trace) {
        let env_vars = RefCell::new(Vec::new());
        let mut pnvrc = None;
        let result = self.resolve_inner(
            &mut || {
                let cwd = std::env::current_dir()
                    .map_err(|err| Error::io("find", Path::new("."), &err))?;
                let Some(path) = Pnvrc::find(cwd) else {
                    return Ok(None);
                };
                pnvrc = Some(path.clone());
                Pnvrc::load(&path)
            },
            &|name| {
                env_vars.borrow_mut().push(name.to_owned());
                std::env::var(name).ok()
            },
        );
        let trace = Trace {
            env_vars: env_vars.into_inner(),
            pnvrc,
        };
        (result, trace)
    }

    fn resolve_inner(
        &self,
        load: &mut dyn FnMut() -> Result<Option<Pnvrc>>,
        env: &dyn Fn(&str) -> Option<String>,
    ) -> Result<ResolvedKey> {
        if let Some(key) = self.key.as_deref().filter(|key| !key.trim().is_empty()) {
            return Ok(ResolvedKey {
                key: Key::decode(key)?,
                source: KeySource::Key,
                flavor: None,
            });
        }

        if let Some(path) = &self.key_file {
            return Ok(ResolvedKey {
                key: Key::read_file(path)?,
                source: KeySource::KeyFile(path.clone()),
                flavor: None,
            });
        }

        if let Some(flavor) = self
            .flavor
            .as_deref()
            .map(str::trim)
            .filter(|flavor| !flavor.is_empty())
        {
            return find_flavor_key(flavor, None, load, env);
        }

        if let Some(file) = &self.file {
            let flavor = flavor_from_path(file);
            if flavor.is_empty() {
                return Err(Error::NoKey {
                    file: Some(file.clone()),
                });
            }
            return find_flavor_key(&flavor, Some(file), load, env);
        }

        Err(Error::NoKey { file: None })
    }
}

/// What a [`KeyLookup`] looked at.
#[derive(Debug, Default)]
pub(crate) struct Trace {
    /// Every environment variable read, in order.
    pub(crate) env_vars: Vec<String>,
    /// The `.pnvrc` that was found, when one was needed.
    pub(crate) pnvrc: Option<PathBuf>,
}

fn find_flavor_key(
    name: &str,
    file: Option<&PathBuf>,
    load: &mut dyn FnMut() -> Result<Option<Pnvrc>>,
    env: &dyn Fn(&str) -> Option<String>,
) -> Result<ResolvedKey> {
    let env_var = key_env_var(name);
    if let Some(found) = from_env(&env_var, name, env)? {
        return Ok(found);
    }

    let not_found = |key_file| Error::KeyNotFound {
        flavor: name.to_owned(),
        env_var: env_var.clone(),
        key_file,
        file: file.cloned(),
    };

    let Some(pnvrc) = load()? else {
        return Err(not_found(None));
    };

    let key_file = pnvrc.key_file(name)?;
    if let Some(found) = from_storage(&key_file, name)? {
        return Ok(found);
    }

    for owner in pnvrc
        .flavors()
        .iter()
        .filter(|owner| owner.name() != name && owner.aliases().iter().any(|a| a == name))
    {
        if let Some(found) = from_env(&key_env_var(owner.name()), owner.name(), env)? {
            return Ok(found);
        }
        if let Some(found) = from_storage(&pnvrc.key_file(owner.name())?, owner.name())? {
            return Ok(found);
        }
    }

    Err(not_found(Some(key_file)))
}

fn from_env(
    var: &str,
    flavor: &str,
    env: &dyn Fn(&str) -> Option<String>,
) -> Result<Option<ResolvedKey>> {
    let Some(value) = env(var).filter(|value| !value.trim().is_empty()) else {
        return Ok(None);
    };
    Ok(Some(ResolvedKey {
        key: Key::from_key_file(&value)?,
        source: KeySource::EnvVar(var.to_owned()),
        flavor: Some(flavor.to_owned()),
    }))
}

fn from_storage(path: &Path, flavor: &str) -> Result<Option<ResolvedKey>> {
    if !path.is_file() {
        return Ok(None);
    }
    Ok(Some(ResolvedKey {
        key: Key::read_file(path)?,
        source: KeySource::Storage(path.to_path_buf()),
        flavor: Some(flavor.to_owned()),
    }))
}

#[cfg(test)]
mod tests {
    use std::collections::HashMap;

    use super::*;
    use crate::key::write_key_file;

    const LOCAL: &str = "oI0tNittVqP_nLwY";
    const PROD: &str = "AAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA=";
    const CI: &str = "AQEBAQEBAQEBAQEBAQEBAQEBAQEBAQEBAQEBAQEBAQE=";

    struct Project {
        _dir: tempfile::TempDir,
        storage: PathBuf,
        pnvrc: Pnvrc,
    }

    fn project() -> Project {
        let dir = tempfile::tempdir().unwrap();
        let storage = dir.path().join("keys");
        let pnvrc = Pnvrc::parse(&format!(
            r#"{{"storage": {:?}, "flavors": {{"local": [], "production": ["prod", "ci"]}}}}"#,
            storage.to_str().unwrap()
        ))
        .unwrap()
        .unwrap();
        write_key_file(storage.join("local.key"), LOCAL).unwrap();
        write_key_file(storage.join("production.key"), PROD).unwrap();
        Project {
            _dir: dir,
            storage,
            pnvrc,
        }
    }

    fn env(vars: &[(&str, &str)]) -> impl Fn(&str) -> Option<String> {
        let vars: HashMap<String, String> = vars
            .iter()
            .map(|(k, v)| ((*k).to_owned(), (*v).to_owned()))
            .collect();
        move |name| vars.get(name).cloned()
    }

    fn no_env(_: &str) -> Option<String> {
        None
    }

    #[test]
    fn a_key_wins_over_everything() {
        let p = project();
        let found = KeyLookup::new()
            .key(CI)
            .key_file("/missing")
            .flavor("local")
            .resolve_with(Some(&p.pnvrc), env(&[("PNV_KEY_LOCAL", PROD)]))
            .unwrap();
        assert_eq!(found.key.encode(), CI);
        assert_eq!(found.source, KeySource::Key);
    }

    #[test]
    fn a_blank_key_counts_as_none() {
        let p = project();
        let found = KeyLookup::new()
            .key("  ")
            .flavor("local")
            .resolve_with(Some(&p.pnvrc), no_env)
            .unwrap();
        assert_eq!(found.key.encode(), LOCAL);
    }

    #[test]
    fn a_key_file_wins_over_a_flavor() {
        let p = project();
        let path = p.storage.join("other.key");
        write_key_file(&path, &format!("  {CI}\n")).unwrap();
        let found = KeyLookup::new()
            .key_file(&path)
            .flavor("local")
            .resolve_with(Some(&p.pnvrc), no_env)
            .unwrap();
        assert_eq!(found.key.encode(), CI);
        assert_eq!(found.source, KeySource::KeyFile(path));
    }

    #[test]
    fn a_missing_key_file_does_not_fall_back() {
        let p = project();
        let err = KeyLookup::new()
            .key_file(p.storage.join("nope.key"))
            .flavor("local")
            .resolve_with(Some(&p.pnvrc), no_env)
            .unwrap_err();
        assert_eq!(err.kind().as_str(), "io");
    }

    #[test]
    fn a_flavor_uses_its_key_file() {
        let p = project();
        let found = KeyLookup::new()
            .flavor(" local ")
            .resolve_with(Some(&p.pnvrc), no_env)
            .unwrap();
        assert_eq!(found.key.encode(), LOCAL);
        assert_eq!(
            found.source,
            KeySource::Storage(p.storage.join("local.key"))
        );
        assert_eq!(found.flavor.as_deref(), Some("local"));
    }

    #[test]
    fn the_env_var_comes_before_the_key_file_and_is_trimmed() {
        let p = project();
        let found = KeyLookup::new()
            .flavor("local")
            .resolve_with(
                Some(&p.pnvrc),
                env(&[("PNV_KEY_LOCAL", &format!("{CI}\n"))]),
            )
            .unwrap();
        assert_eq!(found.key.encode(), CI);
        assert_eq!(found.source, KeySource::EnvVar("PNV_KEY_LOCAL".into()));
    }

    #[test]
    fn a_blank_env_var_is_skipped() {
        let p = project();
        let found = KeyLookup::new()
            .flavor("local")
            .resolve_with(Some(&p.pnvrc), env(&[("PNV_KEY_LOCAL", " ")]))
            .unwrap();
        assert_eq!(found.key.encode(), LOCAL);
    }

    #[test]
    fn the_env_var_needs_no_pnvrc() {
        let found = KeyLookup::new()
            .flavor("staging-eu")
            .resolve_with(None, env(&[("PNV_KEY_STAGING_EU", CI)]))
            .unwrap();
        assert_eq!(found.key.encode(), CI);
    }

    #[test]
    fn the_pnvrc_is_only_loaded_when_needed() {
        let mut loaded = false;
        let found = KeyLookup::new()
            .flavor("local")
            .resolve_inner(
                &mut || {
                    loaded = true;
                    Ok(None)
                },
                &env(&[("PNV_KEY_LOCAL", LOCAL)]),
            )
            .unwrap();
        assert_eq!(found.key.encode(), LOCAL);
        assert!(!loaded);
    }

    #[test]
    fn an_alias_uses_its_flavors_key() {
        let p = project();
        let found = KeyLookup::new()
            .flavor("prod")
            .resolve_with(Some(&p.pnvrc), no_env)
            .unwrap();
        assert_eq!(found.key.encode(), PROD);
        assert_eq!(found.flavor.as_deref(), Some("production"));

        let found = KeyLookup::new()
            .flavor("prod")
            .resolve_with(Some(&p.pnvrc), env(&[("PNV_KEY_PRODUCTION", CI)]))
            .unwrap();
        assert_eq!(found.source, KeySource::EnvVar("PNV_KEY_PRODUCTION".into()));
    }

    #[test]
    fn an_aliases_own_key_file_comes_first() {
        let p = project();
        write_key_file(p.storage.join("ci.key"), CI).unwrap();
        let found = KeyLookup::new()
            .flavor("ci")
            .resolve_with(Some(&p.pnvrc), no_env)
            .unwrap();
        assert_eq!(found.key.encode(), CI);
        assert_eq!(found.flavor.as_deref(), Some("ci"));
    }

    #[test]
    fn the_file_name_picks_the_flavor() {
        let p = project();
        let found = KeyLookup::new()
            .file("config/app.prod.yaml")
            .resolve_with(Some(&p.pnvrc), no_env)
            .unwrap();
        assert_eq!(found.key.encode(), PROD);

        let found = KeyLookup::new()
            .flavor("local")
            .file("config/app.prod.yaml")
            .resolve_with(Some(&p.pnvrc), no_env)
            .unwrap();
        assert_eq!(found.key.encode(), LOCAL);
    }

    #[test]
    fn says_which_key_it_could_not_find() {
        let p = project();
        let err = KeyLookup::new()
            .file("app.staging.yaml")
            .resolve_with(Some(&p.pnvrc), no_env)
            .unwrap_err();
        assert_eq!(
            err,
            Error::KeyNotFound {
                flavor: "staging".into(),
                env_var: "PNV_KEY_STAGING".into(),
                key_file: Some(p.storage.join("staging.key")),
                file: Some("app.staging.yaml".into()),
            }
        );
        let message = err.to_string();
        assert!(message.contains("PNV_KEY_STAGING"), "{message}");
        assert!(message.contains("staging.key"), "{message}");

        let err = KeyLookup::new()
            .flavor("local")
            .resolve_with(None, no_env)
            .unwrap_err();
        assert!(err.to_string().contains("no .pnvrc"), "{err}");
    }

    #[test]
    fn nothing_given_is_no_key() {
        let p = project();
        let err = KeyLookup::new()
            .resolve_with(Some(&p.pnvrc), no_env)
            .unwrap_err();
        assert_eq!(err, Error::NoKey { file: None });

        let err = KeyLookup::new()
            .flavor(" ")
            .file(".env")
            .resolve_with(Some(&p.pnvrc), no_env)
            .unwrap_err();
        assert_eq!(
            err,
            Error::NoKey {
                file: Some(".env".into())
            }
        );
    }
}
