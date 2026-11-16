//! A secrets YAML file kept as text, so that changing one value leaves the
//! rest of the file as it was.

use std::path::{Path, PathBuf};
use std::rc::Rc;
use std::str::FromStr;

use yaml_edit::{Mapping, YamlFile};

use crate::loader::{self, Node, Scalar};
use crate::{Error, Key, Result, Value, decrypt, is_secret};

/// A YAML file of values and secrets, read and edited in place.
///
/// [`Document::set`] changes one value and keeps every comment, blank line,
/// key order and indent around it, so a file can be edited by `pnv set` and
/// by hand. [`Document::get`] reads one value, and [`Document::decrypted`]
/// gives the whole file with its secrets in plain text.
///
/// A key path names a value by its keys from the top of the file, joined by
/// `.`: `app.api-key` is `api-key` under `app`.
///
/// ```
/// use pnv::{Document, Key, Value, create_key, encrypt};
///
/// let key = Key::decode(&create_key()?)?;
/// let mut doc = Document::parse("# the app\napp:\n  name: demo\n")?;
///
/// doc.set("app.api-key", &encrypt("sk-live-abc", &key)?)?;
///
/// assert!(doc.as_str().starts_with("# the app\napp:\n  name: demo\n  api-key: SECRET;"));
/// assert_eq!(doc.decrypted(&key)?, "# the app\napp:\n  name: demo\n  api-key: sk-live-abc\n");
/// assert_eq!(doc.get("app.name")?, Value::String("demo".into()));
/// # Ok::<(), pnv::Error>(())
/// ```
#[derive(Debug, Clone, PartialEq, Eq)]
pub struct Document {
    source: String,
    path: Option<PathBuf>,
}

impl Document {
    /// Reads a YAML file. Nothing is checked until a value is read or set.
    ///
    /// # Errors
    ///
    /// [`Error::Io`] when the file cannot be read.
    pub fn read(path: impl AsRef<Path>) -> Result<Self> {
        let path = path.as_ref();
        let source = std::fs::read_to_string(path).map_err(|err| Error::io("read", path, &err))?;
        Ok(Self {
            source,
            path: Some(path.to_path_buf()),
        })
    }

    /// Wraps YAML text.
    ///
    /// # Errors
    ///
    /// [`Error::InvalidYaml`] when the text is not YAML.
    pub fn parse(source: impl Into<String>) -> Result<Self> {
        let doc = Self {
            source: source.into(),
            path: None,
        };
        doc.root()?;
        Ok(doc)
    }

    /// The file's text, with any change made by [`Document::set`].
    pub fn as_str(&self) -> &str {
        &self.source
    }

    /// The file this was read from, if any.
    pub fn path(&self) -> Option<&Path> {
        self.path.as_deref()
    }

    /// The value at `key_path`, as written: a secret is still encrypted.
    ///
    /// # Errors
    ///
    /// [`Error::InvalidKeyPath`] for a path with an empty part,
    /// [`Error::InvalidYaml`] and [`Error::NotAMap`] for a file that is not
    /// a map of values, [`Error::NoSuchKey`] when nothing is there,
    /// [`Error::IsAGroup`] when the path names a group of values rather than
    /// one, and [`Error::UnsupportedType`] for a list.
    pub fn get(&self, key_path: &str) -> Result<Value> {
        let segments = segments(key_path)?;
        let missing = || Error::NoSuchKey {
            key: segments.join("."),
            path: self.path.clone(),
        };

        let Some(root) = self.root()? else {
            return Err(missing());
        };
        let mut node = self.top(&root)?;
        for segment in &segments {
            let Node::Map(entries) = &*node else {
                return Err(missing());
            };
            node = child(entries, segment).ok_or_else(missing)?;
        }

        match &*node {
            Node::Scalar(Scalar { value, .. }) => Ok(value.clone()),
            Node::Map(_) => Err(Error::IsAGroup {
                key: segments.join("."),
            }),
            Node::Seq => Err(Error::UnsupportedType {
                path: self.path.clone(),
                key: segments.join("."),
            }),
        }
    }

    /// Writes `value` at `key_path` as a string, adding any groups on the way
    /// in block style. An existing value is replaced, keeping the comment on
    /// its line. Everything else in the file stays as it was.
    ///
    /// The document is left unchanged when this fails.
    ///
    /// # Errors
    ///
    /// [`Error::InvalidKeyPath`] for a path with an empty part,
    /// [`Error::InvalidYaml`] and [`Error::NotAMap`] for a file that is not
    /// a map of values, and [`Error::NotAGroup`] when a part of the path
    /// before the last holds a value (null included) rather than a group.
    pub fn set(&mut self, key_path: &str, value: &str) -> Result<()> {
        let segments = segments(key_path)?;
        let key = segments.join(".");

        // Check the whole path against the file as YAML reads it before
        // touching anything, so a refusal writes nothing.
        if let Some(root) = self.root()? {
            let mut node = self.top(&root)?;
            for (depth, segment) in segments[..segments.len() - 1].iter().enumerate() {
                let Node::Map(entries) = &*node else {
                    unreachable!("only a group is descended into");
                };
                let Some(next) = child(entries, segment) else {
                    break;
                };
                if !matches!(&*next, Node::Map(_)) {
                    return Err(not_a_group(&segments[..=depth], &key));
                }
                node = next;
            }
        }

        let file = YamlFile::from_str(&self.source).map_err(|err| self.unwritable(&key, err))?;
        let mapping = file
            .ensure_document()
            .as_mapping()
            .ok_or_else(|| self.not_a_map())?;
        write(&mapping, &segments, 0, value, &key)?;

        let mut updated = file.to_string();
        if !updated.ends_with('\n') {
            updated.push('\n');
        }

        // The edit must read back as exactly what was written, or the file
        // is left as it was.
        let check = Self {
            source: updated,
            path: self.path.clone(),
        };
        match check.get(&key) {
            Ok(Value::String(read)) if read == value => {}
            _ => return Err(self.unwritable(&key, "the edit did not read back")),
        }

        self.source = check.source;
        Ok(())
    }

    /// Whether any value in the file is a secret.
    ///
    /// A file that is not YAML, or not a map, has none.
    pub fn has_secrets(&self) -> bool {
        let Ok(Some(root)) = self.root() else {
            return false;
        };
        let mut found = false;
        leaves(&root, &mut Vec::new(), &mut |_, text| {
            found |= is_secret(text)
        });
        found
    }

    /// The file's text with every secret replaced by its plain text, and
    /// nothing else changed. A file with no secrets comes back as it is.
    ///
    /// A secret reached only through an alias (`*name`) is left as the alias;
    /// it is decrypted where its anchor is.
    ///
    /// # Errors
    ///
    /// [`Error::InvalidYaml`] for a file that is not YAML, and the errors of
    /// [`decrypt`] for a secret that does not decrypt, naming its key.
    pub fn decrypted(&self, key: &Key) -> Result<String> {
        let Some(root) = self.root()? else {
            return Ok(self.source.clone());
        };

        let mut secrets = Vec::new();
        leaves(&root, &mut Vec::new(), &mut |path, text| {
            if is_secret(text) {
                secrets.push((path.to_vec(), text.to_owned()));
            }
        });
        if secrets.is_empty() {
            return Ok(self.source.clone());
        }

        let file = YamlFile::from_str(&self.source).map_err(|err| self.unwritable("", err))?;
        let Some(mapping) = file.document().and_then(|doc| doc.as_mapping()) else {
            return Ok(self.source.clone());
        };

        for (path, token) in secrets {
            let at = self.at(&path.join("."));
            let plain = decrypt(&token, key).map_err(|err| err.with_context(at))?;
            replace_scalar(&mapping, &path, &plain);
        }

        Ok(file.to_string())
    }

    fn root(&self) -> Result<Option<Rc<Node>>> {
        loader::load(&self.source).map_err(|err| Error::InvalidYaml {
            path: self.path.clone(),
            line: err.line,
            column: err.column,
            message: err.message,
        })
    }

    /// The top-level map, refusing anything else.
    fn top(&self, root: &Rc<Node>) -> Result<Rc<Node>> {
        match &**root {
            Node::Map(_) => Ok(Rc::clone(root)),
            _ => Err(self.not_a_map()),
        }
    }

    fn not_a_map(&self) -> Error {
        Error::NotAMap {
            path: self.path.clone(),
        }
    }

    fn unwritable(&self, key: &str, why: impl std::fmt::Display) -> Error {
        Error::InvalidYaml {
            path: self.path.clone(),
            line: 0,
            column: 0,
            message: format!("could not edit \"{key}\": {why}"),
        }
    }

    fn at(&self, key: &str) -> String {
        match &self.path {
            Some(file) => format!("{} \u{2192} {key}", file.display()),
            None => key.to_owned(),
        }
    }
}

impl std::fmt::Display for Document {
    fn fmt(&self, f: &mut std::fmt::Formatter<'_>) -> std::fmt::Result {
        f.write_str(&self.source)
    }
}

/// Splits `app.api-key` into its keys, trimming each, as the Dart tool does.
fn segments(raw: &str) -> Result<Vec<String>> {
    let parts: Vec<String> = raw.split('.').map(|part| part.trim().to_owned()).collect();
    if parts.iter().any(String::is_empty) {
        return Err(Error::InvalidKeyPath {
            path: raw.to_owned(),
        });
    }
    Ok(parts)
}

/// The value under a string key. A key YAML reads as a number or a bool
/// (`8080:`) is not the string `"8080"`, as in the Dart tool.
fn child(entries: &[(Scalar, Rc<Node>)], segment: &str) -> Option<Rc<Node>> {
    entries
        .iter()
        .find(|(key, _)| key.value.as_str() == Some(segment))
        .map(|(_, node)| Rc::clone(node))
}

fn not_a_group(at: &[String], key: &str) -> Error {
    Error::NotAGroup {
        at: at.join("."),
        key: key.to_owned(),
    }
}

/// Sets `segments[depth..]` under `mapping`, creating groups as needed. A
/// new group takes the style of the one it goes in: block under block.
fn write(
    mapping: &Mapping,
    segments: &[String],
    depth: usize,
    value: &str,
    key: &str,
) -> Result<()> {
    let segment = segments[depth].as_str();
    if depth == segments.len() - 1 {
        mapping.set(segment, value);
        return Ok(());
    }
    if let Some(nested) = mapping.get_mapping(segment) {
        return write(&nested, segments, depth + 1, value, key);
    }
    if mapping.get(segment).is_some() {
        // Something YAML reads as a group but is not one in the text, such
        // as an alias. Writing a new group here would drop what it points
        // to.
        return Err(not_a_group(&segments[..=depth], key));
    }
    if mapping.is_flow_style() {
        mapping.set(segment, Mapping::new_flow());
    } else {
        mapping.set(segment, Mapping::new_pending_block());
    }
    let nested = mapping
        .get_mapping(segment)
        .expect("a group was just added here");
    write(&nested, segments, depth + 1, value, key)
}

/// Replaces the scalar at `path` when the text holds one there, and not an
/// alias or a tagged value.
fn replace_scalar(mapping: &Mapping, path: &[String], value: &str) {
    let Some((last, parents)) = path.split_last() else {
        return;
    };
    let mut mapping = mapping.clone();
    for segment in parents {
        let Some(nested) = mapping.get_mapping(segment.as_str()) else {
            return;
        };
        mapping = nested;
    }
    if mapping
        .get(last.as_str())
        .is_some_and(|node| node.as_scalar().is_some())
    {
        mapping.set(last.as_str(), value);
    }
}

/// Calls `f` with the path and text of every string value under a map.
fn leaves(node: &Node, path: &mut Vec<String>, f: &mut dyn FnMut(&[String], &str)) {
    let Node::Map(entries) = node else {
        return;
    };
    for (key, value) in entries {
        let Some(name) = key.value.as_str() else {
            continue;
        };
        path.push(name.to_owned());
        match &**value {
            Node::Map(_) => leaves(value, path, f),
            Node::Scalar(Scalar {
                value: Value::String(text),
                ..
            }) => f(path, text),
            _ => {}
        }
        path.pop();
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::encrypt;

    const KEY: &str = "AAECAwQFBgcICQoLDA0ODxAREhMUFRYXGBkaGxwdHh8=";

    fn key() -> Key {
        Key::decode(KEY).unwrap()
    }

    fn set(source: &str, path: &str, value: &str) -> Result<String> {
        let mut doc = Document::parse(source)?;
        doc.set(path, value)?;
        Ok(doc.as_str().to_owned())
    }

    #[test]
    fn set_replaces_a_value_and_keeps_everything_else() {
        let source = "# a leading comment\nbase-url: http://localhost:3000   # trailing comment\napp:\n  name: demo\n  api-key: replace-me # the key\n\n# db\ndb:\n  host: localhost\n";
        assert_eq!(
            set(source, "app.api-key", "SECRET;v1:abc").unwrap(),
            "# a leading comment\nbase-url: http://localhost:3000   # trailing comment\napp:\n  name: demo\n  api-key: SECRET;v1:abc # the key\n\n# db\ndb:\n  host: localhost\n"
        );
    }

    #[test]
    fn set_adds_missing_groups_in_block_style() {
        assert_eq!(
            set("app:\n  name: demo\n", "app.db.password", "x").unwrap(),
            "app:\n  name: demo\n  db:\n    password: x\n"
        );
    }

    #[test]
    fn set_seeds_an_empty_or_comment_only_file() {
        assert_eq!(set("", "a.b.c", "v").unwrap(), "a:\n  b:\n    c: v\n");
        assert_eq!(set("# note\n", "a", "v").unwrap(), "# note\na: v\n");
    }

    #[test]
    fn set_keeps_a_value_that_looks_like_another_type_a_string() {
        let out = set("a: 1\n", "b", "8080").unwrap();
        assert_eq!(
            Document::parse(out).unwrap().get("b").unwrap(),
            Value::String("8080".into())
        );
    }

    #[test]
    fn set_writes_awkward_strings_so_they_read_back() {
        for value in [
            "x: y",
            "a # b",
            "*ref",
            "",
            "true",
            " lead",
            "it's \"q\"",
            "a\nb",
        ] {
            let out = set("a: 1\n", "v", value).unwrap();
            assert_eq!(
                Document::parse(out).unwrap().get("v").unwrap(),
                Value::String(value.into()),
                "{value:?}"
            );
        }
    }

    #[test]
    fn set_refuses_a_path_through_a_value() {
        for (source, at) in [
            ("app:\n  name: demo\n", "app.name"),
            ("app:\n", "app"),
            ("app: ~\n", "app"),
            ("app:\n  - x\n", "app"),
        ] {
            let mut doc = Document::parse(source).unwrap();
            let err = doc.set(&format!("{at}.oops"), "v").unwrap_err();
            assert_eq!(
                err,
                Error::NotAGroup {
                    at: at.into(),
                    key: format!("{at}.oops")
                }
            );
            assert_eq!(doc.as_str(), source);
        }
    }

    #[test]
    fn set_refuses_to_write_through_an_alias() {
        let source = "a: &x\n  k: v\nuse: *x\n";
        let mut doc = Document::parse(source).unwrap();
        assert!(matches!(
            doc.set("use.k", "z").unwrap_err(),
            Error::NotAGroup { .. }
        ));
        assert_eq!(doc.as_str(), source);
    }

    #[test]
    fn set_refuses_a_file_that_is_not_a_map() {
        let mut doc = Document::parse("- a\n").unwrap();
        assert!(matches!(
            doc.set("a", "v").unwrap_err(),
            Error::NotAMap { .. }
        ));
    }

    #[test]
    fn key_paths_need_every_part() {
        let mut doc = Document::parse("a: b\n").unwrap();
        for path in ["app..key", "", ".a", "a."] {
            assert!(matches!(
                doc.set(path, "v").unwrap_err(),
                Error::InvalidKeyPath { .. }
            ));
        }
        assert_eq!(doc.get(" a ").unwrap(), Value::String("b".into()));
    }

    #[test]
    fn get_reads_typed_values() {
        let doc =
            Document::parse("a:\n  n: 0x1F\n  f: 1e3\n  b: true\n  z: ~\n  s: 'x'\n").unwrap();
        assert_eq!(doc.get("a.n").unwrap(), Value::Int(31));
        assert_eq!(doc.get("a.f").unwrap(), Value::Float(1000.0));
        assert_eq!(doc.get("a.b").unwrap(), Value::Bool(true));
        assert_eq!(doc.get("a.z").unwrap(), Value::Null);
        assert_eq!(doc.get("a.s").unwrap(), Value::String("x".into()));
    }

    #[test]
    fn get_tells_missing_from_group() {
        let doc = Document::parse("app:\n  name: demo\n  list: [1]\n8080: x\n").unwrap();
        assert!(matches!(doc.get("app.nope"), Err(Error::NoSuchKey { .. })));
        assert!(matches!(
            doc.get("app.name.x"),
            Err(Error::NoSuchKey { .. })
        ));
        assert!(matches!(doc.get("8080"), Err(Error::NoSuchKey { .. })));
        assert!(matches!(doc.get("app"), Err(Error::IsAGroup { .. })));
        assert!(matches!(
            doc.get("app.list"),
            Err(Error::UnsupportedType { .. })
        ));
        assert!(matches!(
            Document::parse("").unwrap().get("a"),
            Err(Error::NoSuchKey { .. })
        ));
    }

    #[test]
    fn decrypted_replaces_only_secrets() {
        let key = key();
        let token = encrypt("the-secret", &key).unwrap();
        let source =
            format!("# a comment\napp:\n  key: {token} # note\n  name: demo\nlist:\n  - {token}\n");
        let doc = Document::parse(source).unwrap();
        assert!(doc.has_secrets());
        // A list is left alone, as the Dart tool leaves it.
        assert_eq!(
            doc.decrypted(&key).unwrap(),
            format!(
                "# a comment\napp:\n  key: the-secret # note\n  name: demo\nlist:\n  - {token}\n"
            )
        );
    }

    #[test]
    fn decrypted_passes_a_file_without_secrets_through() {
        for source in ["a: 1\nb: two\n", "a:   spaced   # c\n\n\nb: 2", "- a\n", ""] {
            let doc = Document::parse(source).unwrap();
            assert!(!doc.has_secrets());
            assert_eq!(doc.decrypted(&key()).unwrap(), source);
        }
    }

    #[test]
    fn decrypted_names_the_secret_that_fails() {
        let other = Key::decode(&crate::create_key().unwrap()).unwrap();
        let token = encrypt("x", &other).unwrap();
        let doc = Document::parse(format!("db:\n  password: {token}\n")).unwrap();
        let err = doc.decrypted(&key()).unwrap_err();
        assert_eq!(err.context(), Some("db.password"));
    }
}
