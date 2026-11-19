use std::fs;
use std::path::{Path, PathBuf};

use crate::detector::{PLAINTEXT_MARKER, suspect_plaintext};
use crate::error::{Error, Result};
use crate::key::Key;
use crate::lookup::KeyLookup;
use crate::pnvrc::Pnvrc;
use crate::token::{Token, is_secret};
use crate::yaml;

/// Directories never worth walking for secrets.
const SKIP_DIRECTORIES: [&str; 5] = [".git", "target", "build", "node_modules", ".dart_tool"];

/// Project files that are YAML but never hold secrets, and whose keys (a
/// dependency called `signature`, say) would only produce noise.
const SKIP_FILES: [&str; 2] = ["pubspec.yaml", "analysis_options.yaml"];

/// What [`verify`] found.
#[derive(Debug, Clone, Default, PartialEq, Eq)]
pub struct VerifyReport {
    /// How many YAML files were checked.
    pub files: usize,
    /// How many `SECRET;` values were found, whether or not they decrypt.
    pub secrets: usize,
    /// Everything wrong, one sentence each. Empty means safe to publish.
    pub problems: Vec<String>,
}

impl VerifyReport {
    /// Whether nothing was found.
    pub fn is_clean(&self) -> bool {
        self.problems.is_empty()
    }
}

/// Checks that the YAML files under `root` are safe to commit.
///
/// Every `.yaml` and `.yml` file is checked. In a git work tree that means
/// the files git tracks or would track (gitignored files are skipped);
/// elsewhere every file under `root`, skipping `.git`, `target`, `build`,
/// `node_modules` and `.dart_tool`. Every document of a multi-document file
/// is checked. These are reported:
///
/// - a secret that does not decrypt under the key of its file's flavor
///   (a corrupt value is reported as corrupt, and a value from another
///   flavor says which flavor's key made it);
/// - a string that looks like a secret but is not encrypted (see
///   [`suspect_plaintext`](crate::suspect_plaintext));
/// - a key storage directory inside the project, which is `project_root`
///   (the directory of the `.pnvrc`).
///
/// A file only needs a key if it holds a secret. Keys are found as
/// [`KeyLookup`] does, including `PNV_KEY_<FLAVOR>`.
///
/// # Errors
///
/// When `root` cannot be read. Problems with the files are in the report,
/// not errors.
pub fn verify(
    root: impl AsRef<Path>,
    project_root: impl AsRef<Path>,
    pnvrc: &Pnvrc,
) -> Result<VerifyReport> {
    verify_with(root.as_ref(), project_root.as_ref(), pnvrc, &|name| {
        std::env::var(name).ok()
    })
}

pub(crate) fn verify_with(
    root: &Path,
    project_root: &Path,
    pnvrc: &Pnvrc,
    env: &dyn Fn(&str) -> Option<String>,
) -> Result<VerifyReport> {
    let mut files = match git_files(root) {
        Some(files) => files,
        None => {
            let mut files = Vec::new();
            walk(root, &mut files)?;
            files
        }
    };
    files.sort();

    let mut report = VerifyReport {
        files: files.len(),
        ..VerifyReport::default()
    };

    for file in &files {
        check_file(file, project_root, pnvrc, env, &mut report);
    }

    check_storage(project_root, pnvrc, &mut report);
    Ok(report)
}

/// The `.yaml` and `.yml` files under `dir` that git tracks or would track,
/// or `None` when `dir` is not in a git work tree or git is not installed.
///
/// Asking git keeps gitignored copies of the project, such as worktrees
/// under `.claude/worktrees/`, out of the check. They are not what gets
/// published.
fn git_files(dir: &Path) -> Option<Vec<PathBuf>> {
    let output = std::process::Command::new("git")
        .args([
            "ls-files",
            "-z",
            "--cached",
            "--others",
            "--exclude-standard",
            "--",
            "*.yaml",
            "*.yml",
        ])
        .current_dir(dir)
        .stderr(std::process::Stdio::null())
        .output()
        .ok()?;
    if !output.status.success() {
        return None;
    }

    let files = String::from_utf8_lossy(&output.stdout)
        .split('\0')
        .filter(|path| !path.is_empty())
        .map(|path| dir.join(path))
        // A file deleted from disk but not yet from the index is not there
        // to publish.
        .filter(|path| path.is_file())
        .filter(|path| {
            path.file_name()
                .is_none_or(|name| !SKIP_FILES.contains(&name.to_string_lossy().as_ref()))
        })
        .collect();
    Some(files)
}

fn walk(dir: &Path, out: &mut Vec<PathBuf>) -> Result<()> {
    let entries = fs::read_dir(dir).map_err(|err| Error::io("read", dir, &err))?;
    for entry in entries {
        let entry = entry.map_err(|err| Error::io("read", dir, &err))?;
        let path = entry.path();
        let Ok(kind) = entry.file_type() else {
            continue;
        };
        let name = entry.file_name();
        let name = name.to_string_lossy();

        if kind.is_dir() {
            if !SKIP_DIRECTORIES.contains(&name.as_ref()) {
                walk(&path, out)?;
            }
        } else if kind.is_file()
            && matches!(
                path.extension().and_then(|e| e.to_str()),
                Some("yaml" | "yml")
            )
            && !SKIP_FILES.contains(&name.as_ref())
        {
            out.push(path);
        }
    }
    Ok(())
}

fn check_file(
    file: &Path,
    project_root: &Path,
    pnvrc: &Pnvrc,
    env: &dyn Fn(&str) -> Option<String>,
    report: &mut VerifyReport,
) {
    let relative = file.strip_prefix(project_root).unwrap_or(file);
    let relative = relative.display().to_string();

    let source = match fs::read_to_string(file) {
        Ok(source) => source,
        Err(err) => {
            report
                .problems
                .push(format!("{relative}: {}", Error::io("read", file, &err)));
            return;
        }
    };
    let leaves = match yaml::leaves(&source) {
        Ok(leaves) => leaves,
        Err(err) => {
            report
                .problems
                .push(format!("{relative}: not valid YAML: {err}"));
            return;
        }
    };

    // Only ask for a key once the file holds a secret: a plain config file
    // should not need one to be checked.
    let key = if leaves.iter().any(|l| l.is_string && is_secret(&l.text)) {
        let found = KeyLookup::new().file(file).resolve_with(Some(pnvrc), env);
        match found {
            Ok(found) => Some(found.key),
            Err(err) => {
                report.problems.push(format!("{relative}: {err}"));
                None
            }
        }
    } else {
        None
    };

    for leaf in &leaves {
        if !leaf.is_string {
            continue;
        }
        let path = leaf.path.join(".");
        let place = format!("{relative} \u{2192} {path}");

        if is_secret(&leaf.text) {
            report.secrets += 1;
            if let Some(key) = &key
                && let Err(err) = check_secret(&leaf.text, key, &place, pnvrc, env)
            {
                report.problems.push(err);
            }
            continue;
        }

        if let Some(suspicion) = suspect_plaintext(&path, &leaf.text, leaf.comment.as_deref()) {
            report.problems.push(format!(
                "{place}: {}. Encrypt it with `pnv set {path} ... --file {relative}`, or mark \
                 it `# {PLAINTEXT_MARKER}` if it is meant to be public.",
                suspicion.reason
            ));
        }
    }
}

/// Decrypts one secret, returning the problem to report if it does not.
fn check_secret(
    value: &str,
    key: &Key,
    place: &str,
    pnvrc: &Pnvrc,
    env: &dyn Fn(&str) -> Option<String>,
) -> std::result::Result<(), String> {
    let token = Token::parse(value).map_err(|err| err.with_context(place).to_string())?;

    match token.decrypt(key) {
        Ok(_) => Ok(()),
        Err(err @ Error::WrongKey { .. }) => {
            let mut message = err.with_context(place).to_string();
            if let Some(flavor) = flavor_of_key_id(&token, pnvrc, env) {
                message.push_str(&format!(
                    " It was encrypted with the key of flavor \"{flavor}\"."
                ));
            }
            Err(message)
        }
        Err(err) => Err(err.with_context(place).to_string()),
    }
}

/// The flavor whose key made a v1 token, going by the key id.
fn flavor_of_key_id(
    token: &Token,
    pnvrc: &Pnvrc,
    env: &dyn Fn(&str) -> Option<String>,
) -> Option<String> {
    let id = token.key_id()?;
    pnvrc.flavors().iter().find_map(|flavor| {
        let found = KeyLookup::new()
            .flavor(flavor.name())
            .resolve_with(Some(pnvrc), env)
            .ok()?;
        (found.key.id() == id).then(|| flavor.name().to_owned())
    })
}

/// Keys that live inside the repository get committed with it.
fn check_storage(project_root: &Path, pnvrc: &Pnvrc, report: &mut VerifyReport) {
    let Ok(storage) = pnvrc.storage_dir() else {
        return;
    };
    let storage = absolute(&storage);
    let root = absolute(project_root);

    if storage.starts_with(&root) {
        report.problems.push(format!(
            "the key storage directory \"{}\" is inside the project. Keys must live outside \
             the repo.",
            pnvrc.storage()
        ));
    }
}

/// An absolute path with symlinks resolved as far as the path exists, so a
/// storage directory that is not created yet still compares correctly.
fn absolute(path: &Path) -> PathBuf {
    let path = if path.is_absolute() {
        path.to_path_buf()
    } else {
        std::env::current_dir().map_or_else(|_| path.to_path_buf(), |cwd| cwd.join(path))
    };
    let path = normalize(&path);

    let mut missing = Vec::new();
    let mut existing = path.as_path();
    loop {
        if let Ok(real) = existing.canonicalize() {
            return missing.iter().rev().fold(real, |acc, part| acc.join(part));
        }
        match (existing.parent(), existing.file_name()) {
            (Some(parent), Some(name)) => {
                missing.push(name.to_owned());
                existing = parent;
            }
            _ => return path,
        }
    }
}

/// Resolves `.` and `..` by hand.
fn normalize(path: &Path) -> PathBuf {
    use std::path::Component;
    let mut out = PathBuf::new();
    for part in path.components() {
        match part {
            Component::ParentDir => {
                out.pop();
            }
            Component::CurDir => {}
            other => out.push(other),
        }
    }
    out
}
