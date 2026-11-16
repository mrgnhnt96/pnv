use std::path::Path;
use std::rc::Rc;

use crate::error::{Error, Result};
use crate::key::Key;
use crate::loader::{self, Node, Scalar};
use crate::lookup::KeyLookup;
use crate::token::{decrypt, is_secret};
use crate::value::Value;

/// One value of a YAML file, with the name it gets as an environment
/// variable.
#[derive(Debug, Clone, PartialEq)]
pub struct Entry {
    path: Vec<String>,
    name: String,
    value: Value,
    comment: Option<String>,
    encrypted: bool,
}

impl Entry {
    /// The variable name: the keys on the path joined with `_`, uppercased,
    /// with every `-` turned into `_`. `db: {deep-key: x}` gives
    /// `DB_DEEP_KEY`.
    pub fn name(&self) -> &str {
        &self.name
    }

    /// The keys from the top of the file down to this value, as written
    /// (`["db", "deep-key"]`).
    pub fn path(&self) -> &[String] {
        &self.path
    }

    /// The keys joined with `.`, such as `db.deep-key`.
    pub fn key(&self) -> String {
        self.path.join(".")
    }

    /// The value, decrypted when it was a secret.
    pub fn value(&self) -> &Value {
        &self.value
    }

    /// The comment after the value on its own line, such as `int` for
    /// `port: 8080 # int`.
    pub fn comment(&self) -> Option<&str> {
        self.comment.as_deref()
    }

    /// Whether the value was a `SECRET;` token in the file.
    pub fn was_encrypted(&self) -> bool {
        self.encrypted
    }

    /// The entry as one `.env` line, without the line break:
    /// `NAME=value`, then ` # comment` when there is one.
    pub fn to_env_line(&self) -> String {
        let mut line = format!("{}={}", self.name, self.value.to_env_value());
        if let Some(comment) = &self.comment {
            line.push_str(" # ");
            line.push_str(comment);
        }
        line
    }
}

/// The decrypted values of one YAML file, in the order the file lists them.
///
/// Nested keys are flattened into one name each (`db: {host: x}` gives
/// `DB_HOST`), so this is the same set of values `pnv generate env` writes.
/// Lists are refused.
///
/// Nothing is written to the process environment: that is unsafe in Rust
/// once threads run, so what to do with the values is left to the caller.
///
/// ```no_run
/// let env = pnv::Env::load("config/app.production.yaml")?;
/// let url = env.get("DATABASE_URL").expect("DATABASE_URL is set");
/// println!("connecting to {url}");
/// # Ok::<(), pnv::Error>(())
/// ```
#[derive(Debug, Clone, Default, PartialEq)]
pub struct Env {
    entries: Vec<Entry>,
}

impl Env {
    /// Reads a YAML file, finding its key from the file's name: the flavor
    /// it implies (`app.production.yaml` gives `production`), looked up as
    /// [`KeyLookup`] does.
    ///
    /// # Errors
    ///
    /// The errors of [`KeyLookup::resolve`] and [`Env::read`].
    pub fn load(path: impl AsRef<Path>) -> Result<Self> {
        let path = path.as_ref();
        let key = KeyLookup::new().file(path).resolve()?.key;
        Self::read(path, &key)
    }

    /// Reads a YAML file and decrypts its secrets with `key`.
    ///
    /// # Errors
    ///
    /// [`Error::Io`] when the file cannot be read, and the errors of
    /// [`Env::parse`], naming the file.
    pub fn read(path: impl AsRef<Path>, key: &Key) -> Result<Self> {
        let path = path.as_ref();
        let text = std::fs::read_to_string(path).map_err(|err| Error::io("read", path, &err))?;
        parse(&text, key, Some(path))
    }

    /// Parses YAML text and decrypts its secrets with `key`.
    ///
    /// An empty document, or one with only comments, gives no values.
    ///
    /// # Errors
    ///
    /// [`Error::InvalidYaml`] when the text is not YAML, [`Error::NotAMap`]
    /// when its top level is not a mapping, [`Error::UnsupportedType`] for a
    /// list, and the errors of [`decrypt`] for a secret that does not
    /// decrypt, naming its key. The first problem in file order is the one
    /// reported.
    pub fn parse(yaml: &str, key: &Key) -> Result<Self> {
        parse(yaml, key, None)
    }

    /// The value of a variable, by its name, such as `DB_HOST`. When two
    /// keys flatten to the same name, the later one wins, as it would when
    /// the `.env` text is read back.
    pub fn get(&self, name: &str) -> Option<&Value> {
        self.entries
            .iter()
            .rev()
            .find(|entry| entry.name == name)
            .map(Entry::value)
    }

    /// Every value, in file order.
    pub fn entries(&self) -> &[Entry] {
        &self.entries
    }

    /// Iterates over every value, in file order.
    pub fn iter(&self) -> std::slice::Iter<'_, Entry> {
        self.entries.iter()
    }

    /// How many values there are.
    pub fn len(&self) -> usize {
        self.entries.len()
    }

    /// Whether there are no values.
    pub fn is_empty(&self) -> bool {
        self.entries.is_empty()
    }

    /// The values as `.env` text, byte for byte what the Dart tool's
    /// `pnv generate env` writes: one `NAME=value` line each, ending in
    /// `\n`, with strings quoted and escaped and type comments kept.
    pub fn to_dotenv(&self) -> String {
        let mut out = String::new();
        for entry in &self.entries {
            out.push_str(&entry.to_env_line());
            out.push('\n');
        }
        out
    }
}

impl IntoIterator for Env {
    type Item = Entry;
    type IntoIter = std::vec::IntoIter<Entry>;

    fn into_iter(self) -> Self::IntoIter {
        self.entries.into_iter()
    }
}

impl<'a> IntoIterator for &'a Env {
    type Item = &'a Entry;
    type IntoIter = std::slice::Iter<'a, Entry>;

    fn into_iter(self) -> Self::IntoIter {
        self.entries.iter()
    }
}

fn parse(text: &str, key: &Key, file: Option<&Path>) -> Result<Env> {
    let root = loader::load(text).map_err(|err| Error::InvalidYaml {
        path: file.map(Path::to_path_buf),
        line: err.line,
        column: err.column,
        message: err.message,
    })?;

    let mut env = Env::default();
    let Some(root) = root else {
        return Ok(env);
    };
    match &*root {
        Node::Map(entries) => {
            let mut walk = Walk {
                key,
                file,
                path: Vec::new(),
                out: &mut env.entries,
            };
            walk.map(entries)?;
            Ok(env)
        }
        Node::Scalar(Scalar {
            value: Value::Null, ..
        }) => Ok(env),
        _ => Err(Error::NotAMap {
            path: file.map(Path::to_path_buf),
        }),
    }
}

struct Walk<'a> {
    key: &'a Key,
    file: Option<&'a Path>,
    path: Vec<String>,
    out: &'a mut Vec<Entry>,
}

impl Walk<'_> {
    fn map(&mut self, entries: &[(Scalar, Rc<Node>)]) -> Result<()> {
        for (key, node) in entries {
            self.path.push(key_string(&key.value));
            match &**node {
                Node::Map(entries) => self.map(entries)?,
                Node::Seq => {
                    return Err(Error::UnsupportedType {
                        path: self.file.map(Path::to_path_buf),
                        key: self.path.join("."),
                    });
                }
                Node::Scalar(scalar) => self.scalar(scalar)?,
            }
            self.path.pop();
        }
        Ok(())
    }

    fn scalar(&mut self, scalar: &Scalar) -> Result<()> {
        let mut value = scalar.value.clone();
        let mut encrypted = false;
        if let Value::String(text) = &value
            && is_secret(text)
        {
            let plain = decrypt(text, self.key).map_err(|err| err.with_context(self.at()))?;
            value = Value::String(plain);
            encrypted = true;
        }

        self.out.push(Entry {
            name: self.path.join("_").to_uppercase().replace('-', "_"),
            path: self.path.clone(),
            value,
            comment: scalar.comment.clone(),
            encrypted,
        });
        Ok(())
    }

    fn at(&self) -> String {
        let key = self.path.join(".");
        match self.file {
            Some(file) => format!("{} \u{2192} {key}", file.display()),
            None => key,
        }
    }
}

fn key_string(value: &Value) -> String {
    match value {
        Value::Null => "null".to_owned(),
        other => other.to_string(),
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    const KEY: &str = "AAECAwQFBgcICQoLDA0ODxAREhMUFRYXGBkaGxwdHh8=";

    fn env(yaml: &str) -> Env {
        Env::parse(yaml, &Key::decode(KEY).unwrap()).unwrap()
    }

    fn error(yaml: &str) -> Error {
        Env::parse(yaml, &Key::decode(KEY).unwrap()).unwrap_err()
    }

    #[test]
    fn entries_keep_path_comment_and_secrecy() {
        let env = env(
            "db:\n  deep-key: x # string\ntoken: SECRET;v1:ikceywABAgMEBQYHCAkKCyLDfmHplmR3TDvBmf48BQQ9Ry9u/Zx9DFyk6Ao=\n",
        );
        let [first, second] = env.entries() else {
            panic!("{env:?}")
        };
        assert_eq!(first.name(), "DB_DEEP_KEY");
        assert_eq!(first.path(), ["db", "deep-key"]);
        assert_eq!(first.key(), "db.deep-key");
        assert_eq!(first.comment(), Some("string"));
        assert!(!first.was_encrypted());
        assert_eq!(second.value(), &Value::String("s3cr3t-value".into()));
        assert!(second.was_encrypted());
        assert_eq!(
            env.get("TOKEN").and_then(Value::as_str),
            Some("s3cr3t-value")
        );
    }

    #[test]
    fn the_later_of_two_equal_names_wins() {
        let env = env("a_b: 1\na:\n  b: 2\n");
        assert_eq!(env.len(), 2);
        assert_eq!(env.get("A_B"), Some(&Value::Int(2)));
    }

    #[test]
    fn a_top_level_null_is_empty() {
        assert!(env("~\n").is_empty());
        assert!(env("---\n# only a comment\n").is_empty());
    }

    #[test]
    fn non_string_keys_are_named_as_dart_prints_them() {
        let names: Vec<_> = env("~: a\n1.0: b\n0x10: c\nFalse: d\n")
            .iter()
            .map(|entry| entry.name().to_owned())
            .collect();
        assert_eq!(names, ["NULL", "1.0", "16", "FALSE"]);
    }

    #[test]
    fn a_comment_after_a_quoted_value_is_read_after_the_closing_quote() {
        let env = env("a: \"x # y\" # int\nb: 'it''s # no' # bool\nc: \"esc \\\" # no\" # num\n");
        let comments: Vec<_> = env.iter().map(Entry::comment).collect();
        assert_eq!(comments, [Some("int"), Some("bool"), Some("num")]);
        assert_eq!(env.get("B"), Some(&Value::String("it's # no".into())));
    }

    #[test]
    fn an_alias_keeps_the_comment_of_the_node_it_points_to() {
        let env = env("a: &n 1 # int\nb: *n\n");
        assert_eq!(env.entries()[1].comment(), Some("int"));
    }

    #[test]
    fn non_ascii_text_keeps_comments_aligned() {
        let env = env("é: ü # ok\nnext: \"ß\" # bool\n");
        assert_eq!(env.entries()[0].comment(), Some("ok"));
        assert_eq!(env.entries()[1].comment(), Some("bool"));
        assert_eq!(env.entries()[0].name(), "É");
    }

    #[test]
    fn bad_yaml_is_refused_with_its_position() {
        let err = error("a: 1\na: 2\n");
        assert_eq!(err.kind().as_str(), "invalid-yaml");
        assert!(err.to_string().contains("line 2"), "{err}");

        for yaml in [
            "a: [1\n",
            "a: *nope\n",
            "a: !foo x\n",
            "a: !!int x\n",
            "? [a]\n: b\n",
            "a: 1\n---\nb: 2\n",
            "a: !!seq {}\n",
        ] {
            assert_eq!(error(yaml).kind().as_str(), "invalid-yaml", "{yaml:?}");
        }
    }

    #[test]
    fn a_list_names_its_key() {
        let err = error("db:\n  hosts: [a, b]\n");
        assert_eq!(err.kind().as_str(), "unsupported-type");
        assert!(err.to_string().contains("\"db.hosts\""), "{err}");
    }

    #[test]
    fn a_failed_secret_names_the_file_and_key() {
        let dir = tempfile::tempdir().unwrap();
        let file = dir.path().join("app.yaml");
        std::fs::write(&file, "db:\n  password: SECRET;not base64!\n").unwrap();
        let err = Env::read(&file, &Key::decode(KEY).unwrap()).unwrap_err();
        assert_eq!(
            err.context(),
            Some(format!("{} \u{2192} db.password", file.display()).as_str())
        );
    }

    #[test]
    fn a_missing_file_is_an_io_error() {
        let err = Env::read("/no/such/pnv/file.yaml", &Key::decode(KEY).unwrap()).unwrap_err();
        assert_eq!(err.kind().as_str(), "io");
    }
}
