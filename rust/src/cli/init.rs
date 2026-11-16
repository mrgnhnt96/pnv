use std::fs;
use std::path::{Path, PathBuf};

use clap::Args;
use pnv::{KEY_FILE_EXTENSION, PNVRC_FILE_NAME, Pnvrc};

use super::{Failure, Log, Outcome, current_dir};

/// What pnv adds to `.gitignore`, and why each line is there.
const GITIGNORE_ENTRIES: [(&str, &str); 2] = [
    ("*.key", "pnv encryption keys"),
    ("*.key.previous", "pnv keys kept by `pnv rotate --new-key`"),
];

#[derive(Debug, Args)]
pub struct InitArgs {
    /// Where to keep the encryption keys. Must be outside the repo.
    /// Defaults to `~/.<project directory name>`.
    #[arg(short, long, value_name = "~/.my_project")]
    storage: Option<String>,

    /// A flavor to create. Repeatable, or separate names with commas.
    #[arg(short, long, value_delimiter = ',', value_name = "production")]
    flavor: Vec<String>,

    /// Add pnv key patterns to .gitignore.
    #[arg(long)]
    gitignore: bool,

    /// Accepted for scripts written for the Dart tool; this command never
    /// prompts.
    #[arg(short, long, hide = true)]
    yes: bool,
}

pub fn run(args: &InitArgs, log: &Log) -> Outcome {
    let cwd = current_dir()?;
    let storage = args
        .storage
        .as_deref()
        .map(str::trim)
        .filter(|storage| !storage.is_empty());

    let (path, mut pnvrc, is_new) = match Pnvrc::discover(&cwd)? {
        Some((path, pnvrc)) => {
            if let Some(storage) = storage.filter(|storage| *storage != pnvrc.storage()) {
                log.warn(format!(
                    "\u{26a0} {} already keeps its keys in \"{}\"; ignoring --storage \
                     \"{storage}\".",
                    path.display(),
                    pnvrc.storage()
                ));
            }
            (path, pnvrc, false)
        }
        None => {
            // An empty .pnvrc counts as none, but it still marks the project.
            let path = Pnvrc::find(&cwd).unwrap_or_else(|| cwd.join(PNVRC_FILE_NAME));
            let project = path.parent().unwrap_or(&cwd);
            let storage = storage.map_or_else(|| default_storage(project), str::to_owned);
            (path, Pnvrc::new(storage), true)
        }
    };
    let project = path.parent().map_or_else(|| cwd.clone(), Path::to_path_buf);

    log.info(format!("Initializing pnv in {}...", project.display()));

    let storage_dir = pnvrc.storage_dir()?;
    fs::create_dir_all(&storage_dir).map_err(|err| {
        Failure::Message(format!(
            "Could not create the storage directory \"{}\": {err}",
            storage_dir.display()
        ))
    })?;
    if is_new {
        warn_if_inside(&storage_dir, &project, pnvrc.storage(), log);
    }

    let on_disk = key_files(&storage_dir)?;
    for name in &on_disk {
        if pnvrc.flavor(name).is_some() {
            continue;
        }
        if let Err(err) = pnvrc.add_flavor(name) {
            log.warn(format!("\u{26a0} Skipping key file \"{name}.key\": {err}"));
        }
    }
    let found: Vec<String> = on_disk
        .into_iter()
        .filter(|name| pnvrc.flavor(name).is_some())
        .collect();
    if !found.is_empty() {
        log.info("Found flavors:");
        for name in &found {
            log.info(format!("  {name}"));
        }
    }

    let mut to_create: Vec<String> = pnvrc
        .flavors()
        .iter()
        .map(|flavor| flavor.name().to_owned())
        .filter(|name| !found.contains(name))
        .collect();
    for name in args.flavor.iter().map(|name| name.trim()) {
        if name.is_empty() || found.iter().any(|f| f == name) || to_create.iter().any(|f| f == name)
        {
            continue;
        }
        pnvrc.add_flavor(name)?;
        to_create.push(name.to_owned());
    }

    for name in &to_create {
        pnv::write_key_file(pnvrc.key_file(name)?, &pnv::create_key()?)?;
        log.info(format!("\u{2713} Created flavor {name}"));
    }

    pnvrc.save(&path)?;
    log.detail(format!("Wrote {}", path.display()));

    if args.gitignore {
        add_gitignore_entries(&project, log)?;
    }

    Ok(())
}

/// `~/.<name of the project directory>`, as the Dart tool uses the package
/// name.
fn default_storage(project: &Path) -> String {
    let name = project
        .file_name()
        .map(|name| name.to_string_lossy().into_owned())
        .filter(|name| !name.is_empty())
        .unwrap_or_else(|| "pnv".to_owned());
    format!("~/.{name}")
}

/// The flavors that have a key file in `dir`, sorted by name.
fn key_files(dir: &Path) -> Result<Vec<String>, Failure> {
    let entries = fs::read_dir(dir)
        .map_err(|err| Failure::Message(format!("Could not read \"{}\": {err}", dir.display())))?;

    let mut names: Vec<String> = entries
        .filter_map(Result::ok)
        .map(|entry| entry.path())
        .filter(|path| path.is_file())
        .filter(|path| {
            path.extension()
                .is_some_and(|ext| ext == KEY_FILE_EXTENSION)
        })
        .filter_map(|path| Some(path.file_stem()?.to_string_lossy().into_owned()))
        .collect();
    names.sort();
    Ok(names)
}

fn warn_if_inside(storage: &Path, project: &Path, written: &str, log: &Log) {
    let (Ok(storage), Ok(project)) = (storage.canonicalize(), project.canonicalize()) else {
        return;
    };
    if storage.starts_with(&project) {
        log.warn(format!(
            "\u{26a0} \"{written}\" is inside the project. Keys stored there are one `git add` \
             away from being published. Prefer somewhere under your home directory."
        ));
    }
}

/// Appends pnv's key patterns to `.gitignore`, skipping any already there.
fn add_gitignore_entries(project: &Path, log: &Log) -> Outcome {
    let path: PathBuf = project.join(".gitignore");
    let existing = match fs::read_to_string(&path) {
        Ok(text) => text,
        Err(err) if err.kind() == std::io::ErrorKind::NotFound => String::new(),
        Err(err) => return Err(format!("Could not read \"{}\": {err}", path.display()).into()),
    };

    // Compare the pattern only: each entry is written with a trailing
    // comment, so matching whole lines would never see its own output.
    let patterns: Vec<&str> = existing
        .lines()
        .map(|line| line.split('#').next().unwrap_or_default().trim())
        .collect();
    let missing: Vec<_> = GITIGNORE_ENTRIES
        .iter()
        .filter(|(pattern, _)| !patterns.contains(pattern))
        .collect();

    if missing.is_empty() {
        log.detail(".gitignore already covers pnv keys");
        return Ok(());
    }

    let mut text = existing;
    if !text.is_empty() && !text.ends_with('\n') {
        text.push('\n');
    }
    text.push_str("\n# pnv\n");
    for (pattern, why) in &missing {
        text.push_str(&format!("{pattern} # {why}\n"));
    }

    fs::write(&path, text).map_err(|err| {
        Failure::Message(format!("Could not write \"{}\": {err}", path.display()))
    })?;

    let added: Vec<_> = missing.iter().map(|(pattern, _)| *pattern).collect();
    log.info(format!("\u{2713} Added {} to .gitignore", added.join(", ")));
    Ok(())
}
