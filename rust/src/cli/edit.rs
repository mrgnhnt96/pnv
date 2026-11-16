//! `pnv set`, `pnv get` and `pnv show`: one value of a YAML file, or all of
//! it, without disturbing the rest.

use std::io::BufRead;
use std::path::{Path, PathBuf};

use clap::Args;

use super::generate::is_yaml;
use super::{Failure, KeyArgs, Log, Outcome};

#[derive(Debug, Args)]
pub struct SetArgs {
    #[command(flatten)]
    key: KeyArgs,

    /// The .yaml file to set the value in.
    #[arg(
        short = 'i',
        long,
        visible_alias = "input",
        value_name = "envs/app.local.yaml"
    )]
    file: Option<PathBuf>,

    /// Read the value from stdin instead of an argument. Use this for values
    /// too long or awkward to quote.
    #[arg(long)]
    stdin: bool,

    /// Write the value unencrypted. For config that lives beside secrets and
    /// is not one.
    #[arg(long)]
    plain: bool,

    /// The key path, such as app.api-key.
    path: Option<String>,

    /// The value. More than one word is joined with spaces.
    value: Vec<String>,
}

#[derive(Debug, Args)]
pub struct GetArgs {
    #[command(flatten)]
    key: KeyArgs,

    /// The .yaml file to read the value from.
    #[arg(
        short = 'i',
        long,
        visible_alias = "input",
        value_name = "envs/app.local.yaml"
    )]
    file: Option<PathBuf>,

    /// The key path, such as app.api-key.
    path: Option<String>,
}

#[derive(Debug, Args)]
pub struct ShowArgs {
    #[command(flatten)]
    key: KeyArgs,

    /// The .yaml file to show.
    #[arg(
        short = 'i',
        long = "file",
        visible_alias = "input",
        value_name = "envs/app.local.yaml"
    )]
    file_flag: Option<PathBuf>,

    /// The .yaml file to show. Given bare, as git's textconv passes it.
    file: Option<PathBuf>,
}

pub fn set(args: &SetArgs, log: &Log) -> Outcome {
    let path = args.path.as_deref().ok_or(
        "Missing the key path. Try: pnv set app.api-key \"value\" --file envs/app.local.yaml",
    )?;
    let file = target_file(args.file.as_deref())?;

    let value = if args.stdin {
        read_line()?
    } else if args.value.is_empty() {
        return Err("Missing the value. Pass it as an argument, or use --stdin.".into());
    } else {
        args.value.join(" ")
    };

    let mut doc = pnv::Document::read(file)?;
    let key_path = segments_shown(path);

    // Check the path against the file before looking for a key, so a path
    // that cannot be set is reported as that rather than as a missing key.
    doc.clone().set(path, "")?;

    let stored = if args.plain {
        value
    } else {
        pnv::encrypt(&value, &key_for(&args.key, file)?)?
    };
    doc.set(path, &stored)?;

    std::fs::write(file, doc.as_str()).map_err(|err| {
        Failure::Message(format!("Could not write \"{}\": {err}", file.display()))
    })?;

    let verb = if args.plain { "Set" } else { "Encrypted" };
    log.info(format!(
        "\u{2713} {verb} {} \u{2192} {key_path}",
        file.display()
    ));
    Ok(())
}

pub fn get(args: &GetArgs, log: &Log) -> Outcome {
    let path = args
        .path
        .as_deref()
        .ok_or("Missing the key path. Try: pnv get app.api-key --file envs/app.local.yaml")?;
    let file = target_file(args.file.as_deref())?;

    let value = pnv::Document::read(file)?.get(path)?;

    let text = match value {
        pnv::Value::String(text) if pnv::is_secret(&text) => {
            let key = key_for(&args.key, file)?;
            let at = format!("{} \u{2192} {}", file.display(), segments_shown(path));
            pnv::decrypt(&text, &key).map_err(|err| err.with_context(at))?
        }
        // Plain config lives in these files too, and reads back the same
        // way. Null prints as the Dart tool prints it.
        pnv::Value::Null => "null".to_owned(),
        other => other.to_string(),
    };

    log.out(text);
    Ok(())
}

pub fn show(args: &ShowArgs, log: &Log) -> Outcome {
    // The path is taken bare as well as with --file: git's textconv driver
    // appends the file as a bare argument and cannot be told otherwise.
    let file = args
        .file_flag
        .as_deref()
        .or(args.file.as_deref())
        .ok_or("Name the .yaml file to show.")?;
    if !file.is_file() {
        return Err(format!("Input file \"{}\" does not exist.", file.display()).into());
    }

    let doc = pnv::Document::read(file)?;

    // A file with no secrets, including one that is not YAML at all, is
    // printed exactly as it is: a textconv driver must always print
    // something readable, or the diff shows nothing.
    if !doc.has_secrets() {
        log.write(doc.as_str());
        return Ok(());
    }

    let key = key_for(&args.key, file)?;
    log.write(doc.decrypted(&key)?);
    Ok(())
}

/// The `--file` to act on: present, existing and a .yaml file.
fn target_file(file: Option<&Path>) -> Result<&Path, Failure> {
    let file = file
        .filter(|file| !file.as_os_str().is_empty())
        .ok_or("--file is required.")?;
    if !file.is_file() {
        return Err(format!("Input file \"{}\" does not exist.", file.display()).into());
    }
    if !is_yaml(file) {
        return Err(format!("Input file \"{}\" must be a .yaml file.", file.display()).into());
    }
    Ok(file)
}

/// The key the flags name, or else the one the file's name implies, as
/// `generate env` finds it.
fn key_for(key: &KeyArgs, file: &Path) -> Result<pnv::Key, Failure> {
    let lookup = key
        .lookup()
        .unwrap_or_else(|| pnv::KeyLookup::new().file(file));
    Ok(lookup.resolve()?.key)
}

/// One line of stdin, without its line break.
fn read_line() -> Result<String, Failure> {
    let mut line = String::new();
    std::io::stdin()
        .lock()
        .read_line(&mut line)
        .map_err(|err| Failure::Message(format!("Could not read stdin: {err}")))?;
    if line.ends_with('\n') {
        line.pop();
        if line.ends_with('\r') {
            line.pop();
        }
    }
    Ok(line)
}

/// A key path with each part trimmed, as it is stored.
fn segments_shown(path: &str) -> String {
    path.split('.').map(str::trim).collect::<Vec<_>>().join(".")
}
