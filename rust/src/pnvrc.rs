use std::collections::HashSet;
use std::fs;
use std::io;
use std::path::{Path, PathBuf};

use serde_json::{Map, Value};

use crate::error::{Error, Result};
use crate::flavor::is_valid_flavor_name;

/// The name of the project's pnv configuration file.
pub const PNVRC_FILE_NAME: &str = ".pnvrc";

/// The extension of a key file: `<storage>/<flavor>.key`.
pub const KEY_FILE_EXTENSION: &str = "key";

/// One flavor in a `.pnvrc`: its name and the aliases that resolve to it.
#[derive(Debug, Clone, PartialEq, Eq)]
pub struct Flavor {
    name: String,
    aliases: Vec<String>,
}

impl Flavor {
    /// The flavor's own name, which is also its key file's name.
    pub fn name(&self) -> &str {
        &self.name
    }

    /// The aliases as written, which may include the flavor's own name.
    pub fn aliases(&self) -> &[String] {
        &self.aliases
    }

    /// The flavor's group: its name, then each alias that is not its name.
    pub fn names(&self) -> impl Iterator<Item = &str> {
        std::iter::once(self.name.as_str()).chain(
            self.aliases
                .iter()
                .map(String::as_str)
                .filter(move |alias| *alias != self.name),
        )
    }

    /// Whether `name` is this flavor or one of its aliases.
    pub fn answers_to(&self, name: &str) -> bool {
        self.name == name || self.aliases.iter().any(|alias| alias == name)
    }
}

/// A project's `.pnvrc`: where its keys are stored and which flavors it has.
///
/// ```
/// let pnvrc = pnv::Pnvrc::parse(r#"{
///   "storage": "/keys/my_project",
///   "flavors": { "local": [], "production": ["prod", "ci"] }
/// }"#)?.expect("a .pnvrc");
///
/// assert_eq!(pnvrc.group("ci").unwrap().name(), "production");
/// assert_eq!(
///     pnvrc.key_file("production")?,
///     std::path::Path::new("/keys/my_project/production.key"),
/// );
/// # Ok::<(), pnv::Error>(())
/// ```
#[derive(Debug, Clone, PartialEq, Eq)]
pub struct Pnvrc {
    storage: String,
    flavors: Vec<Flavor>,
}

impl Pnvrc {
    /// A `.pnvrc` with the given storage directory and no flavors.
    pub fn new(storage: impl Into<String>) -> Self {
        Self {
            storage: storage.into(),
            flavors: Vec::new(),
        }
    }

    /// Parses the text of a `.pnvrc`.
    ///
    /// Text that is empty or only whitespace, or JSON that is not an object,
    /// counts as no `.pnvrc` and gives `None`. Unknown fields are ignored.
    ///
    /// # Errors
    ///
    /// [`Error::InvalidPnvrc`] when the text is not JSON, `storage` is
    /// missing or a field has the wrong type, and [`Error::FlavorConflict`]
    /// when a name is used twice among the flavors and aliases.
    pub fn parse(text: &str) -> Result<Option<Self>> {
        if text.trim().is_empty() {
            return Ok(None);
        }

        let value: Value = serde_json::from_str(text).map_err(|err| Error::InvalidPnvrc {
            path: None,
            reason: format!("not valid JSON: {err}"),
        })?;

        match value {
            Value::Object(object) => Self::from_object(&object).map(Some),
            _ => Ok(None),
        }
    }

    fn from_object(object: &Map<String, Value>) -> Result<Self> {
        let invalid = |reason: &str| Error::InvalidPnvrc {
            path: None,
            reason: reason.to_owned(),
        };

        let storage = match object.get("storage") {
            Some(Value::String(storage)) => storage.clone(),
            Some(_) => return Err(invalid("\"storage\" must be a string")),
            None => return Err(invalid("\"storage\" is missing")),
        };

        let flavors = match object.get("flavors") {
            None | Some(Value::Null) => Vec::new(),
            Some(Value::Object(flavors)) => flavors
                .iter()
                .map(|(name, aliases)| {
                    let aliases = aliases
                        .as_array()
                        .and_then(|aliases| {
                            aliases
                                .iter()
                                .map(|alias| alias.as_str().map(str::to_owned))
                                .collect::<Option<Vec<_>>>()
                        })
                        .ok_or_else(|| Error::InvalidPnvrc {
                            path: None,
                            reason: format!(
                                "the aliases of flavor \"{name}\" must be a list of strings"
                            ),
                        })?;
                    Ok(Flavor {
                        name: name.clone(),
                        aliases,
                    })
                })
                .collect::<Result<_>>()?,
            Some(_) => return Err(invalid("\"flavors\" must be an object")),
        };

        let pnvrc = Self { storage, flavors };
        pnvrc.check_conflicts()?;
        Ok(pnvrc)
    }

    /// Reads and parses the `.pnvrc` at `path`.
    ///
    /// A file that does not exist gives `None`, as does one [`Pnvrc::parse`]
    /// reads as no `.pnvrc`.
    ///
    /// # Errors
    ///
    /// As [`Pnvrc::parse`], naming the file, and [`Error::Io`] when it
    /// cannot be read.
    pub fn load(path: impl AsRef<Path>) -> Result<Option<Self>> {
        let path = path.as_ref();
        match fs::read_to_string(path) {
            Ok(text) => Self::parse(&text).map_err(|err| err.with_pnvrc_path(path)),
            Err(err) if err.kind() == io::ErrorKind::NotFound => Ok(None),
            Err(err) => Err(Error::io("read", path, &err)),
        }
    }

    /// The nearest `.pnvrc`, walking up from `dir` to the filesystem root.
    ///
    /// Unlike the Dart tool, this does not stop at a project file such as
    /// `pubspec.yaml` or `Cargo.toml`, so a workspace can keep one `.pnvrc`
    /// at its root.
    pub fn find(dir: impl AsRef<Path>) -> Option<PathBuf> {
        dir.as_ref()
            .ancestors()
            .map(|dir| dir.join(PNVRC_FILE_NAME))
            .find(|path| path.is_file())
    }

    /// Finds the nearest `.pnvrc` from `dir` (see [`Pnvrc::find`]) and loads
    /// it, returning where it was found too.
    ///
    /// # Errors
    ///
    /// As [`Pnvrc::load`].
    pub fn discover(dir: impl AsRef<Path>) -> Result<Option<(PathBuf, Self)>> {
        let Some(path) = Self::find(dir) else {
            return Ok(None);
        };
        Ok(Self::load(&path)?.map(|pnvrc| (path, pnvrc)))
    }

    /// The storage directory as written in the file.
    pub fn storage(&self) -> &str {
        &self.storage
    }

    /// The storage directory, with a leading `~` replaced by the home
    /// directory (`HOME`, or `USERPROFILE` on Windows).
    ///
    /// # Errors
    ///
    /// [`Error::NoHome`] when the path starts with `~` and the home
    /// directory is not set.
    pub fn storage_dir(&self) -> Result<PathBuf> {
        let home_var = if cfg!(windows) { "USERPROFILE" } else { "HOME" };
        expand_home(&self.storage, std::env::var_os(home_var).as_deref())
    }

    /// Where a flavor's key file lives: `<storage>/<flavor>.key`.
    ///
    /// # Errors
    ///
    /// As [`Pnvrc::storage_dir`].
    pub fn key_file(&self, flavor: &str) -> Result<PathBuf> {
        Ok(self
            .storage_dir()?
            .join(format!("{flavor}.{KEY_FILE_EXTENSION}")))
    }

    /// The flavors, in file order.
    pub fn flavors(&self) -> &[Flavor] {
        &self.flavors
    }

    /// The flavor with this exact name, not counting aliases.
    pub fn flavor(&self, name: &str) -> Option<&Flavor> {
        self.flavors.iter().find(|flavor| flavor.name == name)
    }

    /// The flavor `name` resolves to: the flavor of that name, or else the
    /// first, in file order, that lists it as an alias.
    pub fn group(&self, name: &str) -> Option<&Flavor> {
        self.flavor(name).or_else(|| {
            self.flavors
                .iter()
                .find(|flavor| flavor.aliases.iter().any(|alias| alias == name))
        })
    }

    /// Adds a flavor with no aliases at the end.
    ///
    /// Returns `false`, changing nothing, when a flavor of that name already
    /// exists.
    ///
    /// # Errors
    ///
    /// [`Error::InvalidFlavorName`] when the name is not letters, digits,
    /// `_` and `-`, and [`Error::FlavorConflict`] when it is another
    /// flavor's alias.
    pub fn add_flavor(&mut self, name: &str) -> Result<bool> {
        if !is_valid_flavor_name(name) {
            return Err(Error::InvalidFlavorName {
                name: name.to_owned(),
            });
        }
        if self.flavor(name).is_some() {
            return Ok(false);
        }
        if self.group(name).is_some() {
            return Err(Error::FlavorConflict {
                path: None,
                name: name.to_owned(),
            });
        }

        self.flavors.push(Flavor {
            name: name.to_owned(),
            aliases: Vec::new(),
        });
        Ok(true)
    }

    /// Removes the flavor of that name and its aliases. Returns whether there
    /// was one. Its key file is left alone.
    pub fn remove_flavor(&mut self, name: &str) -> bool {
        let before = self.flavors.len();
        self.flavors.retain(|flavor| flavor.name != name);
        self.flavors.len() != before
    }

    /// The file's text as pnv writes it: `storage`, then `flavors` in their
    /// order, indented with two spaces, with no trailing newline.
    pub fn to_json(&self) -> String {
        let flavors = self
            .flavors
            .iter()
            .map(|flavor| (flavor.name.clone(), Value::from(flavor.aliases.clone())))
            .collect::<Map<_, _>>();

        let mut object = Map::new();
        object.insert("storage".into(), Value::from(self.storage.clone()));
        object.insert("flavors".into(), Value::Object(flavors));

        serde_json::to_string_pretty(&Value::Object(object))
            .expect("a JSON value always serializes")
    }

    /// Writes [`Pnvrc::to_json`] to `path`, creating its directory if needed.
    ///
    /// # Errors
    ///
    /// [`Error::Io`] when the file cannot be written.
    pub fn save(&self, path: impl AsRef<Path>) -> Result<()> {
        let path = path.as_ref();
        if let Some(dir) = path.parent().filter(|dir| !dir.as_os_str().is_empty()) {
            fs::create_dir_all(dir).map_err(|err| Error::io("create", dir, &err))?;
        }
        fs::write(path, self.to_json()).map_err(|err| Error::io("write", path, &err))
    }

    fn check_conflicts(&self) -> Result<()> {
        let mut seen = HashSet::new();
        for flavor in &self.flavors {
            let own = flavor
                .aliases
                .iter()
                .position(|alias| *alias == flavor.name);
            let aliases = flavor
                .aliases
                .iter()
                .enumerate()
                .filter(|(i, _)| Some(*i) != own)
                .map(|(_, alias)| alias);

            for name in std::iter::once(&flavor.name).chain(aliases) {
                if !seen.insert(name.as_str()) {
                    return Err(Error::FlavorConflict {
                        path: None,
                        name: name.clone(),
                    });
                }
            }
        }
        Ok(())
    }
}

fn expand_home(storage: &str, home: Option<&std::ffi::OsStr>) -> Result<PathBuf> {
    let Some(rest) = storage.strip_prefix('~') else {
        return Ok(PathBuf::from(storage));
    };
    let mut path = home.ok_or(Error::NoHome)?.to_os_string();
    path.push(rest);
    Ok(PathBuf::from(path))
}

#[cfg(test)]
mod tests {
    use std::ffi::OsStr;

    use super::*;

    fn parse(text: &str) -> Pnvrc {
        Pnvrc::parse(text).unwrap().unwrap()
    }

    #[test]
    fn empty_or_non_object_is_no_pnvrc() {
        for text in ["", "  \n", "[]", "1", "\"x\"", "null"] {
            assert_eq!(Pnvrc::parse(text).unwrap(), None, "{text:?}");
        }
    }

    #[test]
    fn invalid_json_is_an_error() {
        let err = Pnvrc::parse("{storage").unwrap_err();
        assert_eq!(err.kind().as_str(), "invalid");
    }

    #[test]
    fn unknown_fields_are_ignored_and_null_flavors_is_none() {
        let pnvrc = parse(r#"{"storage": "/k", "flavors": null, "extra": 1}"#);
        assert_eq!(pnvrc, Pnvrc::new("/k"));
    }

    #[test]
    fn tilde_is_replaced_once_at_the_start() {
        let home = Some(OsStr::new("/home/me"));
        assert_eq!(
            expand_home("~/.keys", home).unwrap(),
            Path::new("/home/me/.keys")
        );
        assert_eq!(
            expand_home("~/a~b", home).unwrap(),
            Path::new("/home/me/a~b")
        );
        assert_eq!(expand_home("keys/~", None).unwrap(), Path::new("keys/~"));
        assert_eq!(expand_home("~/x", None).unwrap_err(), Error::NoHome);
    }

    #[test]
    fn writes_storage_then_flavors_in_order() {
        let mut pnvrc = parse(r#"{"flavors": {"zeta": ["z"], "alpha": []}, "storage": "~/.k"}"#);
        assert!(pnvrc.add_flavor("beta").unwrap());
        assert_eq!(
            pnvrc.to_json(),
            "{\n  \"storage\": \"~/.k\",\n  \"flavors\": {\n    \"zeta\": [\n      \"z\"\n    ],\n    \
             \"alpha\": [],\n    \"beta\": []\n  }\n}"
        );
        assert_eq!(
            Pnvrc::new("/k").to_json(),
            "{\n  \"storage\": \"/k\",\n  \"flavors\": {}\n}"
        );
    }

    #[test]
    fn add_and_remove_flavors() {
        let mut pnvrc = parse(r#"{"storage": "/k", "flavors": {"production": ["prod"]}}"#);

        assert!(!pnvrc.add_flavor("production").unwrap());
        assert_eq!(
            pnvrc.add_flavor("prod").unwrap_err().kind().as_str(),
            "conflict"
        );
        assert_eq!(
            pnvrc.add_flavor("a b").unwrap_err().kind().as_str(),
            "invalid-flavor-name"
        );

        assert!(pnvrc.remove_flavor("production"));
        assert!(!pnvrc.remove_flavor("production"));
        assert!(pnvrc.add_flavor("prod").unwrap());
    }

    #[test]
    fn finds_the_nearest_pnvrc_walking_up() {
        let root = tempfile::tempdir().unwrap();
        let nested = root.path().join("a/b/c");
        fs::create_dir_all(&nested).unwrap();
        fs::write(root.path().join("Cargo.toml"), "").unwrap();
        fs::write(root.path().join("a/b/Cargo.toml"), "").unwrap();

        assert_eq!(Pnvrc::find(&nested), None);

        Pnvrc::new("/outer")
            .save(root.path().join(".pnvrc"))
            .unwrap();
        let (path, pnvrc) = Pnvrc::discover(&nested).unwrap().unwrap();
        assert_eq!(path, root.path().join(".pnvrc"));
        assert_eq!(pnvrc.storage(), "/outer");

        Pnvrc::new("/inner")
            .save(root.path().join("a/.pnvrc"))
            .unwrap();
        assert_eq!(
            Pnvrc::discover(&nested).unwrap().unwrap().1.storage(),
            "/inner"
        );
    }

    #[test]
    fn a_bad_pnvrc_names_its_file() {
        let dir = tempfile::tempdir().unwrap();
        let path = dir.path().join(".pnvrc");
        fs::write(
            &path,
            r#"{"storage": "/k", "flavors": {"a": ["b"], "c": ["b"]}}"#,
        )
        .unwrap();

        let err = Pnvrc::load(&path).unwrap_err();
        assert_eq!(
            err,
            Error::FlavorConflict {
                path: Some(path.clone()),
                name: "b".into()
            }
        );
        assert!(err.to_string().contains(&*path.to_string_lossy()));
    }

    #[test]
    fn an_empty_pnvrc_stops_the_walk() {
        let root = tempfile::tempdir().unwrap();
        let nested = root.path().join("a");
        fs::create_dir_all(&nested).unwrap();
        Pnvrc::new("/outer")
            .save(root.path().join(".pnvrc"))
            .unwrap();
        fs::write(nested.join(".pnvrc"), "").unwrap();

        assert_eq!(Pnvrc::discover(&nested).unwrap(), None);
    }
}
